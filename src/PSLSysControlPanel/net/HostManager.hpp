#pragma once

// Manages N (host, port) target sessions so the operator can flip between
// several machines (e.g. a workstation and a remote VPS) inside a single
// panel window. Each session owns its own AgentClient + ComponentModel pair; the
// one exposed to QML switches atomically when ``currentIndex`` changes.

#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>

namespace pslcp {
class ComponentModel;
} // namespace pslcp

namespace pslcp::net {

class AgentClient;

struct HostSpec {
    QString name;
    QString host;
    quint16 port = 0;
};

class HostManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(int currentIndex READ currentIndex WRITE setCurrentIndex NOTIFY currentIndexChanged)
    Q_PROPERTY(QStringList hostNames READ hostNames NOTIFY hostNamesChanged)
    Q_PROPERTY(QObject* currentClient READ currentClient NOTIFY currentChanged)
    Q_PROPERTY(QObject* currentModel READ currentModel NOTIFY currentChanged)

public:
    explicit HostManager(QObject* parent = nullptr);
    ~HostManager() override;

    // Add a live session; not connected until ``startAll`` is called.
    // The manager takes ownership of the AgentClient + ComponentModel.
    void addSession(const HostSpec& spec, const QByteArray& psk);

    // Add a disconnected/mock session that powers the ComponentModel's
    // synthetic ticker. Used in --offline mode and when MANAGER_PSK is
    // missing so the QML bindings still have a non-null target.
    void addOfflineSession(const QString& name);

    // Call once after all sessions have been added. Kicks off the first
    // socket connections; safe to call with zero live sessions.
    void startAll();

    int count() const;
    int currentIndex() const;
    QStringList hostNames() const;
    QObject* currentClient() const;
    QObject* currentModel() const;

    // Parse a ``name=host:port`` or ``host:port`` or ``host`` string into
    // a HostSpec. ``default_port`` is applied when the spec has no port.
    static HostSpec parseSpec(const QString& raw, quint16 default_port);

public slots:
    void setCurrentIndex(int i);

signals:
    void countChanged();
    void currentIndexChanged();
    void hostNamesChanged();
    void currentChanged();

private:
    struct Session {
        HostSpec spec;
        AgentClient* client;
        pslcp::ComponentModel* model;
    };

    QList<Session> sessions_;
    int current_index_;
};

} // namespace pslcp::net
