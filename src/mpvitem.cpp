#include "mpvitem.h"
#include "keynames.h"
#include "gpus.h"
#include "paths.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QStyleHints>
#include <QHash>
#include <QKeyEvent>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QQuickWindow>
#include <QTimer>
#include <QWindow>
#include <QtMath>
#include <atomic>
#include <memory>
#include <thread>
#include <mpv/client.h>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace {
// mpv's "%bytes%text" quoting lets option values contain commas, as stream URLs do.
QByteArray optValue(const QByteArray &v) { return '%' + QByteArray::number(v.size()) + '%' + v; }

// mpv key name for a Qt key event (see mpv's input.conf syntax), or empty if mpv has no use for it.
QByteArray mpvButtonName(Qt::MouseButton b)
{
    switch (b) {
    case Qt::LeftButton: return "MBTN_LEFT";
    case Qt::RightButton: return "MBTN_RIGHT";
    case Qt::MiddleButton: return "MBTN_MID";
    case Qt::BackButton: return "MBTN_BACK";
    case Qt::ForwardButton: return "MBTN_FORWARD";
    default: return {};
    }
}
} // namespace

// The native window mpv draws into. mpv disables its own embedded window, so input arrives here and is
// handed to mpv as commands; that drives its on-screen controller and key bindings.
class MpvVideoWindow : public QWindow
{
public:
    MpvVideoWindow(MpvItem *item, QWindow *parent) : QWindow(parent), m_item(item)
    {
        setFlags(Qt::FramelessWindowHint);
        m_cursorTimer.setSingleShot(true);
        m_cursorTimer.setInterval(4000); // hides with the control bar
        QObject::connect(&m_cursorTimer, &QTimer::timeout, [this] { setCursor(Qt::BlankCursor); });
    }

protected:
    void sendPosition(const QPointF &pos)
    {
        const QPointF p = pos * devicePixelRatio();
        m_item->command({"mouse", QByteArray::number(qRound(p.x())), QByteArray::number(qRound(p.y()))});
    }
    void mouseMoveEvent(QMouseEvent *e) override
    {
        sendPosition(e->position());
        showCursor();
        emit m_item->mouseActivity();
        emit m_item->mouseMoved(e->position().x(), e->position().y());
    }
    void mousePressEvent(QMouseEvent *e) override { press(e); }
    void mouseReleaseEvent(QMouseEvent *e) override
    {
        if (e->button() == Qt::LeftButton && m_swallowRelease) { // the double-click's second press wasn't sent
            m_swallowRelease = false;
            return;
        }
        m_item->command({"keyup", mpvButtonName(e->button())});
    }
    // Qt reports a double-click after (or instead of) the second press; it is detected in press() instead.
    void mouseDoubleClickEvent(QMouseEvent *e) override
    {
        if (!m_pressed.isValid() || m_pressed.elapsed() > 20) // no press came with it
            press(e);
    }
    void wheelEvent(QWheelEvent *e) override
    {
        const QPoint d = e->angleDelta();
        // Near the control bar the wheel goes to mpv (its buttons use it, e.g. speed and volume; see bindWheel).
        // Elsewhere it changes the volume or, where that is turned off, scrolls the page.
        if (!m_item->wheelChangesVolume() && e->position().y() < height() - 90) {
            if (d.y())
                emit m_item->wheelScroll(d.y());
            return;
        }
        if (d.y())
            m_item->command({"keypress", d.y() > 0 ? "WHEEL_UP" : "WHEEL_DOWN"});
        else if (d.x())
            m_item->command({"keypress", d.x() > 0 ? "WHEEL_LEFT" : "WHEEL_RIGHT"});
    }
    void keyPressEvent(QKeyEvent *e) override
    {
        const QByteArray key = mpvKeyName(e->key(), e->modifiers(), e->text());
        // mpv's "q" quits its core, which would leave an empty player; the app's back button does that job.
        if (!key.isEmpty() && key != "q" && key != "Q")
            m_item->command({"keypress", key});
    }
    bool event(QEvent *e) override
    {
        // FTL_TEST_IGNORE_LEAVE: simulated clicks in tests otherwise look like the pointer left the video.
        static const bool ignoreLeave = qEnvironmentVariableIsSet("FTL_TEST_IGNORE_LEAVE");
        if (e->type() == QEvent::Leave && !ignoreLeave) {
            m_item->command({"keypress", "MOUSE_LEAVE"});
            m_cursorTimer.stop();
            unsetCursor();
        }
        return QWindow::event(e);
    }

private:
    void showCursor()
    {
        unsetCursor();
        m_cursorTimer.start();
    }

    // A second left click soon after the first, above the control bar (where quick clicks are meant for
    // its buttons), toggles fullscreen and undoes the first click's pause; it isn't passed on to mpv.
    // Detected from the presses because Qt's double-click event didn't always arrive, and mpv's own
    // detection (MBTN_LEFT_DBL, now ignored) toggled fullscreen a second time.
    void press(QMouseEvent *e)
    {
        m_pressed.start();
        requestActivate(); // so the keyboard reaches mpv too
        m_item->endTyping(); // (and not the search field once the main window is active again)
        sendPosition(e->position()); // the control bar decides by position which button was clicked
        showCursor();
        emit m_item->mouseActivity();
        if (e->button() == Qt::LeftButton && e->position().y() < height() - 90) {
            const int interval = QGuiApplication::styleHints()->mouseDoubleClickInterval();
            if (m_firstClick.isValid() && m_firstClick.elapsed() <= interval
                && (e->position() - m_firstClickPos).manhattanLength() <= 12) {
                m_firstClick.invalidate();
                m_swallowRelease = true;
                m_item->command({"cycle", "pause"});
                m_item->setFullscreen(!m_item->fullscreen());
                return;
            }
            m_firstClick.start();
            m_firstClickPos = e->position();
        }
        m_item->command({"keydown", mpvButtonName(e->button())});
    }

    MpvItem *m_item;
    QTimer m_cursorTimer;
    QElapsedTimer m_pressed;      // the last press (to tell Qt's double-click event apart from it)
    QElapsedTimer m_firstClick;   // a left click that may become a double-click
    QPointF m_firstClickPos;
    bool m_swallowRelease = false;
};

MpvItem::MpvItem(QQuickItem *parent) : QQuickItem(parent)
{
    // Fallback for quitting without a window close (the window's closing signal is the main path).
    connect(qApp, &QCoreApplication::aboutToQuit, this, &MpvItem::release);
    m_settle.setSingleShot(true);
    m_settle.setInterval(50);
    connect(&m_settle, &QTimer::timeout, this, [this] {
        m_settled = true;
        syncChildWindow();
        m_settled = false;
    });
}

// Fullscreen comes or goes: for the next 0.4 s the video window takes a new size only once the layout has
// stopped changing for 50 ms (syncChildWindow).
void MpvItem::startSettling()
{
    m_settling.start();
}

MpvItem::~MpvItem()
{
    release();
    delete m_video;
}

bool MpvItem::ensureMpv()
{
    if (m_mpv)
        return true;
    if (!window())
        return false;

    if (!m_video) {
        m_video = new MpvVideoWindow(this, window());
        syncChildWindow();
        m_video->setVisible(isVisible());
    }

    m_mpv = mpv_create();
    if (!m_mpv)
        return false;
    const qint64 wid = qint64(m_video->winId());
    mpv_set_option(m_mpv, "wid", MPV_FORMAT_INT64, const_cast<qint64 *>(&wid));
    // Extra controller options for testing, e.g. FTL_SCRIPT_OPTS="osc-visibility=always".
    QByteArray scriptOpts = qgetenv("FTL_SCRIPT_OPTS");
    if (!scriptOpts.isEmpty())
        scriptOpts += ',';
    const std::pair<const char *, QByteArray> options[] = {
        {"osd-bar", "no"}, // the big white bar on seeks / volume changes; the control bar shows them
        {"osd-on-seek", "no"}, // nor a text message (an empty box in the corner, with the bar off)
        {"vo", "gpu-next"}, {"gpu-api", "d3d11"}, {"hwdec", m_hwdec ? "auto-safe" : "no"},
        // the GPU for this video (play()): an adapter by name, "" = Windows' default; hardware decoding uses it
        {"d3d11-adapter", m_adapter},
        {"speed", QByteArray::number(m_speed)},
        {"volume", QByteArray::number(m_volume)}, {"mute", m_muted ? "yes" : "no"},
        // On-screen messages (speed, volume, seeking) and captions: small text on a dark box.
        {"osd-font-size", "28"}, {"osd-border-style", "background-box"}, {"osd-back-color", "#C0000000"},
        {"osd-margin-x", "24"}, {"osd-margin-y", "20"}, {"osd-duration", "1200"},
        {"sub-border-style", "background-box"}, {"sub-back-color", "#B0000000"}, {"sub-font-size", "36"},
        // mpv's controller with three extra buttons (speed, quality, captions) that ask the app to open
        // its menus. A copy of the controller is used so the buttons can be as wide as their text.
        {"osc", "no"}, {"scripts", QDir::toNativeSeparators(Paths::app() + "/mpv/osc.lua").toUtf8()},
        // deadzonesize=0: pointer movement anywhere over the video shows the bar (not only near the bottom)
        // hidetimeout: the bar stays 4 s after the pointer stops moving
        {"script-opts", scriptOpts + "osc-layout=bottombar,osc-deadzonesize=0,osc-hidetimeout=4000,"
                        + (m_timeTotal ? "osc-timetotal=yes," : "osc-timetotal=no,") +
                        // FreeTube-like seek bar: red played part with a knob
                        "osc-seekbarstyle=knob,osc-seekbarhandlesize=0.8,osc-seekbar_color=#F04242,"
                        // played part thick from the start, buffered part ahead thin (osc.lua edits)
                        "osc-seekrangestyle=slider,osc-seekrangealpha=110,"
                        "osc-custom_button_1_content=1\u00d7,"
                        "osc-custom_button_1_mbtn_left_command=script-message ftl-menu speed,"
                        "osc-custom_button_2_content=Auto,"
                        "osc-custom_button_2_mbtn_left_command=script-message ftl-menu quality,"
                        "osc-custom_button_3_content={\\fnmpv-osd-symbols},"  // subtitle icon (U+E107)
                        "osc-custom_button_3_mbtn_left_command=script-message ftl-menu captions,"
                        "osc-custom_button_4_mbtn_left_command=script-message ftl-menu audio"},
        {"input-default-bindings", "yes"},
        {"force-window", "yes"}, {"idle", "yes"}, {"keep-open", "yes"}, {"ytdl", "no"},
        {"audio-client-name", "FTL Player"},
        // Read ahead ~20 s instead of mpv's 150 MiB default: ~10 MB at 1080p, capped at 48 MB for 4K.
        {"cache-secs", "20"}, {"demuxer-max-bytes", "48MiB"}, {"demuxer-max-back-bytes", "8MiB"},
    };
    for (const auto &[name, value] : options)
        mpv_set_option_string(m_mpv, name, value.constData());

    if (const QByteArray log = qgetenv("FTL_MPV_LOG"); !log.isEmpty())
        mpv_set_option_string(m_mpv, "log-file", log.constData());
    // Extra options for testing, e.g. FTL_MPV_OPTS="mute=yes;volume=50".
    for (const QByteArray &kv : qgetenv("FTL_MPV_OPTS").split(';')) {
        if (const qsizetype eq = kv.indexOf('='); eq > 0)
            mpv_set_option_string(m_mpv, kv.left(eq).constData(), kv.mid(eq + 1).constData());
    }

    if (mpv_initialize(m_mpv) < 0) {
        mpv_destroy(m_mpv);
        m_mpv = nullptr;
        return false;
    }
    mpv_observe_property(m_mpv, 0, "fullscreen", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "eof-reached", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "mute", MPV_FORMAT_FLAG);
    // Set by the control bar while the pointer is over the seek bar (where and when to show a preview).
    mpv_observe_property(m_mpv, 0, "user-data/osc/draw-preview", MPV_FORMAT_NODE);
    bindSpeedKeys();
    mpv_set_wakeup_callback(m_mpv, [](void *self) {
        QMetaObject::invokeMethod(static_cast<MpvItem *>(self), &MpvItem::processEvents, Qt::QueuedConnection);
    }, this);
    return true;
}

void MpvItem::command(const QList<QByteArray> &args)
{
    if (!m_mpv || args.isEmpty() || args.contains(QByteArray()))
        return;
    std::vector<const char *> argv;
    for (const QByteArray &a : args)
        argv.push_back(a.constData());
    argv.push_back(nullptr);
    mpv_command_async(m_mpv, 0, argv.data());
}

void MpvItem::play(const QVariantMap &stream)
{
    // The GPU for this video: the setting's, or with "auto" one that decodes its codec in hardware (mpv
    // starts again on it when that changes, e.g. from a VP9 video to an AV1 one)
    const QString codec = stream.value("hls").toString().isEmpty()
                              ? stream.value("video").toMap().value("codec").toString() : stream.value("liveCodec", QStringLiteral("avc1")).toString();   // live: H.264 (HLS) or the DASH format's
    const QByteArray adapter = (m_gpu == "auto" ? (m_hwdec ? Gpus::autoFor(codec) : QString())
                                                : Gpus::forChoice(m_gpu).name).toUtf8();
    if (m_mpv && adapter != m_adapter)
        release();
    m_adapter = adapter;
    if (!ensureMpv()) {
        emit failed("Could not start the video player.");
        return;
    }
    const QString hls = stream.value("hls").toString();
    const QByteArray url = (hls.isEmpty() ? stream.value("video").toMap().value("url").toString() : hls).toUtf8();
    QByteArray opts = "user-agent=" + optValue(stream.value("userAgent").toString().toUtf8())
                    + ",force-media-title=" + optValue(stream.value("title").toString().toUtf8());
    if (hls.isEmpty())
        opts += ",audio-files=" + optValue(stream.value("audio").toMap().value("url").toString().toUtf8());
    // The caption track is added once the video has loaded, so it can carry its name and language.
    m_pendingSubtitle = stream.value("subtitle").toMap();
    if (const double start = stream.value("start").toDouble(); start > 0)
        opts += ",start=" + QByteArray::number(start, 'f', 3);
    opts += stream.value("pause").toBool() ? ",pause=yes" : ",pause=no";
    const char *cmd[] = {"loadfile", url.constData(), "replace", "-1", opts.constData(), nullptr};
    m_fileLoaded = false;
    mpv_command(m_mpv, cmd);
    // keyboard goes to mpv (space, arrows, f, m, 9/0 ...); not for a window opened in the background
    if (window() && window()->isActive())
        m_video->requestActivate();
}

double MpvItem::doubleProperty(const char *name) const
{
    double v = 0;
    if (m_mpv && mpv_get_property(m_mpv, name, MPV_FORMAT_DOUBLE, &v) < 0)
        v = 0;
    return v;
}

double MpvItem::timePos() const { return doubleProperty("time-pos"); }

void MpvItem::setControlBarOption(const QString &name, const QString &value)
{
    command({"change-list", "script-opts", "append", ("osc-" + name + "=" + value).toUtf8()});
}

void MpvItem::controlBarMessage(const QString &name, const QString &arg)
{
    if (m_mpv)
        command({"script-message-to", "osc", name.toUtf8(), arg.toUtf8()});
}

void MpvItem::holdControlBar(bool on)
{
    // FTL_SCRIPT_OPTS may already keep it always visible (tests)
    static const bool always = qgetenv("FTL_SCRIPT_OPTS").contains("osc-visibility=always");
    command({"script-message-to", "osc", "osc-visibility", on || always ? "always" : "auto", "no-osd"});
    if (!on)
        command({"script-message-to", "osc", "osc-show"}); // then hides after the usual time
}

void MpvItem::setControlButtons(const QString &speed, const QString &quality, const QString &captions,
                                const QString &audio)
{
    const QString labels[] = {speed, quality, captions, audio};
    for (int i = 0; i < 4; ++i) {
        // Commas would end the option value; the labels never need them. The control bar stops at the
        // first empty button, which is how the (last) audio button disappears for single-track videos.
        const QString text = labels[i].isEmpty() && i < 3 ? QStringLiteral(" ") : QString(labels[i]).remove(',');
        command({"change-list", "script-opts", "append",
                 QStringLiteral("osc-custom_button_%1_content=%2").arg(i + 1).arg(text).toUtf8()});
    }
}

void MpvItem::setStoryboard(const QVariantMap &storyboard)
{
    hidePreview();
    m_storyboard = storyboard;
    // (the control bar puts the chapter name above the preview picture, or above the time without one)
    setControlBarOption("ftl_preview", storyboard.isEmpty() ? "no" : "yes");
    m_sheets.clear();
    const auto loading = std::exchange(m_sheetsLoading, {});
    for (QNetworkReply *r : loading)
        r->abort();
}

void MpvItem::previewRequested(const mpv_node *request)
{
    if (request->format != MPV_FORMAT_NODE_MAP || m_storyboard.isEmpty()) {
        hidePreview();
        return;
    }
    PreviewRequest r;
    const mpv_node_list *map = request->u.list;
    for (int i = 0; i < map->num; ++i) {
        const char *key = map->keys[i];
        const mpv_node &v = map->values[i];
        const double num = v.format == MPV_FORMAT_INT64 ? double(v.u.int64) : v.format == MPV_FORMAT_DOUBLE ? v.u.double_ : 0;
        if (qstrcmp(key, "x") == 0) r.x = int(num);
        else if (qstrcmp(key, "y") == 0) r.y = int(num);
        else if (qstrcmp(key, "w") == 0) r.w = int(num);
        else if (qstrcmp(key, "h") == 0) r.h = int(num);
        else if (qstrcmp(key, "hover-sec") == 0) r.seconds = num;
        else if (qstrcmp(key, "ass") == 0 && v.format == MPV_FORMAT_STRING) r.frame = v.u.string;
    }
    if (r.w <= 0 || r.h <= 0 || r.seconds < 0) {
        hidePreview();
        return;
    }
    m_preview = r;
    drawPreview();
}

// Cuts the storyboard tile for the hover time out of its sheet (downloading the sheet the first time),
// scales it to the requested size and has mpv draw it, with the control bar's frame behind it.
void MpvItem::drawPreview()
{
    if (!m_mpv || m_storyboard.isEmpty() || m_preview.seconds < 0)
        return;
    const int cols = m_storyboard.value("columns").toInt(), rows = m_storyboard.value("rows").toInt();
    const int count = m_storyboard.value("count").toInt();
    const double interval = m_storyboard.value("interval").toDouble();
    if (cols <= 0 || rows <= 0 || count <= 0 || interval <= 0)
        return;
    // (live streams: offset = the segment number the timeline starts with; pictures are numbered by segment)
    const int offset = m_storyboard.value("offset").toInt();
    const int per = cols * rows;
    int index = qBound(0, offset + int(m_preview.seconds * 1000 / interval), count - 1);
    // A live stream's sheet holds only 9 pictures (45 s) and its seek bar spans up to 12 h, so moving along it
    // asked for a new sheet nearly every pixel; the downloads queued up (6 at a time) and the picture trailed
    // the pointer. So a picture of a sheet already here is taken when it is within ~2 px of the pointer's
    // time (0.2 % of the video), and only the newest sheet asked for is downloaded.
    if (!m_sheets.contains(index / per)) {
        const double duration = doubleProperty("duration");
        const int slack = duration > 0 ? int(duration * 1000 / interval / 500) : 0;
        const int target = index;
        int bestDiff = slack + 1;
        for (auto it = m_sheets.cbegin(); it != m_sheets.cend(); ++it) {
            const int i = qBound(it.key() * per, target, it.key() * per + per - 1);
            if (qAbs(i - target) < bestDiff) {
                bestDiff = qAbs(i - target);
                index = i;
            }
        }
    }
    const int sheet = index / per, cell = index % per;

    if (!m_sheets.contains(sheet)) {
        if (m_sheetsLoading.contains(sheet))
            return;
        if (!m_net)
            m_net = new QNetworkAccessManager(this);
        const auto older = m_sheetsLoading;   // (abort() runs the finished handler, which edits the hash)
        for (QNetworkReply *r : older)
            r->abort();
        const QVariantMap board = m_storyboard;
        const QUrl url(board.value("template").toString().replace("$M", QString::number(sheet)));
        QNetworkReply *reply = m_net->get(QNetworkRequest(url));
        m_sheetsLoading.insert(sheet, reply);
        connect(reply, &QNetworkReply::finished, this, [this, reply, sheet, board] {
            reply->deleteLater();
            if (board != m_storyboard)
                return; // a different video by now
            m_sheetsLoading.remove(sheet);
            QImage img;
            if (reply->error() == QNetworkReply::NoError && img.loadFromData(reply->readAll())) {
                m_sheets.insert(sheet, img);
                drawPreview();
            }
        });
        return;
    }

    const QImage &img = m_sheets[sheet];
    // Sheets are a grid of cols x rows; the last sheet may be shorter, so tile size comes from the board.
    const int tw = m_storyboard.value("width").toInt(), th = m_storyboard.value("height").toInt();
    const QRect tile((cell % cols) * tw, (cell / cols) * th, tw, th);
    if (!img.rect().contains(tile))
        return;
    m_previewImage = img.copy(tile)
                         .scaled(m_preview.w, m_preview.h, Qt::IgnoreAspectRatio, Qt::SmoothTransformation)
                         .convertToFormat(QImage::Format_ARGB32_Premultiplied); // = mpv's "bgra" in memory

    if (!m_preview.frame.isEmpty()) {
        // The frame's coordinates are in OSD pixels, so the overlay uses the OSD size as its resolution.
        mpv_node dims;
        qint64 osdW = 0, osdH = 0;
        if (mpv_get_property(m_mpv, "osd-dimensions", MPV_FORMAT_NODE, &dims) >= 0) {
            if (dims.format == MPV_FORMAT_NODE_MAP)
                for (int i = 0; i < dims.u.list->num; ++i) {
                    if (qstrcmp(dims.u.list->keys[i], "w") == 0) osdW = dims.u.list->values[i].u.int64;
                    if (qstrcmp(dims.u.list->keys[i], "h") == 0) osdH = dims.u.list->values[i].u.int64;
                }
            mpv_free_node_contents(&dims);
        }
        const char *keys[] = {"name", "id", "format", "data", "res_x", "res_y", "z"};
        mpv_node values[7];
        values[0] = {{.string = const_cast<char *>("osd-overlay")}, MPV_FORMAT_STRING};
        values[1].format = MPV_FORMAT_INT64; values[1].u.int64 = 0x7f17;
        values[2] = {{.string = const_cast<char *>("ass-events")}, MPV_FORMAT_STRING};
        values[3] = {{.string = m_preview.frame.data()}, MPV_FORMAT_STRING};
        values[4].format = MPV_FORMAT_INT64; values[4].u.int64 = osdW;
        values[5].format = MPV_FORMAT_INT64; values[5].u.int64 = osdH;
        values[6].format = MPV_FORMAT_INT64; values[6].u.int64 = 2000;
        mpv_node_list list{7, values, const_cast<char **>(keys)};
        mpv_node cmd;
        cmd.format = MPV_FORMAT_NODE_MAP;
        cmd.u.list = &list;
        mpv_command_node(m_mpv, &cmd, nullptr);
    }

    const QByteArray addr = "&" + QByteArray::number(quintptr(m_previewImage.constBits()));
    const QByteArray x = QByteArray::number(m_preview.x), y = QByteArray::number(m_preview.y);
    const QByteArray w = QByteArray::number(m_previewImage.width()), h = QByteArray::number(m_previewImage.height());
    const QByteArray stride = QByteArray::number(m_previewImage.bytesPerLine());
    const char *cmd[] = {"overlay-add", "0", x.constData(), y.constData(), addr.constData(), "0", "bgra",
                         w.constData(), h.constData(), stride.constData(), nullptr};
    mpv_command(m_mpv, cmd); // synchronous: mpv has copied the picture when this returns
    m_previewShown = true;
}

void MpvItem::hidePreview()
{
    m_preview.seconds = -1;
    if (!m_mpv || !m_previewShown)
        return;
    m_previewShown = false;
    const char *remove[] = {"overlay-remove", "0", nullptr};
    mpv_command(m_mpv, remove);
    const char *keys[] = {"name", "id", "format", "data"};
    mpv_node values[4];
    values[0] = {{.string = const_cast<char *>("osd-overlay")}, MPV_FORMAT_STRING};
    values[1].format = MPV_FORMAT_INT64; values[1].u.int64 = 0x7f17;
    values[2] = {{.string = const_cast<char *>("none")}, MPV_FORMAT_STRING};
    values[3] = {{.string = const_cast<char *>("")}, MPV_FORMAT_STRING};
    mpv_node_list list{4, values, const_cast<char **>(keys)};
    mpv_node cmd;
    cmd.format = MPV_FORMAT_NODE_MAP;
    cmd.u.list = &list;
    mpv_command_node(m_mpv, &cmd, nullptr);
}

void MpvItem::focusVideo()
{
    if (m_video)
        m_video->requestActivate();
}

void MpvItem::setSubtitle(const QString &url, const QString &title, const QString &lang)
{
    if (!m_mpv)
        return;
    command({"sub-remove"}); // the current caption track, if any
    if (url.isEmpty())
        command({"set", "sid", "no"});
    else
        command({"sub-add", url.toUtf8(), "select", (title.isEmpty() ? QStringLiteral("Captions") : title).toUtf8(),
                 (lang.isEmpty() ? QStringLiteral("und") : lang).toUtf8()});
}
double MpvItem::duration() const { return doubleProperty("duration"); }

void MpvItem::setSpeed(double speed)
{
    speed = qBound(0.1, speed, 4.0);
    if (qFuzzyCompare(m_speed, speed))
        return;
    m_speed = speed;
    if (m_mpv)
        mpv_set_property(m_mpv, "speed", MPV_FORMAT_DOUBLE, &speed);
    if (m_fileLoaded)
        showSpeed();
    emit speedChanged();
}

// "1.25×" in the message box at the top of the video (osc.lua)
void MpvItem::showSpeed()
{
    command({"script-message-to", "osc", "ftl-flash", QByteArray::number(qRound(m_speed * 100) / 100.0) + "×"});
}

void MpvItem::setPaused(bool on)
{
    if (!m_mpv)
        return;
    int flag = on;
    mpv_set_property(m_mpv, "pause", MPV_FORMAT_FLAG, &flag);
}

void MpvItem::seek(double seconds)
{
    if (m_mpv)
        command({"seek", QByteArray::number(seconds), "absolute+exact"});
}

void MpvItem::setHotkeys(const QVariantMap &keys)
{
    if (keys == m_hotkeys)
        return;
    // keys no longer used get back their fixed meaning (0-9), else do nothing (rather than mpv's own meaning)
    for (auto it = m_hotkeys.cbegin(); it != m_hotkeys.cend(); ++it)
        if (!keys.contains(it.key()) && m_mpv)
            command({"keybind", it.key().toUtf8(), fixedBinding(it.key())});
    m_hotkeys = keys;
    if (m_mpv)
        for (auto it = m_hotkeys.cbegin(); it != m_hotkeys.cend(); ++it)
            command({"keybind", it.key().toUtf8(), it.value().toString().toUtf8()});
    emit hotkeysChanged();
}

void MpvItem::setSpeedStep(double step)
{
    if (qFuzzyCompare(m_speedStep, step) || step <= 0)
        return;
    m_speedStep = step;
    bindSpeedKeys();
    emit speedStepChanged();
}

// Fixed bindings, plus the hotkeys from the settings (speed, jumps, frame steps). mpv's own [ and ] keep
// changing the speed too.
// 0-9 jump to 0 %, 10 % ... 90 % of the video, as on YouTube (mpv's own meanings for them: volume, picture);
// Up / Down change the volume by 5 % (mpv's: seek 1 min).
QByteArray MpvItem::fixedBinding(const QString &key)
{
    if (key.size() == 1 && key.at(0).isDigit())
        return "script-message-to osc ftl-percent " + QByteArray::number(key.at(0).digitValue() * 10);
    if (key == "UP" || key == "DOWN")
        return key == "UP" ? "osd-msg add volume 5" : "osd-msg add volume -5";   // "Volume: 55%", like the slider
    return "ignore";
}

void MpvItem::bindSpeedKeys()
{
    if (!m_mpv)
        return;
    for (int i = 0; i <= 9; ++i)        // before the hotkeys: a key bound to a hotkey keeps that
        command({"keybind", QByteArray::number(i), fixedBinding(QString::number(i))});
    for (const char *key : {"UP", "DOWN"})
        command({"keybind", key, fixedBinding(key)});
    for (auto it = m_hotkeys.cbegin(); it != m_hotkeys.cend(); ++it)
        command({"keybind", it.key().toUtf8(), it.value().toString().toUtf8()});
    command({"keybind", "[", "no-osd multiply speed 1/1.1"});
    command({"keybind", "]", "no-osd multiply speed 1.1"});
    // A click on the video pauses / resumes (the control bar's own buttons take clicks on the bar).
    command({"keybind", "MBTN_LEFT", "cycle pause"});
    // The double-click is handled here (MpvVideoWindow): mpv also spots one in the forwarded clicks and would
    // toggle fullscreen a second time, so the window went in and straight back out.
    command({"keybind", "MBTN_LEFT_DBL", "ignore"});
    // Playlists: Shift+N / Shift+P for the next / previous video, as on YouTube.
    command({"keybind", "N", "script-message ftl-playlist next"});
    command({"keybind", "P", "script-message ftl-playlist previous"});
    bindWheel();
}

// The wheel follows the settings (and fullscreen): over the video it changes the volume or scrolls the page
// (ftl-scroll), and so does it over the parts of the control bar that don't use it (ftl_wheel_*: empty space,
// the title, the time, the quality / captions / audio buttons). The seek bar and the speed button seek and
// change the speed, or scroll the page too. The volume button and slider always change the volume.
void MpvItem::bindWheel()
{
    if (!m_mpv)
        return;
    const bool volume = wheelChangesVolume();
    const QByteArray up = volume ? "add volume 2" : "script-message ftl-scroll 120";
    const QByteArray down = volume ? "add volume -2" : "script-message ftl-scroll -120";
    command({"keybind", "WHEEL_UP", up});
    command({"keybind", "WHEEL_DOWN", down});
    setControlBarOption("ftl_wheel_up_command", up);
    setControlBarOption("ftl_wheel_down_command", down);
    const bool seek = wheelSeeks();
    setControlBarOption("seekbar_wheel_up_command", seek ? "seek 10" : "script-message ftl-scroll 120");
    setControlBarOption("seekbar_wheel_down_command", seek ? "seek -10" : "script-message ftl-scroll -120");
    const bool speed = wheelChangesSpeed();
    setControlBarOption("custom_button_1_wheel_up_command", speed ? "script-message ftl-speed 1" : "script-message ftl-scroll 120");
    setControlBarOption("custom_button_1_wheel_down_command", speed ? "script-message ftl-speed -1" : "script-message ftl-scroll -120");
}

void MpvItem::setTimeTotal(bool on)
{
    if (on == m_timeTotal)
        return;
    m_timeTotal = on;
    if (m_mpv)
        setControlBarOption("timetotal", on ? "yes" : "no");
    emit timeTotalChanged();
}

void MpvItem::setVolume(double v)
{
    if (qFuzzyCompare(v + 1, m_volume + 1))
        return;
    m_volume = v;
    if (m_mpv)
        mpv_set_property(m_mpv, "volume", MPV_FORMAT_DOUBLE, &v);
    emit volumeChanged();
}

void MpvItem::setMuted(bool on)
{
    if (on == m_muted)
        return;
    m_muted = on;
    if (m_mpv) {
        int flag = on;
        mpv_set_property(m_mpv, "mute", MPV_FORMAT_FLAG, &flag);
    }
    emit mutedChanged();
}

void MpvItem::setWheelSeek(int mode)
{
    if (m_wheelSeek == mode)
        return;
    m_wheelSeek = mode;
    bindWheel();
    emit wheelSeekChanged();
}

void MpvItem::setWheelSpeed(int mode)
{
    if (m_wheelSpeed == mode)
        return;
    m_wheelSpeed = mode;
    bindWheel();
    emit wheelSpeedChanged();
}

void MpvItem::setWheelVolume(int mode)
{
    if (m_wheelVolume == mode)
        return;
    m_wheelVolume = mode;
    bindWheel();
    emit wheelVolumeChanged();
}

void MpvItem::stop()
{
    if (!m_mpv)
        return;
    const char *cmd[] = {"stop", nullptr};
    mpv_command(m_mpv, cmd);
    setFullscreen(false);
}

void MpvItem::release()
{
    if (!m_mpv)
        return;
    setFullscreen(false);
    // Frees the decoder, GPU device and caches; the next play() starts mpv again.
    // mpv's video window is a child of ours but runs on mpv's own thread, and while shutting down it waits
    // for this thread to answer window messages. So terminate on a helper thread and keep handling events
    // here until it is done; calling mpv_terminate_destroy() directly can deadlock (e.g. on app exit).
    mpv_handle *mpv = std::exchange(m_mpv, nullptr);
    mpv_set_wakeup_callback(mpv, nullptr, nullptr);
    auto done = std::make_shared<std::atomic_bool>(false);
    std::thread([mpv, done] { mpv_terminate_destroy(mpv); *done = true; }).detach();
    QElapsedTimer waited;
    waited.start();
    while (!*done && waited.elapsed() < 5000) {
        QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents, 10);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (m_paused) {
        m_paused = false;
        emit pausedChanged();
    }
}

// A player started in a window that is behind others (one loaded once its window came forward), paused, showed
// the frame mpv drew while the window was still being laid out, cut and shifted, with what was behind showing
// through, until the window was resized: mpv draws a paused video again only when asked. Windows asks with a
// paint message, so the video window is marked as needing one, now and while the layout settles.
void MpvItem::redrawVideo()
{
#ifdef Q_OS_WIN
    if (!m_video)
        return;
    QPointer<QWindow> video(m_video);
    for (int ms : {0, 150, 500, 1000})
        QTimer::singleShot(ms, this, [video] {
            if (video && video->isVisible())   // (not UPDATENOW: mpv's window belongs to mpv's thread)
                RedrawWindow(reinterpret_cast<HWND>(video->winId()), nullptr, nullptr,
                             RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
        });
#endif
}

void MpvItem::setFullscreen(bool on)
{
    // (logged: once a window's interface stopped reacting, fullscreen included; this tells whether the request
    // got this far, next to Main.qml's "fullscreen on/off" line)
    qInfo("player %p: fullscreen %s requested (was %s), window \"%s\"", static_cast<void *>(this), on ? "on" : "off",
          m_fullscreen ? "on" : "off", window() ? qPrintable(window()->title()) : "");
    if (m_fullscreen == on)
        return;
    m_fullscreen = on;
    startSettling();
    if (m_mpv) {
        int flag = on;
        mpv_set_property(m_mpv, "fullscreen", MPV_FORMAT_FLAG, &flag);
    }
    bindWheel();
    emit fullscreenChanged();
}

void MpvItem::processEvents()
{
    while (m_mpv) {
        mpv_event *ev = mpv_wait_event(m_mpv, 0);
        if (ev->event_id == MPV_EVENT_NONE)
            break;
        switch (ev->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE: {
            auto *p = static_cast<mpv_event_property *>(ev->data);
            if (qstrcmp(p->name, "user-data/osc/draw-preview") == 0) {
                if (p->format == MPV_FORMAT_NODE)
                    previewRequested(static_cast<mpv_node *>(p->data));
                else
                    hidePreview();
                break;
            }
            if (p->format == MPV_FORMAT_DOUBLE && qstrcmp(p->name, "speed") == 0) {
                const double v = *static_cast<double *>(p->data);
                if (!qFuzzyCompare(v, m_speed)) {
                    m_speed = v;
                    emit speedChanged();
                    if (m_fileLoaded)   // changed by mpv itself ([ and ])
                        showSpeed();
                }
                break;
            }
            if (p->format == MPV_FORMAT_DOUBLE && qstrcmp(p->name, "volume") == 0) {
                const double v = *static_cast<double *>(p->data);
                if (!qFuzzyCompare(v + 1, m_volume + 1)) {
                    m_volume = v;
                    emit volumeChanged();
                }
                break;
            }
            if (p->format != MPV_FORMAT_FLAG)
                break;
            const bool v = *static_cast<int *>(p->data);
            if (qstrcmp(p->name, "mute") == 0) {
                if (v != m_muted) {
                    m_muted = v;
                    emit mutedChanged();
                }
                break;
            }
            if (qstrcmp(p->name, "fullscreen") == 0 && v != m_fullscreen) {
                // mpv's own controls (double-click, f, Esc, the OSC button) toggle this.
                qInfo("player %p: mpv set fullscreen %s", static_cast<void *>(this), v ? "on" : "off");
                m_fullscreen = v;
                startSettling();
                bindWheel();
                emit fullscreenChanged();
            } else if (qstrcmp(p->name, "pause") == 0 && v != m_paused) {
                m_paused = v;
                emit pausedChanged();
            } else if (qstrcmp(p->name, "eof-reached") == 0 && v) {
                emit ended();
            }
            break;
        }
        case MPV_EVENT_SEEK:
            // while a seek runs, time-pos is its target (recentSeekTarget)
            m_seekTarget = timePos();
            m_seekAt.start();
            break;
        case MPV_EVENT_FILE_LOADED:
            m_fileLoaded = true;
            redrawVideo();
            setControlBarOption("ftl_preview", m_storyboard.isEmpty() ? "no" : "yes");
            if (const QVariantMap sub = std::exchange(m_pendingSubtitle, {}); !sub.isEmpty())
                setSubtitle(sub.value("url").toString(), sub.value("title").toString(), sub.value("lang").toString());
            emit started();
            break;
        case MPV_EVENT_END_FILE: {
            auto *e = static_cast<mpv_event_end_file *>(ev->data);
            if (e->reason == MPV_END_FILE_REASON_ERROR)
                emit failed(QString::fromUtf8(mpv_error_string(e->error)));
            break;
        }
        case MPV_EVENT_CLIENT_MESSAGE: {
            auto *m = static_cast<mpv_event_client_message *>(ev->data);
            if (m->num_args == 2 && qstrcmp(m->args[0], "ftl-menu") == 0) {
                // where the button was clicked (mpv's pointer position, in device pixels)
                double x = 0, y = 0;
                mpv_node pos;
                if (mpv_get_property(m_mpv, "mouse-pos", MPV_FORMAT_NODE, &pos) >= 0) {
                    if (pos.format == MPV_FORMAT_NODE_MAP)
                        for (int i = 0; i < pos.u.list->num; ++i) {
                            const mpv_node &v = pos.u.list->values[i];
                            const double d = v.format == MPV_FORMAT_INT64 ? double(v.u.int64) : v.format == MPV_FORMAT_DOUBLE ? v.u.double_ : 0;
                            if (qstrcmp(pos.u.list->keys[i], "x") == 0) x = d;
                            else if (qstrcmp(pos.u.list->keys[i], "y") == 0) y = d;
                        }
                    mpv_free_node_contents(&pos);
                }
                const qreal dpr = m_video ? m_video->devicePixelRatio() : 1;
                // top of the whole control bar (title line included): the controller publishes the share of
                // the video it covers at the bottom
                double barTop = y / dpr;
                mpv_node margins;
                if (mpv_get_property(m_mpv, "user-data/osc/margins", MPV_FORMAT_NODE, &margins) >= 0) {
                    if (margins.format == MPV_FORMAT_NODE_MAP)
                        for (int i = 0; i < margins.u.list->num; ++i)
                            if (qstrcmp(margins.u.list->keys[i], "b") == 0
                                && margins.u.list->values[i].format == MPV_FORMAT_DOUBLE)
                                barTop = qMin(barTop, height() * (1 - margins.u.list->values[i].u.double_));
                    mpv_free_node_contents(&margins);
                }
                emit menuRequested(QString::fromUtf8(m->args[1]), x / dpr, y / dpr, barTop);
            }
            else if (m->num_args == 2 && qstrcmp(m->args[0], "ftl-playlist") == 0)
                emit playlistRequested(QString::fromUtf8(m->args[1]));
            else if (m->num_args == 2 && qstrcmp(m->args[0], "ftl-speed") == 0)
                emit speedStepRequested(QByteArray(m->args[1]).toInt());
            else if (m->num_args == 2 && qstrcmp(m->args[0], "ftl-scroll") == 0)
                emit wheelScroll(QByteArray(m->args[1]).toInt());
            else if (m->num_args == 2 && qstrcmp(m->args[0], "ftl-timetotal") == 0) {
                // the right timecode was clicked: total time (yes) or time left (no)
                const bool total = qstrcmp(m->args[1], "yes") == 0;
                if (total != m_timeTotal) {
                    m_timeTotal = total;
                    emit timeTotalChanged();
                }
            }
            break;
        }
        case MPV_EVENT_SHUTDOWN:
            QTimer::singleShot(0, this, &MpvItem::release);
            return;
        default:
            break;
        }
    }
}

void MpvItem::syncChildWindow()
{
    if (!m_video)
        return;
    const QPointF topLeft = mapToScene(QPointF(0, 0));
    const QRect r(topLeft.toPoint(), QSize(qCeil(width()), qCeil(height())));
#ifdef Q_OS_WIN
    // In real pixels, from the item's edges: Qt's whole logical numbers made the video 2561 px wide in fullscreen
    // at 150 % (and mpv scaled it by 1.0004).
    const qreal dpr = m_video->devicePixelRatio();
    // Qt's window itself is whole logical pixels too (1707 = 2560.5 real), so in fullscreen an edge that rounds
    // to one pixel past its client area is taken back (only then: in the page, a video reaching past the bottom
    // while it scrolls would change size on the way).
    RECT client = {};
    GetClientRect(reinterpret_cast<HWND>(window()->winId()), &client);
    const auto edge = [this](int e, int limit) { return m_fullscreen && e == limit + 1 ? limit : e; };
    const QRect px(QPoint(qRound(topLeft.x() * dpr), qRound(topLeft.y() * dpr)),
                   QPoint(edge(qRound((topLeft.x() + width()) * dpr), int(client.right)) - 1,
                          edge(qRound((topLeft.y() + height()) * dpr), int(client.bottom)) - 1));
    const QSize size = px.size(), current = m_videoPx.size();
#else
    const QSize size = r.size(), current = m_video->geometry().size();
#endif
    // Fullscreen coming or going takes the layout through 3-5 sizes in ~0.15 s (the sidebar, the window's own
    // steps, width and height one after the other); mpv drew every one and dropped ~5 frames of a 60 fps video
    // per switch. Then the video keeps its size until the layout has stopped changing for 50 ms.
    if (size != current && m_video->isVisible() && !m_settled && m_settling.isValid() && m_settling.elapsed() < 400) {
        if (size != m_settleSize || !m_settle.isActive()) {   // (the wait restarts only for a new size)
            m_settleSize = size;
            m_settle.start();
        }
        return;
    }
#ifdef Q_OS_WIN
    // Straight to Windows: Qt's move / resize repaints at once, which waits for mpv's own thread (it owns the
    // window inside); while the page scrolls the window moves every frame, and that made scrolling uneven.
    // Windows' compositor shows a moved video without the repaint.
    if (px != m_videoPx) {
        const bool move = size == current && m_video->isVisible();
        SetWindowPos(reinterpret_cast<HWND>(m_video->winId()), nullptr, px.x(), px.y(), px.width(), px.height(),
                     SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSENDCHANGING | (move ? SWP_NOSIZE | SWP_NOREDRAW | SWP_DEFERERASE : 0));
        m_videoPx = px;
    }
#else
    if (m_video->geometry() != r)
        m_video->setGeometry(r);
#endif
    // A native window draws over everything in the Qt window, so it is cut to what clipping parents (the
    // player's scrolling page) leave visible, and hidden while scrolled out of sight.
    QRectF visible = mapRectToScene(boundingRect());
    for (QQuickItem *p = parentItem(); p; p = p->parentItem())
        if (p->clip())
            visible &= p->mapRectToScene(p->boundingRect());
    const QRect full(QPoint(), r.size());
    const QRect shown = visible.toAlignedRect().translated(-r.topLeft()) & full;
    const bool show = isVisible() && !shown.isEmpty();
    if (m_video->isVisible() != show)
        m_video->setVisible(show);
    const QRegion mask = shown == full ? QRegion() : QRegion(shown);
    if (mask != m_videoMask) {
        m_videoMask = mask;
#ifdef Q_OS_WIN
        // Like the move: without an immediate repaint (Qt's setMask repaints).
        const qreal dpr = m_video->devicePixelRatio();
        const QRect px(qFloor(shown.x() * dpr), qFloor(shown.y() * dpr), qCeil(shown.width() * dpr), qCeil(shown.height() * dpr));
        SetWindowRgn(reinterpret_cast<HWND>(m_video->winId()),
                     mask.isEmpty() ? nullptr : CreateRectRgn(px.left(), px.top(), px.left() + px.width(), px.top() + px.height()), FALSE);
#else
        m_video->setMask(mask);
#endif
    }
}

void MpvItem::itemChange(ItemChange change, const ItemChangeData &value)
{
    QQuickItem::itemChange(change, value);
    if (change == ItemVisibleHasChanged && m_video) {
        syncChildWindow();
        m_video->setVisible(value.boolValue);
    } else if (change == ItemSceneChange && value.window) {
        // Layout changes elsewhere (e.g. the header hiding in fullscreen) can move this item without
        // changing its own geometry, so re-check the position on every frame the scene produces.
        connect(value.window, &QQuickWindow::afterAnimating, this, &MpvItem::syncChildWindow);
        // Shut mpv down as soon as the window is asked to close, before Qt hides it: hiding notifies mpv's
        // video window, which belongs to mpv's thread, and mpv's shutdown in turn waits on this thread, so
        // doing it any later deadlocks (the app froze when closed with the X button).
        connect(value.window, &QQuickWindow::closing, this, &MpvItem::release);
        // Keys pressed while the app's window (not the video) has the keyboard still reach the player.
        value.window->installEventFilter(this);
    }
}

// While a video shows, keys the window gets go to mpv (its hotkeys), unless someone is typing in a text
// field; Ctrl+key in a selectable text (copying from a comment) stays with the text. The window's shortcuts
// (Esc, F5) come first: a matched shortcut takes the key before it is pressed.
static bool isTyping(QQuickItem *focus)
{
    return focus && (focus->inherits("QQuickTextInput")
                     || (focus->inherits("QQuickTextEdit") && !focus->property("readOnly").toBool()));
}

// A click outside the text field being typed in ends the typing (the focus goes to the window), so keys reach
// the player again: a click beside the video left them in the search field, also in fullscreen, where it is
// hidden. (A click on the video does the same, see MpvVideoWindow::press.)
void MpvItem::endTyping()
{
    // (the field itself lets go: the window's root item alone would hand the focus straight back to it)
    if (QQuickItem *focus = window() ? window()->activeFocusItem() : nullptr; isTyping(focus)) {
        focus->setFocus(false);
        window()->contentItem()->forceActiveFocus();
    }
}

bool MpvItem::eventFilter(QObject *watched, QEvent *event)
{
    if (event->type() == QEvent::MouseButtonPress && watched == window()) {
        QQuickItem *focus = window()->activeFocusItem();
        // (logged: whether clicks on the page reach the window at all, should its interface stop reacting again)
        const QPointF at = static_cast<QMouseEvent *>(event)->scenePosition();
        qInfo("window \"%s\": press at %.0f,%.0f, focus %s", qPrintable(window()->title()), at.x(), at.y(),
              focus ? focus->metaObject()->className() : "none");
        if (isTyping(focus) && !focus->contains(focus->mapFromScene(static_cast<QMouseEvent *>(event)->scenePosition())))
            endTyping();
        return QQuickItem::eventFilter(watched, event);
    }
    if (event->type() != QEvent::KeyPress || !m_mpv || !isVisible() || watched != window())
        return QQuickItem::eventFilter(watched, event);
    auto *e = static_cast<QKeyEvent *>(event);
    if (QQuickItem *focus = window()->activeFocusItem()) {
        if (isTyping(focus))
            return false;
        if (focus->inherits("QQuickTextEdit") && (e->modifiers() & Qt::ControlModifier))
            return false;
    }
    const QByteArray key = mpvKeyName(e->key(), e->modifiers(), e->text());
    if (key.isEmpty() || key == "q" || key == "Q")   // q would quit mpv's core (see MpvVideoWindow)
        return false;
    command({"keypress", key});
    return true;
}

void MpvItem::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    syncChildWindow();
}
