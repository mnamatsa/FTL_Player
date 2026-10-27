#include "windowtools.h"

#include <QGuiApplication>
#include <QIcon>
#include <QPointer>
#include <QStyleHints>
#include <QScreen>
#include <QTimer>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

#ifdef Q_OS_WIN
// What Electron's flashFrame does (FreeTube's background windows; Chromium's HWNDMessageHandler::FlashFrame):
// FLASHW_ALL four times, then the button stays highlighted until stopped. FLASHW_TIMERNOFG ("until the window
// comes to the foreground") showed nothing in real use, apparently because the new window shares the active
// window's thread, which Windows counts as the foreground (test copies, never in the foreground, did flash).
static void flashTaskbarButton(QWindow *w, bool on)
{
    FLASHWINFO info = {sizeof(info), reinterpret_cast<HWND>(w->winId()), DWORD(on ? FLASHW_ALL : FLASHW_STOP), on ? 4u : 0u, 0};
    FlashWindowEx(&info);
}

#endif

void WindowTools::checkFullScreen(QWindow *window, bool on)
{
    QPointer<QWindow> w(window);
    QTimer::singleShot(400, window, [w, on] {
        if (!w || !w->isVisible())
            return;
#ifdef Q_OS_WIN
        // Qt's fullscreen windows have no caption; its other windows do
        const bool real = !(GetWindowLongW(reinterpret_cast<HWND>(w->winId()), GWL_STYLE) & WS_CAPTION);
#else
        const bool real = w->windowStates() & Qt::WindowFullScreen;
#endif
        if (real == on)
            return;
        qWarning("fullscreen %s asked, but the window is %s (Qt's states: %d); setting it anew",
                 on ? "on" : "off", real ? "fullscreen" : "not fullscreen", int(w->windowStates()));
        w->setWindowStates(Qt::WindowNoState);
        if (on)
            w->setWindowStates(Qt::WindowFullScreen);
    });
}

void WindowTools::bringToFront(QWindow *window)
{
    if (!window)
        return;
    const bool test = qEnvironmentVariableIsSet("FTL_TEST_BACKGROUND");
#ifdef Q_OS_WIN
    const HWND hwnd = reinterpret_cast<HWND>(window->winId());
    if (!window->isVisible())        // the first window was closed while others stayed open
        test ? showBehindAll(window) : window->show();
    else if (IsIconic(hwnd))
        ShowWindow(hwnd, test ? SW_SHOWNOACTIVATE : SW_RESTORE);   // back to maximized / fullscreen if it was
    if (!test)
        SetForegroundWindow(hwnd);
#else
    if (!window->isVisible() || (window->windowStates() & Qt::WindowMinimized))
        window->showNormal();
    if (!test) {
        window->raise();
        window->requestActivate();
    }
#endif
}

void WindowTools::showBehindAll(QWindow *window)
{
    window->create();
#ifdef Q_OS_WIN
    SetWindowPos(reinterpret_cast<HWND>(window->winId()), HWND_BOTTOM, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
#endif
    window->setProperty("_q_showWithoutActivating", true);
    window->show();
#ifdef Q_OS_WIN
    SetWindowPos(reinterpret_cast<HWND>(window->winId()), HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
#endif
}

void WindowTools::showInBackground(QWindow *window, QWindow *front)
{
    if (!window)
        return;
    const bool maximized = front && (front->windowStates() & Qt::WindowMaximized);
    window->create();
    if (front) {
        if (maximized) {
            // the work area of its screen, as a normal window (showing it maximized would activate it)
            const QMargins m = window->frameMargins();
            window->setGeometry(front->screen()->availableGeometry().marginsRemoved(m));
        } else {
            window->resize(front->size());
            window->setFramePosition(front->framePosition());
        }
    }
#ifdef Q_OS_WIN
    // Shown by Windows directly behind `front`, in one step (SWP_SHOWWINDOW with `front` as the place in the
    // stack): a plain show puts a new window on top, and it appeared in front for a moment. (Hiding it with
    // DWM's cloak while showing kept the taskbar from showing the flash.) Qt's show() then only records it.
    // A minimized `front` (a link from the browser opened in the background) has no place to go behind or take
    // the rectangle from: the window goes behind all others, where Qt put it.
    const HWND hwnd = reinterpret_cast<HWND>(window->winId());
    const HWND frontHwnd = front ? reinterpret_cast<HWND>(front->winId()) : nullptr;
    const bool iconic = frontHwnd && IsIconic(frontHwnd);
    const HWND after = iconic ? HWND_BOTTOM : frontHwnd;
    if (after) {
        RECT r = {};
        UINT flags = SWP_NOACTIVATE | SWP_SHOWWINDOW;
        if (maximized || iconic || !GetWindowRect(frontHwnd, &r))   // the same outer rectangle (Qt's can be a pixel off)
            flags |= SWP_NOMOVE | SWP_NOSIZE;
        SetWindowPos(hwnd, after, r.left, r.top, r.right - r.left, r.bottom - r.top, flags);
    }
    window->setProperty("_q_showWithoutActivating", true); // read by Qt's Windows platform plugin
    window->show();
    if (after)
        SetWindowPos(hwnd, after, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
    QPointer<QWindow> w(window);
    QTimer::singleShot(300, window, [w] {   // once the taskbar has its button
        if (!w)
            return;
        flashTaskbarButton(w, true);
        QTimer::singleShot(2200, w, [w] { if (w) flashTaskbarButton(w, false); });
    });
#else
    if (front) {
        front->raise();
        front->requestActivate();
    }
    window->alert(2200);
#endif
}

void WindowTools::setColorScheme(const QString &theme)
{
    QStyleHints *hints = QGuiApplication::styleHints();
    if (theme == "system")
        hints->unsetColorScheme();
    else
        hints->setColorScheme(theme == "light" ? Qt::ColorScheme::Light : Qt::ColorScheme::Dark);
}

void WindowTools::setAppIcon(bool dark)
{
    // (windows that have no icon of their own, all of the app's, take the new one)
    QGuiApplication::setWindowIcon(QIcon(dark ? QStringLiteral(":/qt/qml/FreeTubeLight/assets/icon_dark.png")
                                              : QStringLiteral(":/qt/qml/FreeTubeLight/assets/icon_light.png")));
}

void WindowTools::flash(QWindow *window)
{
    if (!window)
        return;
#ifdef Q_OS_WIN
    QPointer<QWindow> w(window);
    flashTaskbarButton(w, true);
    QTimer::singleShot(2200, w, [w] { if (w) flashTaskbarButton(w, false); });
#else
    window->alert(2200);
#endif
}
