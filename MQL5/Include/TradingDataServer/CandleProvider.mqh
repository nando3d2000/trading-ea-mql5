//+------------------------------------------------------------------+
//| CandleProvider.mqh — Obtiene velas OHLCV del histórico de MT5   |
//+------------------------------------------------------------------+
#ifndef CANDLEPROVIDER_MQH
#define CANDLEPROVIDER_MQH

#include "Logger.mqh"

class CCandleProvider {
private:
    CLogger *m_logger;
    int      m_maxCandles;
    int      m_syncRetries;   // intentos de espera de sincronización del histórico
    int      m_syncSleepMs;   // ms entre intentos

    // Verifica que el símbolo existe en el broker y tiene datos disponibles
    bool ValidateSymbol(string symbol) {
        if(!SymbolSelect(symbol, true)) {
            m_logger.Warning("ValidateSymbol: SymbolSelect falló para " + symbol +
                             " error=" + IntegerToString(GetLastError()));
            return false;
        }
        return true;
    }

    // Calcula cuántas velas caben en el rango y verifica el límite
    bool CheckCandleLimit(string symbol, ENUM_TIMEFRAMES period,
                          datetime from_dt, datetime to_dt, int &estimated) {
        int periodSec = PeriodSeconds(period);
        if(periodSec <= 0) return false;

        estimated = (int)((to_dt - from_dt) / periodSec) + 1;
        if(estimated > m_maxCandles) {
            m_logger.Warning(StringFormat(
                "CheckCandleLimit: rango solicita ~%d velas, límite es %d",
                estimated, m_maxCandles));
            return false;
        }
        return true;
    }

    // MT5 descarga el histórico de forma ASÍNCRONA: el primer acceso a un rango
    // viejo dispara la descarga y CopyRates puede devolver 0 hasta que termine.
    // Esperamos (acotado) a que la serie quede sincronizada antes de leer, para
    // no reportar "sin datos" en rangos que en realidad aún se están bajando.
    // Retorna true si la serie está sincronizada con el servidor.
    bool EnsureHistory(string symbol, ENUM_TIMEFRAMES period, datetime from_dt) {
        datetime probe[];
        for(int i = 0; i < m_syncRetries; i++) {
            // Dispara la descarga cerca del inicio del rango solicitado
            CopyRates(symbol, period, from_dt, 1, probe);
            if(SeriesInfoInteger(symbol, period, SERIES_SYNCHRONIZED) != 0)
                return true;
            Sleep(m_syncSleepMs);
        }
        m_logger.Warning(StringFormat(
            "EnsureHistory: %s/%s no sincronizado tras %d intentos",
            symbol, EnumToString(period), m_syncRetries));
        return false;
    }

public:
    CCandleProvider(CLogger *logger, int maxCandles)
        : m_logger(logger), m_maxCandles(maxCandles),
          m_syncRetries(30), m_syncSleepMs(100) {}

    // Obtiene velas en el rango [from_ts, to_ts] (Unix UTC, inclusivo)
    // Retorna el número de velas copiadas, o -1 en error
    // El resultado se deposita en rates[] en orden cronológico ascendente
    int GetCandles(string symbol, ENUM_TIMEFRAMES period,
                   long from_ts, long to_ts, MqlRates &rates[]) {

        // Conversión directa: datetime de MT5 == Unix UTC sin ajuste
        datetime from_dt = (datetime)from_ts;
        datetime to_dt   = (datetime)to_ts;

        if(from_dt >= to_dt) {
            m_logger.Warning(StringFormat(
                "GetCandles: rango inválido from=%d to=%d", from_ts, to_ts));
            return -1;
        }

        if(!ValidateSymbol(symbol)) return -1;

        int estimated = 0;
        if(!CheckCandleLimit(symbol, period, from_dt, to_dt, estimated)) return -2;

        // Garantiza que el histórico del rango esté descargado antes de leer
        bool synced = EnsureHistory(symbol, period, from_dt);

        ArraySetAsSeries(rates, false); // orden cronológico ascendente

        int copied = CopyRates(symbol, period, from_dt, to_dt, rates);

        if(copied < 0) {
            m_logger.Warning(StringFormat(
                "GetCandles: CopyRates error para %s/%s [%d-%d] error=%d",
                symbol, EnumToString(period), from_ts, to_ts, GetLastError()));
            return -1;
        }

        if(copied == 0) {
            // 0 velas: distinguir "rango realmente vacío" (fin de semana, antes
            // del histórico del broker) de "todavía descargando" (reintentable)
            if(!synced) {
                m_logger.Warning(StringFormat(
                    "GetCandles: %s/%s sin sincronizar, rango [%d-%d] reintentable",
                    symbol, EnumToString(period), from_ts, to_ts));
                return -3;
            }
            m_logger.Debug(StringFormat(
                "GetCandles: rango vacío (sincronizado) para %s/%s [%d-%d]",
                symbol, EnumToString(period), from_ts, to_ts));
            return 0; // vacío legítimo
        }

        m_logger.Debug(StringFormat(
            "GetCandles: %d velas obtenidas para %s/%s",
            copied, symbol, EnumToString(period)));

        return copied;
    }

    // Retorna el timestamp de la vela más antigua que el BROKER ofrece para el
    // símbolo/timeframe (SERIES_SERVER_FIRSTDATE), no solo lo cargado localmente.
    // Retorna 0 si no se puede determinar.
    datetime GetOldestServerTs(string symbol, ENUM_TIMEFRAMES period) {
        if(!ValidateSymbol(symbol)) return 0;

        datetime serverOldest = 0;
        datetime probe[];
        for(int i = 0; i < m_syncRetries; i++) {
            serverOldest = (datetime)SeriesInfoInteger(
                symbol, period, SERIES_SERVER_FIRSTDATE);
            if(serverOldest > 0) break;
            // Dispara la sincronización y espera
            CopyRates(symbol, period, 0, 1, probe);
            Sleep(m_syncSleepMs);
        }

        // Fallback: lo más antiguo cargado localmente
        if(serverOldest == 0)
            serverOldest = (datetime)SeriesInfoInteger(
                symbol, period, SERIES_FIRSTDATE);

        return serverOldest;
    }

    // Indica si el código de retorno es un error de "sin datos" (vs. error técnico)
    bool IsNoDataError(int result) { return result == -1; }

    // Indica si el código de retorno es un error de límite superado
    bool IsLimitError(int result)  { return result == -2; }

    // Indica que el histórico aún no está sincronizado (reintentar más tarde)
    bool IsNotSyncedError(int result) { return result == -3; }
};

#endif // CANDLEPROVIDER_MQH
