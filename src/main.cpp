#include <QCommandLineParser>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QStyleHints>
#include <QQuickWindow>
#include <QUrl>

#include "gpus.h"
#include "paths.h"
#include "windowtools.h"

#include <QDateTime>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QCryptographicHash>
#include <QDir>
#include <QLocalServer>
#include <QLocalSocket>
#include <QSettings>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

// Warnings, errors and qInfo() / console.info() lines (e.g. fullscreen changes) also go to Data/app.log, so a
// problem in the installed app (which has no console) can be looked into afterwards. It starts over past 1 MB.
static QtMessageHandler previousHandler = nullptr;
static void logMessage(QtMsgType type, const QMessageLogContext &context, const QString &message)
{
    if (type != QtDebugMsg) {
        static QFile log(Paths::data() + "/app.log");
        if (!log.isOpen())
            log.open(QIODevice::WriteOnly | QIODevice::Text | (log.size() > 1024 * 1024 ? QIODevice::Truncate : QIODevice::Append));
        static const char *names[] = {"debug", "warning", "critical", "fatal", "info"};
        log.write(QStringLiteral("%1 %2 %3\n").arg(QDateTime::currentDateTime().toString(Qt::ISODateWithMs),
                                                     QLatin1StringView(names[type]), message).toUtf8());
        log.flush();
    }
    if (previousHandler)
        previousHandler(type, context, message);
}

// A link handed over on the command line: a YouTube URL, or one wrapped as ftlplayer://<url> by the browser
// extension (freetubelight://, from before the app was renamed, still works). Browsers may drop the colon of the
// inner https:// or percent-encode it.
static QString linkArgument(QString a)
{
    a = a.trimmed();
    const QString scheme = a.section(':', 0, 0).toLower();
    if (scheme == "ftlplayer" || scheme == "freetubelight") {
        a = a.mid(scheme.size() + 1);
        while (a.startsWith('/'))
            a.remove(0, 1);
        if (a.contains("%3A", Qt::CaseInsensitive) || a.contains("%2F", Qt::CaseInsensitive))
            a = QUrl::fromPercentEncoding(a.toUtf8());
        if (a.startsWith("https//") || a.startsWith("http//"))
            a.insert(a.indexOf('/'), ':');
    }
    return a;
}

// One app per Data folder: a link opened while it runs (from the browser) goes to the running app's first window.
static QString instanceName()
{
    return "FreeTubeLight-" + QCryptographicHash::hash(QDir(Paths::data()).absolutePath().toLower().toUtf8(),
                                                     QCryptographicHash::Sha1).toHex().left(16);
}

// What a plain second start sends instead of a link: open another window.
static const QString newWindowMessage = QStringLiteral("ftl:new-window");

// Sends `link` to a running app; false when there is none.
static bool sendToRunning(const QString &link)
{
    QLocalSocket socket;
    socket.connectToServer(instanceName());
    if (!socket.waitForConnected(500))
        return false;
#ifdef Q_OS_WIN
    AllowSetForegroundWindow(ASFW_ANY);   // the running app may come to the front (this just started process may)
#endif
    socket.write(link.toUtf8());
    socket.waitForBytesWritten(1000);
    socket.disconnectFromServer();
    return true;
}

// ftlplayer:// opens this exe (in the current user's Software\Classes, no admin needed); updated when the app
// has moved (or been renamed). Also freetubelight://, from before the rename: an extension not reloaded yet still
// uses it. Not for test copies.
static void registerProtocol()
{
    if (qEnvironmentVariableIsSet("FTL_DATA_DIR") || qEnvironmentVariableIsSet("FTL_TEST_BACKGROUND"))
        return;
    const QString exe = QDir::toNativeSeparators(QCoreApplication::applicationFilePath());
    const QString command = "\"" + exe + "\" \"%1\"";
    for (const char *scheme : {"ftlplayer", "freetubelight"}) {
        QSettings reg(QStringLiteral("HKEY_CURRENT_USER\\Software\\Classes\\") + scheme, QSettings::NativeFormat);
        if (reg.value("shell/open/command/.").toString() == command)
            continue;
        reg.setValue(".", "URL:FTL Player");
        reg.setValue("URL Protocol", "");
        reg.setValue("DefaultIcon/.", "\"" + exe + "\",0");
        reg.setValue("shell/open/command/.", command);
    }
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    previousHandler = qInstallMessageHandler(logMessage);
    QGuiApplication::setApplicationName("FTL Player");
    QGuiApplication::setApplicationDisplayName("FTL Player");
    QQuickStyle::setStyle("Material");

    QCommandLineParser args;
    args.addOptions({{"search", "Search for <query> on startup.", "query"},
                     {"play", "Play the video <id> on startup.", "id"},
                     {"channel", "Open the channel <id> on startup.", "id"},
                     {"playlist", "Play the playlist <id> on startup.", "id"},
                     {"import", "Import the subscription <file> on startup.", "file"},
                     {"export", "Export the subscriptions to <file> (.db, .csv, .opml, .json) on startup.", "file"}});
    args.addPositionalArgument("link", "A YouTube link (or ftlplayer://<link>) to open.", "[link]");
    args.process(app);
    const QStringList positional = args.positionalArguments();
    const QString link = positional.isEmpty() ? QString() : linkArgument(positional.constFirst());
    if (!link.isEmpty() && sendToRunning(link))
        return 0;
    // One copy per Data folder: started again without anything to do (the shortcut, the exe), the running copy
    // opens another window instead (a second copy took ~300 MB more, and its helper ~50 MB).
    const bool plain = link.isEmpty() && !args.isSet("search") && !args.isSet("play") && !args.isSet("channel")
                       && !args.isSet("playlist") && !args.isSet("import") && !args.isSet("export");
    if (plain && sendToRunning(newWindowMessage))
        return 0;
    registerProtocol();

    // The GPU setting for the interface (Qt picks the adapter when the first window is shown); the video
    // reads it itself when mpv starts.
    // The theme too, before the first window shows (its title bar, the icon; AppState follows changes).
    QString theme = "dark";
    {
        QFile f(Paths::data() + "/settings.json");
        if (f.open(QIODevice::ReadOnly)) {
            const QJsonObject settings = QJsonDocument::fromJson(f.readAll()).object();
            const Gpus::Adapter a = Gpus::forChoice(settings.value("gpu").toString());
            if (a.index >= 0 && !qEnvironmentVariableIsSet("QT_D3D_ADAPTER_INDEX"))
                qputenv("QT_D3D_ADAPTER_INDEX", QByteArray::number(a.index));
            theme = settings.value("theme").toString("dark");
        }
    }
    WindowTools::setColorScheme(theme);
    WindowTools::setAppIcon(QGuiApplication::styleHints()->colorScheme() != Qt::ColorScheme::Light);

    QQmlApplicationEngine engine;
    QVariantMap props{{"startSearch", args.value("search")}, {"startVideo", args.value("play")},
                      {"startChannel", args.value("channel")}, {"startPlaylist", args.value("playlist")},
                      {"startImport", args.isSet("import") ? QUrl::fromLocalFile(args.value("import")) : QUrl()},
                      {"startExport", args.isSet("export") ? QUrl::fromLocalFile(args.value("export")) : QUrl()},
                      {"startLink", link}};
    // Test copies open behind everything without taking the focus, so they don't get in the way.
    const bool background = qEnvironmentVariableIsSet("FTL_TEST_BACKGROUND");
    if (background) {
        props.insert("visible", false);
        props.insert("startedInBackground", true);
    }
    engine.setInitialProperties(props);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("FreeTubeLight", "Main");
    if (background && !engine.rootObjects().isEmpty())
        if (auto *w = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst()))
            WindowTools::showBehindAll(w);

    // Links from later starts (sendToRunning) open in the first window.
    QLocalServer server;
    if (!engine.rootObjects().isEmpty()) {
        QObject *first = engine.rootObjects().constFirst();
        QObject::connect(&server, &QLocalServer::newConnection, &server, [&server, first] {
            while (QLocalSocket *socket = server.nextPendingConnection()) {
                auto *data = new QByteArray;
                QObject::connect(socket, &QLocalSocket::readyRead, socket, [socket, data] { *data += socket->readAll(); });
                QObject::connect(socket, &QLocalSocket::disconnected, socket, [socket, data, first] {
                    const QString link = QString::fromUtf8(*data + socket->readAll()).trimmed();
                    delete data;
                    socket->deleteLater();
                    if (link == newWindowMessage)
                        QMetaObject::invokeMethod(first, "openNewWindow");
                    else if (!link.isEmpty())
                        QMetaObject::invokeMethod(first, "openExternal", Q_ARG(QVariant, link));
                });
            }
        });
        QLocalServer::removeServer(instanceName());   // left over after a crash
        server.listen(instanceName());
    }
    return app.exec();
}
