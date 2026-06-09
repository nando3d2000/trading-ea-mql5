# CLAUDE.md — trading-ea-mql5

Expert Advisor para MetaTrader 5 que actúa como servidor TCP.
Recibe peticiones JSON del `data-ingestor` (Python) y responde
con velas OHLCV extraídas del histórico interno de MT5.

**Repositorio:** https://github.com/nando3d2000/trading-ea-mql5

## Propósito

Este EA NO opera — no abre ni cierra trades.
Su única responsabilidad es:
1. Escuchar conexiones TCP en el puerto 9090
2. Recibir peticiones JSON del data-ingestor
3. Consultar el histórico de MT5 con CopyRates()
4. Responder con las velas OHLCV en formato JSON

## Infraestructura

- MT5 corre bajo Wine en Lubuntu 26.04 (host: 192.168.1.14)
- El EA se adjunta al chart EURUSD H1 — desde ahí sirve todos los símbolos
- El data-ingestor (Docker) se conecta vía `host.docker.internal:9090`
- Puerto TCP: 9090

## Símbolos soportados

El EA sirve cualquier símbolo disponible en el broker.
Los 5 del catálogo inicial:
- EURUSD, GBPUSD, USDJPY, XAUUSD, US500

## Timeframes soportados

M1, M5, M15, M30, H1, H4, D1, W1
Mapeados a los ENUM_TIMEFRAMES de MQL5:
PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30,
PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1

## Protocolo TCP — JSON

### Petición (data-ingestor → EA)
```json
{
  "action": "get_candles",
  "symbol": "EURUSD",
  "timeframe": "H1",
  "from_ts": 1704067200,
  "to_ts": 1704153600
}
```

### Respuesta exitosa (EA → data-ingestor)
```json
{
  "status": "ok",
  "symbol": "EURUSD",
  "timeframe": "H1",
  "count": 24,
  "candles": [
    {
      "ts": 1704067200,
      "open": 1.10500,
      "high": 1.10650,
      "low": 1.10480,
      "close": 1.10620,
      "volume": 1250,
      "tick_volume": 3400
    }
  ]
}
```

### Respuesta de error (EA → data-ingestor)
```json
{
  "status": "error",
  "message": "Symbol EURUSD not found or no data available"
}
```

### Ping de health check
```json
// Petición
{"action": "ping"}

// Respuesta
{"status": "ok", "message": "pong"}
```

## Estructura de archivos

```
MQL5/
  Experts/
    TradingDataServer/
      TradingDataServer.mq5    ← EA principal (OnInit, OnDeinit, OnTimer)
  Include/
    TradingDataServer/
      TCPServer.mqh            ← manejo de ServerSocket y conexiones
      JSONHandler.mqh          ← parser y builder de JSON
      CandleProvider.mqh       ← CopyRates + conversión de timestamps
      Logger.mqh               ← logging a archivo y Print()
docs/
  architecture.md
  protocol.md
  installation.md
tests/
  test_protocol.py             ← script Python para probar el EA manualmente
README.md
```

## Instalación en MT5

1. Copiar `MQL5/Experts/TradingDataServer/` a la carpeta Experts de MT5
2. Copiar `MQL5/Include/TradingDataServer/` a la carpeta Include de MT5
3. Compilar `TradingDataServer.mq5` en MetaEditor (F7)
4. Abrir chart EURUSD H1 en MT5
5. Arrastrar el EA al chart
6. Verificar que aparece la carita sonriente en la esquina superior derecha
7. Revisar la pestaña Experts para confirmar "Server started on port 9090"

## Parámetros configurables del EA

| Parámetro | Default | Descripción |
|---|---|---|
| TCP_PORT | 9090 | Puerto de escucha |
| MAX_CANDLES_PER_REQUEST | 5000 | Límite de velas por petición |
| TIMER_INTERVAL_MS | 100 | Frecuencia del OnTimer en ms |
| LOG_TO_FILE | true | Guardar logs en archivo |
| LOG_LEVEL | INFO | DEBUG / INFO / WARNING / ERROR |

## Reglas absolutas

- Ver `.claude/rules/` antes de escribir cualquier archivo
- El EA nunca abre órdenes — sin OrderSend(), sin trades
- Siempre responder JSON válido — nunca dejar la conexión colgada
- Timestamps siempre en Unix UTC — nunca timestamps locales
- Manejar símbolos no disponibles con error JSON, no con crash
- Compilar sin warnings en MetaEditor antes de dar por terminado
