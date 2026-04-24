#include <QCommandLineParser>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>

#include "ComponentModel.hpp"
#include "net/AgentClient.hpp"
#include "net/Credentials.hpp"
#include "net/OperatorAuth.hpp"

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    app.setOrganizationName("PolySignalLab");
    app.setOrganizationDomain("polysignallab.local");
    app.setApplicationName("PSL System Control Panel");
    app.setApplicationDisplayName("PSL System Control Panel");

    QCommandLineParser parser;
    parser.setApplicationDescription("PSLSysControlPanel");
    parser.addHelpOption();
    QCommandLineOption hostOpt(
        QStringList() << "host",
        "Agent host or Tailscale hostname (default: 127.0.0.1)",
        "host", "127.0.0.1");
    QCommandLineOption portOpt(
        QStringList() << "port",
        "Agent TCP port (default: 19733)",
        "port", "19733");
    QCommandLineOption offlineOpt(
        QStringList() << "offline",
        "Run with mock data only; don't attempt to connect to an agent.");
    parser.addOption(hostOpt);
    parser.addOption(portOpt);
    parser.addOption(offlineOpt);
    parser.process(app);

    // Initialize libsodium up-front so any failure shows at startup, not
    // later when the operator tries to authenticate.
    if (!pslcp::net::ensureSodium()) {
        qWarning() << "libsodium failed to initialize — operator auth will be disabled";
    }

    pslcp::ComponentModel componentModel;
    pslcp::net::AgentClient agentClient;

    if (!parser.isSet(offlineOpt)) {
        const auto cred = pslcp::net::loadManagerPsk();
        if (!cred.ok) {
            qWarning().noquote() << "MANAGER_PSK unavailable:" << cred.error_message
                                 << " — falling back to mock data. Use --offline to silence this.";
        } else {
            agentClient.configure(parser.value(hostOpt),
                                  static_cast<quint16>(parser.value(portOpt).toUInt()),
                                  cred.key_bytes);
            componentModel.attachAgent(&agentClient);
            agentClient.start();
        }
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("componentModel", &componentModel);
    engine.rootContext()->setContextProperty("agentClient", &agentClient);
    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        return -1;
    }
    return app.exec();
}
