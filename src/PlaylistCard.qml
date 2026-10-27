import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

// One playlist (channel Playlists tab): cover picture with the video count, and the title.
// Clicking plays it; middle click or the context menu opens it in a new window.
ItemDelegate {
    id: card
    padding: 6
    hoverEnabled: true

    required property string playlistId
    required property string title
    required property string count
    required property string thumbnail
    property real uiScale: 1
    property string subtitle: "Play all"
    // (saved playlists: a click opens the list, "Play" is in the menu)
    property bool openOnClick: false

    signal play()
    signal playInNewWindow()
    signal openList()

    background: Rectangle {
        radius: 8
        color: card.hovered ? AppState.colors.card : "transparent"
    }
    onClicked: openOnClick ? card.openList() : card.play()
    TapHandler { acceptedButtons: Qt.MiddleButton; onTapped: card.playInNewWindow() }
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: (point) => {
            const m = menuComponent.createObject(card)
            m.closed.connect(() => m.destroy())
            m.popup(point.position.x, point.position.y)   // where the card was clicked
        }
    }
    Component {
        id: menuComponent
        Menu {
            MenuItem { text: "Open"; visible: card.openOnClick; height: visible ? implicitHeight : 0; onTriggered: card.openList() }
            MenuItem { text: "Play"; onTriggered: card.play() }
            MenuItem { text: "Play in new window"; onTriggered: card.playInNewWindow() }
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
            }
            // Video count, on a dark strip along the right edge like YouTube's playlist covers
            Rectangle {
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                width: parent.width * 0.38
                color: "#cc000000"
                Column {
                    anchors.centerIn: parent
                    spacing: 2
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: "☰"; font.pixelSize: 20; color: "white" }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: card.count
                        font.pixelSize: 12
                        font.bold: true
                        color: "white"
                    }
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
            text: card.subtitle
            color: AppState.colors.secondary
            font.pixelSize: Math.round(12 * card.uiScale)
        }
    }
}
