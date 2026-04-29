#include <QCommandLineParser>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>

#include "net/Credentials.hpp"
#include "net/HostManager.hpp"
#include "net/OperatorAuth.hpp"

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    app.setOrganizationName("PolySignalLab");
    app.setOrganizationDomain("polysignallab.local");
    app.setApplicationName("PSL System Control Panel");
    app.setApplicationDisplayName("PSL System Control Panel");
    app.setWindowIcon(QIcon(QStringLiteral(":/app.ico")));

    QCommandLineParser parser;
    parser.setApplicationDescription(
        "PSLSysControlPanel\n\n"
        "Connects to one or more PSLAgent hosts over Tailscale.\n"
        "Defaults to the PolySignalLab fleet (workstation + node2) when no\n"
        "--host is given; pass --host to override.\n"
        "Single host:  --host workstation --port 19733\n"
        "Multi host:   --host workstation=10.0.0.1:19733 --host node2=10.0.0.2:19733");
    parser.addHelpOption();
    QCommandLineOption hostOpt(
        QStringList() << "host",
        "Agent host as a bare hostname, ``host:port``, or ``name=host:port``. "
        "Pass multiple times to show several hosts in one panel. If omitted, "
        "the panel connects to the hardcoded workstation + node2 Tailscale IPs.",
        "host");
    QCommandLineOption portOpt(
        QStringList() << "port",
        "Default agent TCP port (applied to --host values that omit one).",
        "port", "19733");
    QCommandLineOption offlineOpt(
        QStringList() << "offline",
        "Run with mock data only; don't attempt to connect to an agent.");
    parser.addOption(hostOpt);
    parser.addOption(portOpt);
    parser.addOption(offlineOpt);
    parser.process(app);

    if (!pslcp::net::ensureSodium()) {
        qWarning() << "libsodium failed to initialize — operator auth will be disabled";
    }

    const quint16 default_port =
        static_cast<quint16>(parser.value(portOpt).toUInt());
    QStringList host_values = parser.values(hostOpt);
    if (host_values.isEmpty()) {
        // Tailscale IPs are static by design, so hardcoding the fleet here
        // means a double-click launch Just Works. Override with --host when
        // adding a new machine or running against a staging agent.
        host_values << QStringLiteral("workstation=100.100.100.100:19733")
                    << QStringLiteral("node2=127.0.0.1:19733");
    }

    pslcp::net::HostManager host_manager;

    if (parser.isSet(offlineOpt)) {
        host_manager.addOfflineSession(QStringLiteral("offline"));
    } else {
        const auto cred = pslcp::net::loadManagerPsk();
        if (!cred.ok) {
            qWarning().noquote()
                << "MANAGER_PSK unavailable:" << cred.error_message
                << " — falling back to mock data. Use --offline to silence this.";
            host_manager.addOfflineSession(QStringLiteral("mock"));
        } else {
            for (const QString& raw : host_values) {
                const auto spec = pslcp::net::HostManager::parseSpec(raw, default_port);
                host_manager.addSession(spec, cred.key_bytes);
            }
            host_manager.startAll();
        }
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("hostManager", &host_manager);
    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        return -1;
    }
    return app.exec();
}
