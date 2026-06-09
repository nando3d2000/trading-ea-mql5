//+------------------------------------------------------------------+
//| Logger.mqh — Sistema de logging para TradingDataServer          |
//+------------------------------------------------------------------+
#ifndef LOGGER_MQH
#define LOGGER_MQH

enum ENUM_LOG_LEVEL {
    LOG_LEVEL_DEBUG   = 0,
    LOG_LEVEL_INFO    = 1,
    LOG_LEVEL_WARNING = 2,
    LOG_LEVEL_ERROR   = 3
};

class CLogger {
private:
    ENUM_LOG_LEVEL m_minLevel;
    bool           m_toFile;
    int            m_fileHandle;
    string         m_fileName;

    string LevelToString(ENUM_LOG_LEVEL level) {
        switch(level) {
            case LOG_LEVEL_DEBUG:   return "DEBUG";
            case LOG_LEVEL_INFO:    return "INFO";
            case LOG_LEVEL_WARNING: return "WARNING";
            case LOG_LEVEL_ERROR:   return "ERROR";
            default:                return "UNKNOWN";
        }
    }

    void WriteLog(ENUM_LOG_LEVEL level, string message) {
        if(level < m_minLevel) return;

        string line = StringFormat("[%s] %s: %s",
            TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS),
            LevelToString(level),
            message
        );

        Print(line);

        if(m_toFile && m_fileHandle != INVALID_HANDLE) {
            FileWriteString(m_fileHandle, line + "\n");
            FileFlush(m_fileHandle);
        }
    }

public:
    CLogger() : m_minLevel(LOG_LEVEL_INFO),
                m_toFile(false),
                m_fileHandle(INVALID_HANDLE),
                m_fileName("TradingDataServer.log") {}

    ~CLogger() { Close(); }

    bool Init(ENUM_LOG_LEVEL level, bool toFile,
              string fileName = "TradingDataServer.log") {
        m_minLevel = level;
        m_toFile   = toFile;
        m_fileName = fileName;

        if(!m_toFile) return true;

        // Abrir en modo lectura/escritura para poder hacer append
        m_fileHandle = FileOpen(m_fileName,
            FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);

        if(m_fileHandle == INVALID_HANDLE) {
            Print("LOGGER ERROR: No se pudo abrir archivo de log: ", m_fileName,
                  " error=", GetLastError());
            m_toFile = false;
            return false;
        }

        // Posicionarse al final para no sobreescribir sesiones anteriores
        FileSeek(m_fileHandle, 0, SEEK_END);
        return true;
    }

    void Close() {
        if(m_fileHandle != INVALID_HANDLE) {
            FileClose(m_fileHandle);
            m_fileHandle = INVALID_HANDLE;
        }
    }

    void Debug(string message)   { WriteLog(LOG_LEVEL_DEBUG,   message); }
    void Info(string message)    { WriteLog(LOG_LEVEL_INFO,    message); }
    void Warning(string message) { WriteLog(LOG_LEVEL_WARNING, message); }
    void Error(string message)   { WriteLog(LOG_LEVEL_ERROR,   message); }

    // Convierte string de configuración al enum correspondiente
    static ENUM_LOG_LEVEL ParseLevel(string level) {
        if(level == "DEBUG")   return LOG_LEVEL_DEBUG;
        if(level == "WARNING") return LOG_LEVEL_WARNING;
        if(level == "ERROR")   return LOG_LEVEL_ERROR;
        return LOG_LEVEL_INFO;
    }
};

#endif // LOGGER_MQH
