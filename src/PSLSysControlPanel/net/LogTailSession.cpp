#include "LogTailSession.hpp"

#include "Envelope.hpp"

#include <QByteArray>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QTcpSocket>
#include <QTimer>

namespace pslcp::net {

namespace {

constexpr int kMaxFrameBytesTail = 256 * 1024;
// Tail streams are higher-volume than the main control connection — a
// log_tail flood after a network stall can dump hundreds of push frames
// at once. Same bounded-pump pattern as AgentClient: process this many
// per call, then yield to the event loop so the GUI can paint.
constexpr int kMaxFramesPerPumpTail = 32;
constexpr int kRecvBufferCompactWatermarkTail = 64 * 1024;

} // namespace

LogTailSession::LogTailSession(const QByteArray& psk, const QByteArray& operator_key,
                               int row, const QString& component_id,
                               const QString& path, const QString& filter_pattern,
                               qint64 history_bytes, qint64 from_offset,
                               QObject* parent)
    : QObject(parent)
    , psk_(psk)
    , operator_key_(operator_key)
    , row_(row)
    , component_id_(component_id)
    , path_(path)
    , filter_pattern_(filter_pattern)
    , history_bytes_(history_bytes)
    , from_offset_(from_offset)
    , socket_(new QTcpSocket(this))
    , pump_timer_(new QTimer(this))
    , recv_consumed_(0)
    , hello_done_(false)
    , probe_sent_(false)
    , tail_sent_(false)
    , ended_emitted_(false)
{
    connect(socket_, &QTcpSocket::connected, this, &LogTailSession::onConnected);
    connect(socket_, &QTcpSocket::readyRead, this, &LogTailSession::onReadyRead);
    connect(socket_, &QTcpSocket::errorOccurred, this, &LogTailSession::onError);
    connect(socket_, &QTcpSocket::disconnected, this, &LogTailSession::onDisconnected);

    pump_timer_->setSingleShot(true);
    pump_timer_->setInterval(0);
    connect(pump_timer_, &QTimer::timeout, this, &LogTailSession::pumpFramesFromBuffer);
}

void LogTailSession::start(const QString& host, quint16 port)
{
    socket_->connectToHost(host, port);
}

void LogTailSession::stop()
{
    pump_timer_->stop();
    if (socket_->state() != QAbstractSocket::UnconnectedState) {
        socket_->abort();
    }
}

void LogTailSession::onConnected()
{
    QJsonObject inner;
    inner.insert(QStringLiteral("type"), QStringLiteral("agent_hello"));
    inner.insert(QStringLiteral("req_id"), QStringLiteral("tail-hello"));
    inner.insert(QStringLiteral("timestamp"), QString::fromUtf8(nowIso()));
    QJsonObject args;
    args.insert(QStringLiteral("panel_version"), QStringLiteral("0.1.0"));
    inner.insert(QStringLiteral("args"), args);
    socket_->write(encodeSignedFrame(psk_, inner));
}

void LogTailSession::onReadyRead()
{
    recv_buffer_.append(socket_->readAll());
    pumpFramesFromBuffer();
}

void LogTailSession::pumpFramesFromBuffer()
{
    int processed = 0;
    while (processed < kMaxFramesPerPumpTail) {
        const int available = recv_buffer_.size() - recv_consumed_;
        if (available < 4) break;
        const unsigned char* p =
            reinterpret_cast<const unsigned char*>(recv_buffer_.constData()) + recv_consumed_;
        const quint32 length =
            (static_cast<quint32>(p[0]) << 24) |
            (static_cast<quint32>(p[1]) << 16) |
            (static_cast<quint32>(p[2]) << 8)  |
            (static_cast<quint32>(p[3]));
        if (length == 0 || length > kMaxFrameBytesTail) {
            if (!ended_emitted_) {
                ended_emitted_ = true;
                emit ended(row_, QStringLiteral("invalid frame length"));
            }
            stop();
            return;
        }
        if (static_cast<quint32>(available) < 4 + length) break;
        const QByteArray body =
            QByteArray(recv_buffer_.constData() + recv_consumed_ + 4,
                       static_cast<int>(length));
        recv_consumed_ += 4 + static_cast<int>(length);
        ++processed;
        const DecodeResult r = decodeAndVerify(body, psk_);
        if (!r.ok) {
            if (!ended_emitted_) {
                ended_emitted_ = true;
                emit ended(row_, r.error_message);
            }
            stop();
            return;
        }
        const QString t = r.payload.type;
        if (t == QStringLiteral("agent_hello.ok") && !hello_done_) {
            hello_done_ = true;
            if (from_offset_ >= 0 || history_bytes_ > 0) {
                // Probe the file size first; actual log_tail is deferred
                // until the probe response lands so we can choose between
                // resume-at-cached-offset and back-up-from-end semantics
                // (and detect rotation in the resume case).
                sendFilesProbe();
            } else {
                sendTailRequest(-1);  // -1 = omit from_offset, tail from EOF
                emit started(row_, path_);
            }
        } else if (t == QStringLiteral("log_files.ok") && probe_sent_ && !tail_sent_) {
            const QJsonArray files =
                r.payload.body.value(QStringLiteral("files")).toArray();
            qint64 file_size = 0;
            for (const QJsonValue& v : files) {
                const QJsonObject f = v.toObject();
                if (f.value(QStringLiteral("path")).toString() == path_) {
                    file_size =
                        static_cast<qint64>(f.value(QStringLiteral("size")).toDouble());
                    break;
                }
            }
            qint64 resolved_from = 0;
            if (from_offset_ >= 0) {
                // Resume mode. Use the cached offset if the file is at
                // least that big; otherwise the file was rotated (new
                // session, archive cycle) and is now shorter than where
                // we left off, so start over from the beginning.
                resolved_from = (file_size >= from_offset_) ? from_offset_ : 0;
            } else {
                // Relative-to-end mode (history_bytes_).
                resolved_from =
                    (file_size > history_bytes_) ? (file_size - history_bytes_) : 0;
            }
            sendTailRequest(resolved_from);
            emit started(row_, path_);
        } else if (t == QStringLiteral("log_tail.push")) {
            if (r.payload.body.contains(QStringLiteral("line_no"))) {
                emit line(row_,
                          r.payload.body.value(QStringLiteral("line_no")).toInt(),
                          r.payload.body.value(QStringLiteral("text")).toString());
            } else if (r.payload.body.contains(QStringLiteral("bytes_b64"))) {
                const QByteArray data = QByteArray::fromBase64(
                    r.payload.body.value(QStringLiteral("bytes_b64")).toString().toUtf8());
                emit bytesChunk(
                    row_,
                    static_cast<qint64>(
                        r.payload.body.value(QStringLiteral("offset")).toDouble()),
                    data);
            }
        } else if (t.endsWith(QStringLiteral(".err"))) {
            if (!ended_emitted_) {
                ended_emitted_ = true;
                // Prefix the reason with the error code so the AgentClient
                // can route on ``bad_op_signature`` without a new signal
                // parameter. Empty-code responses pass the message through.
                const QString code =
                    r.payload.body.value(QStringLiteral("code")).toString();
                const QString msg =
                    r.payload.body.value(QStringLiteral("message")).toString();
                const QString reason =
                    code.isEmpty() ? msg : (code + QStringLiteral(": ") + msg);
                emit ended(row_, reason);
            }
            stop();
            return;
        }
    }

    if (recv_consumed_ >= kRecvBufferCompactWatermarkTail) {
        recv_buffer_.remove(0, recv_consumed_);
        recv_consumed_ = 0;
    }

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

void LogTailSession::onError()
{
    if (!ended_emitted_) {
        ended_emitted_ = true;
        emit ended(row_, socket_->errorString());
    }
}

void LogTailSession::onDisconnected()
{
    if (!ended_emitted_) {
        ended_emitted_ = true;
        emit ended(row_, QStringLiteral("disconnected"));
    }
}

void LogTailSession::sendFilesProbe()
{
    QJsonObject args;
    args.insert(QStringLiteral("id"), component_id_);
    QJsonObject inner;
    inner.insert(QStringLiteral("type"), QStringLiteral("log_files"));
    inner.insert(QStringLiteral("req_id"), QStringLiteral("tail-files"));
    inner.insert(QStringLiteral("timestamp"), QString::fromUtf8(nowIso()));
    inner.insert(QStringLiteral("args"), args);
    // log_files is operator-gated server-side.
    socket_->write(encodeSignedFrame(psk_, inner, operator_key_));
    probe_sent_ = true;
}

void LogTailSession::sendTailRequest(qint64 from_offset)
{
    QJsonObject args;
    args.insert(QStringLiteral("id"), component_id_);
    args.insert(QStringLiteral("path"), path_);
    if (!filter_pattern_.isEmpty()) {
        args.insert(QStringLiteral("filter_pattern"), filter_pattern_);
    }
    if (from_offset >= 0) {
        args.insert(QStringLiteral("from_offset"),
                    static_cast<double>(from_offset));
    }
    QJsonObject inner;
    inner.insert(QStringLiteral("type"), QStringLiteral("log_tail"));
    inner.insert(QStringLiteral("req_id"), QStringLiteral("tail-req"));
    inner.insert(QStringLiteral("timestamp"), QString::fromUtf8(nowIso()));
    inner.insert(QStringLiteral("args"), args);
    socket_->write(encodeSignedFrame(psk_, inner, operator_key_));
    tail_sent_ = true;
}

} // namespace pslcp::net
