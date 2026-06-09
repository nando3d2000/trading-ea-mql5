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
#define MAX_CONNECTIONS  10                   // conexiones simultáneas máximas

class CTCPServer {
private:
    ServerSocket    *m_server;
    CLogger         *m_logger;
    CJSONHandler    *m_json;
    CCandleProvider *m_candles;
    int              m_port;
    int              m_activeConns;

    // Protocolo: [4 bytes big-endian length][payload UTF-8]
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
            m_logger.Warning("ReadMessage: longitud inválida=" +
                             IntegerToString(length));
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

    // Envía respuesta precedida por header de 4 bytes big-endian con la longitud
    bool SendMessage(ClientSocket *client, const string &response) {
        uchar payload[];
        // StringToCharArray añade null terminator — usamos StringLen para excluirlo
        StringToCharArray(response, payload, 0, StringLen(response), CP_UTF8);
        uint length = ArraySize(payload) - 1; // sin el null terminator

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

    // Maneja la acción get_candles — validación y obtención de datos
    string HandleGetCandles(const TradingRequest &req) {
        if(req.symbol == "")    return ERR_MISSING_SYMBOL;
        if(req.timeframe == "") return ERR_MISSING_TIMEFRAME;

        ENUM_TIMEFRAMES period = m_json.ParseTimeframe(req.timeframe);
        if(period == PERIOD_CURRENT) return ERR_INVALID_TIMEFRAME;

        MqlRates rates[];
        int count = m_candles.GetCandles(req.symbol, period,
                                          req.from_ts, req.to_ts, rates);

        if(m_candles.IsLimitError(count))  return ERR_TOO_MANY_CANDLES;

        if(m_candles.IsNoDataError(count)) {
            // Distinguir símbolo inexistente de rango sin datos
            if(!SymbolSelect(req.symbol, false)) return ERR_SYMBOL_NOT_FOUND;
            return ERR_NO_DATA;
        }

        return m_json.BuildCandlesResponse(req.symbol, req.timeframe, rates, count);
    }

    // Despacha la petición y retorna el JSON de respuesta
    string DispatchRequest(const string &json) {
        TradingRequest req;
        if(!m_json.ParseRequest(json, req)) return ERR_UNKNOWN_ACTION;

        m_logger.Debug("DispatchRequest: action=" + req.action +
                       " symbol=" + req.symbol + " tf=" + req.timeframe);

        if(req.action == "ping")        return m_json.BuildPongResponse();
        if(req.action == "get_candles") return HandleGetCandles(req);

        m_logger.Warning("DispatchRequest: acción desconocida '" + req.action + "'");
        return ERR_UNKNOWN_ACTION;
    }

public:
    CTCPServer(CLogger *logger, CJSONHandler *json,
               CCandleProvider *candles, int port)
        : m_server(NULL), m_logger(logger), m_json(json),
          m_candles(candles), m_port(port), m_activeConns(0) {}

    ~CTCPServer() { Stop(); }

    bool Start() {
        if(m_server != NULL) return true; // ya iniciado

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

    // Llamar desde OnTimer() — Accept() es no bloqueante
    // Receive() bloquea hasta recibir los datos o que la conexión cierre
    void ProcessConnections() {
        if(!IsRunning()) {
            // Intentar reiniciar si el socket se perdió
            m_logger.Warning("ProcessConnections: servidor caído, reintentando Start()");
            Start();
            return;
        }

        if(m_activeConns >= MAX_CONNECTIONS) {
            m_logger.Warning("ProcessConnections: máximo de conexiones alcanzado (" +
                             IntegerToString(MAX_CONNECTIONS) + ")");
            return;
        }

        ClientSocket *client = m_server.Accept();
        if(client == NULL) return; // sin conexiones pendientes

        m_activeConns++;
        m_logger.Debug("Conexión aceptada (activas=" +
                       IntegerToString(m_activeConns) + ")");

        string request = "";
        if(ReadMessage(client, request)) {
            m_logger.Debug("Petición: " + request);
            string response = DispatchRequest(request);
            if(!SendMessage(client, response)) {
                m_logger.Warning("ProcessConnections: fallo al enviar respuesta");
            } else {
                m_logger.Debug("Respuesta enviada (" +
                               IntegerToString(StringLen(response)) + " bytes)");
            }
        }

        delete client;
        m_activeConns--;
    }
};

#endif // TCPSERVER_MQH
