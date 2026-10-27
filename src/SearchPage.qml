import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Search results with YouTube's filters (type, upload date, duration, order, features), as videos, channels or
// playlists. The filters stay for the next searches; changing one searches again.
Item {
    id: page

    signal openVideo(var video)
    signal openVideoInNewWindow(var video)
    signal openChannel(var channel)                 // {id, name}
    signal openChannelInNewWindow(var channel)
    signal openPlaylist(var playlist)               // {playlistId, title, channel}
    signal openPlaylistInNewWindow(var playlist)

    property string query: ""
    property string status: ""
    property bool searching: false
    property bool more: false
    property bool loadingMore: false
    property string kind: "video"                   // of the results shown: video | channel | playlist
    property var filters: ({ type: "video", upload_date: "all", duration: "all", prioritize: "relevance", features: [] })
    property int generation: 0                      // replies to an older search are dropped

    ListModel { id: videos }
    ListModel { id: channels }
    ListModel { id: playlists }
    readonly property int count: kind === "channel" ? channels.count : kind === "playlist" ? playlists.count : videos.count

    function modelFor(k) { return k === "channel" ? channels : k === "playlist" ? playlists : videos }

    function run(q) {
        q = q.trim()
        if (!q) return
        query = q
        const gen = ++generation
        searching = true
        status = ""
        more = false
        videos.clear(); channels.clear(); playlists.clear()
        kind = filters.type
        Helper.call("search", { query: q, filters: filters }, function (r) {
            if (gen !== generation) return
            searching = false
            if (!r.ok) { status = "Search failed: " + r.error; return }
            kind = r.kind || "video"
            modelFor(kind).append(r.results)
            more = r.more
            if (r.results.length === 0) status = "No results for “" + q + "”" + (filtered ? " with these filters." : ".")
        })
    }
    function loadMore() {
        if (!more || loadingMore || searching) return
        const gen = generation
        loadingMore = true
        Helper.call("searchMore", {}, function (r) {
            if (gen !== generation) return
            loadingMore = false
            if (!r.ok) { more = false; return }
            modelFor(r.kind || kind).append(r.results)
            more = r.more
        })
    }
    function setFilter(key, value) {
        filters = Object.assign({}, filters, { [key]: value })
        if (query) run(query)
    }
    function toggleFeature(f) {
        const list = filters.features.indexOf(f) >= 0 ? filters.features.filter(x => x !== f) : filters.features.concat([f])
        setFilter("features", list)
    }
    readonly property bool filtered: filters.type !== "video" || filters.upload_date !== "all" || filters.duration !== "all"
                                     || filters.prioritize !== "relevance" || filters.features.length > 0

    // A compact filter drop-down: [label, value] entries bound to one filter.
    component FilterCombo: ComboBox {
        property string key
        property var options: []
        model: options.map(o => o[0])
        currentIndex: Math.max(0, options.findIndex(o => o[1] === page.filters[key]))
        onActivated: (index) => page.setFilter(key, options[index][1])
        implicitContentWidthPolicy: ComboBox.WidestText
        font.pixelSize: 13
        implicitHeight: 36
        topInset: 0
        bottomInset: 0
        Material.containerStyle: Material.Filled
    }
    // A feature that can be asked for (4K, live ...): a rounded chip, filled while it is on.
    component FeatureChip: Button {
        id: chip
        property string feature
        readonly property bool on: page.filters.features.indexOf(feature) >= 0
        font.pixelSize: 12
        leftPadding: 12
        rightPadding: 12
        topPadding: 5
        bottomPadding: 5
        topInset: 0
        bottomInset: 0
        implicitHeight: 28
        onClicked: page.toggleFeature(feature)
        background: Rectangle {
            radius: height / 2
            color: chip.on ? AppState.colors.chipOn : chip.hovered ? AppState.colors.hover : "transparent"
            border.color: chip.on ? "#f04242" : AppState.colors.border
        }
        contentItem: Label { text: chip.text; font: chip.font; color: AppState.colors.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Flow {
            Layout.fillWidth: true
            spacing: 8
            FilterCombo {
                key: "type"
                options: [["Videos", "video"], ["Channels", "channel"], ["Playlists", "playlist"]]
            }
            FilterCombo {
                key: "upload_date"
                options: [["Any time", "all"], ["Today", "today"], ["This week", "week"], ["This month", "month"], ["This year", "year"]]
                visible: page.filters.type === "video"
            }
            FilterCombo {
                key: "duration"
                options: [["Any length", "all"], ["Under 3 minutes", "under_three_mins"], ["3 - 20 minutes", "three_to_twenty_mins"],
                          ["Over 20 minutes", "over_twenty_mins"]]
                visible: page.filters.type === "video"
            }
            FilterCombo {
                key: "prioritize"
                options: [["Relevance", "relevance"], ["Popularity", "popularity"]]
            }
            Item { width: 4; height: 36 }
            Repeater {
                model: page.filters.type === "video" ? [["Live", "live"], ["4K", "4k"], ["HD", "hd"], ["Subtitles", "subtitles"],
                                                        ["HDR", "hdr"], ["360°", "360"], ["Creative Commons", "creative_commons"]] : []
                delegate: FeatureChip {
                    required property var modelData
                    text: modelData[0]
                    feature: modelData[1]
                }
            }
            Button {
                visible: page.filtered
                text: "Clear filters"
                flat: true
                font.pixelSize: 13
                implicitHeight: 36
                topInset: 0
                bottomInset: 0
                onClicked: {
                    page.filters = { type: "video", upload_date: "all", duration: "all", prioritize: "relevance", features: [] }
                    if (page.query) page.run(page.query)
                }
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: page.kind === "channel" ? 1 : page.kind === "playlist" ? 2 : 0

            VideoGrid {
                model: videos
                loadingMore: page.loadingMore
                onOpenVideo: (video) => page.openVideo(video)
                onOpenVideoInNewWindow: (video) => page.openVideoInNewWindow(video)
                onOpenChannel: (channel) => page.openChannel(channel)
                onOpenChannelInNewWindow: (channel) => page.openChannelInNewWindow(channel)
                onNearEnd: page.loadMore()
            }

            // Channels: avatar, name, handle and subscribers, and Subscribe; a click opens the channel.
            ListView {
                id: channelList
                model: channels
                clip: true
                spacing: 2
                ScrollBar.vertical: ScrollBar {}
                SmoothScroll { flickable: channelList }
                onContentYChanged: if (count > 0 && contentHeight - contentY - height < 300) page.loadMore()
                delegate: ItemDelegate {
                    id: channelRow
                    required property var model
                    readonly property string channelId: model.id
                    required property string name
                    required property string thumbnail
                    required property string handle
                    required property string subscribers
                    width: channelList.width
                    implicitHeight: 84
                    onClicked: page.openChannel({ id: channelId, name: name })
                    TapHandler { acceptedButtons: Qt.MiddleButton; onTapped: page.openChannelInNewWindow({ id: channelRow.channelId, name: channelRow.name }) }
                    contentItem: RowLayout {
                        spacing: 16
                        Avatar { source: channelRow.thumbnail; name: channelRow.name; size: 64 }
                        ColumnLayout {
                            spacing: 2
                            Layout.fillWidth: true
                            Label { text: channelRow.name; font.pixelSize: 16; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                            Label {
                                text: [channelRow.handle, channelRow.subscribers].filter(s => s).join("  •  ")
                                color: AppState.colors.secondary
                                font.pixelSize: 13
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                        Button {
                            readonly property bool subscribed: AppState.isSubscribed(channelRow.channelId)
                            text: subscribed ? "Subscribed" : "Subscribe"
                            highlighted: !subscribed
                            flat: subscribed
                            onClicked: AppState.setSubscribed({ id: channelRow.channelId, name: channelRow.name, thumbnail: channelRow.thumbnail }, !subscribed)
                        }
                    }
                }
            }

            // Playlists, as on a channel's Playlists tab.
            GridView {
                id: playlistGrid
                model: playlists
                clip: true
                readonly property real uiScale: AppState.settings.gridScale || 1
                readonly property int columns: Math.max(1, Math.floor(width / (300 * uiScale)))
                cellWidth: width / columns
                cellHeight: cellWidth * 9 / 16 + 76 * uiScale
                reuseItems: true
                ScrollBar.vertical: ScrollBar {}
                SmoothScroll { flickable: playlistGrid }
                onContentYChanged: if (count > 0 && contentHeight - contentY - height < cellHeight * 2) page.loadMore()
                delegate: PlaylistCard {
                    required property string channel
                    width: playlistGrid.cellWidth
                    height: playlistGrid.cellHeight
                    uiScale: playlistGrid.uiScale
                    onPlay: page.openPlaylist({ playlistId: playlistId, title: title, channel: channel })
                    onPlayInNewWindow: page.openPlaylistInNewWindow({ playlistId: playlistId, title: title, channel: channel })
                }
            }
        }
    }

    BusyIndicator {
        anchors.centerIn: parent
        running: page.searching
        visible: running
    }
    Label {
        anchors.centerIn: parent
        visible: !page.searching && page.count === 0
        text: page.status || "Search for a video to get started."
        color: AppState.colors.secondary
        font.pixelSize: 16
        wrapMode: Text.Wrap
        width: Math.min(parent.width - 48, 640)
        horizontalAlignment: Text.AlignHCenter
    }
}
