import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// One channel: picture, name, subscribers and Subscribe, with its Videos and Live tabs (more load on scroll).
Item {
    id: page

    property var channel: null          // {id, name, thumbnail}
    property var info: null             // from the helper: {name, avatar, subscribers, videoCount, handle, description}
    property string error: ""
    signal openVideo(var video)
    signal openVideoInNewWindow(var video)
    signal openPlaylist(var playlist)            // {playlistId, title, channel, channelId}
    signal openPlaylistInNewWindow(var playlist)

    component TabState: QtObject {
        property string tab
        property string continuation: ""
        property bool loading: false
        property bool loaded: false
        property int extraPages: 0
    }
    TabState { id: videosTab; tab: "videos" }
    TabState { id: liveTab; tab: "streams" }
    TabState { id: playlistsTab; tab: "playlists" }
    ListModel { id: videosModel }
    ListModel { id: liveModel }
    ListModel { id: playlistsModel }

    function playlistOf(card) {
        return { playlistId: card.playlistId, title: card.title, channel: page.name, channelId: channel ? channel.id : "" }
    }

    function load(st, more) {
        if (!channel || st.loading || (more && !st.continuation)) return
        st.loading = true
        const id = channel.id
        const model = st === videosTab ? videosModel : st === liveTab ? liveModel : playlistsModel
        const args = more ? { continuation: st.continuation } : { channelId: id, tab: st.tab }
        Helper.call("channelPage", args, function (r) {
            if (!channel || channel.id !== id) return
            st.loading = false
            st.loaded = true
            if (!r.ok) { error = r.error; st.continuation = ""; return }
            if (r.info) {
                info = r.info
                AppState.updateChannel(r.info)
            }
            for (const it of r.items)
                it.channel = (info && info.name) || channel.name
            model.append(r.items)
            st.continuation = r.continuation || ""
            // The Live tab keeps only streams, so a page can come back nearly empty; fetch on until the
            // grid has something to scroll (at most a few extra pages).
            st.extraPages = more ? st.extraPages : 0
            if (st.continuation && model.count < 12 && st.extraPages < 5) {
                st.extraPages++
                Qt.callLater(() => page.load(st, true))
            }
        })
    }

    function reload() {          // refresh button: same tab, fetched again
        const tab = tabs.currentIndex
        reset()
        tabs.currentIndex = tab
    }
    onChannelChanged: reset()
    function reset() {
        info = null
        error = ""
        for (const st of [videosTab, liveTab, playlistsTab]) { st.continuation = ""; st.loading = false; st.loaded = false }
        videosModel.clear()
        liveModel.clear()
        playlistsModel.clear()
        tabs.currentIndex = 0
        load(videosTab, false)
    }

    readonly property string name: info && info.name ? info.name : channel ? channel.name : ""

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            spacing: 16
            Layout.fillWidth: true
            Layout.leftMargin: 6

            Avatar {
                source: page.info && page.info.avatar ? page.info.avatar : page.channel ? page.channel.thumbnail || "" : ""
                name: page.name
                size: 72
            }
            ColumnLayout {
                spacing: 2
                Layout.fillWidth: true
                Label { text: page.name; font.pixelSize: 22; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                Label {
                    text: page.info ? [page.info.handle, page.info.subscribers, page.info.videoCount].filter(s => s).join("  •  ") : ""
                    color: AppState.colors.secondary
                }
                Label {
                    text: page.info ? page.info.description : ""
                    color: AppState.colors.muted
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    Layout.fillWidth: true
                }
            }
            Button {
                readonly property bool subscribed: page.channel ? AppState.isSubscribed(page.channel.id) : false
                visible: !!page.channel
                text: subscribed ? "Subscribed" : "Subscribe"
                highlighted: !subscribed
                flat: subscribed
                onClicked: AppState.setSubscribed({ id: page.channel.id, name: page.name,
                                                    thumbnail: page.info ? page.info.avatar : "" }, !subscribed)
            }
        }

        TabBar {
            id: tabs
            TabButton { text: "Videos"; width: implicitWidth + 24 }
            TabButton { text: "Live"; width: implicitWidth + 24 }
            TabButton { text: "Playlists"; width: implicitWidth + 24 }
            onCurrentIndexChanged: {
                if (currentIndex === 1 && !liveTab.loaded) page.load(liveTab, false)
                if (currentIndex === 2 && !playlistsTab.loaded) page.load(playlistsTab, false)
            }
        }

        StackLayout {
            currentIndex: tabs.currentIndex
            Layout.fillWidth: true
            Layout.fillHeight: true

            VideoGrid {
                model: videosModel
                loadingMore: videosTab.loading
                onOpenVideo: (video) => page.openVideo(video)
                onOpenVideoInNewWindow: (video) => page.openVideoInNewWindow(video)
                onNearEnd: page.load(videosTab, true)
            }
            VideoGrid {
                model: liveModel
                loadingMore: liveTab.loading
                onOpenVideo: (video) => page.openVideo(video)
                onOpenVideoInNewWindow: (video) => page.openVideoInNewWindow(video)
                onNearEnd: page.load(liveTab, true)
            }
            GridView {
                id: playlistsGrid
                clip: true
                model: playlistsModel
                readonly property real uiScale: AppState.settings.gridScale || 1
                readonly property int columns: Math.max(1, Math.floor(width / (300 * uiScale)))
                cellWidth: width / columns
                cellHeight: cellWidth * 9 / 16 + 76 * uiScale
                reuseItems: true
                cacheBuffer: Math.max(0, height)
                ScrollBar.vertical: ScrollBar {}
                SmoothScroll { flickable: playlistsGrid }
                onContentYChanged: if (count > 0 && contentHeight - contentY - height < cellHeight * 2) page.load(playlistsTab, true)
                WheelHandler {
                    acceptedModifiers: Qt.ControlModifier
                    onWheel: (event) => AppState.stepGridScale(event.angleDelta.y)
                }
                delegate: PlaylistCard {
                    width: playlistsGrid.cellWidth
                    height: playlistsGrid.cellHeight
                    uiScale: playlistsGrid.uiScale
                    onPlay: page.openPlaylist(page.playlistOf(this))
                    onPlayInNewWindow: page.openPlaylistInNewWindow(page.playlistOf(this))
                }
                Label {
                    anchors.centerIn: parent
                    visible: playlistsTab.loaded && !playlistsTab.loading && playlistsModel.count === 0
                    text: "This channel has no public playlists."
                    color: AppState.colors.secondary
                }
            }
        }
        Label {
            visible: page.error !== ""
            text: page.error
            color: AppState.colors.error
        }
    }
}
