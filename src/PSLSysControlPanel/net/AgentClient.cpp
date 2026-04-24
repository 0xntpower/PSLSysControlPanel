#include "AgentClient.hpp"

#include "Envelope.hpp"
#include "LogTailSession.hpp"
#include "OperatorAuth.hpp"

#include <QHostAddress>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QTcpSocket>
#include <QThread>
#include <QTimer>
#include <QUuid>
#include <QtConcurrent/QtConcurrent>

#include <cstring>

namespace pslcp::net {
namespace {

constexpr int kReconnectDelayMs = 3000;
constexpr int kSocketTimeoutMs = 8000;
constexpr int kMaxFrameBytes = 256 * 1024;
// Poll the agent's component_list every few seconds while connected so the
// UI reflects crashes / restarts / new enrollments without manual refresh.
constexpr int kRefreshIntervalMs = 3000;

QByteArray freshReqId()
{
    return QUuid::createUuid().toByteArray(QUuid::WithoutBraces).left(16);
}

} // namespace

AgentClient::AgentClient(QObject* parent)
    : QObject(parent)
    , socket_(new QTcpSocket(this))
    , reconnect_timer_(new QTimer(this))
    , refresh_timer_(new QTimer(this))
    , state_(Disconnected)
    , operator_enrolled_(false)
    , operator_auth_in_progress_(false)
    , port_(0)
    , argon2_mem_kib_(0)
    , argon2_iters_(0)
    , argon2_threads_(0)
    , log_tail_session_(nullptr)
{
    connect(socket_, &QTcpSocket::connected, this, &AgentClient::onSocketConnected);
    connect(socket_, &QTcpSocket::readyRead, this, &AgentClient::onSocketReadyRead);
    connect(socket_, &QTcpSocket::disconnected, this, &AgentClient::onSocketDisconnected);
    connect(socket_, &QTcpSocket::errorOccurred, this, &AgentClient::onSocketErrorOccurred);

    reconnect_timer_->setSingleShot(true);
    reconnect_timer_->setInterval(kReconnectDelayMs);
    connect(reconnect_timer_, &QTimer::timeout, this, &AgentClient::start);

    // Refresh timer kicks in when the state machine enters Ready and is
    // stopped on any other transition (see setState). Its sole job is to
    // keep the component list fresh for the UI.
    refresh_timer_->setInterval(kRefreshIntervalMs);
    connect(refresh_timer_, &QTimer::timeout, this, &AgentClient::refreshComponentList);
}

AgentClient::~AgentClient()
{
    socket_->abort();
}

void AgentClient::configure(const QString& host, quint16 port, const QByteArray& psk)
{
    host_ = host;
    port_ = port;
    psk_ = psk;
}

void AgentClient::start()
{
    if (psk_.isEmpty() || host_.isEmpty() || port_ == 0) {
        setError(QStringLiteral("agent client not configured"));
        setState(Failed);
        return;
    }
    reconnect_timer_->stop();
    if (socket_->state() != QAbstractSocket::UnconnectedState) {
        socket_->abort();
    }
    recv_buffer_.clear();
    components_.clear();
    emit componentListUpdated();
    host_id_.clear();
    operator_enrolled_ = false;
    // Wipe any prior operator key — reconnecting forces re-authentication.
    if (!operator_key_.isEmpty()) {
        std::fill(operator_key_.begin(), operator_key_.end(), static_cast<char>(0));
        operator_key_.clear();
        emit operatorAuthenticatedChanged();
    }
    operator_salt_.clear();
    argon2_mem_kib_ = 0;
    argon2_iters_ = 0;
    argon2_threads_ = 0;
    emit agentHostIdChanged();
    emit operatorEnrolledChanged();

    setState(Connecting);
    socket_->connectToHost(host_, port_);
}

void AgentClient::refreshComponentList()
{
    if (state_ != Ready) {
        return;
    }
    sendRequest(QStringLiteral("component_list"), {});
}

AgentClient::ConnectionState AgentClient::connectionState() const { return state_; }
QString AgentClient::lastError() const { return last_error_; }
QString AgentClient::agentHostId() const { return host_id_; }
bool AgentClient::operatorEnrolled() const { return operator_enrolled_; }
bool AgentClient::operatorAuthenticated() const { return !operator_key_.isEmpty(); }
bool AgentClient::operatorAuthInProgress() const { return operator_auth_in_progress_; }

QList<AgentClient::ComponentInfo> AgentClient::components() const { return components_; }

void AgentClient::authenticateOperator(const QString& password)
{
    if (!operator_enrolled_ || operator_salt_.isEmpty()) {
        setError(QStringLiteral("agent has no operator enrolled"));
        return;
    }
    if (operator_auth_in_progress_) {
        return;  // ignore double-click
    }
    operator_auth_in_progress_ = true;
    emit operatorAuthInProgressChanged();

    const Argon2idParams params{
        argon2_mem_kib_,
        argon2_iters_,
        argon2_threads_,
    };
    const QByteArray salt = operator_salt_;

    auto future = QtConcurrent::run(
        [password, salt, params]() { return deriveOperatorKey(password, salt, params); });
    // FutureWatcher dispatches the completion back to the GUI thread.
    auto* watcher = new QFutureWatcher<OperatorKeyResult>(this);
    connect(watcher, &QFutureWatcher<OperatorKeyResult>::finished, this,
            [this, watcher]() {
                const OperatorKeyResult res = watcher->result();
                watcher->deleteLater();
                operator_auth_in_progress_ = false;
                emit operatorAuthInProgressChanged();
                if (!res.ok) {
                    setError(res.error_message);
                    return;
                }
                operator_key_ = res.key;
                emit operatorAuthenticatedChanged();
            });
    watcher->setFuture(future);
}

void AgentClient::startComponent(int row)    { sendComponentLifecycle(row, QStringLiteral("component_start")); }
void AgentClient::stopComponent(int row)     { sendComponentLifecycle(row, QStringLiteral("component_stop")); }
void AgentClient::restartComponent(int row)  { sendComponentLifecycle(row, QStringLiteral("component_restart")); }

// ---------------------------------------------------------------------------
// Config editor
// ---------------------------------------------------------------------------

void AgentClient::listConfigFiles(int row)
{
    if (state_ != Ready || operator_key_.isEmpty()) {
        emit configFailed(row, QStringLiteral("files"),
                          QStringLiteral("agent not ready or operator not authenticated"));
        return;
    }
    if (row < 0 || row >= components_.size()) {
        emit configFailed(row, QStringLiteral("files"), QStringLiteral("bad row"));
        return;
    }
    QJsonObject args;
    args.insert(QStringLiteral("id"), components_.at(row).id);
    pushPendingConfig({row, QString(), QStringLiteral("files")});
    sendRequest(QStringLiteral("config_files"), args, /*require_operator=*/true);
}

void AgentClient::loadConfigFile(int row, const QString& path)
{
    if (state_ != Ready || operator_key_.isEmpty()) {
        emit configFailed(row, QStringLiteral("get"),
                          QStringLiteral("agent not ready or operator not authenticated"));
        return;
    }
    if (row < 0 || row >= components_.size()) {
        emit configFailed(row, QStringLiteral("get"), QStringLiteral("bad row"));
        return;
    }
    QJsonObject args;
    args.insert(QStringLiteral("id"), components_.at(row).id);
    args.insert(QStringLiteral("path"), path);
    pushPendingConfig({row, path, QStringLiteral("get")});
    sendRequest(QStringLiteral("config_get"), args, /*require_operator=*/true);
}

void AgentClient::saveConfigFile(int row, const QString& path,
                                  const QString& content,
                                  const QString& expectedSha)
{
    if (state_ != Ready || operator_key_.isEmpty()) {
        emit configFailed(row, QStringLiteral("set"),
                          QStringLiteral("agent not ready or operator not authenticated"));
        return;
    }
    if (row < 0 || row >= components_.size()) {
        emit configFailed(row, QStringLiteral("set"), QStringLiteral("bad row"));
        return;
    }
    QJsonObject args;
    args.insert(QStringLiteral("id"), components_.at(row).id);
    args.insert(QStringLiteral("path"), path);
    args.insert(QStringLiteral("new_content_utf8"), content);
    args.insert(QStringLiteral("expected_sha256"), expectedSha);
    pushPendingConfig({row, path, QStringLiteral("set")});
    sendRequest(QStringLiteral("config_set"), args, /*require_operator=*/true);
}

void AgentClient::pushPendingConfig(const PendingConfigOp& op)
{
    pending_config_.append(op);
}

AgentClient::PendingConfigOp AgentClient::popPendingConfig()
{
    // If we ever get out-of-order responses this is where debugging starts;
    // today the agent answers strictly in-order so FIFO is correct.
    if (pending_config_.isEmpty()) {
        return {-1, QString(), QString()};
    }
    const PendingConfigOp op = pending_config_.first();
    pending_config_.removeFirst();
    return op;
}

void AgentClient::handleConfigFrame(const QString& type, const QJsonObject& body)
{
    const PendingConfigOp op = popPendingConfig();
    if (op.row < 0) {
        return;  // unsolicited response — ignore
    }
    const bool is_err = type.endsWith(QStringLiteral(".err"));
    if (is_err) {
        const QString code = body.value(QStringLiteral("code")).toString();
        const QString message = body.value(QStringLiteral("message")).toString();
        if (op.kind == QStringLiteral("set")
            && code == QStringLiteral("config_conflict")) {
            const QString current_sha = body.value(QStringLiteral("detail"))
                                             .toObject()
                                             .value(QStringLiteral("current_sha256"))
                                             .toString();
            emit configConflict(op.row, op.path, current_sha);
            return;
        }
        emit configFailed(op.row, op.kind, QStringLiteral("%1: %2").arg(code, message));
        return;
    }
    if (op.kind == QStringLiteral("files")) {
        const QJsonArray arr = body.value(QStringLiteral("files")).toArray();
        QStringList paths;
        paths.reserve(arr.size());
        for (const QJsonValue& v : arr) {
            const QJsonObject o = v.toObject();
            paths.append(o.value(QStringLiteral("path")).toString());
        }
        emit configFilesListed(op.row, paths);
    } else if (op.kind == QStringLiteral("get")) {
        emit configFileLoaded(
            op.row,
            body.value(QStringLiteral("path")).toString(),
            body.value(QStringLiteral("content_utf8")).toString(),
            body.value(QStringLiteral("sha256")).toString(),
            static_cast<qint64>(body.value(QStringLiteral("mtime")).toDouble()));
    } else if (op.kind == QStringLiteral("set")) {
        emit configFileSaved(
            op.row,
            body.value(QStringLiteral("path")).toString(),
            body.value(QStringLiteral("sha256")).toString());
    }
}

// ---------------------------------------------------------------------------
// Log tail: AgentClient starts a dedicated LogTailSession (its own
// connection) and forwards its signals out to QML. Defined in
// LogTailSession.{hpp,cpp}.
// ---------------------------------------------------------------------------

#if 0
class AgentClient::LogTailSession : public QObject {
    Q_OBJECT
public:
    LogTailSession(AgentClient* owner, int row, const QString& component_id,
                   const QString& path, const QString& filter_pattern,
                   QObject* parent = nullptr)
        : QObject(parent)
        , owner_(owner)
        , row_(row)
        , component_id_(component_id)
        , path_(path)
        , filter_pattern_(filter_pattern)
        , socket_(new QTcpSocket(this))
        , hello_done_(false)
    {
        connect(socket_, &QTcpSocket::connected, this, &LogTailSession::onConnected);
        connect(socket_, &QTcpSocket::readyRead, this, &LogTailSession::onReadyRead);
        connect(socket_, &QTcpSocket::errorOccurred, this, &LogTailSession::onError);
        connect(socket_, &QTcpSocket::disconnected, this, &LogTailSession::onDisconnected);
    }

    void start(const QString& host, quint16 port)
    {
        socket_->connectToHost(host, port);
    }

    void stop()
    {
        if (socket_->state() != QAbstractSocket::UnconnectedState) {
            socket_->abort();
        }
    }

    int row() const { return row_; }
    const QString& path() const { return path_; }

private slots:
    void onConnected()
    {
        // agent_hello first, same as the main client.
        QJsonObject inner;
        inner.insert(QStringLiteral("type"), QStringLiteral("agent_hello"));
        inner.insert(QStringLiteral("req_id"), QStringLiteral("tail-hello"));
        inner.insert(QStringLiteral("timestamp"), QString::fromUtf8(nowIso()));
        QJsonObject args;
        args.insert(QStringLiteral("panel_version"), QStringLiteral("0.1.0"));
        inner.insert(QStringLiteral("args"), args);
        socket_->write(encodeSignedFrame(owner_->psk_, inner));
    }

    void onReadyRead()
    {
        recv_buffer_.append(socket_->readAll());
        while (true) {
            if (recv_buffer_.size() < 4) return;
            const quint32 length =
                (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[0])) << 24) |
                (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[1])) << 16) |
                (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[2])) << 8)  |
                (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[3])));
            if (length == 0 || length > 256 * 1024) {
                emit owner_->logTailEnded(row_, QStringLiteral("invalid frame length"));
                stop();
                return;
            }
            if (static_cast<quint32>(recv_buffer_.size()) < 4 + length) return;
            const QByteArray body = recv_buffer_.mid(4, static_cast<int>(length));
            recv_buffer_.remove(0, 4 + static_cast<int>(length));
            const DecodeResult r = decodeAndVerify(body, owner_->psk_);
            if (!r.ok) {
                emit owner_->logTailEnded(row_, r.error_message);
                stop();
                return;
            }
            const QString t = r.payload.type;
            if (t == QStringLiteral("agent_hello.ok") && !hello_done_) {
                hello_done_ = true;
                sendTailRequest();
                emit owner_->logTailStarted(row_, path_);
            } else if (t == QStringLiteral("log_tail.push")) {
                if (r.payload.body.contains(QStringLiteral("line_no"))) {
                    emit owner_->logTailLine(
                        row_,
                        r.payload.body.value(QStringLiteral("line_no")).toInt(),
                        r.payload.body.value(QStringLiteral("text")).toString());
                } else if (r.payload.body.contains(QStringLiteral("bytes_b64"))) {
                    const QByteArray data = QByteArray::fromBase64(
                        r.payload.body.value(QStringLiteral("bytes_b64"))
                            .toString()
                            .toUtf8());
                    emit owner_->logTailBytes(
                        row_,
                        static_cast<qint64>(
                            r.payload.body.value(QStringLiteral("offset")).toDouble()),
                        data);
                }
            } else if (t.endsWith(QStringLiteral(".err"))) {
                emit owner_->logTailEnded(
                    row_,
                    r.payload.body.value(QStringLiteral("message")).toString());
                stop();
                return;
            }
        }
    }

    void onError()
    {
        emit owner_->logTailEnded(row_, socket_->errorString());
    }

    void onDisconnected()
    {
        emit owner_->logTailEnded(row_, QStringLiteral("disconnected"));
    }

private:
    void sendTailRequest()
    {
        QJsonObject args;
        args.insert(QStringLiteral("id"), component_id_);
        args.insert(QStringLiteral("path"), path_);
        if (!filter_pattern_.isEmpty()) {
            args.insert(QStringLiteral("filter_pattern"), filter_pattern_);
        }
        // from_offset omitted → agent tails from the current end.
        QJsonObject inner;
        inner.insert(QStringLiteral("type"), QStringLiteral("log_tail"));
        inner.insert(QStringLiteral("req_id"), QStringLiteral("tail-req"));
        inner.insert(QStringLiteral("timestamp"), QString::fromUtf8(nowIso()));
        inner.insert(QStringLiteral("args"), args);
        socket_->write(encodeSignedFrame(owner_->psk_, inner, owner_->operator_key_));
    }

    AgentClient* owner_;
    int row_;
    QString component_id_;
    QString path_;
    QString filter_pattern_;
    QTcpSocket* socket_;
    QByteArray recv_buffer_;
    bool hello_done_;
};
#endif

void AgentClient::startLogTail(int row, const QString& path,
                                const QString& filterPattern)
{
    if (state_ != Ready || operator_key_.isEmpty()) {
        emit logTailEnded(row, QStringLiteral("agent not ready / operator not authenticated"));
        return;
    }
    if (row < 0 || row >= components_.size()) {
        emit logTailEnded(row, QStringLiteral("bad row"));
        return;
    }
    stopLogTail();  // only one session at a time in v0
    log_tail_session_ = new LogTailSession(
        psk_, operator_key_, row, components_.at(row).id, path, filterPattern, this);
    connect(log_tail_session_, &LogTailSession::started,
            this, &AgentClient::logTailStarted);
    connect(log_tail_session_, &LogTailSession::line,
            this, &AgentClient::logTailLine);
    connect(log_tail_session_, &LogTailSession::bytesChunk,
            this, &AgentClient::logTailBytes);
    connect(log_tail_session_, &LogTailSession::ended,
            this, &AgentClient::logTailEnded);
    log_tail_session_->start(host_, port_);
}

void AgentClient::stopLogTail()
{
    if (log_tail_session_ != nullptr) {
        log_tail_session_->stop();
        log_tail_session_->deleteLater();
        log_tail_session_ = nullptr;
    }
}

void AgentClient::sendComponentLifecycle(int row, const QString& type)
{
    if (state_ != Ready) {
        setError(QStringLiteral("agent not ready"));
        return;
    }
    if (operator_key_.isEmpty()) {
        setError(QStringLiteral("operator not authenticated"));
        return;
    }
    if (row < 0 || row >= components_.size()) {
        setError(QStringLiteral("bad component row: %1").arg(row));
        return;
    }
    QJsonObject args;
    args.insert(QStringLiteral("id"), components_.at(row).id);
    sendRequest(type, args, /*require_operator=*/true);
}

void AgentClient::onSocketConnected()
{
    setState(Handshaking);
    sendHello();
}

void AgentClient::onSocketDisconnected()
{
    if (state_ != Failed) {
        setState(Disconnected);
    }
    reconnect_timer_->start();
}

void AgentClient::onSocketErrorOccurred()
{
    setError(socket_->errorString());
}

void AgentClient::onSocketReadyRead()
{
    recv_buffer_.append(socket_->readAll());
    while (true) {
        if (recv_buffer_.size() < 4) {
            return;
        }
        const quint32 length =
            (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[0])) << 24) |
            (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[1])) << 16) |
            (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[2])) << 8)  |
            (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[3])));
        if (length == 0 || length > kMaxFrameBytes) {
            setError(QStringLiteral("oversize or zero frame (%1)").arg(length));
            socket_->abort();
            return;
        }
        if (static_cast<quint32>(recv_buffer_.size()) < 4 + length) {
            return;
        }
        const QByteArray body = recv_buffer_.mid(4, static_cast<int>(length));
        recv_buffer_.remove(0, 4 + static_cast<int>(length));
        handleFrame(body);
    }
}

void AgentClient::handleFrame(const QByteArray& frame_body)
{
    const DecodeResult r = decodeAndVerify(frame_body, psk_);
    if (!r.ok) {
        setError(r.error_message);
        socket_->abort();
        return;
    }
    const QString t = r.payload.type;
    if (t == QStringLiteral("agent_hello.ok")) {
        host_id_ = r.payload.body.value(QStringLiteral("host_id")).toString();
        const QJsonValue salt_v = r.payload.body.value(QStringLiteral("operator_salt_b64"));
        operator_enrolled_ = salt_v.isString() && !salt_v.toString().isEmpty();
        if (operator_enrolled_) {
            operator_salt_ = QByteArray::fromBase64(salt_v.toString().toUtf8());
            const QJsonObject argon = r.payload.body
                                         .value(QStringLiteral("argon2id"))
                                         .toObject();
            argon2_mem_kib_ = argon.value(QStringLiteral("mem_kib")).toInt();
            argon2_iters_ = argon.value(QStringLiteral("iters")).toInt();
            argon2_threads_ = argon.value(QStringLiteral("threads")).toInt();
        } else {
            operator_salt_.clear();
            argon2_mem_kib_ = 0;
            argon2_iters_ = 0;
            argon2_threads_ = 0;
        }
        emit agentHostIdChanged();
        emit operatorEnrolledChanged();
        setState(Ready);
        // Immediately fetch the initial component list.
        refreshComponentList();
        return;
    }
    if (t == QStringLiteral("component_start.ok")
        || t == QStringLiteral("component_stop.ok")
        || t == QStringLiteral("component_restart.ok")) {
        // Refresh the component list so the UI reflects the new state.
        refreshComponentList();
        return;
    }
    if (t == QStringLiteral("component_list.ok")) {
        components_.clear();
        const QJsonArray arr = r.payload.body.value(QStringLiteral("components")).toArray();
        for (const QJsonValue& v : arr) {
            const QJsonObject o = v.toObject();
            ComponentInfo ci;
            ci.id = o.value(QStringLiteral("id")).toString();
            ci.display_name = o.value(QStringLiteral("display_name")).toString();
            ci.state = o.value(QStringLiteral("state")).toString();
            const QJsonValue pid = o.value(QStringLiteral("pid"));
            ci.pid = pid.isNull() ? 0 : pid.toInt();
            const QJsonValue started = o.value(QStringLiteral("started_at"));
            ci.started_at = started.isNull() ? 0 : static_cast<qint64>(started.toDouble());
            ci.telemetry_endpoint = o.value(QStringLiteral("telemetry_endpoint")).toString();
            components_.append(ci);
        }
        emit componentListUpdated();
        return;
    }
    if (t.startsWith(QStringLiteral("config_"))) {
        handleConfigFrame(t, r.payload.body);
        return;
    }
    if (t.endsWith(QStringLiteral(".err"))) {
        const QString msg = r.payload.body.value(QStringLiteral("message")).toString();
        const QString code = r.payload.body.value(QStringLiteral("code")).toString();
        setError(QStringLiteral("%1: %2 (%3)").arg(t, msg, code));
        return;
    }
    // Unhandled types are ignored for v0 — panel only consumes a subset.
}

void AgentClient::sendHello()
{
    QJsonObject inner;
    inner.insert(QStringLiteral("type"), QStringLiteral("agent_hello"));
    inner.insert(QStringLiteral("req_id"), QString::fromUtf8(freshReqId()));
    inner.insert(QStringLiteral("timestamp"), QString::fromUtf8(nowIso()));
    QJsonObject args;
    args.insert(QStringLiteral("panel_version"), QStringLiteral("0.1.0"));
    inner.insert(QStringLiteral("args"), args);
    socket_->write(encodeSignedFrame(psk_, inner));
}

void AgentClient::sendRequest(const QString& type, const QJsonObject& args,
                              bool require_operator)
{
    QJsonObject inner;
    inner.insert(QStringLiteral("type"), type);
    inner.insert(QStringLiteral("req_id"), QString::fromUtf8(freshReqId()));
    inner.insert(QStringLiteral("timestamp"), QString::fromUtf8(nowIso()));
    inner.insert(QStringLiteral("args"), args);
    const QByteArray op_key = require_operator ? operator_key_ : QByteArray();
    socket_->write(encodeSignedFrame(psk_, inner, op_key));
}

void AgentClient::setState(ConnectionState s)
{
    if (state_ == s) return;
    state_ = s;
    if (s == Ready) {
        refresh_timer_->start();
    } else {
        refresh_timer_->stop();
    }
    emit connectionStateChanged();
}

void AgentClient::setError(const QString& msg)
{
    last_error_ = msg;
    emit lastErrorChanged();
}

} // namespace pslcp::net
