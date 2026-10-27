import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Window

ApplicationWindow {
    id: win
    width: 1360
    height: 820
    minimumWidth: 640
    minimumHeight: 420
    visible: true
    title: playerView.video ? playerView.video.title + " - FTL Player" : "FTL Player"

    Material.theme: AppState.dark ? Material.Dark : Material.Light
    Material.accent: "#f04242"
    Material.primary: AppState.colors.header
    color: AppState.colors.window

    property string page: "subscriptions"   // subscriptions | channels | channel | history | settings | search
    // Pages are built when first shown: a window opened for a video doesn't load the feed (that took ~0.5 s).
    property var shownPages: ({})
    function markShown() { if (!watching && !shownPages[page]) shownPages = Object.assign({ [page]: true }, shownPages) }
    onPageChanged: markShown()
    onWatchingChanged: markShown()
    property string dataMessage: ""         // result of the last import/export, shown in Settings
    property var pageStack: []               // previous pages, for the back button
    property string startSearch: ""          // --search
    property string startVideo: ""           // --play
    property string startChannel: ""         // --channel
    property string startPlaylist: ""        // --playlist
    property var startVideoInfo: null        // set when opened as a new window for a video
    property var startPlaylistInfo: null     // ... or for a playlist
    property var startChannelInfo: null      // ... or for a channel
    property bool startedInBackground: false // opened behind another window (setting openInBackground)
    property bool deferPlayer: false         // ... by newWindow (not the app's first window, also in tests)
    property string lastQuery: ""
    property url startImport                 // --import
    property url startExport                 // --export
    property string startLink: ""            // a YouTube link on the command line (the browser extension)
    readonly property bool watching: playerView.video !== null

    Component.onCompleted: {
        // Settings > Windows > "Open maximized" (a window opened in the background keeps its place behind the other)
        if (AppState.settings.startMaximized && !startedInBackground) win.visibility = Window.Maximized
        if (startSearch) { query.text = startSearch; search(startSearch) }
        if (startImport.toString()) importFrom(startImport)
        if (startExport.toString()) {
            const err = Store.exportSubscriptions(startExport, AppState.subscriptions)
            if (err) console.warn("export: " + err)
        }
        if (startChannel) openChannel({ id: startChannel, name: "" })
        // (opened behind another window: its video starts without its player, see PlayerView)
        playerView.startDeferred = deferPlayer
        if (startPlaylist) openPlaylist({ playlistId: startPlaylist, title: "" })
        if (startPlaylistInfo) openPlaylist(startPlaylistInfo)
        if (startChannelInfo) openChannel(startChannelInfo)
        if (startVideoInfo) openVideo(startVideoInfo)
        if (startVideo) openVideo({ videoId: startVideo, title: "", channel: "", channelId: "", views: "", published: "" })
        if (startLink && !openLink(startLink)) search(startLink, true)
        markShown()     // after the start video (if any): a window for a video doesn't build the feed
    }
    onClosing: { playerView.close(); AppState.flush() }

    // The app started again while it runs (main.cpp): one copy only, so another window of this one, in front.
    function openNewWindow() {
        const w = newWindow({}, "front")
        if (w) WindowTools.bringToFront(w)
    }

    // A link opened while the app runs ("Open in FTL Player" in the browser; main.cpp): a new window
    // (Settings > Windows > "Open links from other apps in a new window"), else this window opens it in place of
    // what it showed. In front, or ("... in the background") behind, with its taskbar button flashing.
    function openExternal(link) {
        const background = !!AppState.settings.externalBackground
        if (AppState.settings.externalNewWindow && win.visible) {
            const w = newWindow({ startLink: link }, background ? "background" : "front")
            if (w && !background) WindowTools.bringToFront(w)
            return
        }
        if (background && win.visible) WindowTools.flash(win)
        else WindowTools.bringToFront(win)     // restored if minimized, shown again if it was closed
        if (!openLink(link)) search(link, true)
    }

    // Shutdown timer: the 60 s warning before a PC action (in every window; the first window comes forward),
    // and pausing (with the position saved) when the time is up.
    Connections {
        target: SleepTimer
        function onWarn() {
            if (AppState.windows.indexOf(win) < 0 && !SleepTimer.quiet()) {      // the first window
                win.show(); win.raise(); win.requestActivate(); win.alert(0)
            }
        }
        function onFired(action) {
            playerView.pauseForTimer()
            AppState.flush()
        }
    }
    Popup {
        id: timerWarning
        popupType: Popup.Window
        modal: true
        visible: SleepTimer.warning
        closePolicy: Popup.NoAutoClose
        anchors.centerIn: parent
        width: 440
        padding: 24
        background: Rectangle { color: AppState.colors.card; radius: 12; border.color: "#e53935" }
        contentItem: ColumnLayout {
            spacing: 10
            Label {
                text: SleepTimer.verb(SleepTimer.action) + " in " + Math.ceil(SleepTimer.remaining / 1000) + " seconds"
                font.pixelSize: 21
                font.bold: true
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                text: "Your video will be paused and its progress saved first."
                opacity: 0.8
                Layout.alignment: Qt.AlignHCenter
                Layout.bottomMargin: 8
            }
            RowLayout {
                spacing: 10
                Layout.alignment: Qt.AlignHCenter
                Button { text: "Cancel"; highlighted: true; onClicked: SleepTimer.cancel() }
                Button { text: "Snooze 10 min"; onClicked: SleepTimer.add(10) }
            }
        }
    }

    // --- navigation

    // The back stack holds pages, and videos left for another page ({page, video, playlist, playlistIndex}:
    // back reopens the video, at its saved position, over the page it was opened from).
    function navigate(p) {
        if (watching) {
            pageStack = pageStack.concat([{ page: page, video: playerView.video, playlist: playerView.playlist,
                                            playlistIndex: playerView.playlistIndex }])
            closePlayer()
            page = p
        } else if (p !== page) {
            pageStack = pageStack.concat([page])
            page = p
        }
    }
    function goBack() {
        if (watching) { closePlayer(); return }
        if (pageStack.length) {
            const last = pageStack[pageStack.length - 1]
            pageStack = pageStack.slice(0, -1)
            if (typeof last === "string") { page = last; return }
            page = last.page
            if (last.playlist) playerView.openPlaylist(last.playlist, Math.max(0, last.playlistIndex))
            else if (last.video && last.video.videoId) playerView.open(last.video, false, 0)
        }
    }
    function openChannel(channel) {
        if (!channel || !channel.id) return
        const sub = AppState.subscriptions.find(s => s.id === channel.id)
        channelPage.channel = Object.assign({ thumbnail: sub ? sub.thumbnail : "" }, channel)
        navigate("channel")
        if (!startedInBackground) {
            win.raise()
            win.requestActivate()
        }
    }

    // --- videos

    function openVideo(v) { playerView.open(v) }
    function closePlayer() { playerView.close() }

    function openPlaylist(playlist) { playerView.openPlaylist(playlist, 0) }

    // Another complete window (sidebar, pages, player) playing the video or playlist, or showing a channel.
    // Windows share the helper and AppState; AppState.windows keeps them referenced while open.
    function openInNewWindow(v, playlist) { newWindow({ startVideoInfo: v || null, startPlaylistInfo: playlist || null }) }
    function openChannelInNewWindow(channel) { if (channel && channel.id) newWindow({ startChannelInfo: channel }) }
    // `place` "front" / "background": there whatever openInBackground says (links from other apps; test copies
    // keep it behind).
    // (made by AppState.createWindow, which also keeps it referenced while open: see there)
    function newWindow(props, place) {
        const background = place === "background" || (place === "front" ? WindowTools.testCopy()
                                                                         : !!AppState.settings.openInBackground)
        // On this window's screen, slightly offset (Qt would otherwise use the primary screen); in the
        // background exactly behind this one, shown without taking the focus, its taskbar button flashing.
        const offset = 48 * (AppState.windows.length + 1)
        const w = AppState.createWindow(Object.assign({ x: win.x + offset, y: win.y + offset,
                                                        width: win.width, height: win.height,
                                                        visible: !background, startedInBackground: background,
                                                        deferPlayer: background }, props))
        if (!w) return null
        if (background) WindowTools.showInBackground(w, win)
        console.info("new window" + (background ? " in the background" : "") + ", from a window with visibility "
                     + win.visibility + ": " + JSON.stringify(Object.keys(props).filter(k => props[k])))
        return w
    }

    // Refresh button: reloads what is showing (the video at its position, the feed, a channel, search, history).
    function refresh() {
        if (watching) { playerView.reload(); return }
        if (page === "subscriptions") { if (subscriptionsLoader.item) subscriptionsLoader.item.refreshCurrent() }
        else if (page === "channel") channelPage.reload()
        else if (page === "history") { if (historyLoader.item) historyLoader.item.rebuild() }
        else if (page === "search" && lastQuery) search(lastQuery)
    }

    // --- search

    // A YouTube link in the search field opens what it links to instead of being searched for: a video (at its
    // t=, also youtu.be / shorts / live / embed links), a playlist, or a channel (/channel/UC..., or @handle,
    // /c/, /user/ looked up by the helper). Returns false for anything else.
    function openLink(text) {
        const u = text.trim()
        if (!/^(https?:\/\/)?((www|m|music)\.)?(youtube\.com|youtu\.be|youtube-nocookie\.com)\/\S*$/i.test(u)) return false
        const video = u.match(/(?:[?&]v=|youtu\.be\/|\/(?:shorts|live|embed|v)\/)([\w-]{11})(?![\w-])/)
        if (video) {
            const t = u.match(/[?&#](?:t|start)=(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?(?!\w)/)
            const start = t ? 3600 * (+t[1] || 0) + 60 * (+t[2] || 0) + (+t[3] || 0) : 0
            playerView.open({ videoId: video[1], title: "", channel: "", channelId: "" }, false, start)
            return true
        }
        const list = u.match(/[?&]list=([\w-]+)/)
        if (list) { openPlaylist({ playlistId: list[1], title: "" }); return true }
        const channel = u.match(/\/channel\/(UC[\w-]{22})/)
        if (channel) { openChannel({ id: channel[1], name: "" }); return true }
        if (/\/(@[^/?#]+|c\/[^/?#]+|user\/[^/?#]+)/.test(u)) {
            Helper.call("resolveChannel", { url: /^https?:/i.test(u) ? u : "https://" + u }, function (r) {
                if (r.ok) openChannel({ id: r.channelId, name: "" })
                else search(u, true)        // not a channel after all: search for it
            })
            return true
        }
        return false
    }

    // "Save to playlist" for a video (cards' menus, the player's Save button): the saved playlists, ticked where it is in.
    function saveToPlaylist(video) {
        if (!video || !video.videoId) return
        savePopup.video = video
        savePopup.open()
    }
    SavePopup { id: savePopup }

    // The search page runs the search, with the filters chosen there (SearchPage).
    function search(q, plain) {
        q = q.trim()
        if (!q) return
        if (!plain && openLink(q)) { query.text = ""; return }
        lastQuery = q
        navigate("search")
        searchPage.run(q)
    }

    // --- subscription files

    function importFrom(file) {
        const r = Store.importSubscriptions(file)
        let msg
        if (r.error) msg = r.error
        else {
            const added = AppState.addSubscriptions(r.channels)
            msg = "Imported " + added + " new channel" + (added === 1 ? "" : "s") + " from the " + r.format + " file"
                + (r.channels.length > added ? " (" + (r.channels.length - added) + " were already subscribed)." : ".")
        }
        win.dataMessage = msg
        message.text = msg
        message.open()
    }

    FileDialog {
        id: importDialog
        title: "Import subscriptions"
        nameFilters: ["Subscription files (*.db *.csv *.opml *.xml *.json)", "All files (*)"]
        onAccepted: win.importFrom(selectedFile)
    }
    FileDialog {
        id: exportDialog
        title: "Export subscriptions"
        fileMode: FileDialog.SaveFile
        nameFilters: ["FreeTube (*.db)", "YouTube CSV (*.csv)", "NewPipe (*.json)", "OPML (*.opml)"]
        defaultSuffix: selectedNameFilter.extensions[0] || "db"
        onAccepted: {
            const err = Store.exportSubscriptions(selectedFile, AppState.subscriptions)
            win.dataMessage = err || "Exported " + AppState.subscriptions.length + " channels to "
                                              + decodeURIComponent(String(selectedFile).replace(/^file:\/{3}/, "")) + "."
        }
    }
    Dialog {
        id: message
        property alias text: messageText.text
        anchors.centerIn: parent
        modal: true
        title: "Subscriptions"
        Label { id: messageText; wrapMode: Text.Wrap; width: Math.min(win.width - 120, 480) }
        standardButtons: Dialog.Ok
    }

    // --- keys and fullscreen

    Connections {
        target: playerView.player
        // Follow mpv's fullscreen state (double-click, F, Esc and the on-screen button all change it).
        function onFullscreenChanged() {
            const on = playerView.player.fullscreen
            if (on) playerView.player.endTyping()   // (a hidden search field kept the keys in fullscreen)
            console.info("fullscreen " + (on ? "on" : "off") + " (window visibility was " + win.visibility + ")")
            win.visibility = on ? Window.FullScreen : Window.AutomaticVisibility
            WindowTools.checkFullScreen(win, on)     // and set anew if the window didn't follow
        }
    }
    Shortcut {
        sequence: "Esc"
        enabled: playerView.player.fullscreen
        onActivated: playerView.player.fullscreen = false
    }
    Shortcut { sequences: [StandardKey.Back]; onActivated: win.goBack() }
    Shortcut { sequence: "F5"; onActivated: win.refresh() }

    header: ToolBar {
        visible: !playerView.player.fullscreen
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 8

            // Back and refresh use Windows' icons (Segoe Fluent Icons / MDL2 Assets), like the timer's clock,
            // at the same size
            ToolButton {
                text: ""
                font.family: Qt.fontFamilies().indexOf("Segoe Fluent Icons") >= 0 ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
                font.pixelSize: 18
                enabled: win.watching || win.pageStack.length > 0
                onClicked: win.goBack()
                ToolTip.visible: hovered
                ToolTip.text: "Back (Alt+Left)"
            }
            ToolButton {
                text: ""
                font.family: Qt.fontFamilies().indexOf("Segoe Fluent Icons") >= 0 ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
                font.pixelSize: 18
                onClicked: win.refresh()
                ToolTip.visible: hovered
                ToolTip.text: "Refresh (F5)"
            }
            TimerButton {}
            // The logo goes to the subscriptions, like YouTube's
            RowLayout {
                spacing: 8
                Layout.leftMargin: 4
                Layout.rightMargin: 24
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: win.navigate("subscriptions") }
                Image {
                    source: AppState.dark ? "assets/icon_dark.png" : "assets/icon_light.png"   // (black laser on dark, white on light)
                    sourceSize: Qt.size(26, 26)
                }
                Label {
                    text: "FTL Player"
                    font.pixelSize: 17
                    font.bold: true
                }
            }
            TextField {
                id: query
                Layout.fillWidth: true
                Layout.maximumWidth: 600
                selectByMouse: true
                onAccepted: win.search(text)
                // A pasted YouTube link (many characters at once) opens at once; a typed one on Enter (search()).
                property int lastLength: 0
                onTextEdited: {
                    const pasted = text.length - lastLength > 10
                    lastLength = text.length
                    if (pasted && win.openLink(text)) clear()
                }
                onTextChanged: if (!text) lastLength = 0

                // A plain hint instead of Material's floating placeholder, which the toolbar would clip.
                Label {
                    x: query.leftPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Search YouTube"
                    color: AppState.colors.muted
                    visible: query.text === "" && query.preeditText === ""
                }
            }
            Button {
                text: "Search"
                highlighted: true
                onClicked: win.search(query.text)
            }
            Item { Layout.fillWidth: true }
        }
    }

    // Sidebar
    Rectangle {
        id: sidebar
        visible: !playerView.player.fullscreen
        width: 190
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        color: AppState.colors.sidebar

        Column {
            anchors.fill: parent
            anchors.topMargin: 8
            Repeater {
                model: [
                    { page: "subscriptions", text: "Subscriptions" },
                    { page: "channels", text: "Channels" },
                    { page: "history", text: "History" },
                    { page: "playlists", text: "Playlists" },
                    { page: "settings", text: "Settings" }
                ]
                delegate: ItemDelegate {
                    required property var modelData
                    width: sidebar.width
                    text: modelData.text
                    highlighted: !win.watching && (win.page === modelData.page
                                 || (modelData.page === "channels" && win.page === "channel"))
                    onClicked: win.navigate(modelData.page)
                }
            }
        }
    }

    // Pages
    StackLayout {
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: sidebar.right
        anchors.right: parent.right
        visible: !win.watching
        currentIndex: ["subscriptions", "channels", "channel", "history", "settings", "search", "playlists"].indexOf(win.page)

        Loader {
            id: subscriptionsLoader
            active: !!win.shownPages.subscriptions
            sourceComponent: SubscriptionsPage {
                onOpenVideo: (video) => win.openVideo(video)
                onOpenVideoInNewWindow: (video) => win.openInNewWindow(video)
                onOpenChannel: (channel) => win.openChannel(channel)
                onOpenChannelInNewWindow: (channel) => win.openChannelInNewWindow(channel)
                onImportRequested: importDialog.open()
            }
        }
        Loader {
            active: !!win.shownPages.channels
            sourceComponent: ChannelsPage {
                onOpenChannel: (channel) => win.openChannel(channel)
                onOpenChannelInNewWindow: (channel) => win.openChannelInNewWindow(channel)
                onImportRequested: importDialog.open()
            }
        }
        ChannelPage {
            id: channelPage
            onOpenVideo: (video) => win.openVideo(video)
            onOpenVideoInNewWindow: (video) => win.openInNewWindow(video)
            onOpenPlaylist: (playlist) => win.openPlaylist(playlist)
            onOpenPlaylistInNewWindow: (playlist) => win.openInNewWindow(null, playlist)
        }
        Loader {
            id: historyLoader
            active: !!win.shownPages.history
            sourceComponent: HistoryPage {
                onOpenVideo: (video) => win.openVideo(video)
                onOpenVideoInNewWindow: (video) => win.openInNewWindow(video)
                onOpenChannel: (channel) => win.openChannel(channel)
                onOpenChannelInNewWindow: (channel) => win.openChannelInNewWindow(channel)
            }
        }
        Loader {
            active: !!win.shownPages.settings
            sourceComponent: SettingsPage {
                dataMessage: win.dataMessage
                onImportRequested: importDialog.open()
                onExportRequested: exportDialog.open()
            }
        }
        SearchPage {
            id: searchPage
            onOpenVideo: (video) => win.openVideo(video)
            onOpenVideoInNewWindow: (video) => win.openInNewWindow(video)
            onOpenChannel: (channel) => win.openChannel(channel)
            onOpenChannelInNewWindow: (channel) => win.openChannelInNewWindow(channel)
            onOpenPlaylist: (playlist) => win.openPlaylist(playlist)
            onOpenPlaylistInNewWindow: (playlist) => win.openInNewWindow(null, playlist)
        }
        Loader {
            active: !!win.shownPages.playlists
            sourceComponent: PlaylistsPage {
                onPlayPlaylist: (info, index) => playerView.openPlaylist(info, index)
                onPlayPlaylistInNewWindow: (info) => win.openInNewWindow(null, info)
                onOpenVideoInNewWindow: (video) => win.openInNewWindow(video)
                onOpenChannel: (channel) => win.openChannel(channel)
                onOpenChannelInNewWindow: (channel) => win.openChannelInNewWindow(channel)
            }
        }
    }

    // Player (covers the pages; in fullscreen also the sidebar)
    PlayerView {
        id: playerView
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: playerView.player.fullscreen ? parent.left : sidebar.right
        anchors.right: parent.right
        visible: win.watching
        onOpenChannel: (channel) => win.openChannel(channel)
    }
}
