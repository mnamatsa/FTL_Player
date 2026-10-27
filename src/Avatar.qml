import QtQuick
import QtQuick.Controls
import QtQuick.Effects

// Round channel picture, or the channel's initial when there is no picture (yet).
Item {
    id: avatar
    property string source
    property string name
    property int size: 40
    width: size
    height: size

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Qt.hsla(((avatar.name.charCodeAt(0) || 0) * 37 % 360) / 360, 0.45, 0.4, 1)
        visible: image.status !== Image.Ready
        Label {
            anchors.centerIn: parent
            text: avatar.name ? avatar.name.charAt(0).toUpperCase() : "?"
            font.pixelSize: avatar.size * 0.45
            font.bold: true
            color: "white"
        }
    }
    Image {
        id: image
        anchors.fill: parent
        source: avatar.source
        asynchronous: true
        sourceSize: Qt.size(avatar.size * 2, avatar.size * 2)
        fillMode: Image.PreserveAspectCrop
        visible: false
    }
    Rectangle {
        id: mask
        anchors.fill: parent
        radius: width / 2
        layer.enabled: true
        visible: false
    }
    MultiEffect {
        anchors.fill: parent
        source: image
        maskEnabled: true
        maskSource: mask
        visible: image.status === Image.Ready
    }
}
