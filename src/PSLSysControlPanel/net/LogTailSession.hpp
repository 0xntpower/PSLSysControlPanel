#pragma once

// Dedicated secondary connection for ``log_tail`` streaming. Per spec §6.4
// ``log_tail`` takes over its own session (our main AgentClient connection
// would otherwise be blocked from request/response traffic for the duration
// of the stream). Owned by AgentClient, talks only to the same agent.

#include <QByteArray>
#include <QObject>
#include <QString>

class QTcpSocket;

namespace pslcp::net {

class LogTailSession : public QObject {
    Q_OBJECT
public:
    // ``history_bytes`` > 0 primes the stream with the tail of the existing
    // file: the session sends a ``log_files`` probe to learn the current
    // size, then starts ``log_tail`` with ``from_offset = size -
    // history_bytes`` (clamped at 0). 0 means "start at EOF" (tail only
    // new writes). Clients that want an initial context chunk should pass
    // e.g. 64 KiB for the overlay or ~4 KiB for the detail-pane mirror.
    LogTailSession(const QByteArray& psk, const QByteArray& operator_key,
                   int row, const QString& component_id,
                   const QString& path, const QString& filter_pattern,
                   qint64 history_bytes,
                   QObject* parent = nullptr);

    // Connect to ``host:port`` and drive the handshake. Emits either
    // ``started`` or ``ended`` exactly once per lifetime.
    void start(const QString& host, quint16 port);

    // Abort the socket. Idempotent.
    void stop();

    int row() const { return row_; }
    const QString& path() const { return path_; }

signals:
    void started(int row, const QString& path);
    void line(int row, int lineNo, const QString& text);
    void bytesChunk(int row, qint64 offset, const QByteArray& data);
    void ended(int row, const QString& reason);

private slots:
    void onConnected();
    void onReadyRead();
    void onError();
    void onDisconnected();

private:
    void sendFilesProbe();
    void sendTailRequest(qint64 from_offset);

    QByteArray psk_;
    QByteArray operator_key_;
    int row_;
    QString component_id_;
    QString path_;
    QString filter_pattern_;
    qint64 history_bytes_;
    QTcpSocket* socket_;
    QByteArray recv_buffer_;
    bool hello_done_;
    bool probe_sent_;
    bool tail_sent_;
    bool ended_emitted_;
};

} // namespace pslcp::net
