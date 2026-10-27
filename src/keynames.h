#pragma once

#include <QByteArray>
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// mpv's name for a key press, e.g. "LEFT", "j", "L" (Shift+l), ">", "Ctrl+s", "Shift+RIGHT"; "" for keys mpv
// has no name for (and modifier keys on their own).
QByteArray mpvKeyName(int key, Qt::KeyboardModifiers mods, const QString &text);

// The same for QML (the hotkey settings record keys by these names).
class KeyNames : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit KeyNames(QObject *parent = nullptr) : QObject(parent) {}
    Q_INVOKABLE QString name(int key, int modifiers, const QString &text) const
    {
        return QString::fromUtf8(mpvKeyName(key, Qt::KeyboardModifiers(modifiers), text));
    }
};
