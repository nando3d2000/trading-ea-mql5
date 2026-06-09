//+------------------------------------------------------------------+
//| TradingDataServer.mq5 — EA servidor de datos OHLCV vía TCP      |
//| Este EA NO opera: no abre ni cierra trades de ningún tipo.       |
//+------------------------------------------------------------------+
#property copyright "TradingDataServer"
#property version   "1.00"
#property strict

#include <TradingDataServer/Logger.mqh>
#include <TradingDataServer/JSONHandler.mqh>
#include <TradingDataServer/CandleProvider.mqh>
#include <TradingDataServer/TCPServer.mqh>

//--- Parámetros configurables desde la interfaz del EA
input int    TCP_PORT                = 9090;   // Puerto TCP de escucha
input int    MAX_CANDLES_PER_REQUEST = 5000;   // Límite de velas por petición
input int    TIMER_INTERVAL_MS       = 100;    // Frecuencia del timer en ms
input bool   LOG_TO_FILE             = true;   // Guardar logs en archivo
input string LOG_LEVEL               = "INFO"; // DEBUG / INFO / WARNING / ERROR

//--- Instancias globales (punteros para control explícito del ciclo de vida)
CLogger         *g_logger   = NULL;
CJSONHandler    *g_json     = NULL;
CCandleProvider *g_candles  = NULL;
CTCPServer      *g_server   = NULL;

//+------------------------------------------------------------------+
int OnInit() {
    // 1. Logger — primero para que el resto pueda loggear
    g_logger = new CLogger();
    if(!g_logger.Init(CLogger::ParseLevel(LOG_LEVEL), LOG_TO_FILE)) {
        Print("INIT ERROR: No se pudo inicializar el logger");
        return INIT_FAILED;
    }
    g_logger.Info("=== TradingDataServer iniciando ===");
    g_logger.Info(StringFormat("Parámetros: puerto=%d maxVelas=%d timerMs=%d logFile=%s level=%s",
        TCP_PORT, MAX_CANDLES_PER_REQUEST, TIMER_INTERVAL_MS,
        LOG_TO_FILE ? "true" : "false", LOG_LEVEL));

    // 2. Módulos de negocio
    g_json    = new CJSONHandler(g_logger);
    g_candles = new CCandleProvider(g_logger, MAX_CANDLES_PER_REQUEST);

    // 3. Servidor TCP
    g_server = new CTCPServer(g_logger, g_json, g_candles, TCP_PORT);
    if(!g_server.Start()) {
        g_logger.Error("OnInit: no se pudo iniciar el servidor TCP");
        Cleanup();
        return INIT_FAILED;
    }

    // 4. Timer que llama ProcessConnections() periódicamente
    if(!EventSetMillisecondTimer(TIMER_INTERVAL_MS)) {
        g_logger.Error("OnInit: EventSetMillisecondTimer falló error=" +
                       IntegerToString(GetLastError()));
        Cleanup();
        return INIT_FAILED;
    }

    g_logger.Info("Servidor listo en puerto " + IntegerToString(TCP_PORT));
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();

    if(g_logger != NULL)
        g_logger.Info("OnDeinit: razón=" + IntegerToString(reason) +
                      " — deteniendo servidor");

    Cleanup();
}

//+------------------------------------------------------------------+
void OnTimer() {
    if(g_server != NULL)
        g_server.ProcessConnections();
}

//+------------------------------------------------------------------+
// OnTick no se usa — el EA no opera ni necesita quotes en tiempo real
void OnTick() {}

//+------------------------------------------------------------------+
// Libera todos los objetos en orden inverso al de creación
void Cleanup() {
    if(g_server != NULL)  { delete g_server;  g_server  = NULL; }
    if(g_candles != NULL) { delete g_candles; g_candles = NULL; }
    if(g_json != NULL)    { delete g_json;    g_json    = NULL; }
    if(g_logger != NULL)  {
        g_logger.Info("=== TradingDataServer detenido ===");
        g_logger.Close();
        delete g_logger;
        g_logger = NULL;
    }
}
