#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QList>
#include <QPointF>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

namespace pslcp::net {
class AgentClient;
} // namespace pslcp::net

namespace pslcp {

enum class ComponentStatus : int {
    Stopped = 0,
    Starting = 1,
    Running = 2,
    Degraded = 3,
    Crashed = 4
};

struct ComponentRow {
    QString name;
    QString host;
    ComponentStatus status = ComponentStatus::Stopped;
    qint64 uptimeSec = 0;
    double eventsPerSec = 0.0;
    double cpuPct = 0.0;
    int queueDepth = 0;
    double phase = 0.0;
    double baseline = 0.0;
    QList<QPointF> history;
    QStringList recentLogs;
};

class ComponentModel : public QAbstractListModel {
    Q_OBJECT
public:
    enum Roles {
        NameRole = Qt::UserRole + 1,
        HostRole,
        StatusRole,
        StatusTextRole,
        UptimeRole,
        UptimeTextRole,
        EventsRole,
        CpuRole,
        QueueRole
    };

    explicit ComponentModel(QObject* parent = nullptr);

    // Attach a real agent client. Once attached, the model stops its
    // synthetic ticker and sources ``id``/``display_name``/``state`` from
    // the agent's ``component_list`` responses. The detail-pane-specific
    // fields (events/sec, CPU, queue, chart, logs) remain empty until a
    // future phase hooks up log_tail + telemetry aggregation.
    void attachAgent(net::AgentClient* client);

    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    Q_INVOKABLE void startComponent(int row);
    Q_INVOKABLE void stopComponent(int row);
    Q_INVOKABLE void restartComponent(int row);
    Q_INVOKABLE QVariantList historyFor(int row) const;
    Q_INVOKABLE QStringList logsFor(int row) const;
    Q_INVOKABLE QVariantMap snapshotFor(int row) const;

private:
    void Tick();
    void SyncFromAgent();
    static QString FormatUptime(qint64 sec);
    static QString StatusText(ComponentStatus s);
    static ComponentStatus StatusFromString(const QString& s);
    void PushLog(int row, const QString& line);

    QList<ComponentRow> rows_;
    QTimer tickTimer_;
    qint64 tickCount_;
    net::AgentClient* agent_client_;
};

} // namespace pslcp
