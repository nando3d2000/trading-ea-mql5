"""
test_protocol.py — Pruebas del protocolo TCP del TradingDataServer EA.

Requiere el EA corriendo en MT5 (Wine @ 192.168.1.14:9090 por defecto).
Configurar via variables de entorno:
    EA_HOST=192.168.1.14
    EA_PORT=9090

Ejecutar:
    pip install -r requirements.txt
    pytest tests/test_protocol.py -v
    pytest tests/test_protocol.py -v -k test_ping   # un solo test
"""

import json
import os
import socket
import time

import pytest

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

EA_HOST = os.getenv("EA_HOST", "192.168.1.14")
EA_PORT = int(os.getenv("EA_PORT", "9090"))
TIMEOUT = float(os.getenv("EA_TIMEOUT", "10"))

# Rango fijo para tests de velas: semana del 2024-01-01 (mercado abierto)
TS_2024_01_02 = 1704153600  # 2024-01-02 00:00:00 UTC (lunes — apertura forex)
TS_2024_01_05 = 1704412800  # 2024-01-05 00:00:00 UTC (viernes — cierre semana)


# ---------------------------------------------------------------------------
# Cliente TCP reutilizable
# ---------------------------------------------------------------------------

class MT5Client:
    """Cliente TCP minimalista que implementa el framing del protocolo EA."""

    def __init__(self, host: str, port: int, timeout: float = 10.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock: socket.socket | None = None

    def connect(self) -> None:
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.settimeout(self.timeout)
        self._sock.connect((self.host, self.port))

    def close(self) -> None:
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def send_request(self, request: dict) -> dict:
        """Envía JSON plano, hace half-close y lee respuesta hasta EOF."""
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
        self._sock.sendall(payload)
        # Half-close: señala al EA que terminamos de enviar (EOF en su Receive)
        self._sock.shutdown(socket.SHUT_WR)

        chunks = []
        while True:
            chunk = self._sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)

        raw = b"".join(chunks)
        return json.loads(raw.decode("utf-8"))

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *_):
        self.close()


# ---------------------------------------------------------------------------
# Fixtures pytest
# ---------------------------------------------------------------------------

@pytest.fixture
def client():
    """Fixture que provee un cliente conectado al EA y lo cierra al terminar."""
    with MT5Client(EA_HOST, EA_PORT, TIMEOUT) as c:
        yield c


def _fresh_client() -> MT5Client:
    """Crea y conecta un cliente nuevo (para tests que necesitan conexión propia)."""
    c = MT5Client(EA_HOST, EA_PORT, TIMEOUT)
    c.connect()
    return c


# ---------------------------------------------------------------------------
# Tests de conectividad
# ---------------------------------------------------------------------------

class TestConnectivity:
    def test_ping(self, client):
        resp = client.send_request({"action": "ping"})
        assert resp["status"] == "ok"
        assert resp["message"] == "pong"

    def test_ping_multiple_times(self, client):
        """El servidor debe responder pings consecutivos sin degradarse."""
        for _ in range(5):
            resp = client.send_request({"action": "ping"})
            assert resp["status"] == "ok"

    def test_multiple_independent_connections(self):
        """Cada conexión nueva debe funcionar correctamente."""
        for _ in range(3):
            with MT5Client(EA_HOST, EA_PORT, TIMEOUT) as c:
                resp = c.send_request({"action": "ping"})
                assert resp["status"] == "ok"


# ---------------------------------------------------------------------------
# Tests de get_candles — casos exitosos
# ---------------------------------------------------------------------------

class TestGetCandles:
    def test_eurusd_h1(self, client):
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    "EURUSD",
            "timeframe": "H1",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "ok"
        assert resp["symbol"] == "EURUSD"
        assert resp["timeframe"] == "H1"
        assert resp["count"] > 0
        assert len(resp["candles"]) == resp["count"]

    def test_candle_fields_present(self, client):
        """Cada vela debe tener los 7 campos del protocolo."""
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    "EURUSD",
            "timeframe": "H1",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_02 + 3600 * 4,
        })
        assert resp["status"] == "ok"
        assert resp["count"] > 0

        for candle in resp["candles"]:
            assert "ts"          in candle
            assert "open"        in candle
            assert "high"        in candle
            assert "low"         in candle
            assert "close"       in candle
            assert "volume"      in candle
            assert "tick_volume" in candle

    def test_candle_ohlc_integrity(self, client):
        """high >= open, close; low <= open, close en cada vela."""
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    "EURUSD",
            "timeframe": "H1",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "ok"
        for c in resp["candles"]:
            assert c["high"] >= c["open"],  f"high < open en ts={c['ts']}"
            assert c["high"] >= c["close"], f"high < close en ts={c['ts']}"
            assert c["low"]  <= c["open"],  f"low > open en ts={c['ts']}"
            assert c["low"]  <= c["close"], f"low > close en ts={c['ts']}"

    def test_candles_chronological_order(self, client):
        """Las velas deben llegar en orden cronológico ascendente."""
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    "EURUSD",
            "timeframe": "H1",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "ok"
        timestamps = [c["ts"] for c in resp["candles"]]
        assert timestamps == sorted(timestamps), "Velas fuera de orden cronológico"

    def test_candle_timestamps_are_utc(self, client):
        """Los timestamps deben caer dentro del rango solicitado."""
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    "EURUSD",
            "timeframe": "H1",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "ok"
        for c in resp["candles"]:
            assert TS_2024_01_02 <= c["ts"] <= TS_2024_01_05, \
                f"Timestamp {c['ts']} fuera del rango solicitado"

    @pytest.mark.parametrize("symbol", ["EURUSD", "GBPUSD", "USDJPY", "XAUUSD"])
    def test_multiple_symbols(self, client, symbol):
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    symbol,
            "timeframe": "H1",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "ok", \
            f"{symbol}: {resp.get('message', 'sin mensaje')}"
        assert resp["count"] > 0

    @pytest.mark.parametrize("timeframe", ["M1", "M5", "M15", "M30", "H1", "H4", "D1"])
    def test_all_timeframes(self, client, timeframe):
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    "EURUSD",
            "timeframe": timeframe,
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "ok", \
            f"{timeframe}: {resp.get('message', 'sin mensaje')}"
        assert resp["count"] > 0


# ---------------------------------------------------------------------------
# Tests de error — validación del protocolo
# ---------------------------------------------------------------------------

class TestErrors:
    def test_unknown_action(self, client):
        resp = client.send_request({"action": "unknown_action"})
        assert resp["status"] == "error"
        assert "Unknown action" in resp["message"]

    def test_missing_action_field(self, client):
        resp = client.send_request({"symbol": "EURUSD"})
        assert resp["status"] == "error"

    def test_missing_symbol(self, client):
        resp = client.send_request({
            "action":    "get_candles",
            "timeframe": "H1",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "error"
        assert "Symbol" in resp["message"]

    def test_missing_timeframe(self, client):
        resp = client.send_request({
            "action":  "get_candles",
            "symbol":  "EURUSD",
            "from_ts": TS_2024_01_02,
            "to_ts":   TS_2024_01_05,
        })
        assert resp["status"] == "error"
        assert "Timeframe" in resp["message"] or "timeframe" in resp["message"].lower()

    def test_invalid_timeframe(self, client):
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    "EURUSD",
            "timeframe": "X99",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "error"
        assert "timeframe" in resp["message"].lower()

    def test_symbol_not_found(self, client):
        resp = client.send_request({
            "action":    "get_candles",
            "symbol":    "FAKESYMBOL999",
            "timeframe": "H1",
            "from_ts":   TS_2024_01_02,
            "to_ts":     TS_2024_01_05,
        })
        assert resp["status"] == "error"
        assert "Symbol" in resp["message"] or "symbol" in resp["message"].lower()

    def test_response_is_always_valid_json(self, client):
        """Incluso con entradas basura, la respuesta debe ser JSON válido."""
        bad_requests = [
            {"action": ""},
            {"action": "get_candles", "symbol": "", "timeframe": ""},
            {"action": "get_candles", "symbol": "EURUSD", "timeframe": "H1",
             "from_ts": 0, "to_ts": 0},
        ]
        for req in bad_requests:
            resp = client.send_request(req)
            assert isinstance(resp, dict), f"Respuesta no es dict para {req}"
            assert "status" in resp, f"Sin campo 'status' para {req}"
