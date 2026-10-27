#pragma once

#include <QObject>
#include <QUrl>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

// Small JSON documents in the portable Data folder (subscriptions, settings, history, feed cache), and
// subscription import/export in the formats FreeTube supports.
class Store : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit Store(QObject *parent = nullptr) : QObject(parent) {}

    // Data/<name>.json; name may only use letters, digits and '-'.
    Q_INVOKABLE QVariant load(const QString &name, const QVariant &fallback = {}) const;
    Q_INVOKABLE bool save(const QString &name, const QVariant &value) const;

    // Reads a subscription file: FreeTube (.db), YouTube Takeout (.csv), OPML (.opml/.xml) or NewPipe (.json).
    // Returns {channels: [{id, name, thumbnail}], format, error}.
    Q_INVOKABLE QVariantMap importSubscriptions(const QUrl &file) const;
    // Writes channels in the format matching the file's extension (.db, .csv, .opml, .json). Returns an error or "".
    Q_INVOKABLE QString exportSubscriptions(const QUrl &file, const QVariant &channels) const;
};
