import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// All subscribed channels, alphabetically, with a filter. Clicking one opens its page.
Item {
    id: page
    signal openChannel(var channel)
    signal openChannelInNewWindow(var channel)
    signal importRequested()

    readonly property var channels: {
        const q = filter.text.trim().toLowerCase()
        return AppState.subscriptions.filter(c => !q || c.name.toLowerCase().includes(q))
            .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }))
    }

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
                Label {
                    x: filter.leftPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Filter channels"
                    color: AppState.colors.muted
                    visible: filter.text === "" && filter.preeditText === ""
                }
            }
            Label {
                text: page.channels.length === AppState.subscriptions.length
                      ? AppState.subscriptions.length + " channels"
                      : page.channels.length + " of " + AppState.subscriptions.length + " channels"
                color: AppState.colors.tertiary
                Layout.fillWidth: true
            }
        }

        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: page.channels
            readonly property int columns: Math.max(1, Math.floor(width / 260))
            cellWidth: width / columns
            cellHeight: 64
            ScrollBar.vertical: ScrollBar {}
            SmoothScroll { flickable: grid }
            delegate: ItemDelegate {
                required property var modelData
                width: grid.cellWidth
                height: grid.cellHeight
                onClicked: page.openChannel(modelData)
                TapHandler { acceptedButtons: Qt.MiddleButton; onTapped: page.openChannelInNewWindow(modelData) }
                contentItem: RowLayout {
                    spacing: 12
                    Avatar { source: modelData.thumbnail || ""; name: modelData.name; size: 40 }
                    Label {
                        text: modelData.name
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
            }
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        visible: AppState.subscriptions.length === 0
        spacing: 12
        Label { text: "No channels yet"; font.pixelSize: 20; font.bold: true; Layout.alignment: Qt.AlignHCenter }
        Button {
            text: "Import subscriptions…"
            highlighted: true
            Layout.alignment: Qt.AlignHCenter
            onClicked: page.importRequested()
        }
    }
}
