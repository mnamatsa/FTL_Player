import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// "Save to playlist": the saved playlists, ticked where the video is in one (a click adds or removes it), and a
// new playlist by name (the video goes into it). A window of its own, so the video's native window can't cover it.
Popup {
    id: pop
    property var video: null            // {videoId, title, channel, ...}

    popupType: Popup.Window
    modal: true
    anchors.centerIn: parent
    width: 380
    padding: 16
    background: Rectangle { color: AppState.colors.popup; radius: 10; border.color: AppState.colors.popupBorder }
    onOpened: newName.clear()

    function create() {
        if (!newName.text.trim() || !video) return
        AppState.addToPlaylist(AppState.createPlaylist(newName.text), video)
        newName.clear()
    }

    contentItem: ColumnLayout {
        spacing: 6
        Label { text: "Save to playlist"; font.bold: true; font.pixelSize: 16 }
        Label {
            text: pop.video ? pop.video.title || "" : ""
            color: AppState.colors.secondary
            font.pixelSize: 12
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.bottomMargin: 4
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(list.implicitHeight, 320)
            clip: true
            ColumnLayout {
                id: list
                width: parent.width
                spacing: 0
                Repeater {
                    model: AppState.playlistsRevision >= 0 ? AppState.playlists : []
                    delegate: CheckBox {
                        required property var modelData
                        text: modelData.name + "  (" + modelData.videos.length + ")"
                        checked: !!pop.video && AppState.playlistsRevision >= 0 && AppState.inPlaylist(modelData.id, pop.video.videoId)
                        font.pixelSize: 14
                        implicitHeight: 36
                        topPadding: 2
                        bottomPadding: 2
                        onToggled: checked ? AppState.addToPlaylist(modelData.id, pop.video)
                                           : AppState.removeFromPlaylist(modelData.id, pop.video.videoId)
                    }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 6
            spacing: 8
            TextField {
                id: newName
                placeholderText: "New playlist"
                selectByMouse: true
                font.pixelSize: 14
                implicitHeight: 40
                Layout.fillWidth: true
                onAccepted: pop.create()
            }
            Button {
                text: "Create"
                enabled: newName.text.trim() !== ""
                onClicked: pop.create()
            }
        }
        Button {
            text: "Done"
            highlighted: true
            Layout.alignment: Qt.AlignRight
            Layout.topMargin: 4
            onClicked: pop.close()
        }
    }
}
