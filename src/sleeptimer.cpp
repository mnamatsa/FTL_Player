#include "sleeptimer.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QFile>
#include <QHash>
#include <QProcess>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

static constexpr qint64 WarnMs = 60'000;
static constexpr qint64 LateMs = 15'000;   // a timer this late ran out while the PC was asleep

SleepTimer::SleepTimer(QObject *parent) : QObject(parent)
{
    m_fire.setSingleShot(true);
    m_warn.setSingleShot(true);
    connect(&m_fire, &QTimer::timeout, this, &SleepTimer::fire);
    connect(&m_warn, &QTimer::timeout, this, [this] {
        if (m_state != "running" || QDateTime::currentMSecsSinceEpoch() - m_deadline > LateMs)   // see fire()
            return;
        m_warning = true;
        m_warnClock.start();
        emit changed();
        emit warn();
    });
    m_ticker.setInterval(250);
    connect(&m_ticker, &QTimer::timeout, this, &SleepTimer::tick);
}

SleepTimer::~SleepTimer() { keepAwake(false); }

bool SleepTimer::isPcAction(const QString &action)
{
    static const QStringList pc = {"shutdown", "restart", "sleep", "hibernate", "signout", "lock"};
    return pc.contains(action);
}

QString SleepTimer::verb(const QString &action)
{
    static const QHash<QString, QString> verbs = {
        {"shutdown", "Shutting down"}, {"restart", "Restarting"}, {"sleep", "Going to sleep"},
        {"hibernate", "Hibernating"}, {"signout", "Signing out"}, {"lock", "Locking the PC"},
        {"pause", "Pausing the video"}, {"close", "Closing FTL Player"}};
    return verbs.value(action);
}

qint64 SleepTimer::remaining() const
{
    if (m_state == "paused")
        return m_remaining;
    if (m_state == "running" && m_mode == "countdown")
        return qMax<qint64>(0, m_endIn - m_clock.elapsed());
    return 0;
}

void SleepTimer::start(const QString &action, const QString &mode, double minutes, bool graceful, bool keepAwakeOn)
{
    if (!isPcAction(action) && action != "pause" && action != "close")
        return;
    m_action = action;
    m_mode = (mode == "endOfVideo" || mode == "endOfPlaylist") ? mode : "countdown";
    m_graceful = graceful;
    m_keepAwake = keepAwakeOn;
    m_warning = false;
    m_state = "running";
    m_duration = m_mode == "countdown" ? qBound(qint64(1000), qRound64(minutes * 60'000), qint64(86'400'000)) : 0;
    m_endIn = m_duration;
    m_clock.start();
    keepAwake(m_keepAwake);
    schedule();
    emit changed();
    emit tick();
}

void SleepTimer::cancel()
{
    m_fire.stop();
    m_warn.stop();
    m_ticker.stop();
    m_state = "idle";
    m_warning = false;
    keepAwake(false);
    emit changed();
    emit tick();
}

void SleepTimer::pause()
{
    if (m_state != "running" || m_mode != "countdown")
        return;
    m_remaining = remaining();
    m_fire.stop();
    m_warn.stop();
    m_state = "paused";
    m_warning = false;
    emit changed();
    emit tick();
}

void SleepTimer::resume()
{
    if (m_state != "paused")
        return;
    m_endIn = m_remaining;
    m_clock.start();
    m_state = "running";
    m_warning = false;
    schedule();
    emit changed();
}

void SleepTimer::add(double minutes)
{
    const qint64 ms = qBound(qint64(0), qRound64(minutes * 60'000), qint64(86'400'000));
    if (m_state == "paused") {
        m_remaining += ms;
    } else if (m_state == "running" && m_mode == "countdown") {
        m_endIn += ms;
        m_warning = m_warning && remaining() <= WarnMs;
        schedule();
    }
    emit changed();
    emit tick();
}

void SleepTimer::restart()
{
    if (m_state == "idle" || m_mode != "countdown" || m_duration <= 0)
        return;
    m_warning = false;
    if (m_state == "paused") {
        m_remaining = m_duration;
    } else {
        m_endIn = m_duration;
        m_clock.start();
        schedule();
    }
    emit changed();
    emit tick();
}

bool SleepTimer::videoEnded(bool lastOfPlaylist)
{
    if (m_state != "running" || (m_mode != "endOfVideo" && !(m_mode == "endOfPlaylist" && lastOfPlaylist)))
        return false;
    // now a countdown: a minute (with the warning) for PC actions, at once for pause / close
    m_mode = "countdown";
    m_duration = 0;
    m_endIn = isPcAction(m_action) ? WarnMs : 0;
    m_clock.start();
    schedule();
    emit changed();
    return true;
}

void SleepTimer::schedule()
{
    m_fire.stop();
    m_warn.stop();
    if (m_state != "running" || m_mode != "countdown") {
        m_ticker.stop();
        return;
    }
    m_ticker.start();
    const qint64 left = remaining();
    m_deadline = QDateTime::currentMSecsSinceEpoch() + left;
    if (isPcAction(m_action) && !m_warning) {
        if (left - WarnMs <= 0)
            QTimer::singleShot(0, this, [this] { if (m_state == "running" && !m_warning) m_warn.start(0); });
        else
            m_warn.start(int(left - WarnMs));
    }
    m_fire.start(int(qMax<qint64>(0, left)));
}

void SleepTimer::fire()
{
    if (m_state != "running")
        return;
    // Windows runs the timers that ran out while the PC was asleep or hibernated the moment it wakes up: acting
    // then would turn the PC off again right after it was woken, so such a timer is dropped.
    const qint64 late = QDateTime::currentMSecsSinceEpoch() - m_deadline;
    if (late > LateMs) {
        qInfo("shutdown timer: \"%s\" ran out %lld s ago while the PC was asleep, cancelled",
              qPrintable(m_action), late / 1000);
        cancel();
        return;
    }
    // PC actions always get the full warning first (the warning and fire timers can run out together)
    const qint64 shown = m_warning ? m_warnClock.elapsed() : 0;
    if (isPcAction(m_action) && shown < WarnMs - 1000) {
        m_endIn = m_clock.elapsed() + WarnMs - shown;
        if (!m_warning) {
            m_warning = true;
            m_warnClock.start();
            emit changed();
            emit warn();
        }
        schedule();
        return;
    }
    const QString action = m_action;
    m_warn.stop();
    m_ticker.stop();
    m_state = "idle";
    m_warning = false;
    keepAwake(false);
    emit fired(action);     // windows pause their videos and save progress
    emit changed();
    emit tick();
    if (action != "pause")
        QTimer::singleShot(1500, this, [this, action] { run(action); });
}

void SleepTimer::run(const QString &action)
{
    if (action == "close") {
        if (qEnvironmentVariableIsSet("FTL_TIMER_DRYRUN")) {
            QFile f(qEnvironmentVariable("FTL_TIMER_DRYRUN"));
            if (f.open(QIODevice::Append))
                f.write(QDateTime::currentDateTime().toString(Qt::ISODate).toUtf8() + " WOULD RUN: quit FTL Player\n");
            return;
        }
        QCoreApplication::quit();
        return;
    }
    const QStringList force = m_graceful ? QStringList() : QStringList{"/f"};
    QString program;
    QStringList args;
    if (action == "shutdown") { program = "shutdown"; args = QStringList{"/s", "/t", "0"} + force; }
    else if (action == "restart") { program = "shutdown"; args = QStringList{"/r", "/t", "0"} + force; }
    else if (action == "signout") { program = "shutdown"; args = QStringList{"/l"} + force; }
    else if (action == "hibernate") { program = "shutdown"; args = QStringList{"/h"} + force; }
    else if (action == "sleep") {
        program = "powershell";
        args = {"-NoProfile", "-NonInteractive", "-Command",
                "Add-Type -AssemblyName System.Windows.Forms; "
                "[void][System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)"};
    } else if (action == "lock") { program = "rundll32.exe"; args = {"user32.dll,LockWorkStation"}; }
    else return;
    if (qEnvironmentVariableIsSet("FTL_TIMER_DRYRUN")) {
        QFile f(qEnvironmentVariable("FTL_TIMER_DRYRUN"));
        if (f.open(QIODevice::Append))
            f.write(QDateTime::currentDateTime().toString(Qt::ISODate).toUtf8() + " WOULD RUN: " + program.toUtf8()
                    + " " + args.join(' ').toUtf8() + "\n");
        return;
    }
    QProcess::startDetached(program, args);
}

// "Keep the screen awake until then"
void SleepTimer::keepAwake(bool on)
{
    if (on == m_awake)
        return;
    m_awake = on;
#ifdef Q_OS_WIN
    SetThreadExecutionState(on ? (ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED) : ES_CONTINUOUS);
#endif
}
