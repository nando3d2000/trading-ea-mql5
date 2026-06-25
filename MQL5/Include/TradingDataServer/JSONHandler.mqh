//+------------------------------------------------------------------+
//| JSONHandler.mqh — Parser y builder de JSON para TradingDataServer|
//+------------------------------------------------------------------+
#ifndef JSONHANDLER_MQH
#define JSONHANDLER_MQH

#include "Logger.mqh"

// Respuestas de error estándar — siempre JSON válido
#define ERR_UNKNOWN_ACTION    "{\"status\":\"error\",\"message\":\"Unknown action\"}"
#define ERR_MISSING_SYMBOL    "{\"status\":\"error\",\"message\":\"Symbol parameter missing\"}"
#define ERR_MISSING_TIMEFRAME "{\"status\":\"error\",\"message\":\"Timeframe parameter missing\"}"
#define ERR_SYMBOL_NOT_FOUND  "{\"status\":\"error\",\"message\":\"Symbol not found in broker\"}"
#define ERR_NO_DATA           "{\"status\":\"error\",\"message\":\"No data available for range\"}"
#define ERR_INVALID_TIMEFRAME "{\"status\":\"error\",\"message\":\"Invalid timeframe\"}"
#define ERR_TOO_MANY_CANDLES  "{\"status\":\"error\",\"message\":\"Request exceeds MAX_CANDLES_PER_REQUEST\"}"
#define ERR_NOT_SYNCED        "{\"status\":\"error\",\"message\":\"History not synchronized yet\"}"

struct TradingRequest {
    string action;
    string symbol;
    string timeframe;
    long   from_ts;
    long   to_ts;
};

class CJSONHandler {
private:
    CLogger *m_logger;

    // Extrae el valor string de una clave JSON simple (sin anidamiento)
    // Tolera espacios después de los dos puntos: "key": "value" y "key":"value"
    string ExtractString(const string &json, string key) {
        string search = "\"" + key + "\":";
        int start = StringFind(json, search);
        if(start < 0) return "";
        start += StringLen(search);
        // Saltar espacios opcionales entre ':' y '"'
        while(start < StringLen(json) &&
              StringGetCharacter(json, start) == ' ') start++;
        // Debe seguir una comilla de apertura
        if(start >= StringLen(json) ||
           StringGetCharacter(json, start) != '"') return "";
        start++; // saltar comilla de apertura
        int end = StringFind(json, "\"", start);
        if(end < 0) return "";
        return StringSubstr(json, start, end - start);
    }

    // Extrae el valor numérico entero de una clave JSON
    long ExtractLong(const string &json, string key) {
        string search = "\"" + key + "\":";
        int start = StringFind(json, search);
        if(start < 0) return 0;
        start += StringLen(search);
        // Saltar espacios
        while(start < StringLen(json) &&
              StringGetCharacter(json, start) == ' ') start++;
        int end = start;
        ushort c = StringGetCharacter(json, end);
        // Avanzar mientras sea dígito o signo negativo
        while(end < StringLen(json) &&
              (c == '-' || (c >= '0' && c <= '9'))) {
            end++;
            c = StringGetCharacter(json, end);
        }
        if(end == start) return 0;
        return StringToInteger(StringSubstr(json, start, end - start));
    }

    // Serializa una sola vela como objeto JSON
    string CandleToJSON(const MqlRates &rate) {
        return StringFormat(
            "{\"ts\":%d,\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,"
            "\"close\":%.5f,\"volume\":%.2f,\"tick_volume\":%d}",
            (long)rate.time,
            rate.open, rate.high, rate.low, rate.close,
            (double)rate.real_volume,
            (long)rate.tick_volume
        );
    }

public:
    CJSONHandler(CLogger *logger) : m_logger(logger) {}

    // Parsea el JSON de la petición y rellena la estructura TradingRequest
    bool ParseRequest(const string &json, TradingRequest &req) {
        req.action    = ExtractString(json, "action");
        req.symbol    = ExtractString(json, "symbol");
        req.timeframe = ExtractString(json, "timeframe");
        req.from_ts   = ExtractLong(json, "from_ts");
        req.to_ts     = ExtractLong(json, "to_ts");

        if(req.action == "") {
            m_logger.Warning("ParseRequest: campo 'action' no encontrado en JSON");
            return false;
        }
        return true;
    }

    // Convierte string de timeframe al ENUM_TIMEFRAMES de MQL5
    ENUM_TIMEFRAMES ParseTimeframe(string tf) {
        if(tf == "M1")  return PERIOD_M1;
        if(tf == "M5")  return PERIOD_M5;
        if(tf == "M15") return PERIOD_M15;
        if(tf == "M30") return PERIOD_M30;
        if(tf == "H1")  return PERIOD_H1;
        if(tf == "H4")  return PERIOD_H4;
        if(tf == "D1")  return PERIOD_D1;
        if(tf == "W1")  return PERIOD_W1;
        return PERIOD_CURRENT; // señal de timeframe inválido
    }

    // Construye la respuesta JSON con el array de velas
    // NOTA: se usa concatenación directa — StringFormat tiene un límite
    // de ~4096 chars de salida y truncaría respuestas grandes
    string BuildCandlesResponse(string symbol, string timeframe,
                                MqlRates &rates[], int count) {
        string candles = "";
        for(int i = 0; i < count; i++) {
            if(i > 0) candles += ",";
            candles += CandleToJSON(rates[i]);
        }

        return "{\"status\":\"ok\",\"symbol\":\"" + symbol +
               "\",\"timeframe\":\"" + timeframe +
               "\",\"count\":" + IntegerToString(count) +
               ",\"candles\":[" + candles + "]}";
    }

    // Construye una respuesta de error con el mensaje indicado
    string BuildErrorResponse(string message) {
        // Escapar comillas dobles en el mensaje por seguridad
        StringReplace(message, "\"", "'");
        return StringFormat("{\"status\":\"error\",\"message\":\"%s\"}", message);
    }

    // Respuesta al ping de health check
    string BuildPongResponse() {
        return "{\"status\":\"ok\",\"message\":\"pong\"}";
    }
};

#endif // JSONHANDLER_MQH
