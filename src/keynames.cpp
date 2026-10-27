#include "keynames.h"

#include <QHash>

QByteArray mpvKeyName(int key, Qt::KeyboardModifiers mods, const QString &text)
{
    static const QHash<int, QByteArray> special = {
        {Qt::Key_Space, "SPACE"}, {Qt::Key_Left, "LEFT"}, {Qt::Key_Right, "RIGHT"}, {Qt::Key_Up, "UP"},
        {Qt::Key_Down, "DOWN"}, {Qt::Key_Escape, "ESC"}, {Qt::Key_Return, "ENTER"}, {Qt::Key_Enter, "KP_ENTER"},
        {Qt::Key_Backspace, "BS"}, {Qt::Key_Tab, "TAB"}, {Qt::Key_PageUp, "PGUP"}, {Qt::Key_PageDown, "PGDWN"},
        {Qt::Key_Home, "HOME"}, {Qt::Key_End, "END"}, {Qt::Key_Insert, "INS"}, {Qt::Key_Delete, "DEL"},
        {Qt::Key_MediaPlay, "PLAY"}, {Qt::Key_MediaPause, "PAUSE"}, {Qt::Key_MediaTogglePlayPause, "PLAYPAUSE"},
        {Qt::Key_MediaStop, "STOP"}, {Qt::Key_MediaNext, "NEXT"}, {Qt::Key_MediaPrevious, "PREV"},
        // (not the keyboard's volume and mute keys: they are Windows' volume, and mpv changed its own as well)
    };
    QByteArray name = special.value(key);
    bool fromText = false;
    if (name.isEmpty() && key >= Qt::Key_F1 && key <= Qt::Key_F12) {
        name = "F" + QByteArray::number(key - Qt::Key_F1 + 1);
    } else if (name.isEmpty()) {
        if (!text.isEmpty() && text.at(0).isPrint()) {
            name = text.toUtf8(); // already reflects Shift (e.g. "A", ">")
            fromText = true;
            if (name == "#")
                name = "SHARP";
        } else if (key >= Qt::Key_A && key <= Qt::Key_Z) {
            name = QByteArray(1, char('a' + key - Qt::Key_A)); // Ctrl+letter produces no text
        } else if (key >= Qt::Key_0 && key <= Qt::Key_9) {
            name = QByteArray(1, char('0' + key - Qt::Key_0));
        }
    }
    if (name.isEmpty())
        return {};
    QByteArray prefix;
    if (mods & Qt::ControlModifier) prefix += "Ctrl+";
    if (mods & Qt::AltModifier) prefix += "Alt+";
    if (mods & Qt::MetaModifier) prefix += "Meta+";
    if ((mods & Qt::ShiftModifier) && !fromText) prefix += "Shift+";
    return prefix + name;
}
