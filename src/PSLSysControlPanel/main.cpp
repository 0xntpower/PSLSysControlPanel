#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QIcon>

#include "ComponentModel.hpp"

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    app.setOrganizationName("PolySignalLab");
    app.setOrganizationDomain("polysignallab.local");
    app.setApplicationName("PSL System Control Panel");
    app.setApplicationDisplayName("PSL System Control Panel");

    pslcp::ComponentModel componentModel;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("componentModel", &componentModel);
    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        return -1;
    }
    return app.exec();
}
