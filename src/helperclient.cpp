#include "helperclient.h"
#include "paths.h"

#include <QDir>
#include <QFile>
#include <QJSEngine>
#include <QJsonDocument>
#include <QJsonObject>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

HelperClient::HelperClient(QObject *parent) : QObject(parent)
{
    connect(&m_proc, &QProcess::readyReadStandardOutput, this, &HelperClient::readReplies);
    connect(&m_proc, &QProcess::readyReadStandardError, this, [this] {
        // Keep the helper's diagnostics in Data/helper.log (truncated when it grows past 1 MB).
        QFile log(Paths::data() + "/helper.log");
        if (log.size() > 1 << 20)
            log.remove();
        if (log.open(QIODevice::Append))
            log.write(m_proc.readAllStandardError());
    });
    connect(&m_proc, &QProcess::finished, this, [this] { failAll("The helper process stopped."); });
#ifdef Q_OS_WIN
    m_proc.setCreateProcessArgumentsModifier([](QProcess::CreateProcessArguments *a) {
        a->flags |= CREATE_NO_WINDOW;
    });
#endif
}

HelperClient::~HelperClient()
{
    if (m_proc.state() != QProcess::NotRunning) {
        m_proc.closeWriteChannel(); // the helper exits when stdin closes
        if (!m_proc.waitForFinished(1500))
            m_proc.kill();
    }
}

void HelperClient::start()
{
    const QString helperDir = Paths::app() + "/helper";
    const QString data = Paths::data();
    QDir().mkpath(data + "/cache");

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert("DENO_DIR", QDir::toNativeSeparators(data + "/deno"));
    env.insert("DENO_NO_UPDATE_CHECK", "1");
    env.insert("NO_COLOR", "1");
    m_proc.setProcessEnvironment(env);

    // The helper may only reach YouTube (plus Google's attestation server for PO tokens, and SponsorBlock's server), serve its stream
    // proxy on 127.0.0.1, touch its own cache folder, and load the PO token worker script.
    const QString cache = QDir::toNativeSeparators(data + "/cache");
    const QString tokenWorker = QDir::toNativeSeparators(helperDir + "/potoken.js");
    m_proc.start(helperDir + "/deno.exe", {
        "run", "--no-config", "--no-prompt", "--unstable-worker-options",
        "--allow-net=127.0.0.1,www.youtube.com,m.youtube.com,youtubei.googleapis.com,*.googlevideo.com,"
        "jnn-pa.googleapis.com,www.google.com,www.gstatic.com,sponsor.ajay.app",
        "--allow-read=" + cache + "," + tokenWorker, "--allow-write=" + cache,
        // read by the bundled jsdom/undici code in the PO token worker
        "--allow-env=UNDICI_NO_WASM_SIMD,UNDICI_USE_MILO,HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy,JEST_WORKER_ID,CI",
        QDir::toNativeSeparators(helperDir + "/helper.js"), QDir::toNativeSeparators(data),
        qEnvironmentVariableIsSet("FTL_DEBUG") ? "--debug" : "",
    });
}

void HelperClient::call(const QString &cmd, const QVariantMap &args, const QJSValue &callback)
{
    if (m_proc.state() == QProcess::NotRunning)
        start();
    const int id = m_nextId++;
    QJsonObject req = QJsonObject::fromVariantMap(args);
    req["id"] = id;
    req["cmd"] = cmd;
    m_pending.insert(id, callback);
    m_proc.write(QJsonDocument(req).toJson(QJsonDocument::Compact) + '\n');
}

void HelperClient::readReplies()
{
    m_buffer += m_proc.readAllStandardOutput();
    qsizetype nl;
    while ((nl = m_buffer.indexOf('\n')) >= 0) {
        const QByteArray line = m_buffer.left(nl);
        m_buffer.remove(0, nl + 1);
        const QJsonObject reply = QJsonDocument::fromJson(line).object();
        QJSValue cb = m_pending.take(reply.value("id").toInt());
        if (cb.isCallable())
            // As a QJsonObject the reply becomes plain JavaScript objects and arrays (a QVariantMap would
            // give wrapped lists, which ListModel.append() and array methods don't treat as arrays).
            cb.call({qjsEngine(this)->toScriptValue(reply)});
    }
}

void HelperClient::failAll(const QString &error)
{
    const auto pending = std::exchange(m_pending, {});
    for (QJSValue cb : pending) {
        if (cb.isCallable())
            cb.call({qjsEngine(this)->toScriptValue(QVariantMap{{"ok", false}, {"error", error}})});
    }
    m_buffer.clear();
}
