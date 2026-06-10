# Construir módulo del EA

Construye un módulo del Expert Advisor en el orden correcto.

## Uso

`/build-ea <nombre>` — en este orden obligatorio:

1. `logger`         → `MQL5/Include/TradingDataServer/Logger.mqh`
2. `json-handler`   → `MQL5/Include/TradingDataServer/JSONHandler.mqh`
3. `candle-provider`→ `MQL5/Include/TradingDataServer/CandleProvider.mqh`
4. `tcp-server`     → `MQL5/Include/TradingDataServer/TCPServer.mqh`
5. `main-ea`        → `MQL5/Experts/TradingDataServer/TradingDataServer.mq5`
6. `test-script`    → `tests/test_protocol.py`
7. `docs`           → `docs/installation.md` + `docs/protocol.md`

## Proceso para cada módulo

1. Leer CLAUDE.md y las reglas en `.claude/rules/`
2. Revisar módulos ya escritos para mantener consistencia
3. Escribir el módulo completo
4. Verificar que no hay llamadas a funciones de trading
5. Verificar que los timestamps usan UTC
6. Reportar qué se construyó y qué construir a continuación

## Notas importantes

- `Logger.mqh` primero — todos los demás lo usan
- `JSONHandler.mqh` antes que `TCPServer.mqh` — el server usa el handler
- `CandleProvider.mqh` antes que `TCPServer.mqh` — el server usa el provider
- `TradingDataServer.mq5` último — orquesta todo lo demás
- El script Python de tests va después del EA completo
