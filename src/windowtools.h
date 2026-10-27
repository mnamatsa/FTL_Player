#pragma once

#include <QObject>
#include <QWindow>
#include <QtQml/qqmlregistration.h>

// Window helpers QML lacks: opening a window behind the current one ("Open new windows in the background").
class WindowTools : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit WindowTools(QObject *parent = nullptr) : QObject(parent) {}

    // Shows `window` without activating it, where `front` is (or filling its screen's work area when `front`
    // is maximized), keeps `front` active on top, and flashes the new window's taskbar button for ~2 s,
    // like FreeTube's background windows.
    Q_INVOKABLE void showInBackground(QWindow *window, QWindow *front);

    // Shows `window` (restored to its earlier state if minimized) and makes it the active window, if Windows
    // lets it (a link from the browser: the process that passed it on allows it). Test copies stay behind.
    Q_INVOKABLE void bringToFront(QWindow *window);

    // The theme (Settings > Layout > Theme): "dark", "light" or "system" (Windows' app mode, followed as it
    // changes). Qt's colour scheme also makes the title bars dark or light.
    Q_INVOKABLE static void setColorScheme(const QString &theme);
    // The window / taskbar icon: the black laser on dark, the white one on light.
    Q_INVOKABLE static void setAppIcon(bool dark);

    // Flashes `window`'s taskbar button for ~2 s (as for a window opened in the background).
    Q_INVOKABLE void flash(QWindow *window);

    // Tests: FTL_TEST_CARD_SCRUB=0.4 makes video cards preview as if the pointer were at 40 % of their bar
    // (posted mouse moves don't make Qt hover); 0 when unset.
    Q_INVOKABLE double testCardScrub() const { return qEnvironmentVariable("FTL_TEST_CARD_SCRUB").toDouble(); }

    // A test copy (FTL_TEST_BACKGROUND): its windows open behind everything.
    Q_INVOKABLE bool testCopy() const { return qEnvironmentVariableIsSet("FTL_TEST_BACKGROUND"); }

    // Shows `window` without activating it, behind all other windows (test copies: FTL_TEST_BACKGROUND).
    static void showBehindAll(QWindow *window);

    // After a fullscreen change: 0.4 s later, whether the window really is (not) fullscreen. Once a window
    // stayed as it was while asked for fullscreen, from the button and by double-click, over and over (Qt
    // presumably took it as fullscreen already; not reproduced). If Windows and Qt disagree, the state is
    // set anew (normal first) and that is logged (Data/app.log).
    Q_INVOKABLE void checkFullScreen(QWindow *window, bool on);
};
