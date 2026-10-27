import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The videos of the playlist a PlayerView is playing, the current one highlighted. Used in the panel beside
// the player and in the fullscreen overlay. Loads more of long playlists while scrolling.
ListView {
    id: list
    required property var view          // the PlayerView
    signal chosen(int index)

    clip: true
    model: view.playlistItems
    spacing: 2
    ScrollBar.vertical: ScrollBar {}
    SmoothScroll { flickable: list }
    onContentYChanged: if (count > 0 && contentHeight - contentY - height < 300) view.loadMorePlaylist()
    Component.onCompleted: if (view.playlistIndex >= 0) positionViewAtIndex(view.playlistIndex, ListView.Contain)
    Connections {
        target: list.view
        function onPlaylistIndexChanged() {
            if (list.view.playlistIndex >= 0) list.positionViewAtIndex(list.view.playlistIndex, ListView.Contain)
        }
    }
    footer: Item {
        width: list.width
        height: list.view.playlistLoading ? 48 : 0
        BusyIndicator { anchors.centerIn: parent; running: list.view.playlistLoading; visible: running }
    }
    delegate: ItemDelegate {
        id: row
        required property int index
        required property string title
        required property string channel
        required property string duration
        required property string thumbnail
        width: list.width
        height: 76
        padding: 4
        highlighted: index === list.view.playlistIndex
        onClicked: { list.view.playIndex(index); list.chosen(index) }
        background: Rectangle {
            radius: 6
            color: row.highlighted ? AppState.colors.selected : row.hovered ? AppState.colors.hover : "transparent"
        }
        contentItem: RowLayout {
            spacing: 8
            Label {
                text: row.highlighted ? "▶" : row.index + 1
                color: row.highlighted ? "#f04242" : AppState.colors.muted
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: 22
            }
            Rectangle {
                Layout.preferredWidth: 112
                Layout.preferredHeight: 63
                radius: 4
                color: AppState.colors.placeholder
                clip: true
                Image {
                    anchors.fill: parent
                    source: row.thumbnail
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 160
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 3
                    visible: row.duration !== ""
                    color: "#cc000000"
                    radius: 3
                    width: dur.implicitWidth + 6
                    height: dur.implicitHeight + 2
                    Label { id: dur; anchors.centerIn: parent; text: row.duration; font.pixelSize: 10; color: "white" }
                }
            }
            ColumnLayout {
                spacing: 2
                Layout.fillWidth: true
                Label {
                    text: row.title
                    font.pixelSize: 13
                    font.bold: row.highlighted
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Label {
                    text: row.channel
                    color: AppState.colors.tertiary
                    font.pixelSize: 11
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }
    }
}
