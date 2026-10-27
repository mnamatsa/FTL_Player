import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Watched videos, newest first, with their progress. Filterable; entries can be removed or all cleared.
Item {
    id: page
    signal openVideo(var video)
    signal openVideoInNewWindow(var video)
    signal openChannel(var channel)
    signal openChannelInNewWindow(var channel)

    ListModel { id: model }

    function rebuild() {
        const q = filter.text.trim().toLowerCase()
        const list = AppState.history
            .filter(h => !q || h.title.toLowerCase().includes(q) || (h.channel || "").toLowerCase().includes(q))
            .slice(0, 2000)
            .map(h => ({ videoId: h.videoId, title: h.title, channel: h.channel || "", channelId: h.channelId || "",
                         duration: h.duration || "", views: "", published: "", live: false, upcoming: false,
                         thumbnail: h.thumbnail, watchedAt: h.watchedAt }))
        model.clear()
        model.append(list)
    }

    // The list is rebuilt when entries are added, removed or reordered, not on every progress update.
    Connections {
        target: AppState
        function onHistoryChanged() { if (page.visible) page.rebuild(); else page.stale = true }
    }
    property bool stale: true
    onVisibleChanged: if (visible && stale) { stale = false; rebuild() }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            TextField {
                id: filter
                Layout.preferredWidth: 320
                selectByMouse: true
                onTextChanged: page.rebuild()
                Label {
                    x: filter.leftPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Search history"
                    color: AppState.colors.muted
                    visible: filter.text === "" && filter.preeditText === ""
                }
            }
            Label {
                text: AppState.history.length + " videos" + (AppState.settings.rememberHistory ? "" : "  •  history is turned off in Settings")
                color: AppState.colors.tertiary
                Layout.fillWidth: true
            }
            Button {
                text: "Clear history"
                enabled: AppState.history.length > 0
                onClicked: confirm.open()
            }
        }

        VideoGrid {
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: model
            historyList: true
            onOpenVideo: (video) => page.openVideo(video)
            onOpenVideoInNewWindow: (video) => page.openVideoInNewWindow(video)
            onOpenChannel: (channel) => page.openChannel(channel)
            onOpenChannelInNewWindow: (channel) => page.openChannelInNewWindow(channel)
            onRemoveFromHistory: (videoId) => AppState.removeHistory(videoId)
        }
    }

    Label {
        anchors.centerIn: parent
        visible: model.count === 0
        text: filter.text ? "Nothing in your history matches “" + filter.text + "”." : "Videos you watch will appear here."
        color: AppState.colors.secondary
        font.pixelSize: 16
    }

    Dialog {
        id: confirm
        anchors.centerIn: parent
        modal: true
        title: "Clear watch history?"
        Label { text: "All " + AppState.history.length + " entries and their saved positions will be removed." }
        standardButtons: Dialog.Yes | Dialog.Cancel
        onAccepted: AppState.clearHistory()
    }
}
