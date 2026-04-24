#include "HostManager.hpp"

#include "AgentClient.hpp"
#include "../ComponentModel.hpp"

namespace pslcp::net {

HostManager::HostManager(QObject* parent)
    : QObject(parent)
    , current_index_(-1)
{
}

HostManager::~HostManager() = default;

void HostManager::addSession(const HostSpec& spec, const QByteArray& psk)
{
    auto* client = new AgentClient(this);
    client->configure(spec.host, spec.port, psk);
    auto* model = new pslcp::ComponentModel(this);
    model->attachAgent(client);
    Session s{spec, client, model};
    sessions_.append(s);
    emit countChanged();
    emit hostNamesChanged();
    if (current_index_ < 0) {
        current_index_ = 0;
        emit currentIndexChanged();
        emit currentChanged();
    }
}

void HostManager::addOfflineSession(const QString& name)
{
    // No configure(), no attachAgent() — the ComponentModel keeps its
    // synthetic ticker running and the AgentClient stays Disconnected.
    HostSpec spec;
    spec.name = name.isEmpty() ? QStringLiteral("mock") : name;
    auto* client = new AgentClient(this);
    auto* model = new pslcp::ComponentModel(this);
    Session s{spec, client, model};
    sessions_.append(s);
    emit countChanged();
    emit hostNamesChanged();
    if (current_index_ < 0) {
        current_index_ = 0;
        emit currentIndexChanged();
        emit currentChanged();
    }
}

void HostManager::startAll()
{
    for (Session& s : sessions_) {
        // Only start clients that have been configured. configure() sets
        // host_ on the client; we can't see that from here, so we rely on
        // addOfflineSession() having skipped configure(). start() on an
        // unconfigured client would try to connect to "".
        if (!s.spec.host.isEmpty()) {
            s.client->start();
        }
    }
}

int HostManager::count() const
{
    return static_cast<int>(sessions_.size());
}

int HostManager::currentIndex() const
{
    return current_index_;
}

void HostManager::setCurrentIndex(int i)
{
    if (i < 0 || i >= sessions_.size() || i == current_index_) {
        return;
    }
    current_index_ = i;
    emit currentIndexChanged();
    emit currentChanged();
}

QStringList HostManager::hostNames() const
{
    QStringList out;
    out.reserve(static_cast<int>(sessions_.size()));
    for (const Session& s : sessions_) {
        out.append(s.spec.name);
    }
    return out;
}

QObject* HostManager::currentClient() const
{
    if (current_index_ < 0 || current_index_ >= sessions_.size()) {
        return nullptr;
    }
    return sessions_.at(current_index_).client;
}

QObject* HostManager::currentModel() const
{
    if (current_index_ < 0 || current_index_ >= sessions_.size()) {
        return nullptr;
    }
    return sessions_.at(current_index_).model;
}

HostSpec HostManager::parseSpec(const QString& raw, quint16 default_port)
{
    HostSpec out;
    QString hp = raw;
    const int eq = raw.indexOf('=');
    if (eq > 0) {
        out.name = raw.left(eq).trimmed();
        hp = raw.mid(eq + 1).trimmed();
    }
    // Accept "host:port" with a last-colon split (handles IPv6 poorly but
    // that's fine — this panel is Tailscale/DNS hostnames in practice).
    const int colon = hp.lastIndexOf(':');
    if (colon >= 0) {
        out.host = hp.left(colon).trimmed();
        bool ok = false;
        const uint v = hp.mid(colon + 1).trimmed().toUInt(&ok);
        out.port = (ok && v > 0 && v < 65536) ? static_cast<quint16>(v) : default_port;
    } else {
        out.host = hp.trimmed();
        out.port = default_port;
    }
    if (out.name.isEmpty()) {
        out.name = out.host;
    }
    return out;
}

} // namespace pslcp::net
