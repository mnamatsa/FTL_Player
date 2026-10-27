#pragma once

#include <QHash>
#include <QJSValue>
#include <QObject>
#include <QProcess>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// Runs the Deno helper (helper/deno.exe + helper/helper.js) and exchanges one JSON object per line with it.
class HelperClient : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Helper)
    QML_SINGLETON

public:
    explicit HelperClient(QObject *parent = nullptr);
    ~HelperClient() override;

    // Sends {cmd, ...args}; callback(reply) gets the reply object ({ok: true, ...} or {ok: false, error}).
    Q_INVOKABLE void call(const QString &cmd, const QVariantMap &args, const QJSValue &callback);

private:
    void start();
    void readReplies();
    void failAll(const QString &error);

    QProcess m_proc;
    QByteArray m_buffer;
    QHash<int, QJSValue> m_pending;
    int m_nextId = 1;
};
