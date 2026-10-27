import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

// One video: thumbnail with duration / LIVE / UPCOMING badge and watch progress, title, channel and stats.
// Left click opens it, middle click or the context menu opens it in a new window (the channel name opens the
// channel; middle click on it opens the channel in a new window).
ItemDelegate {
    id: card
    padding: 6
    hoverEnabled: true

    required property string videoId
    required property string title
    required property string channel
    required property string channelId
    required property string duration
    required property string views
    required property string published
    required property bool live
    required property bool upcoming
    required property string thumbnail
    required property var model         // for roles only some lists have
    readonly property double publishedAt: model.publishedAt || 0
    readonly property double watchedAt: model.watchedAt || 0
    readonly property double startAt: model.startAt || 0      // scheduled start of an upcoming video
    // RSS feed items have no duration; the subscriptions page looks those up in the background.
    readonly property string shownDuration: duration || (AppState.durationsRevision >= 0 ? AppState.durations[videoId] || "" : "")
    property bool inHistory: false      // shows "Remove from history" in the menu
    property string inPlaylist: ""      // shown on a saved playlist's page: "Remove from this playlist"
    property real uiScale: 1            // text size, with the grid's card size

    // Preview (Settings > Layout > "Preview on video cards"): the pointer along the bar at the bottom of the
    // thumbnail shows the video at that point, a picture of its storyboard (helper cardStoryboard, asked the
    // first time), with the time.
    readonly property real durationSeconds: shownDuration.split(":").reduce((s, p) => s * 60 + (Number(p) || 0), 0)
    readonly property bool previewable: AppState.settings.cardPreview !== false && !live && !upcoming && durationSeconds > 0
    readonly property real testScrub: WindowTools.testCardScrub()     // (tests: see there)
    readonly property bool scrubbing: previewable && (scrubHover.hovered || testScrub > 0)
    readonly property real scrubFraction: !scrubbing ? 0 : scrubHover.hovered
                                          ? Math.max(0, Math.min(1, scrubHover.point.position.x / scrubArea.width)) : testScrub
    property var board: null            // {template, width, height, count, interval (ms), columns, rows}
    property bool boardAsked: false
    // (cards are reused for other videos, also while the pointer is on one: the list refreshed)
    onVideoIdChanged: { board = null; boardAsked = false; askBoard() }
    onScrubbingChanged: askBoard()
    function askBoard() {
        if (!scrubbing || boardAsked) return
        boardAsked = true
        const id = videoId
        Helper.call("cardStoryboard", { videoId: id }, function (r) { if (r.ok && id === card.videoId) card.board = r.board })
    }
    readonly property int frameIndex: board && scrubbing
                                      ? Math.min(board.count - 1, Math.floor(scrubFraction * durationSeconds * 1000 / board.interval)) : -1
    function timeText(s) {
        s = Math.floor(s)
        const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = s % 60
        return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(sec).padStart(2, "0")
    }

    signal openInNewWindow()
    signal openChannel()
    signal openChannelInNewWindow()
    signal removeFromHistory()
    signal menuShown(bool open)         // the right-click menu opened / closed (the grid holds rebuilds meanwhile)
    property bool menuOpen: false
    // (a card that goes away with its menu open still reports it closed, or the grid would wait for good)
    Component.onDestruction: if (menuOpen) menuShown(false)

    function toVideo() {
        return { videoId: videoId, title: title, channel: channel, channelId: channelId, duration: shownDuration,
                 views: views, published: published, live: live, upcoming: upcoming, thumbnail: thumbnail,
                 publishedAt: publishedAt }
    }

    // "Starts in 13 hours", or the date when it is further off
    function starts(t) {
        const s = (t - Date.now()) / 1000
        if (s < 60) return "Starting soon"
        if (s > 2 * 86400) return "Starts " + Qt.formatDateTime(new Date(t), "ddd d MMM, HH:mm")
        const [n, name] = s >= 3600 ? [Math.round(s / 3600), "hour"] : [Math.round(s / 60), "minute"]
        return "Starts in " + n + " " + name + (n > 1 ? "s" : "")
    }

    function ago(t) {
        // years and months by the calendar, as PlayerView.ago
        const now = new Date(), then = new Date(t)
        let months = (now.getFullYear() - then.getFullYear()) * 12 + now.getMonth() - then.getMonth()
        if (now.getDate() < then.getDate()) months--
        if (months >= 12) { const v = Math.floor(months / 12); return v + " year" + (v > 1 ? "s" : "") + " ago" }
        if (months >= 1) return months + " month" + (months > 1 ? "s" : "") + " ago"
        const s = Math.max(0, (Date.now() - t) / 1000)
        const units = [[604800, "week"], [86400, "day"], [3600, "hour"], [60, "minute"]]
        for (const [n, name] of units)
            if (s >= n) { const v = Math.floor(s / n); return v + " " + name + (v > 1 ? "s" : "") + " ago" }
        return "just now"
    }

    readonly property var watched: AppState.historyRevision >= 0 ? AppState.historyIndex[videoId] : undefined
    readonly property real progress: watched && watched.length > 0 ? Math.min(1, watched.position / watched.length) : 0

    background: Rectangle {
        radius: 8
        color: card.hovered ? AppState.colors.card : "transparent"
    }

    TapHandler {
        acceptedButtons: Qt.MiddleButton
        onTapped: channelHover.hovered && card.channelId ? card.openChannelInNewWindow() : card.openInNewWindow()
    }
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: (point) => {
            const m = menuComponent.createObject(card)
            m.closed.connect(() => { card.menuOpen = false; card.menuShown(false); m.destroy() })
            card.menuOpen = true
            card.menuShown(true)
            m.popup(point.position.x, point.position.y)   // where the card was clicked
        }
    }
    // Made when needed: a menu per card slowed down creating the cards while scrolling.
    Component {
        id: menuComponent
        Menu {
        width: 270                      // fits "Open channel in new window"
        MenuItem { text: "Open in new window"; onTriggered: card.openInNewWindow() }
        MenuItem { text: "Open channel"; enabled: card.channelId !== ""; onTriggered: card.openChannel() }
        MenuItem { text: "Open channel in new window"; enabled: card.channelId !== ""; onTriggered: card.openChannelInNewWindow() }
        MenuSeparator {}
        MenuItem {
            readonly property bool saved: AppState.inPlaylist("watchlater", card.videoId)
            text: saved ? "Remove from Watch later" : "Save to Watch later"
            onTriggered: saved ? AppState.removeFromPlaylist("watchlater", card.videoId)
                               : AppState.addToPlaylist("watchlater", card.toVideo())
        }
        // the window's "Save to playlist" dialog (Main.saveToPlaylist)
        MenuItem { text: "Save to playlist…"; onTriggered: card.Window.window.saveToPlaylist(card.toVideo()) }
        MenuItem {
            text: "Remove from this playlist"
            visible: card.inPlaylist !== "" && card.inPlaylist !== "watchlater"
            height: visible ? implicitHeight : 0
            onTriggered: AppState.removeFromPlaylist(card.inPlaylist, card.videoId)
        }
        MenuItem {
            text: "Remove from history"
            visible: card.inHistory
            height: visible ? implicitHeight : 0
            onTriggered: card.removeFromHistory()
        }
        }
    }

    contentItem: Column {
        spacing: 6

        Rectangle {
            width: parent.width
            height: width * 9 / 16
            radius: 6
            color: AppState.colors.placeholder
            clip: true

            Image {
                anchors.fill: parent
                source: card.thumbnail
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 320
                opacity: card.progress > 0.9 ? 0.55 : 1
            }
            // The storyboard picture at the pointer: its sheet, moved so the picture fills the thumbnail. All the
            // video's sheets load at once (one image each, kept while the pointer is on the card), and a picture
            // whose sheet hasn't arrived yet keeps the last one shown: changing one image's source showed the
            // thumbnail for a moment at every new sheet.
            Item {
                id: preview
                anchors.fill: parent
                clip: true
                visible: card.scrubbing && shownFrame >= 0
                readonly property int columns: card.board ? card.board.columns : 1
                readonly property int perSheet: card.board ? columns * card.board.rows : 1
                readonly property int sheets: card.board ? Math.min(60, Math.ceil(card.board.count / perSheet)) : 0
                property int shownFrame: -1
                readonly property int shownSheet: Math.floor(shownFrame / perSheet)
                readonly property int inSheet: Math.max(0, shownFrame) % perSheet
                function update() {
                    if (card.frameIndex < 0) { shownFrame = -1; return }
                    const it = sheetImages.itemAt(Math.floor(card.frameIndex / perSheet))
                    if (it && it.status === Image.Ready) shownFrame = card.frameIndex
                }
                Connections { target: card; function onFrameIndexChanged() { preview.update() } }
                Repeater {
                    id: sheetImages
                    model: card.board && (card.scrubbing || card.hovered) ? preview.sheets : 0
                    Image {
                        required property int index
                        source: card.board ? card.board.template.replace("$M", index) : ""
                        asynchronous: true
                        visible: index === preview.shownSheet
                        width: preview.width * preview.columns
                        height: preview.height * (card.board ? card.board.rows : 1)
                        x: -(preview.inSheet % preview.columns) * preview.width
                        y: -Math.floor(preview.inSheet / preview.columns) * preview.height
                        onStatusChanged: preview.update()
                    }
                }
            }
            // Where the pointer previews: the lower third of the thumbnail, over the bar
            Item {
                id: scrubArea
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: parent.height / 3
                visible: card.previewable
                HoverHandler { id: scrubHover }
            }
            Rectangle {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 6
                anchors.bottomMargin: progressBar.visible ? 10 : 6
                visible: badge.text !== "" && !card.scrubbing
                color: card.live ? "#cc0000" : card.upcoming ? "#cc1565c0" : "#cc000000"
                radius: 3
                width: badge.implicitWidth + 8
                height: badge.implicitHeight + 2
                Label {
                    id: badge
                    anchors.centerIn: parent
                    text: card.live ? "LIVE" : card.upcoming ? "UPCOMING" : card.shownDuration
                    font.pixelSize: Math.round(12 * card.uiScale)
                    font.bold: true
                    color: "white"
                }
            }
            // Watch progress; also shown while the pointer is on the card when it can preview (where to point)
            Rectangle {
                id: progressBar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: card.scrubbing ? 6 : 4
                color: "#66ffffff"
                visible: card.progress > 0 || card.scrubbing || (card.hovered && card.previewable)
                Rectangle { width: parent.width * card.progress; height: parent.height; color: "#f04242" }
                Rectangle {     // the previewed point
                    visible: card.scrubbing
                    x: parent.width * card.scrubFraction - width / 2
                    width: 3
                    height: parent.height
                    color: "white"
                }
            }
            // the previewed time, above the bar at the pointer
            Rectangle {
                visible: card.scrubbing
                anchors.bottom: progressBar.top
                anchors.bottomMargin: 6
                x: Math.max(4, Math.min(parent.width - width - 4, parent.width * card.scrubFraction - width / 2))
                width: timeLabel.implicitWidth + 10
                height: timeLabel.implicitHeight + 4
                radius: 3
                color: "#cc000000"
                Label {
                    id: timeLabel
                    anchors.centerIn: parent
                    text: card.timeText(card.scrubFraction * card.durationSeconds)
                    font.pixelSize: Math.round(12 * card.uiScale)
                    font.bold: true
                    color: "white"
                }
            }
        }

        Label {
            width: parent.width
            text: card.title
            font.pixelSize: Math.round(14 * card.uiScale)
            font.bold: true
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
        Label {
            text: card.channel
            color: channelHover.hovered && card.channelId ? AppState.colors.text : AppState.colors.secondary
            font.pixelSize: Math.round(12 * card.uiScale)
            font.underline: channelHover.hovered && card.channelId !== ""
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width)
            HoverHandler { id: channelHover; cursorShape: card.channelId ? Qt.PointingHandCursor : Qt.ArrowCursor }
            TapHandler { enabled: card.channelId !== ""; onTapped: card.openChannel() }
        }
        Label {
            width: parent.width
            text: [card.views && !card.upcoming ? card.views + (card.live ? " watching" : " views") : "",
                   card.watchedAt > 0 ? "watched " + card.ago(card.watchedAt)
                       : card.upcoming && card.startAt > 0 ? card.starts(card.startAt)
                       : card.live ? "" : card.publishedAt > 0 ? card.ago(card.publishedAt) : card.published]   // one style when the date is known
                  .filter(s => s).join("  •  ")
            color: AppState.colors.muted
            font.pixelSize: Math.round(12 * card.uiScale)
            elide: Text.ElideRight
        }
    }
}
