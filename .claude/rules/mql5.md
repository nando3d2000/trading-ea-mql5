# Reglas de código MQL5

## Estilo general

- MQL5 moderno — usar clases y estructuras, no solo funciones globales
- Un archivo `.mqh` por responsabilidad — no mezclar TCP con parsing JSON
- Nombres en inglés, PascalCase para clases, camelCase para métodos
- Constantes en UPPER_SNAKE_CASE
- Comentarios en español para explicar lógica de negocio
- Máximo 80 líneas por función — si crece, extraer método privado

## Manejo de errores

- Nunca ignorar el valor de retorno de CopyRates() — verificar siempre
- Si CopyRates() retorna -1: loggear el error y responder JSON de error
- Si ServerSocket falla: loggear y reintentar en el siguiente OnTimer()
- El EA nunca debe crashear MT5 — capturar todos los errores posibles
- Usar GetLastError() después de cada operación crítica

## Sockets TCP en MQL5

```mql5
// Patrón correcto para ServerSocket
ServerSocket server(TCP_PORT, false);
if(!server.Created()) {
    Print("ERROR: No se pudo crear servidor en puerto ", TCP_PORT);
    return INIT_FAILED;
}

// En OnTimer() — aceptar conexiones no bloqueante
ClientSocket *client = server.Accept();
if(client != NULL) {
    // procesar petición
    delete client;
}
```

## Timestamps — crítico

MT5 usa `datetime` que es segundos desde 1970-01-01 00:00 UTC.
Coincide con Unix timestamp — NO hay conversión necesaria.

```mql5
// Convertir Unix timestamp a datetime de MQL5
datetime dt = (datetime)unix_ts;  // cast directo

// Convertir datetime a Unix timestamp para JSON
long unix_ts = (long)dt;          // cast directo
```

NUNCA usar TimeLocal() — siempre TimeGMT() o los timestamps del histórico.

## CopyRates — patrón correcto

```mql5
MqlRates rates[];
ArraySetAsSeries(rates, false);  // orden cronológico ascendente

int copied = CopyRates(
    symbol,           // "EURUSD"
    period,           // PERIOD_H1
    from_datetime,    // inicio
    to_datetime,      // fin
    rates
);

if(copied <= 0) {
    // error — GetLastError() para detalles
    return false;
}
```

## JSON en MQL5

No hay librería nativa. Usar construcción manual para respuestas
y parsing manual simple para peticiones (el protocolo es fijo).

```mql5
// Builder de JSON — siempre escapar strings
string BuildCandleJSON(MqlRates &rate) {
    return StringFormat(
        "{\"ts\":%d,\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f,\"volume\":%.2f,\"tick_volume\":%d}",
        (long)rate.time,
        rate.open, rate.high, rate.low, rate.close,
        (double)rate.real_volume,
        (long)rate.tick_volume
    );
}
```

## Logging

```mql5
// Siempre incluir timestamp y contexto
void Log(string level, string message) {
    string line = StringFormat("[%s] %s: %s",
        TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS),
        level,
        message
    );
    Print(line);
    if(LOG_TO_FILE) {
        // escribir a archivo en MQL5/Files/
    }
}
```

## Lo que el EA NUNCA hace

- OrderSend() — prohibido
- OrderModify() — prohibido
- OrderClose() — prohibido
- AccountBalance() para tomar decisiones — prohibido
- Cualquier operación de trading — prohibido
