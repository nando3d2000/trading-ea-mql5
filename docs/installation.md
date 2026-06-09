# Instalación — TradingDataServer EA

## Requisitos

- MetaTrader 5 corriendo bajo **Wine en Lubuntu** (host `192.168.1.14`)
- MetaEditor disponible dentro de la instalación de MT5
- Python 3.10+ en la máquina que ejecutará los tests (fuera de Wine)

## Estructura de archivos a copiar

```
MQL5/
  Experts/
    TradingDataServer/
      TradingDataServer.mq5     → carpeta Experts de MT5
  Include/
    TradingDataServer/
      Logger.mqh                → carpeta Include de MT5
      JSONHandler.mqh
      CandleProvider.mqh
      TCPServer.mqh
```

Las rutas dentro de Wine suelen ser:
```
~/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/TradingDataServer/
~/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include/TradingDataServer/
```

## Pasos de instalación

### 1. Copiar los archivos

```bash
# Ajustar MT5_PATH a la ruta real de tu instalación
MT5_PATH="$HOME/.wine/drive_c/Program Files/MetaTrader 5/MQL5"

mkdir -p "$MT5_PATH/Experts/TradingDataServer"
mkdir -p "$MT5_PATH/Include/TradingDataServer"

cp MQL5/Experts/TradingDataServer/TradingDataServer.mq5 \
   "$MT5_PATH/Experts/TradingDataServer/"

cp MQL5/Include/TradingDataServer/*.mqh \
   "$MT5_PATH/Include/TradingDataServer/"
```

### 2. Compilar en MetaEditor

1. Abrir **MetaEditor** (botón en la barra de herramientas de MT5, o `F4`)
2. En el árbol de la izquierda: `Experts > TradingDataServer > TradingDataServer.mq5`
3. Pulsar **F7** (o menú Compilar)
4. Verificar en la pestaña **Errors** que no hay errores ni warnings
5. El compilador genera `TradingDataServer.ex5` en la misma carpeta

### 3. Adjuntar el EA al chart

1. Abrir un chart de **EURUSD H1** en MT5
2. En el árbol de Navegador: `Expert Advisors > TradingDataServer`
3. Arrastrar el EA al chart (o doble clic)
4. En la ventana de parámetros, verificar:
   - **Permitir trading algorítmico** — puede estar desmarcado, el EA no opera pero el checkbox es necesario para que OnTimer() funcione
   - **Permitir DLL** — no requerido
5. Pulsar **OK**

### 4. Verificar que el servidor arrancó

En la pestaña **Experts** del terminal MT5 deben aparecer estas líneas:

```
[2024.01.02 10:00:00] INFO: === TradingDataServer iniciando ===
[2024.01.02 10:00:00] INFO: Parámetros: puerto=9090 maxVelas=5000 ...
[2024.01.02 10:00:00] INFO: Servidor TCP iniciado en puerto 9090
[2024.01.02 10:00:00] INFO: Servidor listo en puerto 9090
```

La carita sonriente (🙂) en la esquina superior derecha del chart confirma que el EA está activo.

## Parámetros configurables

| Parámetro | Tipo | Default | Descripción |
|---|---|---|---|
| `TCP_PORT` | int | 9090 | Puerto TCP de escucha |
| `MAX_CANDLES_PER_REQUEST` | int | 5000 | Máximo de velas por petición |
| `TIMER_INTERVAL_MS` | int | 100 | Frecuencia del timer en ms |
| `LOG_TO_FILE` | bool | true | Guardar log en `MQL5/Files/TradingDataServer.log` |
| `LOG_LEVEL` | string | INFO | `DEBUG` / `INFO` / `WARNING` / `ERROR` |

## Verificación rápida con Python

```bash
cd trading-ea-mql5
pip install -r tests/requirements.txt
EA_HOST=192.168.1.14 pytest tests/test_protocol.py::TestConnectivity::test_ping -v
```

Salida esperada:
```
PASSED tests/test_protocol.py::TestConnectivity::test_ping
```

Suite completa:
```bash
EA_HOST=192.168.1.14 pytest tests/test_protocol.py -v
```

## Troubleshooting

### El EA muestra carita triste (☹)

Revisar la pestaña **Experts** para el mensaje de error. Causas comunes:

| Error en log | Causa | Solución |
|---|---|---|
| `No se pudo abrir puerto 9090` | Puerto en uso o firewall | Verificar con `netstat -an \| grep 9090` dentro de Wine |
| `EventSetMillisecondTimer falló` | MT5 desconectado del broker | Conectar MT5 al broker antes de añadir el EA |
| `No se pudo inicializar el logger` | Sin permisos en `MQL5/Files/` | Verificar permisos de escritura en la carpeta Files de MT5 |

### El test de Python no conecta

```
ConnectionRefusedError: [Errno 111] Connection refused
```

1. Verificar que el EA está activo (carita 🙂)
2. Verificar que `EA_HOST` apunta a la IP correcta de la máquina con Wine
3. Verificar que el puerto 9090 no está bloqueado por `ufw`:
   ```bash
   sudo ufw allow 9090/tcp
   ```
4. Desde la máquina con MT5: `telnet localhost 9090` debe conectar

### El test conecta pero no responde

El timer puede estar parado. En MT5:
- Menú **Herramientas > Opciones > Expert Advisors**
- Asegurarse de que **Permitir trading algorítmico** está habilitado globalmente

### Los logs se guardan en

```
~/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Files/TradingDataServer.log
```
