//+------------------------------------------------------------------+
//| TCPServer.mqh — Servidor TCP para TradingDataServer              |
//+------------------------------------------------------------------+
#ifndef TCPSERVER_MQH
#define TCPSERVER_MQH

#include <Socket.mqh>
#include "Logger.mqh"
#include "JSONHandler.mqh"
#include "CandleProvider.mqh"

#define MAX_MSG_BYTES    (10 * 1024 * 1024)  // 10 MB — límite de seguridad
#define MAX_CONNECTIONS  10                   // conexiones a procesar por tick

class CTCPServer {
private:
    ServerSocket    *m_server;
    CLogger         *m_logger;
    CJSONHandler    *m_json;
    CCandleProvider *m_candles;
    int              m_port;

    // ---------------------------------------------------------------
    // Protocolo: JSON plano sin framing
    // Cliente envía JSON + cierra su lado (half-close / shutdown SHUT_WR)
    // EA lee hasta recibir EOF, responde JSON plano y cierra la conexión
    // ---------------------------------------------------------------
    bool ReadMessage(ClientSocket *client, string &message) {
        uchar all[];
        uchar chunk[];
        ArrayResize(chunk, 4096);
        int total = 0;

        while(true) {
            int got = client.Receive(chunk, 4096);
            if(got <= 0) break; // EOF — cliente cerró su lado

            int prev = ArraySize(all);
            ArrayResize(all, prev + got);
            ArrayCopy(all, chunk, prev, 0, got);
            total += got;

            if(total > MAX_MSG_BYTES) {
                m_logger.Error("ReadMessage: mensaje demasiado grande (" +
                               IntegerToString(total) + " bytes)");
                return false;
            }
        }

        if(total == 0) {
            m_logger.Warning("ReadMessage: conexión cerrada sin datos");
            return false;
        }

        message = CharArrayToString(all, 0, total, CP_UTF8);
        m_logger.Debug("ReadMessage: " + IntegerToString(total) + " bytes recibidos");
        return true;
    }

    // Envía JSON plano sin framing en chunks de 4 KB
    // Send() puede retornar menos bytes de los solicitados — el bucle garantiza
    // que se envía la respuesta completa sin importar el tamaño
    bool SendMessage(ClientSocket *client, const string &response) {
        uchar payload[];
        // WHOLE_ARRAY convierte el string completo; el retorno incluye el null.
        // Restar 1 para obtener los bytes reales a enviar.
        int sz = StringToCharArray(response, payload, 0, WHOLE_ARRAY, CP_UTF8);
        int total  = sz - 1;
        int offset = 0;

        m_logger.Debug("SendMessage: " + IntegerToString(total) + " bytes a enviar");

        while(offset < total) {
            int remaining = total - offset;
            int chunkSize = MathMin(remaining, 4096);

            uchar chunk[];
            ArrayResize(chunk, chunkSize);
            ArrayCopy(chunk, payload, 0, offset, chunkSize);

            int sent = client.Send(chunk, chunkSize);
            if(sent <= 0) {
                m_logger.Warning("SendMessage: error al enviar en offset=" +
                                 IntegerToString(offset) + " sent=" + IntegerToString(sent));
                return false;
            }
            offset += sent;
        }
        return true;
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

    // Procesa un cliente: siempre envía respuesta JSON antes de cerrar
    void ProcessOneClient(ClientSocket *client) {
        string request = "";

        if(!ReadMessage(client, request)) {
            // ReadMessage leyó todo — enviar error antes de cerrar
            m_logger.Error("ProcessOneClient: ReadMessage falló — respondiendo error");
            SendMessage(client, ERR_UNKNOWN_ACTION); // best-effort
            delete client;
            return;
        }

        string response = DispatchRequest(request);

        if(!SendMessage(client, response)) {
            m_logger.Warning("ProcessOneClient: SendMessage falló");
        }

        delete client; // FIN limpio — ReadMessage ya leyó todo el buffer
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
