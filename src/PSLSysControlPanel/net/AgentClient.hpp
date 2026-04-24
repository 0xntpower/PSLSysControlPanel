#pragma once

// Qt TCP client for a single PSLAgent host.
//
// State machine (simplified):
//   Disconnected -> Connecting -> Handshaking -> Ready
//                                 ^               |
//                                 +-- ComponentListRequested <-+
//
// Emits ``componentListUpdated`` whenever a fresh component_list arrives,
// and ``connectionStateChanged`` on every transition so the QML layer can
// reflect it in the header.

#include <QByteArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QString>
#include <QtQmlIntegration/qqmlintegration.h>

class QTcpSocket;
class QTimer;

namespace pslcp::net {

class LogTailSession;

class AgentClient : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(ConnectionState connectionState READ connectionState
                   NOTIFY connectionStateChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    Q_PROPERTY(QString agentHostId READ agentHostId NOTIFY agentHostIdChanged)
    Q_PROPERTY(bool operatorEnrolled READ operatorEnrolled
                   NOTIFY operatorEnrolledChanged)
    Q_PROPERTY(bool operatorAuthenticated READ operatorAuthenticated
                   NOTIFY operatorAuthenticatedChanged)
    Q_PROPERTY(bool operatorAuthInProgress READ operatorAuthInProgress
                   NOTIFY operatorAuthInProgressChanged)

public:
    enum ConnectionState {
        Disconnected,
        Connecting,
        Handshaking,
        Ready,
        Failed,
    };
    Q_ENUM(ConnectionState)

    struct ComponentInfo {
        QString id;
        QString display_name;
        QString state;
        int pid = 0;
        qint64 started_at = 0;
        QString telemetry_endpoint;
        // -1.0 means "not reported" — agent sends null for non-live states
        // or when psutil couldn't read the process (denied / already reaped).
        double cpu_pct = -1.0;
        double rss_mb = -1.0;
        // Log files declared in the manifest for this component — lets the
        // panel pre-populate the LOGS path without a second round-trip.
        QStringList log_files;
    };

    explicit AgentClient(QObject* parent = nullptr);
    ~AgentClient() override;

    // Configure the target agent + PSK before calling ``start``.
    void configure(const QString& host, quint16 port, const QByteArray& psk);

    // Kick off the connection. Safe to call multiple times — a new attempt
    // tears down the previous socket.
    Q_INVOKABLE void start();

    // Issue a ``component_list`` request. Emits ``componentListUpdated`` on
    // success, ``lastErrorChanged`` on failure. Silently ignored if the
    // client is not yet in the ``Ready`` state.
    Q_INVOKABLE void refreshComponentList();

    // Derive the operator key from ``password`` + the agent's salt/params.
    // Runs Argon2id in a background thread (takes ~1s with production
    // params) and caches the resulting 32-byte key in RAM for the duration
    // of the session. Emits ``operatorAuthenticatedChanged`` on success or
    // ``lastErrorChanged`` on failure. No-op if the agent hasn't advertised
    // a salt yet (not enrolled).
    Q_INVOKABLE void authenticateOperator(const QString& password);

    // Issue a ``component_start`` / ``component_stop`` / ``component_restart``
    // request for the component at ``row`` (index into the cached
    // component list). Each fails silently if not ``Ready`` or if
    // ``operatorAuthenticated`` is false; callers should check those
    // properties before calling.
    Q_INVOKABLE void startComponent(int row);
    Q_INVOKABLE void stopComponent(int row);
    Q_INVOKABLE void restartComponent(int row);

    // Config editor: list files on the selected component, load one, save
    // one. Each emits a matching ``config...`` signal with the row so the
    // QML side can tell whose response it is.
    Q_INVOKABLE void listConfigFiles(int row);
    Q_INVOKABLE void loadConfigFile(int row, const QString& path);
    Q_INVOKABLE void saveConfigFile(int row, const QString& path,
                                    const QString& content,
                                    const QString& expectedSha);

    // Log tail: opens a DEDICATED secondary TCP connection (spec §6.4 —
    // the main connection is request/response, tailing takes over its own
    // session). ``filter_pattern`` is optional; when empty the stream is
    // byte-oriented, otherwise line-matches only.
    // ``historyBytes`` (default 0) lets the panel pre-load the tail end of
    // the existing file so the overlay isn't empty until the component
    // writes something new. 0 → start at EOF. Positive → probe file size
    // and begin tail at ``max(0, size - historyBytes)``.
    Q_INVOKABLE void startLogTail(int row, const QString& path,
                                  const QString& filterPattern,
                                  qint64 historyBytes = 0);
    Q_INVOKABLE void stopLogTail();

    ConnectionState connectionState() const;
    QString lastError() const;
    QString agentHostId() const;
    bool operatorEnrolled() const;
    bool operatorAuthenticated() const;
    bool operatorAuthInProgress() const;
    QList<ComponentInfo> components() const;

signals:
    void connectionStateChanged();
    void lastErrorChanged();
    void agentHostIdChanged();
    void operatorEnrolledChanged();
    void operatorAuthenticatedChanged();
    void operatorAuthInProgressChanged();
    void componentListUpdated();

    // Config-editor signals. All carry the originating ``row`` so a
    // handler can filter if multiple components are being edited (we only
    // show one modal at a time today but the protocol is per-request).
    void configFilesListed(int row, const QStringList& paths);
    void configFileLoaded(int row, const QString& path, const QString& content,
                          const QString& sha256, qint64 mtime);
    void configFileSaved(int row, const QString& path, const QString& newSha256);
    void configConflict(int row, const QString& path, const QString& currentSha256);
    void configFailed(int row, const QString& operation, const QString& message);

    // Log-tail signals. ``logTailEnded`` fires when the secondary
    // connection is torn down for any reason (user stop, agent close,
    // network error).
    void logTailStarted(int row, const QString& path);
    void logTailLine(int row, int lineNo, const QString& text);
    void logTailBytes(int row, qint64 offset, const QByteArray& data);
    void logTailEnded(int row, const QString& reason);

private slots:
    void onSocketConnected();
    void onSocketReadyRead();
    void onSocketDisconnected();
    void onSocketErrorOccurred();

private slots:
    // Internal forwarder for LogTailSession::ended — inspects the reason
    // prefix for ``bad_op_signature`` so a wrong operator password on
    // the first log_tail doesn't thrash the agent with reconnect
    // attempts. Clears the operator key when matched.
    void onLogTailSessionEnded(int row, const QString& reason);

private:
    void setState(ConnectionState s);
    void setError(const QString& msg);
    void handleFrame(const QByteArray& frame_body);
    void sendRequest(const QString& type, const QJsonObject& args,
                     bool require_operator = false);
    void sendHello();
    void sendComponentLifecycle(int row, const QString& type);
    void handleConfigFrame(const QString& type, const QJsonObject& body);
    // Central handler for ``bad_op_signature`` — clears cached operator
    // key, flips operatorAuthenticated to false, sets a user-friendly
    // lastError. Idempotent.
    void handleOperatorRejected();

    struct PendingConfigOp {
        int row;
        QString path;    // "" for list
        QString kind;    // "files" | "get" | "set"
    };
    void pushPendingConfig(const PendingConfigOp& op);
    PendingConfigOp popPendingConfig();

    QTcpSocket* socket_;
    QTimer* reconnect_timer_;
    QTimer* refresh_timer_;  // periodic component_list poll while Ready
    QByteArray recv_buffer_;
    ConnectionState state_;
    QString last_error_;
    QString host_id_;
    bool operator_enrolled_;
    bool operator_auth_in_progress_;
    QString host_;
    quint16 port_;
    QByteArray psk_;
    QList<ComponentInfo> components_;

    // Operator-auth state (set by agent_hello / authenticateOperator).
    QByteArray operator_salt_;  // 16 bytes when advertised (libsodium requirement)
    int argon2_mem_kib_;
    int argon2_iters_;
    int argon2_threads_;
    QByteArray operator_key_;   // 32 bytes when authenticated; empty otherwise

    QList<PendingConfigOp> pending_config_;
    LogTailSession* log_tail_session_;
};

} // namespace pslcp::net
