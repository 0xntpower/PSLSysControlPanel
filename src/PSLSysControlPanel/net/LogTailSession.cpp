#include "LogTailSession.hpp"

#include "Envelope.hpp"

#include <QByteArray>
#include <QJsonObject>
#include <QTcpSocket>

namespace pslcp::net {

LogTailSession::LogTailSession(const QByteArray& psk, const QByteArray& operator_key,
                               int row, const QString& component_id,
                               const QString& path, const QString& filter_pattern,
                               QObject* parent)
    : QObject(parent)
    , psk_(psk)
    , operator_key_(operator_key)
    , row_(row)
    , component_id_(component_id)
    , path_(path)
    , filter_pattern_(filter_pattern)
    , socket_(new QTcpSocket(this))
    , hello_done_(false)
    , ended_emitted_(false)
{
    connect(socket_, &QTcpSocket::connected, this, &LogTailSession::onConnected);
    connect(socket_, &QTcpSocket::readyRead, this, &LogTailSession::onReadyRead);
    connect(socket_, &QTcpSocket::errorOccurred, this, &LogTailSession::onError);
    connect(socket_, &QTcpSocket::disconnected, this, &LogTailSession::onDisconnected);
}

void LogTailSession::start(const QString& host, quint16 port)
{
    socket_->connectToHost(host, port);
}

void LogTailSession::stop()
{
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
    while (true) {
        if (recv_buffer_.size() < 4) return;
        const quint32 length =
            (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[0])) << 24) |
            (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[1])) << 16) |
            (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[2])) << 8) |
            (static_cast<quint32>(static_cast<unsigned char>(recv_buffer_[3])));
        if (length == 0 || length > 256 * 1024) {
            if (!ended_emitted_) {
                ended_emitted_ = true;
                emit ended(row_, QStringLiteral("invalid frame length"));
            }
            stop();
            return;
        }
        if (static_cast<quint32>(recv_buffer_.size()) < 4 + length) return;
        const QByteArray body = recv_buffer_.mid(4, static_cast<int>(length));
        recv_buffer_.remove(0, 4 + static_cast<int>(length));
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
            sendTailRequest();
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
                emit ended(row_,
                            r.payload.body.value(QStringLiteral("message")).toString());
            }
            stop();
            return;
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

void LogTailSession::sendTailRequest()
{
    QJsonObject args;
    args.insert(QStringLiteral("id"), component_id_);
    args.insert(QStringLiteral("path"), path_);
    if (!filter_pattern_.isEmpty()) {
        args.insert(QStringLiteral("filter_pattern"), filter_pattern_);
    }
    QJsonObject inner;
    inner.insert(QStringLiteral("type"), QStringLiteral("log_tail"));
    inner.insert(QStringLiteral("req_id"), QStringLiteral("tail-req"));
    inner.insert(QStringLiteral("timestamp"), QString::fromUtf8(nowIso()));
    inner.insert(QStringLiteral("args"), args);
    socket_->write(encodeSignedFrame(psk_, inner, operator_key_));
}

} // namespace pslcp::net
