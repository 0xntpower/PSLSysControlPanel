#include "ComponentModel.hpp"

#include "net/AgentClient.hpp"

#include <QDateTime>
#include <QtMath>

#include <cmath>
#include <random>

namespace pslcp {

namespace {

std::mt19937& Rng()
{
    static std::mt19937 rng{std::random_device{}()};
    return rng;
}

double Jitter(double amplitude)
{
    std::uniform_real_distribution<double> dist(-amplitude, amplitude);
    return dist(Rng());
}

QString TimestampNow()
{
    return QDateTime::currentDateTime().toString("HH:mm:ss");
}

} // namespace

ComponentModel::ComponentModel(QObject* parent)
    : QAbstractListModel(parent)
    , tickCount_(0)
    , agent_client_(nullptr)
{
    const QList<std::tuple<QString, QString, ComponentStatus, double, double>> seed{
        {"PolyDataCollector",   "vps-01",          ComponentStatus::Running,  142.0, 8.1},
        {"PolyTraderLightning", "vps-01",          ComponentStatus::Running,   18.3, 4.4},
        {"PolySignalEngine",    "workstation-01",  ComponentStatus::Running,   62.7, 21.5},
        {"PolyLiveVisualizer",  "workstation-01",  ComponentStatus::Degraded,   9.8, 2.6},
        {"SignalOrchestrator",  "vps-01",          ComponentStatus::Stopped,    0.0, 0.0},
    };

    int i = 0;
    for (const auto& [name, host, status, eps, cpu] : seed) {
        ComponentRow r;
        r.name = name;
        r.host = host;
        r.status = status;
        r.baseline = eps;
        r.eventsPerSec = eps;
        r.cpuPct = cpu;
        r.queueDepth = static_cast<int>(eps * 0.3);
        r.phase = i * 1.37;
        r.uptimeSec = (status == ComponentStatus::Stopped) ? 0
                    : (status == ComponentStatus::Degraded) ? 732
                    : (12345 + i * 1000);
        r.recentLogs.append(QString("[%1] INFO  %2 started").arg(TimestampNow(), name));
        rows_.append(std::move(r));
        ++i;
    }

    tickTimer_.setInterval(1000);
    QObject::connect(&tickTimer_, &QTimer::timeout, this, &ComponentModel::Tick);
    tickTimer_.start();
}

void ComponentModel::attachAgent(net::AgentClient* client)
{
    agent_client_ = client;
    // Stop the synthetic ticker — real data will flow via the agent.
    tickTimer_.stop();
    if (client == nullptr) {
        return;
    }
    QObject::connect(client, &net::AgentClient::componentListUpdated,
                     this, &ComponentModel::SyncFromAgent);
    // In case the agent already has data cached.
    SyncFromAgent();
}

void ComponentModel::SyncFromAgent()
{
    if (agent_client_ == nullptr) {
        return;
    }
    const QList<net::AgentClient::ComponentInfo> src = agent_client_->components();
    beginResetModel();
    rows_.clear();
    for (const auto& ci : src) {
        ComponentRow r;
        r.name = ci.display_name.isEmpty() ? ci.id : ci.display_name;
        r.host = ci.telemetry_endpoint;
        r.status = StatusFromString(ci.state);
        r.uptimeSec = 0;
        // Starting-at-seconds-since-epoch is provided by the agent but we
        // surface uptime in the UI; compute rough uptime from wall clock.
        if (ci.started_at > 0) {
            const qint64 now = QDateTime::currentSecsSinceEpoch();
            r.uptimeSec = std::max<qint64>(0, now - ci.started_at);
        }
        r.eventsPerSec = 0.0;
        r.cpuPct = (ci.cpu_pct < 0.0) ? 0.0 : ci.cpu_pct;
        r.rssMb = ci.rss_mb;
        r.queueDepth = 0;
        r.logFiles = ci.log_files;
        rows_.append(std::move(r));
    }
    endResetModel();
}

ComponentStatus ComponentModel::StatusFromString(const QString& s)
{
    if (s == "running")   return ComponentStatus::Running;
    if (s == "starting")  return ComponentStatus::Starting;
    if (s == "stopping")  return ComponentStatus::Running;  // UI lumps stopping→running-ish
    if (s == "crashed")   return ComponentStatus::Crashed;
    return ComponentStatus::Stopped;
}

int ComponentModel::rowCount(const QModelIndex& parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(rows_.size());
}

QVariant ComponentModel::data(const QModelIndex& index, int role) const
{
    const int row = index.row();
    if (row < 0 || row >= rows_.size()) {
        return {};
    }
    const ComponentRow& r = rows_[row];
    switch (role) {
        case NameRole:       return r.name;
        case HostRole:       return r.host;
        case StatusRole:     return static_cast<int>(r.status);
        case StatusTextRole: return StatusText(r.status);
        case UptimeRole:     return static_cast<qlonglong>(r.uptimeSec);
        case UptimeTextRole: return FormatUptime(r.uptimeSec);
        case EventsRole:     return r.eventsPerSec;
        case CpuRole:        return r.cpuPct;
        case RssRole:        return r.rssMb;
        case QueueRole:      return r.queueDepth;
        case LogFilesRole:   return r.logFiles;
        default:             return {};
    }
}

QHash<int, QByteArray> ComponentModel::roleNames() const
{
    return {
        {NameRole,       "name"},
        {HostRole,       "host"},
        {StatusRole,     "statusCode"},
        {StatusTextRole, "statusText"},
        {UptimeRole,     "uptimeSec"},
        {UptimeTextRole, "uptimeText"},
        {EventsRole,     "eventsPerSec"},
        {CpuRole,        "cpuPct"},
        {RssRole,        "rssMb"},
        {QueueRole,      "queueDepth"},
        {LogFilesRole,   "logFiles"},
    };
}

void ComponentModel::startComponent(int row)
{
    if (row < 0 || row >= rows_.size()) {
        return;
    }
    ComponentRow& r = rows_[row];
    if (r.status == ComponentStatus::Running) {
        return;
    }
    r.status = ComponentStatus::Starting;
    r.uptimeSec = 0;
    r.eventsPerSec = 0.0;
    PushLog(row, QString("[%1] INFO  start requested").arg(TimestampNow()));
    emit dataChanged(index(row), index(row));
    QTimer::singleShot(1800, this, [this, row]() {
        if (row < 0 || row >= rows_.size()) {
            return;
        }
        rows_[row].status = ComponentStatus::Running;
        PushLog(row, QString("[%1] INFO  ready").arg(TimestampNow()));
        emit dataChanged(index(row), index(row));
    });
}

void ComponentModel::stopComponent(int row)
{
    if (row < 0 || row >= rows_.size()) {
        return;
    }
    ComponentRow& r = rows_[row];
    r.status = ComponentStatus::Stopped;
    r.uptimeSec = 0;
    r.eventsPerSec = 0.0;
    r.cpuPct = 0.0;
    r.queueDepth = 0;
    r.history.clear();
    PushLog(row, QString("[%1] WARN  stopped by operator").arg(TimestampNow()));
    emit dataChanged(index(row), index(row));
}

void ComponentModel::restartComponent(int row)
{
    stopComponent(row);
    QTimer::singleShot(600, this, [this, row]() { startComponent(row); });
}

QVariantList ComponentModel::historyFor(int row) const
{
    if (row < 0 || row >= rows_.size()) {
        return {};
    }
    QVariantList out;
    out.reserve(rows_[row].history.size());
    for (const QPointF& p : rows_[row].history) {
        out.append(QVariant::fromValue(p));
    }
    return out;
}

QStringList ComponentModel::logsFor(int row) const
{
    if (row < 0 || row >= rows_.size()) {
        return {};
    }
    return rows_[row].recentLogs;
}

QVariantMap ComponentModel::snapshotFor(int row) const
{
    QVariantMap m;
    if (row < 0 || row >= rows_.size()) {
        return m;
    }
    const ComponentRow& r = rows_[row];
    m.insert("name",         r.name);
    m.insert("host",         r.host);
    m.insert("statusCode",   static_cast<int>(r.status));
    m.insert("statusText",   StatusText(r.status));
    m.insert("uptimeSec",    static_cast<qlonglong>(r.uptimeSec));
    m.insert("uptimeText",   FormatUptime(r.uptimeSec));
    m.insert("eventsPerSec", r.eventsPerSec);
    m.insert("cpuPct",       r.cpuPct);
    m.insert("rssMb",        r.rssMb);
    m.insert("queueDepth",   r.queueDepth);
    m.insert("logFiles",     r.logFiles);
    return m;
}

void ComponentModel::Tick()
{
    ++tickCount_;
    for (int i = 0; i < rows_.size(); ++i) {
        ComponentRow& r = rows_[i];
        if (r.status == ComponentStatus::Running || r.status == ComponentStatus::Degraded) {
            r.uptimeSec += 1;
            r.phase += 0.18;
            const double wobble = std::sin(r.phase) * r.baseline * 0.15 + Jitter(r.baseline * 0.04);
            const double degrade = (r.status == ComponentStatus::Degraded) ? 0.55 : 1.0;
            r.eventsPerSec = std::max(0.0, (r.baseline + wobble) * degrade);
            r.cpuPct = std::clamp(r.cpuPct + Jitter(1.6), 0.5, 95.0);
            r.queueDepth = std::max(0, r.queueDepth + static_cast<int>(Jitter(3.5)));
        } else if (r.status == ComponentStatus::Starting) {
            r.uptimeSec += 1;
            r.eventsPerSec = std::min(r.baseline, r.eventsPerSec + r.baseline * 0.3);
        } else {
            r.eventsPerSec = 0.0;
        }

        const double x = static_cast<double>(tickCount_);
        r.history.append(QPointF(x, r.eventsPerSec));
        constexpr int kHistoryMax = 60;
        while (r.history.size() > kHistoryMax) {
            r.history.removeFirst();
        }

        if ((tickCount_ + i) % 7 == 0 && r.status != ComponentStatus::Stopped) {
            const QString level = (r.status == ComponentStatus::Degraded) ? "WARN " : "INFO ";
            PushLog(i, QString("[%1] %2 tick eps=%3 cpu=%4%")
                            .arg(TimestampNow(), level)
                            .arg(r.eventsPerSec, 0, 'f', 1)
                            .arg(r.cpuPct, 0, 'f', 1));
        }

        emit dataChanged(index(i), index(i));
    }
}

QString ComponentModel::FormatUptime(qint64 sec)
{
    if (sec <= 0) {
        return "—";
    }
    const qint64 days = sec / 86400;
    const qint64 hours = (sec % 86400) / 3600;
    const qint64 mins = (sec % 3600) / 60;
    const qint64 secs = sec % 60;
    if (days > 0) {
        return QString("%1d %2h %3m").arg(days).arg(hours).arg(mins);
    }
    if (hours > 0) {
        return QString("%1h %2m %3s").arg(hours).arg(mins).arg(secs);
    }
    return QString("%1m %2s").arg(mins).arg(secs);
}

QString ComponentModel::StatusText(ComponentStatus s)
{
    switch (s) {
        case ComponentStatus::Stopped:  return "STOPPED";
        case ComponentStatus::Starting: return "STARTING";
        case ComponentStatus::Running:  return "RUNNING";
        case ComponentStatus::Degraded: return "DEGRADED";
        case ComponentStatus::Crashed:  return "CRASHED";
    }
    return "UNKNOWN";
}

void ComponentModel::PushLog(int row, const QString& line)
{
    if (row < 0 || row >= rows_.size()) {
        return;
    }
    auto& logs = rows_[row].recentLogs;
    logs.append(line);
    constexpr int kLogMax = 80;
    while (logs.size() > kLogMax) {
        logs.removeFirst();
    }
}

} // namespace pslcp
