# Protocolo TCP — TradingDataServer

## Transporte

- **Puerto:** 9090 (configurable via parámetro `TCP_PORT`)
- **Dirección:** el EA escucha en `0.0.0.0:9090`; el data-ingestor conecta a `host.docker.internal:9090`
- **Modelo:** una petición → una respuesta → conexión cerrada
- **Concurrencia:** máximo 10 conexiones simultáneas

## Framing de mensajes

Todos los mensajes (petición y respuesta) usan el mismo framing:

```
┌─────────────────────────────┬──────────────────────────────────┐
│  4 bytes (big-endian uint)  │  N bytes (JSON UTF-8)            │
│  longitud del payload       │  payload                         │
└─────────────────────────────┴──────────────────────────────────┘
```

### Implementación en Python

```python
import json, socket, struct

def send_request(sock: socket.socket, request: dict) -> dict:
    payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
    sock.sendall(struct.pack(">I", len(payload)) + payload)

    # Leer respuesta
    length = struct.unpack(">I", _recv_exact(sock, 4))[0]
    return json.loads(_recv_exact(sock, length).decode("utf-8"))

def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("Conexión cerrada prematuramente")
        buf += chunk
    return buf
```

---

## Acciones

### `ping` — Health check

**Petición:**
```json
{"action": "ping"}
```

**Respuesta:**
```json
{"status": "ok", "message": "pong"}
```

---

### `get_candles` — Obtener velas OHLCV

**Petición:**
```json
{
  "action":    "get_candles",
  "symbol":    "EURUSD",
  "timeframe": "H1",
  "from_ts":   1704067200,
  "to_ts":     1704153600
}
```

| Campo | Tipo | Descripción |
|---|---|---|
| `action` | string | `"get_candles"` |
| `symbol` | string | Símbolo del broker (ej: `"EURUSD"`, `"XAUUSD"`) |
| `timeframe` | string | Ver tabla de timeframes |
| `from_ts` | int | Unix timestamp UTC inicio del rango (inclusivo) |
| `to_ts` | int | Unix timestamp UTC fin del rango (inclusivo) |

**Respuesta exitosa:**
```json
{
  "status":    "ok",
  "symbol":    "EURUSD",
  "timeframe": "H1",
  "count":     24,
  "candles": [
    {
      "ts":          1704067200,
      "open":        1.10500,
      "high":        1.10650,
      "low":         1.10480,
      "close":       1.10620,
      "volume":      1250.00,
      "tick_volume": 3400
    }
  ]
}
```

| Campo de vela | Tipo | Descripción |
|---|---|---|
| `ts` | int | Unix timestamp UTC de apertura de la vela |
| `open` | float | Precio de apertura (5 decimales) |
| `high` | float | Precio máximo (5 decimales) |
| `low` | float | Precio mínimo (5 decimales) |
| `close` | float | Precio de cierre (5 decimales) |
| `volume` | float | Volumen real (`real_volume` en MT5, puede ser 0 si el broker no lo provee) |
| `tick_volume` | int | Número de ticks dentro de la vela |

Las velas se entregan en **orden cronológico ascendente** (la más antigua primero).

---

## Timeframes soportados

| String en petición | Equivalente MT5 | Duración |
|---|---|---|
| `M1` | `PERIOD_M1` | 1 minuto |
| `M5` | `PERIOD_M5` | 5 minutos |
| `M15` | `PERIOD_M15` | 15 minutos |
| `M30` | `PERIOD_M30` | 30 minutos |
| `H1` | `PERIOD_H1` | 1 hora |
| `H4` | `PERIOD_H4` | 4 horas |
| `D1` | `PERIOD_D1` | 1 día |
| `W1` | `PERIOD_W1` | 1 semana |

---

## Respuestas de error

Todos los errores usan la misma estructura:
```json
{"status": "error", "message": "<descripción>"}
```

| Mensaje | Causa |
|---|---|
| `Unknown action` | Campo `action` ausente o no reconocido |
| `Symbol parameter missing` | Campo `symbol` ausente o vacío |
| `Timeframe parameter missing` | Campo `timeframe` ausente o vacío |
| `Invalid timeframe` | Valor de `timeframe` no está en la tabla de timeframes |
| `Symbol not found in broker` | El símbolo no existe en el broker conectado |
| `No data available for range` | El símbolo existe pero no hay histórico para el rango solicitado |
| `Request exceeds MAX_CANDLES_PER_REQUEST` | El rango solicitado supera el límite configurado (default: 5000 velas) |

---

## Límites y timeouts

| Límite | Valor | Descripción |
|---|---|---|
| Tamaño máximo de petición | 10 MB | El EA cierra la conexión si se supera |
| Velas por petición | 5000 | Configurable via `MAX_CANDLES_PER_REQUEST` |
| Conexiones simultáneas | 10 | El EA rechaza nuevas conexiones si se supera |
| Timeout de lectura | implícito en socket | El EA cierra si el cliente no envía datos |

---

## Notas sobre timestamps

- Todos los timestamps son **Unix UTC** (segundos desde 1970-01-01 00:00:00 UTC)
- `datetime` interno de MT5 coincide directamente con Unix UTC — no hay conversión de zona horaria
- El campo `ts` de cada vela corresponde a la **apertura** de la vela
- Forex cierra los fines de semana: los rangos que cruzan sábado/domingo tendrán menos velas de las estimadas

---

## Ejemplo completo en Python

```python
import json, os, socket, struct

HOST = os.getenv("EA_HOST", "192.168.1.14")
PORT = int(os.getenv("EA_PORT", "9090"))

def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("Conexión cerrada")
        buf += chunk
    return buf

def call_ea(request: dict) -> dict:
    with socket.create_connection((HOST, PORT), timeout=10) as sock:
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
        sock.sendall(struct.pack(">I", len(payload)) + payload)
        length = struct.unpack(">I", _recv_exact(sock, 4))[0]
        return json.loads(_recv_exact(sock, length).decode("utf-8"))

# Health check
print(call_ea({"action": "ping"}))
# → {"status": "ok", "message": "pong"}

# Velas EURUSD H1 del 2 al 5 de enero 2024
resp = call_ea({
    "action":    "get_candles",
    "symbol":    "EURUSD",
    "timeframe": "H1",
    "from_ts":   1704153600,
    "to_ts":     1704412800,
})
print(f"Recibidas: {resp['count']} velas")
```
