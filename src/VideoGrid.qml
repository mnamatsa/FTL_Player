import QtQuick
import QtQuick.Controls

// Grid of video cards; used for search results, subscriptions, channel pages and history.
GridView {
    id: grid

    property bool loadingMore: false
    property bool historyList: false
    property string playlistId: ""      // a saved playlist's videos (the cards offer to remove them)
    signal openVideo(var video)
    signal openVideoInNewWindow(var video)
    signal openChannel(var channel)          // {id, name}
    signal openChannelInNewWindow(var channel)
    signal removeFromHistory(string videoId)
    signal nearEnd()

    clip: true
    readonly property real uiScale: AppState.settings.gridScale || 1    // Settings > Video grid size
    readonly property int columns: Math.max(1, Math.floor(width / (300 * uiScale)))
    cellWidth: width / columns
    cellHeight: cellWidth * 9 / 16 + 96 * uiScale
    reuseItems: true            // cards scrolled away are reused for new rows instead of being rebuilt
    cacheBuffer: Math.max(0, height)
    ScrollBar.vertical: ScrollBar {}
    SmoothScroll { flickable: grid }
    // The user is at the list: the pointer is over it or a card's right-click menu is open (the pointer is on the
    // menu then). Lists that refresh in the background don't rebuild meanwhile (SubscriptionsPage.show).
    readonly property bool busy: pointer.hovered || menusOpen > 0
    property int menusOpen: 0
    HoverHandler { id: pointer }
    delegate: VideoCard {
        width: grid.cellWidth
        height: grid.cellHeight
        inHistory: grid.historyList
        inPlaylist: grid.playlistId
        uiScale: grid.uiScale
        // Cards are reused: if the list was rebuilt between press and release, this card shows another video
        // by now, and the click doesn't count.
        property string pressedOn: ""
        onPressed: pressedOn = videoId
        onClicked: if (pressedOn === videoId) grid.openVideo(toVideo())
        onOpenInNewWindow: grid.openVideoInNewWindow(toVideo())
        onOpenChannel: grid.openChannel({ id: channelId, name: channel })
        onOpenChannelInNewWindow: grid.openChannelInNewWindow({ id: channelId, name: channel })
        onRemoveFromHistory: grid.removeFromHistory(videoId)
        onMenuShown: (open) => grid.menusOpen = Math.max(0, grid.menusOpen + (open ? 1 : -1))
    }
    WheelHandler {
        acceptedModifiers: Qt.ControlModifier
        onWheel: (event) => AppState.stepGridScale(event.angleDelta.y)
    }
    onContentYChanged: if (count > 0 && contentHeight - contentY - height < cellHeight * 2) nearEnd()
    footer: Item {
        width: grid.width
        height: grid.loadingMore ? 56 : 0
        BusyIndicator { anchors.centerIn: parent; running: grid.loadingMore; visible: running }
    }
}
