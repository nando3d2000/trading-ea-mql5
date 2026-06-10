# Reglas del protocolo TCP/JSON

## Framing de mensajes

El protocolo usa longitud fija de 4 bytes (big-endian) como header
seguido del payload JSON. Esto evita el problema de saber cuándo
termina un mensaje TCP.

```
[4 bytes longitud big-endian][payload JSON UTF-8]
```

El data-ingestor (Python) ya implementa este protocolo en `mt5_client.py`.
El EA MQL5 debe implementar exactamente el mismo framing.

```mql5
// Leer mensaje completo
bool ReadMessage(ClientSocket *client, string &message) {
    uchar header[4];
    if(client.Receive(header, 4) != 4) return false;

    uint length = (uint)header[0] << 24 |
                  (uint)header[1] << 16 |
                  (uint)header[2] << 8  |
                  (uint)header[3];

    if(length == 0 || length > 10*1024*1024) return false;  // max 10MB

    uchar buffer[];
    ArrayResize(buffer, length);
    if(client.Receive(buffer, length) != (int)length) return false;

    message = CharArrayToString(buffer, 0, length, CP_UTF8);
    return true;
}

// Enviar respuesta con header de longitud
bool SendMessage(ClientSocket *client, string response) {
    uchar payload[];
    StringToCharArray(response, payload, 0, StringLen(response), CP_UTF8);

    uint length = ArraySize(payload);
    uchar header[4];
    header[0] = (uchar)((length >> 24) & 0xFF);
    header[1] = (uchar)((length >> 16) & 0xFF);
    header[2] = (uchar)((length >>  8) & 0xFF);
    header[3] = (uchar)( length        & 0xFF);

    client.Send(header, 4);
    client.Send(payload, length);
    return true;
}
```

## Parsing de peticiones

El protocolo tiene solo 2 acciones — el parser puede ser simple:

```mql5
// Extraer valor de campo JSON simple (string)
string ExtractString(string json, string key) {
    string search = "\"" + key + "\":\"";
    int start = StringFind(json, search);
    if(start < 0) return "";
    start += StringLen(search);
    int end = StringFind(json, "\"", start);
    if(end < 0) return "";
    return StringSubstr(json, start, end - start);
}

// Extraer valor numérico
long ExtractLong(string json, string key) {
    string search = "\"" + key + "\":";
    int start = StringFind(json, search);
    if(start < 0) return 0;
    start += StringLen(search);
    int end = start;
    while(end < StringLen(json) &&
          (StringGetCharacter(json, end) == '-' ||
           (StringGetCharacter(json, end) >= '0' &&
            StringGetCharacter(json, end) <= '9'))) end++;
    return StringToInteger(StringSubstr(json, start, end - start));
}
```

## Respuestas de error estándar

```mql5
// Siempre usar estas constantes para errores
#define ERR_UNKNOWN_ACTION    "{\"status\":\"error\",\"message\":\"Unknown action\"}"
#define ERR_MISSING_SYMBOL    "{\"status\":\"error\",\"message\":\"Symbol parameter missing\"}"
#define ERR_SYMBOL_NOT_FOUND  "{\"status\":\"error\",\"message\":\"Symbol not found in broker\"}"
#define ERR_NO_DATA           "{\"status\":\"error\",\"message\":\"No data available for range\"}"
#define ERR_INVALID_TIMEFRAME "{\"status\":\"error\",\"message\":\"Invalid timeframe\"}"
#define ERR_TOO_MANY_CANDLES  "{\"status\":\"error\",\"message\":\"Request exceeds MAX_CANDLES_PER_REQUEST\"}"
```

## Mapeo de timeframes

```mql5
ENUM_TIMEFRAMES StringToTimeframe(string tf) {
    if(tf == "M1")  return PERIOD_M1;
    if(tf == "M5")  return PERIOD_M5;
    if(tf == "M15") return PERIOD_M15;
    if(tf == "M30") return PERIOD_M30;
    if(tf == "H1")  return PERIOD_H1;
    if(tf == "H4")  return PERIOD_H4;
    if(tf == "D1")  return PERIOD_D1;
    if(tf == "W1")  return PERIOD_W1;
    return PERIOD_CURRENT;  // inválido
}
```

## Límites de seguridad

- Máximo 10MB por mensaje recibido — rechazar y cerrar conexión
- Máximo MAX_CANDLES_PER_REQUEST velas por respuesta (default 5000)
- Timeout de lectura: 30 segundos — cerrar si el cliente no envía
- Máximo 10 conexiones concurrentes — rechazar si se supera
