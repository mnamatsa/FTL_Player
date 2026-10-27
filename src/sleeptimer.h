#pragma once

#include <QElapsedTimer>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QtQml/qqmlregistration.h>

// The shutdown / sleep timer, shared by all windows (like the one in the patched FreeTube): when the time is up,
// or at the end of the video or playlist, it shuts down, restarts, sleeps, hibernates, signs out or locks the PC,
// or pauses the video or closes the app. PC actions get a 60 s warning (Cancel / Snooze) first.
// FTL_TIMER_DRYRUN=file: the PC actions are only written to that file (tests).
class SleepTimer : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString state READ state NOTIFY changed)           // idle | running | paused
    Q_PROPERTY(QString action READ action NOTIFY changed)
    Q_PROPERTY(QString mode READ mode NOTIFY changed)             // countdown | endOfVideo | endOfPlaylist
    Q_PROPERTY(qint64 remaining READ remaining NOTIFY tick)       // ms left (countdown)
    Q_PROPERTY(bool warning READ warning NOTIFY changed)          // in the last minute before a PC action
    Q_PROPERTY(bool graceful READ graceful NOTIFY changed)

public:
    explicit SleepTimer(QObject *parent = nullptr);
    ~SleepTimer() override;

    QString state() const { return m_state; }
    QString action() const { return m_action; }
    QString mode() const { return m_mode; }
    qint64 remaining() const;
    bool warning() const { return m_warning; }
    bool graceful() const { return m_graceful; }

    // action: shutdown | restart | sleep | hibernate | signout | lock | pause | close
    Q_INVOKABLE void start(const QString &action, const QString &mode, double minutes, bool graceful, bool keepAwake);
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void resume();
    Q_INVOKABLE void add(double minutes);   // +10 min, Snooze
    Q_INVOKABLE void restart();             // the countdown again from its full length
    // A video finished. Returns true when that ended an "end of video / playlist" timer (then the playlist
    // shouldn't go on to the next video).
    Q_INVOKABLE bool videoEnded(bool lastOfPlaylist);
    Q_INVOKABLE static bool isPcAction(const QString &action);
    Q_INVOKABLE static QString verb(const QString &action);   // "Shutting down" ...
    // Test copies (FTL_TEST_BACKGROUND) don't bring their window forward for the warning.
    Q_INVOKABLE static bool quiet() { return qEnvironmentVariableIsSet("FTL_TEST_BACKGROUND"); }

signals:
    void changed();
    void tick();
    void warn();                    // the 60 s warning begins (windows show it and come forward)
    void fired(const QString &action); // time is up: windows pause their videos and save progress

private:
    void schedule();
    void fire();
    void run(const QString &action);
    void keepAwake(bool on);

    QString m_state = "idle", m_action = "shutdown", m_mode = "countdown";
    qint64 m_duration = 0;          // ms, countdown length
    qint64 m_remaining = 0;         // ms left while paused
    QElapsedTimer m_clock;          // running: time since m_endIn was set
    qint64 m_endIn = 0;             // ms from m_clock's start to the end
    bool m_warning = false, m_graceful = true, m_keepAwake = false, m_awake = false;
    QTimer m_fire, m_warn, m_ticker;
};
