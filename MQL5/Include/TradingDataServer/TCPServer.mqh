//+------------------------------------------------------------------+
//| TCPServer.mqh — Servidor TCP para TradingDataServer              |
//+------------------------------------------------------------------+
#ifndef TCPSERVER_MQH
#define TCPSERVER_MQH

#include <Socket.mqh>
#include "Logger.mqh"
#include "JSONHandler.mqh"
#include "CandleProvider.mqh"

#define MAX_MSG_BYTES       (10 * 1024 * 1024)  // 10 MB — límite de seguridad
#define MAX_CONNECTIONS     10                   // conexiones a procesar por tick
#define DRAIN_MAX_ITERS     32                   // iteraciones máx en DrainSocket

class CTCPServer {
private:
    ServerSocket    *m_server;
    CLogger         *m_logger;
    CJSONHandler    *m_json;
    CCandleProvider *m_candles;
    int              m_port;

    // ---------------------------------------------------------------
    // Protocolo: [4 bytes big-endian length][payload UTF-8]
    // ---------------------------------------------------------------
    bool ReadMessage(ClientSocket *client, string &message) {
        uchar header[4];
        if(client.Receive(header, 4) != 4) {
            m_logger.Warning("ReadMessage: no se pudo leer los 4 bytes del header");
            return false;
        }

        uint length = ((uint)header[0] << 24) |
                      ((uint)header[1] << 16) |
                      ((uint)header[2] <<  8) |
                       (uint)header[3];

        if(length == 0 || length > MAX_MSG_BYTES) {
            m_logger.Error(StringFormat(
                "ReadMessage: longitud inválida=%u — posible mismatch de protocolo "
                "(¿el cliente envía sin framing de 4 bytes?)", length));
            return false;
        }

        uchar payload[];
        ArrayResize(payload, (int)length);
        if(client.Receive(payload, length) != (int)length) {
            m_logger.Warning("ReadMessage: payload incompleto, esperado=" +
                             IntegerToString(length));
            return false;
        }

        message = CharArrayToString(payload, 0, (int)length, CP_UTF8);
        return true;
    }

    // Envía respuesta con framing [4 bytes big-endian][payload UTF-8]
    bool SendMessage(ClientSocket *client, const string &response) {
        uchar payload[];
        StringToCharArray(response, payload, 0, StringLen(response), CP_UTF8);
        uint length = ArraySize(payload) - 1; // excluir null terminator

        uchar header[4];
        header[0] = (uchar)((length >> 24) & 0xFF);
        header[1] = (uchar)((length >> 16) & 0xFF);
        header[2] = (uchar)((length >>  8) & 0xFF);
        header[3] = (uchar)( length        & 0xFF);

        if(client.Send(header, 4) < 0) {
            m_logger.Warning("SendMessage: error al enviar header");
            return false;
        }
        if(client.Send(payload, length) < 0) {
            m_logger.Warning("SendMessage: error al enviar payload");
            return false;
        }
        return true;
    }

    // Drena los bytes pendientes del socket para garantizar cierre FIN (no RST).
    // Sin esto, delete client con datos no leídos emite RST al peer.
    void DrainSocket(ClientSocket *client) {
        uchar buf[];
        ArrayResize(buf, 4096);
        for(int i = 0; i < DRAIN_MAX_ITERS; i++) {
            if(client.Receive(buf, 4096) <= 0) break;
        }
    }

    // ---------------------------------------------------------------
    // Handlers de acciones
    // ---------------------------------------------------------------
    string HandleGetCandles(const TradingRequest &req) {
        if(req.symbol == "")    return ERR_MISSING_SYMBOL;
        if(req.timeframe == "") return ERR_MISSING_TIMEFRAME;

        ENUM_TIMEFRAMES period = m_json.ParseTimeframe(req.timeframe);
        if(period == PERIOD_CURRENT) {
            m_logger.Warning("HandleGetCandles: timeframe inválido '" +
                             req.timeframe + "'");
            return ERR_INVALID_TIMEFRAME;
        }

        MqlRates rates[];
        int count = m_candles.GetCandles(req.symbol, period,
                                          req.from_ts, req.to_ts, rates);

        if(m_candles.IsLimitError(count)) return ERR_TOO_MANY_CANDLES;

        if(m_candles.IsNoDataError(count)) {
            if(!SymbolSelect(req.symbol, false)) {
                m_logger.Warning("HandleGetCandles: símbolo no encontrado '" +
                                 req.symbol + "'");
                return ERR_SYMBOL_NOT_FOUND;
            }
            return ERR_NO_DATA;
        }

        return m_json.BuildCandlesResponse(req.symbol, req.timeframe, rates, count);
    }

    // Retorna el timestamp más antiguo disponible para el símbolo/timeframe
    string HandleGetOldestTs(const TradingRequest &req) {
        if(req.symbol == "")    return ERR_MISSING_SYMBOL;
        if(req.timeframe == "") return ERR_MISSING_TIMEFRAME;

        ENUM_TIMEFRAMES period = m_json.ParseTimeframe(req.timeframe);
        if(period == PERIOD_CURRENT) return ERR_INVALID_TIMEFRAME;

        if(!SymbolSelect(req.symbol, true)) return ERR_SYMBOL_NOT_FOUND;

        datetime oldest = (datetime)SeriesInfoInteger(req.symbol, period,
                                                      SERIES_FIRSTDATE);
        if(oldest == 0) {
            m_logger.Warning("HandleGetOldestTs: SERIES_FIRSTDATE=0 para " +
                             req.symbol + "/" + req.timeframe);
            return ERR_NO_DATA;
        }

        return StringFormat(
            "{\"status\":\"ok\",\"symbol\":\"%s\",\"timeframe\":\"%s\","
            "\"oldest_ts\":%d}",
            req.symbol, req.timeframe, (long)oldest);
    }

    // Despacha la petición y retorna el JSON de respuesta — NUNCA retorna ""
    string DispatchRequest(const string &json) {
        TradingRequest req;
        if(!m_json.ParseRequest(json, req)) {
            m_logger.Error("DispatchRequest: ParseRequest falló — JSON: " + json);
            return ERR_UNKNOWN_ACTION;
        }

        // Loggear la acción recibida en la pestaña Experts para diagnóstico
        m_logger.Info(StringFormat("Acción recibida: action=%s symbol=%s tf=%s",
                                   req.action, req.symbol, req.timeframe));

        if(req.action == "ping")           return m_json.BuildPongResponse();
        if(req.action == "get_candles")    return HandleGetCandles(req);
        if(req.action == "get_oldest_ts")  return HandleGetOldestTs(req);

        m_logger.Warning("DispatchRequest: acción desconocida '" + req.action + "'");
        return ERR_UNKNOWN_ACTION;
    }

    // Procesa un cliente: siempre envía respuesta y siempre drena antes de cerrar
    void ProcessOneClient(ClientSocket *client) {
        string request  = "";
        string response = "";

        if(!ReadMessage(client, request)) {
            // ReadMessage falló: enviar error y drenar antes de cerrar
            // para evitar que delete client emita RST
            m_logger.Error("ProcessOneClient: ReadMessage falló — respondiendo error");
            SendMessage(client, ERR_UNKNOWN_ACTION); // best-effort
            DrainSocket(client);
            delete client;
            return;
        }

        response = DispatchRequest(request);

        if(!SendMessage(client, response)) {
            m_logger.Warning("ProcessOneClient: SendMessage falló");
        }

        // Drenar bytes residuales antes de cerrar para garantizar FIN limpio
        DrainSocket(client);
        delete client;
    }

public:
    CTCPServer(CLogger *logger, CJSONHandler *json,
               CCandleProvider *candles, int port)
        : m_server(NULL), m_logger(logger), m_json(json),
          m_candles(candles), m_port(port) {}

    ~CTCPServer() { Stop(); }

    bool Start() {
        if(m_server != NULL) return true;

        m_server = new ServerSocket((ushort)m_port, false);
        if(!m_server.Created()) {
            m_logger.Error(StringFormat(
                "Start: no se pudo abrir puerto %d error=%d",
                m_port, GetLastError()));
            delete m_server;
            m_server = NULL;
            return false;
        }

        m_logger.Info("Servidor TCP iniciado en puerto " + IntegerToString(m_port));
        return true;
    }

    void Stop() {
        if(m_server != NULL) {
            delete m_server;
            m_server = NULL;
            m_logger.Info("Servidor TCP detenido");
        }
    }

    bool IsRunning() {
        return (m_server != NULL && m_server.Created());
    }

    // Llamar desde OnTimer() — procesa TODAS las conexiones pendientes en el tick
    void ProcessConnections() {
        if(!IsRunning()) {
            m_logger.Warning("ProcessConnections: servidor caído, reintentando Start()");
            Start();
            return;
        }

        // Procesar todas las conexiones pendientes en este tick del timer,
        // no solo una — evita acumulación en el backlog cuando el scheduler
        // envía múltiples símbolos en ráfaga
        for(int i = 0; i < MAX_CONNECTIONS; i++) {
            ClientSocket *client = m_server.Accept();
            if(client == NULL) break; // no hay más conexiones pendientes

            m_logger.Debug("Conexión aceptada (" + IntegerToString(i + 1) +
                           " en este tick)");
            ProcessOneClient(client); // client se elimina dentro
        }
    }
};

#endif // TCPSERVER_MQH
