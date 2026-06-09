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

public:
    CCandleProvider(CLogger *logger, int maxCandles)
        : m_logger(logger), m_maxCandles(maxCandles) {}

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

        ArraySetAsSeries(rates, false); // orden cronológico ascendente

        int copied = CopyRates(symbol, period, from_dt, to_dt, rates);

        if(copied <= 0) {
            m_logger.Warning(StringFormat(
                "GetCandles: CopyRates devolvió %d para %s/%s [%d-%d] error=%d",
                copied, symbol, EnumToString(period),
                from_ts, to_ts, GetLastError()));
            return -1;
        }

        m_logger.Debug(StringFormat(
            "GetCandles: %d velas obtenidas para %s/%s",
            copied, symbol, EnumToString(period)));

        return copied;
    }

    // Indica si el código de retorno es un error de "sin datos" (vs. error técnico)
    bool IsNoDataError(int result) { return result == -1; }

    // Indica si el código de retorno es un error de límite superado
    bool IsLimitError(int result)  { return result == -2; }
};

#endif // CANDLEPROVIDER_MQH
