#pragma once

// Dedicated secondary connection for ``log_tail`` streaming. Per spec §6.4
// ``log_tail`` takes over its own session (our main AgentClient connection
// would otherwise be blocked from request/response traffic for the duration
// of the stream). Owned by AgentClient, talks only to the same agent.

#include <QByteArray>
#include <QObject>
#include <QString>

class QTcpSocket;
class QTimer;

namespace pslcp::net {

class LogTailSession : public QObject {
    Q_OBJECT
public:
    // Two history-priming modes, in priority order:
    //
    //   * ``from_offset >= 0`` — explicit byte position. The session
    //     still sends a ``log_files`` probe to detect rotation: if the
    //     current ``file_size`` is at least ``from_offset``, the tail
    //     starts at ``from_offset`` exactly; if it's smaller (file was
    //     rotated and is now shorter than our cached high-water mark),
    //     the tail starts at 0 instead. Used by the mini-log to resume
    //     where it left off on a row switch without re-streaming the
    //     entire file.
    //
    //   * ``history_bytes > 0`` (only consulted when ``from_offset < 0``)
    //     — relative-to-end mode: probe ``log_files`` to learn ``file_size``,
    //     then start tail at ``max(0, file_size - history_bytes)``. Used
    //     for "fetch the entire current file" with a sentinel like
    //     ``MAX_SAFE_INTEGER``.
    //
    //   * Both 0/-1 — start at EOF (tail only new writes).
    LogTailSession(const QByteArray& psk, const QByteArray& operator_key,
                   int row, const QString& component_id,
                   const QString& path, const QString& filter_pattern,
                   qint64 history_bytes, qint64 from_offset,
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
    // Drains complete frames from recv_buffer_ starting at recv_consumed_.
    // Bounded per call; reschedules itself via pump_timer_ if more frames
    // are buffered. See AgentClient::pumpFramesFromBuffer for rationale.
    void pumpFramesFromBuffer();

    QByteArray psk_;
    QByteArray operator_key_;
    int row_;
    QString component_id_;
    QString path_;
    QString filter_pattern_;
    qint64 history_bytes_;
    qint64 from_offset_;
    QTcpSocket* socket_;
    QTimer* pump_timer_;
    QByteArray recv_buffer_;
    int recv_consumed_;
    bool hello_done_;
    bool probe_sent_;
    bool tail_sent_;
    bool ended_emitted_;
};

} // namespace pslcp::net
