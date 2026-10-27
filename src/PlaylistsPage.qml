import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The saved playlists (AppState.playlists, "Watch later" first): all of them as cards, or one opened with its
// videos (Play all, rename, delete; a card's menu removes a video). They play like YouTube playlists, from the
// saved list ({localId}, PlayerView.openPlaylist).
Item {
    id: page

    signal playPlaylist(var info, int index)        // info: {localId, title}
    signal playPlaylistInNewWindow(var info)
    signal openChannel(var channel)
    signal openChannelInNewWindow(var channel)
    signal openVideoInNewWindow(var video)

    property string openId: ""                      // the playlist shown; "" = all of them
    readonly property var opened: AppState.playlistsRevision >= 0 && openId ? AppState.playlistById(openId) : null
    onOpenedChanged: if (openId && !opened) openId = ""   // deleted

    ListModel { id: cards }
    ListModel { id: videos }
    function countText(n) { return n + (n === 1 ? " video" : " videos") }
    function rebuild() {
        cards.clear()
        for (const p of AppState.playlists)
            cards.append({ playlistId: p.id, title: p.name, count: countText(p.videos.length),
                           thumbnail: p.videos.length ? p.videos[p.videos.length - 1].thumbnail : "" })
        videos.clear()
        const p = openId ? AppState.playlistById(openId) : null
        if (p) videos.append(p.videos.map(v => AppState.playlistEntry(v)))
    }
    Connections { target: AppState; function onPlaylistsRevisionChanged() { page.rebuild() } }
    onOpenIdChanged: rebuild()
    Component.onCompleted: rebuild()
    function info() { return { localId: openId, title: opened ? opened.name : "" } }

    // all playlists
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8
        visible: page.openId === ""

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Label { text: "Playlists"; font.pixelSize: 20; font.bold: true; Layout.fillWidth: true }
            TextField {
                id: newName
                placeholderText: "New playlist"
                selectByMouse: true
                implicitHeight: 40
                Layout.preferredWidth: 260
                onAccepted: create.clicked()
            }
            Button {
                id: create
                text: "Create"
                enabled: newName.text.trim() !== ""
                onClicked: { AppState.createPlaylist(newName.text); newName.clear() }
            }
        }
        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: cards
            clip: true
            readonly property real uiScale: AppState.settings.gridScale || 1
            readonly property int columns: Math.max(1, Math.floor(width / (300 * uiScale)))
            cellWidth: width / columns
            cellHeight: cellWidth * 9 / 16 + 76 * uiScale
            ScrollBar.vertical: ScrollBar {}
            SmoothScroll { flickable: grid }
            delegate: PlaylistCard {
                width: grid.cellWidth
                height: grid.cellHeight
                uiScale: grid.uiScale
                openOnClick: true
                subtitle: "View playlist"
                onOpenList: page.openId = playlistId
                onPlay: { const p = AppState.playlistById(playlistId); if (p && p.videos.length) page.playPlaylist({ localId: playlistId, title: title }, 0) }
                onPlayInNewWindow: { const p = AppState.playlistById(playlistId); if (p && p.videos.length) page.playPlaylistInNewWindow({ localId: playlistId, title: title }) }
            }
        }
    }

    // one playlist
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8
        visible: page.openId !== ""

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            ToolButton { text: "←"; font.pixelSize: 18; onClicked: page.openId = ""; ToolTip.visible: hovered; ToolTip.text: "All playlists" }
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                Label {
                    visible: !renaming.visible
                    text: page.opened ? page.opened.name : ""
                    font.pixelSize: 20
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                TextField {
                    id: renaming
                    visible: false
                    selectByMouse: true
                    font.pixelSize: 16
                    Layout.fillWidth: true
                    onAccepted: { AppState.renamePlaylist(page.openId, text); visible = false }
                    Keys.onEscapePressed: visible = false
                }
                Label {
                    text: page.opened ? page.countText(page.opened.videos.length) : ""
                    color: AppState.colors.secondary
                    font.pixelSize: 13
                }
            }
            Button {
                text: "Play all"
                highlighted: true
                enabled: videos.count > 0
                onClicked: page.playPlaylist(page.info(), 0)
            }
            Button {
                text: renaming.visible ? "Save name" : "Rename"
                flat: true
                onClicked: {
                    if (renaming.visible) { AppState.renamePlaylist(page.openId, renaming.text); renaming.visible = false; return }
                    renaming.text = page.opened ? page.opened.name : ""
                    renaming.visible = true
                    renaming.forceActiveFocus()
                    renaming.selectAll()
                }
            }
            Button {
                text: "Delete"
                flat: true
                visible: page.openId !== "watchlater"
                onClicked: deleteConfirm.open()
            }
        }
        VideoGrid {
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: videos
            playlistId: page.openId
            onOpenVideo: (video) => {
                let i = 0
                for (; i < videos.count && videos.get(i).videoId !== video.videoId; i++) {}
                page.playPlaylist(page.info(), Math.min(i, videos.count - 1))
            }
            onOpenVideoInNewWindow: (video) => page.openVideoInNewWindow(video)
            onOpenChannel: (channel) => page.openChannel(channel)
            onOpenChannelInNewWindow: (channel) => page.openChannelInNewWindow(channel)
        }
        Label {
            visible: videos.count === 0
            text: page.openId === "watchlater" ? "Nothing to watch later yet: \"Save to Watch later\" is in a video's right-click menu."
                                               : "This playlist is empty: \"Save to playlist\" is in a video's right-click menu and under the player."
            color: AppState.colors.secondary
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
        }
    }

    Popup {
        id: deleteConfirm
        popupType: Popup.Window
        modal: true
        anchors.centerIn: parent
        padding: 16
        background: Rectangle { color: AppState.colors.popup; radius: 10; border.color: AppState.colors.popupBorder }
        contentItem: ColumnLayout {
            spacing: 12
            Label { text: "Delete \"" + (page.opened ? page.opened.name : "") + "\"?"; font.bold: true; font.pixelSize: 15 }
            Label { text: "Its videos stay on YouTube; only this list goes."; color: AppState.colors.secondary }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                Button { text: "Cancel"; flat: true; onClicked: deleteConfirm.close() }
                Button { text: "Delete"; highlighted: true; onClicked: { AppState.deletePlaylist(page.openId); page.openId = ""; deleteConfirm.close() } }
            }
        }
    }
}
