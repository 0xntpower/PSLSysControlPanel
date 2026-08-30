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

#include <algorithm>
#include <cstring>

namespace pslcp::net {
namespace {

constexpr int kReconnectDelayMsBase = 1000;
constexpr int kReconnectDelayMsMax = 30000;
constexpr int kSocketTimeoutMs = 8000;
constexpr int kMaxFrameBytes = 256 * 1024;
// Poll the agent's component_list every few seconds while connected so the
// UI reflects crashes / restarts / new enrollments without manual refresh.
constexpr int kRefreshIntervalMs = 3000;
// Process at most this many frames in one onSocketReadyRead/pump call
// before yielding to the event loop. Keeps the GUI responsive when a
// network stall releases a flood of buffered frames at once.
constexpr int kMaxFramesPerPump = 32;
// Compact recv_buffer_ once the read-cursor passes this watermark.
// Trades memmove cost against memory footprint of the leading slack.
constexpr int kRecvBufferCompactWatermark = 64 * 1024;

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
    , pump_timer_(new QTimer(this))
    , recv_consumed_(0)
    , reconnect_delay_ms_(kReconnectDelayMsBase)
    , component_list_in_flight_(false)
    , state_(Disconnected)
    , operator_enrolled_(false)
    , operator_auth_in_progress_(false)
    , port_(0)
    , argon2_mem_kib_(0)
    , argon2_iters_(0)
    , argon2_threads_(0)
{
    connect(socket_, &QTcpSocket::connected, this, &AgentClient::onSocketConnected);
    connect(socket_, &QTcpSocket::readyRead, this, &AgentClient::onSocketReadyRead);
    connect(socket_, &QTcpSocket::disconnected, this, &AgentClient::onSocketDisconnected);
    connect(socket_, &QTcpSocket::errorOccurred, this, &AgentClient::onSocketErrorOccurred);

    reconnect_timer_->setSingleShot(true);
    reconnect_timer_->setInterval(reconnect_delay_ms_);
    connect(reconnect_timer_, &QTimer::timeout, this, &AgentClient::start);

    // Refresh timer kicks in when the state machine enters Ready and is
    // stopped on any other transition (see setState). Its sole job is to
    // keep the component list fresh for the UI.
    refresh_timer_->setInterval(kRefreshIntervalMs);
    connect(refresh_timer_, &QTimer::timeout, this, &AgentClient::refreshComponentList);

    // Continuation timer for pumpFramesFromBuffer; 0ms singleshot returns
    // control to the event loop between frame batches so the UI can paint.
    pump_timer_->setSingleShot(true);
    pump_timer_->setInterval(0);
    connect(pump_timer_, &QTimer::timeout, this, &AgentClient::pumpFramesFromBuffer);
}

AgentClient::~AgentClient()
{
    // Drop any tail sessions before closing the main socket. Each
    // session owns its own socket, so shutdown order between them
    // doesn't matter, but leaking them would leave QObject children
    // attached to ``this`` and Qt would tear them down anyway —
    // ``stopLogTail`` does it explicitly so socket abort/close is
    // synchronous instead of via the deletion chain.
    stopLogTail();
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
    pump_timer_->stop();
    if (socket_->state() != QAbstractSocket::UnconnectedState) {
        socket_->abort();
    }
    recv_buffer_.clear();
    recv_consumed_ = 0;
    component_list_in_flight_ = false;
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
    // Don't pile up another poll while the previous one is still
    // in flight — under high latency the responses arrive late and
    // the GUI ends up parsing N stale-but-identical lists in a row.
    if (component_list_in_flight_) {
        return;
    }
    component_list_in_flight_ = true;
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


void AgentClient::startLogTail(int row, const QString& path,
                                const QString& filterPattern,
                                qint64 historyBytes, qint64 fromOffset)
{
    if (state_ != Ready || operator_key_.isEmpty()) {
        emit logTailEnded(row, QStringLiteral("agent not ready / operator not authenticated"));
        return;
    }
    if (row < 0 || row >= components_.size()) {
        emit logTailEnded(row, QStringLiteral("bad row"));
        return;
    }
    // Replace any existing session for this row — used when RELOAD is
    // hit with a new filter, or when an old session ended and the
    // panel decided to restart it. Other rows' sessions are unaffected.
    stopLogTailForRow(row);
    auto* session = new LogTailSession(
        psk_, operator_key_, row, components_.at(row).id, path, filterPattern,
        historyBytes, fromOffset, this);
    connect(session, &LogTailSession::started,
            this, &AgentClient::logTailStarted);
    connect(session, &LogTailSession::line,
            this, &AgentClient::logTailLine);
    connect(session, &LogTailSession::bytesChunk,
            this, &AgentClient::logTailBytes);
    connect(session, &LogTailSession::ended,
            this, &AgentClient::onLogTailSessionEnded);
    log_tail_sessions_.insert(row, session);
    session->start(host_, port_);
}

void AgentClient::stopLogTailForRow(int row)
{
    auto it = log_tail_sessions_.find(row);
    if (it == log_tail_sessions_.end()) return;
    LogTailSession* session = it.value();
    log_tail_sessions_.erase(it);
    if (session != nullptr) {
        session->stop();
        session->deleteLater();
    }
}

void AgentClient::stopLogTail()
{
    // Tear down every running session. Used on disconnect / re-auth
    // where the whole set has to go away.
    const QList<int> rows = log_tail_sessions_.keys();
    for (int row : rows) {
        stopLogTailForRow(row);
    }
}

int AgentClient::activeLogTailCount() const
{
    return log_tail_sessions_.size();
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
    // Exponential backoff: each successive failed attempt waits longer
    // before retrying, so a flaky network doesn't get hammered with
    // reconnect storms (which themselves accumulated GUI-thread work).
    // Reset to base on a successful Ready transition (see setState).
    reconnect_timer_->start(reconnect_delay_ms_);
    reconnect_delay_ms_ =
        std::min(reconnect_delay_ms_ * 2, kReconnectDelayMsMax);
}

void AgentClient::onSocketErrorOccurred()
{
    setError(socket_->errorString());
}

void AgentClient::onSocketReadyRead()
{
    recv_buffer_.append(socket_->readAll());
    pumpFramesFromBuffer();
}

void AgentClient::pumpFramesFromBuffer()
{
    int processed = 0;
    while (processed < kMaxFramesPerPump) {
        const int available = recv_buffer_.size() - recv_consumed_;
        if (available < 4) {
            break;
        }
        const unsigned char* p =
            reinterpret_cast<const unsigned char*>(recv_buffer_.constData()) + recv_consumed_;
        const quint32 length =
            (static_cast<quint32>(p[0]) << 24) |
            (static_cast<quint32>(p[1]) << 16) |
            (static_cast<quint32>(p[2]) << 8)  |
            (static_cast<quint32>(p[3]));
        if (length == 0 || length > kMaxFrameBytes) {
            setError(QStringLiteral("oversize or zero frame (%1)").arg(length));
            socket_->abort();
            return;
        }
        if (static_cast<quint32>(available) < 4 + length) {
            break;
        }
        const QByteArray body =
            QByteArray(recv_buffer_.constData() + recv_consumed_ + 4,
                       static_cast<int>(length));
        recv_consumed_ += 4 + static_cast<int>(length);
        ++processed;
        handleFrame(body);
        // handleFrame may have aborted the socket and cleared buffers
        // (e.g. on bad signature); bail out if state's been torn down.
        if (state_ == Disconnected || state_ == Failed) {
            return;
        }
    }

    // Compact lazily — drop the leading consumed slack once it crosses
    // the watermark, so we don't pay a memmove on every single frame
    // but also don't hold unbounded leading bytes forever.
    if (recv_consumed_ >= kRecvBufferCompactWatermark) {
        recv_buffer_.remove(0, recv_consumed_);
        recv_consumed_ = 0;
    }

    // If more complete frames remain past the per-pump cap, yield to
    // the event loop and resume on the next tick. This is what keeps
    // the UI responsive when a stall releases a flood of frames.
    if (recv_buffer_.size() - recv_consumed_ >= 4) {
        const unsigned char* p =
            reinterpret_cast<const unsigned char*>(recv_buffer_.constData()) + recv_consumed_;
        const quint32 next_len =
            (static_cast<quint32>(p[0]) << 24) |
            (static_cast<quint32>(p[1]) << 16) |
            (static_cast<quint32>(p[2]) << 8)  |
            (static_cast<quint32>(p[3]));
        if (static_cast<quint32>(recv_buffer_.size() - recv_consumed_) >= 4 + next_len) {
            pump_timer_->start();
        }
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
        component_list_in_flight_ = false;
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
            const QJsonValue cpu = o.value(QStringLiteral("cpu_pct"));
            ci.cpu_pct = cpu.isNull() ? -1.0 : cpu.toDouble();
            const QJsonValue rss = o.value(QStringLiteral("rss_mb"));
            ci.rss_mb = rss.isNull() ? -1.0 : rss.toDouble();
            const QJsonArray lf_arr = o.value(QStringLiteral("log_files")).toArray();
            for (const QJsonValue& lf : lf_arr) {
                ci.log_files.append(lf.toString());
            }
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
        // Any .err that's a reply to component_list clears the in-flight
        // gate so the next poll can fire instead of being silently dropped.
        if (t == QStringLiteral("component_list.err")) {
            component_list_in_flight_ = false;
        }
        const QString msg = r.payload.body.value(QStringLiteral("message")).toString();
        const QString code = r.payload.body.value(QStringLiteral("code")).toString();
        if (code == QStringLiteral("bad_op_signature")) {
            handleOperatorRejected();
        } else {
            setError(QStringLiteral("%1: %2 (%3)").arg(t, msg, code));
        }
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
        // Successful handshake — reset the backoff so the next outage
        // starts at base delay again, not whatever it had escalated to.
        reconnect_delay_ms_ = kReconnectDelayMsBase;
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

void AgentClient::handleOperatorRejected()
{
    // Drop the cached key, flip the auth flag. Any QML auto-tail / other
    // background retry that was racing on operatorAuthenticated will
    // short-circuit on the next tick since the property is now false.
    if (!operator_key_.isEmpty()) {
        std::fill(operator_key_.begin(), operator_key_.end(), static_cast<char>(0));
        operator_key_.clear();
        emit operatorAuthenticatedChanged();
    }
    setError(QStringLiteral(
        "operator password rejected — please re-authenticate"));
    // Any in-flight log_tail on its secondary connection is already
    // terminating from the agent's .err response; no explicit stop needed.
}

void AgentClient::onLogTailSessionEnded(int row, const QString& reason)
{
    if (reason.startsWith(QStringLiteral("bad_op_signature"))) {
        handleOperatorRejected();
    }
    // Reap the dead session from the hash so a future startLogTail for
    // the same row creates a fresh one. The QTcpSocket may still be
    // emitting tail signals during teardown; ``deleteLater`` defers the
    // free until the event loop drains.
    auto it = log_tail_sessions_.find(row);
    if (it != log_tail_sessions_.end()) {
        LogTailSession* session = it.value();
        log_tail_sessions_.erase(it);
        if (session != nullptr) {
            session->deleteLater();
        }
    }
    emit logTailEnded(row, reason);
}

} // namespace pslcp::net
