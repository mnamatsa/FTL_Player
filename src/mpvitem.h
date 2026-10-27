#pragma once

#include <QHash>
#include <QImage>
#include <QPointer>
#include <QSet>
#include <QTimer>
#include <QElapsedTimer>
#include <QQuickItem>
#include <QRegion>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

struct mpv_handle;
struct mpv_node;
class MpvVideoWindow;
class QNetworkAccessManager;
class QNetworkReply;

// Video area. libmpv renders (Direct3D 11, hardware decoding) into a native child window kept on top of
// this item's rectangle. Mouse and keyboard input on that window is forwarded to mpv, so mpv's own
// on-screen controller and key bindings handle the playback controls.
class MpvItem : public QQuickItem
{
    Q_OBJECT
    QML_NAMED_ELEMENT(MpvVideo)
    Q_PROPERTY(bool fullscreen READ fullscreen WRITE setFullscreen NOTIFY fullscreenChanged)
    Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
    Q_PROPERTY(double speed READ speed WRITE setSpeed NOTIFY speedChanged)
    // Step for the S (slower) and D (faster) keys.
    Q_PROPERTY(double speedStep READ speedStep WRITE setSpeedStep NOTIFY speedStepChanged)
    // Rebindable hotkeys: mpv key name -> mpv command (built by PlayerView from the settings).
    Q_PROPERTY(QVariantMap hotkeys READ hotkeys WRITE setHotkeys NOTIFY hotkeysChanged)
    // Used when mpv starts, i.e. from the next video after a change.
    Q_PROPERTY(bool hardwareDecoding MEMBER m_hwdec NOTIFY hardwareDecodingChanged)
    // The GPU setting (auto | integrated | dedicated), used when mpv starts, i.e. from the next video.
    Q_PROPERTY(QString gpu MEMBER m_gpu NOTIFY gpuChanged)
    // Mouse wheel over the video: 2 = changes the volume, 1 = only in fullscreen, 0 = never. Where it doesn't,
    // wheelScroll() is emitted instead (the page scrolls).
    Q_PROPERTY(int wheelVolume READ wheelVolume WRITE setWheelVolume NOTIFY wheelVolumeChanged)
    // Mouse wheel over the seek bar, the same way: 2 = seeks, 1 = only in fullscreen, 0 = never.
    Q_PROPERTY(int wheelSeek READ wheelSeek WRITE setWheelSeek NOTIFY wheelSeekChanged)
    // Mouse wheel over the speed button, the same way: 2 = changes the speed, 1 = only in fullscreen, 0 = never.
    Q_PROPERTY(int wheelSpeed READ wheelSpeed WRITE setWheelSpeed NOTIFY wheelSpeedChanged)
    // Volume (0-130) and mute: the values mpv starts with, then whatever the viewer sets (to keep them).
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
    // The right timecode shows the total time (true) or the time left; clicking it switches.
    Q_PROPERTY(bool timeTotal READ timeTotal WRITE setTimeTotal NOTIFY timeTotalChanged)

public:
    explicit MpvItem(QQuickItem *parent = nullptr);
    ~MpvItem() override;

    // stream: {video: {url}, audio: {url}} or {hls}, plus userAgent and title; optional start (seconds)
    // and pause, used to switch quality without losing the position.
    Q_INVOKABLE void play(const QVariantMap &stream);
    Q_INVOKABLE double timePos() const; // current playback position in seconds, or 0
    Q_INVOKABLE double duration() const; // length in seconds, or 0
    // Shows the caption track at url (WebVTT), or none when url is empty.
    Q_INVOKABLE void setSubtitle(const QString &url, const QString &title, const QString &lang);
    Q_INVOKABLE void focusVideo(); // keyboard back to mpv, e.g. after using a list in fullscreen
    Q_INVOKABLE void endTyping(); // a text field typed in (the search field) loses the focus, so keys reach mpv
    // Seek bar previews from YouTube's storyboard: {template ($M = sheet number), width, height, count,
    // interval (ms), columns, rows}, or an empty map when the video has none.
    Q_INVOKABLE void setStoryboard(const QVariantMap &storyboard);
    // Labels of the speed, quality, captions and audio buttons in mpv's control bar (ASS text; an empty
    // audio label hides that button).
    Q_INVOKABLE void setControlButtons(const QString &speed, const QString &quality, const QString &captions,
                                       const QString &audio);
    // One option of the control bar script, e.g. ("ftl_playlist", "yes").
    Q_INVOKABLE void setControlBarOption(const QString &name, const QString &value);
    // A message to the control bar script, e.g. ("ftl-segments", json).
    Q_INVOKABLE void controlBarMessage(const QString &name, const QString &arg);
    // Keeps the control bar on screen (e.g. while one of its menus is open, which takes the pointer away).
    Q_INVOKABLE void holdControlBar(bool on);
    Q_INVOKABLE void stop();
    Q_INVOKABLE void setPaused(bool on);
    Q_INVOKABLE void seek(double seconds); // to a time in the video (timestamps in the description)
    // Where the last seek went, if it began less than 15 s ago (else -1): a live stream that broke off at a seek
    // is opened there again (PlayerView).
    Q_INVOKABLE double recentSeekTarget() const { return m_seekAt.isValid() && m_seekAt.elapsed() < 15000 ? m_seekTarget : -1; }
    Q_INVOKABLE void release(); // stop and shut mpv down to give its memory back
    // Has mpv draw the video window again now and over the next second (see there).
    Q_INVOKABLE void redrawVideo();

    bool fullscreen() const { return m_fullscreen; }
    void setFullscreen(bool on);
    bool paused() const { return m_paused; }
    double speed() const { return m_speed; }
    void setSpeed(double speed);
    double speedStep() const { return m_speedStep; }
    void setSpeedStep(double step);
    QVariantMap hotkeys() const { return m_hotkeys; }
    void setHotkeys(const QVariantMap &keys);
    int wheelVolume() const { return m_wheelVolume; }
    void setWheelVolume(int mode);
    bool wheelChangesVolume() const { return m_wheelVolume == 2 || (m_wheelVolume == 1 && m_fullscreen); }
    int wheelSeek() const { return m_wheelSeek; }
    void setWheelSeek(int mode);
    bool wheelSeeks() const { return m_wheelSeek == 2 || (m_wheelSeek == 1 && m_fullscreen); }
    int wheelSpeed() const { return m_wheelSpeed; }
    void setWheelSpeed(int mode);
    bool wheelChangesSpeed() const { return m_wheelSpeed == 2 || (m_wheelSpeed == 1 && m_fullscreen); }
    double volume() const { return m_volume; }
    void setVolume(double v);
    bool muted() const { return m_muted; }
    void setMuted(bool on);
    bool timeTotal() const { return m_timeTotal; }
    void setTimeTotal(bool on);

    void command(const QList<QByteArray> &args); // asynchronous mpv command, e.g. {"keypress", "SPACE"}

signals:
    void fullscreenChanged();
    void pausedChanged();
    void speedChanged();
    void speedStepChanged();
    void hotkeysChanged();
    void hardwareDecodingChanged();
    void gpuChanged();
    void wheelVolumeChanged();
    void wheelSeekChanged();
    void wheelSpeedChanged();
    void volumeChanged();
    void mutedChanged();
    void timeTotalChanged();
    void wheelScroll(int delta); // wheel over the video or bar where it changes nothing there (angle delta)
    void ended(); // playback reached the end of the video
    void mouseActivity(); // the mouse moved or clicked over the video (for showing controls)
    void mouseMoved(qreal x, qreal y); // pointer position over the video, in item coordinates
    // a control bar button was clicked: speed | quality | captions | audio, at (x, y) in item coordinates;
    // barTop: where the control bar begins
    void menuRequested(const QString &which, qreal x, qreal y, qreal barTop);
    void speedStepRequested(int direction);   // mouse wheel over the speed button: +1 / -1
    void playlistRequested(const QString &which); // Shift+N / Shift+P: next | previous
    void started();
    void failed(const QString &error);

protected:
    void itemChange(ItemChange change, const ItemChangeData &value) override;
    bool eventFilter(QObject *watched, QEvent *event) override;
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;

private:
    bool ensureMpv();
    void processEvents();
    void syncChildWindow();
    void startSettling();
    void bindSpeedKeys();
    void showSpeed();
    static QByteArray fixedBinding(const QString &key);
    void bindWheel();
    void previewRequested(const mpv_node *request);
    void drawPreview();
    void hidePreview();
    double doubleProperty(const char *name) const;

    QPointer<MpvVideoWindow> m_video; // owned by the Qt window, which may be destroyed first
    QRegion m_videoMask;              // part of the video window shown when a clipping parent cuts it off
    QRect m_videoPx;                  // the video window's rectangle in real pixels, as last set (Windows)
    // Fullscreen coming or going: the video keeps its size until the layout settles (syncChildWindow).
    QElapsedTimer m_settling;
    QTimer m_settle;
    bool m_settled = false;           // m_settle fired: apply the size now
    QSize m_settleSize;               // the size it waits to apply
    double m_seekTarget = -1;
    QElapsedTimer m_seekAt;
    mpv_handle *m_mpv = nullptr;
    bool m_fullscreen = false;
    bool m_paused = false;
    double m_speed = 1.0;
    double m_speedStep = 0.25;
    QVariantMap m_hotkeys;
    bool m_hwdec = true;
    QString m_gpu = "auto";
    QByteArray m_adapter;       // the GPU mpv runs on ("" = Windows' default)
    int m_wheelVolume = 2;
    int m_wheelSeek = 2;
    int m_wheelSpeed = 2;
    double m_volume = 100;
    bool m_muted = false;
    bool m_timeTotal = false;
    bool m_fileLoaded = false; // speed changes before a video has loaded are not announced
    QVariantMap m_pendingSubtitle; // {url, title, lang} to add when the video has loaded

    // Seek bar preview: the control bar asks for a picture at (x, y, w, h) for hover time `seconds`.
    struct PreviewRequest { int x = 0, y = 0, w = 0, h = 0; double seconds = -1; QByteArray frame; };
    QVariantMap m_storyboard;
    QHash<int, QImage> m_sheets;        // storyboard sheet number -> image
    QHash<int, QNetworkReply *> m_sheetsLoading;   // sheet number -> its download
    QNetworkAccessManager *m_net = nullptr;
    PreviewRequest m_preview;
    QImage m_previewImage;              // must stay alive while mpv shows it
    bool m_previewShown = false;
};
