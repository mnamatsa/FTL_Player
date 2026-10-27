import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Latest videos and live streams of the subscribed channels. The saved feed shows at once; the channels
// are then refreshed in the background, several at a time.
//  - Videos: RSS feeds (all 545 channels in ~10 s) or, in the "full" setting, channel tabs (~35 s, with durations).
//  - Live: every channel's "Live" tab (~33 s), the ones live or streaming most recently first.
Item {
    id: page

    signal openVideo(var video)
    signal openVideoInNewWindow(var video)
    signal openChannel(var channel)
    signal openChannelInNewWindow(var channel)
    signal importRequested()

    readonly property var subscriptions: AppState.subscriptions
    readonly property int liveMaxAge: 5 * 60 * 1000

    // Per tab: channelId -> {t: fetchedAt, items: [...]}
    property var feeds: ({ videos: Store.load("feed-videos", {}), streams: Store.load("feed-streams", {}) })
    property double now: Date.now()

    component FeedState: QtObject {
        property string tab
        property bool running: false
        property int done: 0
        property int total: 0
        property int failed: 0
        property double updated: 0
        property bool dirty: false      // new data not shown yet
        property bool held: false       // not shown because the user has scrolled down
        property var queue: []
        property int inFlight: 0
        property string command
        property var errors: []         // [{channel, error}] of the last refresh
    }
    FeedState { id: videosState; tab: "videos" }
    FeedState { id: liveState; tab: "streams" }

    ListModel { id: videosModel }
    ListModel { id: liveModel }

    // Live, scheduled or ended live stream (channel Live tabs also list premieres, which are left out).
    function isStream(v) {
        return v.live || /^streamed/i.test(v.published) || (v.upcoming && /^scheduled/i.test(v.published))
    }

    function stateFor(tab) { return tab === "videos" ? videosState : liveState }
    function gridFor(tab) { return tab === "videos" ? videosGrid : liveGrid }
    function latestUpload(ch) {
        const f = feeds.videos[ch.id]
        return f && f.items.length ? Math.max(...f.items.map(v => v.publishedAt)) : 0
    }

    // The Live tab checks every channel: live or upcoming ones first, then by their latest stream (channels
    // that never streamed last, by their latest upload), so likely streams show within the first seconds.
    function latestStream(ch) {
        const f = feeds.streams[ch.id]
        if (!f) return 1e15                                  // not checked yet (new subscription)
        let t = 0
        for (const v of f.items)
            if (isStream(v)) t = Math.max(t, v.live || v.upcoming ? 1e15 : v.publishedAt)
        return t
    }

    // Refreshes the given channels (default: all) of one tab; channels that uploaded (Live: streamed) most
    // recently go first.
    function refresh(tab, channels) {
        const st = stateFor(tab)
        if (st.running) return
        const list = channels || subscriptions
        if (!list.length) return
        const rss = tab === "videos" && AppState.settings.feedSource !== "full"
        st.command = rss ? "rssFeed" : "channelTab"
        st.queue = list.slice().sort(tab === "streams"
            ? (a, b) => latestStream(b) - latestStream(a) || latestUpload(b) - latestUpload(a)
            : (a, b) => latestUpload(b) - latestUpload(a))
        st.total = st.queue.length
        st.done = 0
        st.failed = 0
        st.inFlight = 0
        st.errors = []
        st.running = true
        for (let i = 0; i < (rss ? 24 : 12); i++)
            next(st)
    }

    function next(st) {
        if (st.queue.length === 0) {
            if (st.inFlight === 0 && st.running)
                finish(st)
            return
        }
        const ch = st.queue.shift()
        st.inFlight++
        Helper.call(st.command, { channelId: ch.id, tab: st.tab }, function (r) {
            st.inFlight--
            st.done++
            if (r.ok) {
                let items = r.items
                if (st.tab === "streams")   // live and scheduled, plus the latest ended streams
                    items = items.filter(v => isStream(v) && (v.live || v.upcoming))
                        .concat(items.filter(v => isStream(v) && !v.live && !v.upcoming).slice(0, 10))
                else
                    items = items.slice(0, 20)
                for (const it of items)
                    it.channel = ch.name
                feeds[st.tab][ch.id] = { t: Date.now(), items: items }
                st.dirty = true
            } else {
                st.failed++
                st.errors.push({ channel: ch.name, error: r.error })
                console.warn("channel " + ch.name + " (" + ch.id + "): " + r.error)
            }
            next(st)
        })
    }

    function finish(st) {
        st.running = false
        st.updated = Date.now()
        st.dirty = true
        show(st, false)
        Store.save(st.tab === "videos" ? "feed-videos" : "feed-streams", feeds[st.tab])
        if (st.tab === "videos") fillDurations()
        else streamDurations()
        checkUpcoming()
        if (st.tab === "streams" && videosState.updated) {
            videosState.dirty = true      // live/upcoming marks in the Videos tab
            show(videosState, false)
        }
    }

    // Scheduled streams and premieres look like normal uploads in the RSS feed (with 0 views). Those, and the
    // Live tab's upcoming items, are looked up once, and again once their start time has passed; upcoming ones
    // get their start time (shown on the card, and they sort to the top as on YouTube).
    property bool checkingUpcoming: false
    function checkUpcoming() {
        if (checkingUpcoming) return
        const now = Date.now(), known = AppState.videoStates, ids = new Set()
        const due = v => {
            const st = known[v.videoId]
            return !st || (st.u && (st.p === undefined || (st.s < now && now - st.t > 10 * 60000)))
        }
        for (const id in feeds.videos)
            for (const v of feeds.videos[id].items)
                if ((v.upcoming || v.views === "0") && now - v.publishedAt < 30 * 86400000 && due(v)) ids.add(v.videoId)
        for (const id in feeds.streams)
            for (const v of feeds.streams[id].items)
                if (v.upcoming && due(v)) ids.add(v.videoId)
        if (!ids.size) return
        checkingUpcoming = true
        Helper.call("videoStates", { ids: [...ids] }, function (r) {
            checkingUpcoming = false
            if (!r.ok) return
            AppState.addVideoStates(r.states)
            for (const st of [videosState, liveState]) { st.dirty = true; show(st, false) }
        })
    }
    // A feed item with what is known about its start: upcoming (start time, sorted by it) or live now, and
    // whether an upcoming one is a premiere (Videos tab) or a scheduled live stream (Live tab). Every item
    // gets startAt and premiere, so the list models have the same roles throughout.
    function withState(v) {
        const st = AppState.videoStates[v.videoId]
        // What the channel's Live tab says at its last refresh (live now, or "Streamed 2 hours ago") wins over
        // an older lookup: a stream looked up while scheduled stayed "upcoming" once live, so it was missing
        // from the live ones (and hidden with hideUpcomingLive); one looked up while live stayed live once over.
        const current = v.live || /^streamed/i.test(v.published || "")
        const r = st && (st.u || st.l) && !current
            ? Object.assign({}, v, { upcoming: st.u && !st.l, live: st.l, startAt: st.u ? st.s : 0,
                                     publishedAt: st.u && st.s > 0 ? st.s : v.publishedAt })
            : Object.assign({ startAt: 0 }, v)
        // not looked up yet: the Live tab's text tells ("Premieres …" / "Scheduled for …")
        // (also while it plays: a premiere playing now stays in the Videos tab)
        r.premiere = !!(r.upcoming || r.live) && (st && st.p !== undefined ? st.p : /^premiere/i.test(v.scheduleText || v.published || ""))
        return r
    }

    // RSS items have no durations. Afterwards, the Videos tabs of channels with uploads of unknown length are
    // fetched in the background (several at a time) and the durations kept in AppState, so each video is
    // looked up once. Videos the tab doesn't list (Shorts, streams) are remembered as having none.
    property bool fillingDurations: false
    // Past streams also appear in the Videos feed; the Live tab's data has their lengths.
    function streamDurations() {
        const found = {}
        for (const id in feeds.streams)
            for (const v of feeds.streams[id].items)
                if (v.duration && !AppState.durations[v.videoId]) found[v.videoId] = v.duration
        AppState.addDurations(found)
    }
    function fillDurations() {
        if (fillingDurations) return
        streamDurations()
        const known = AppState.durations
        const missing = v => !v.duration && !v.live && !v.upcoming && known[v.videoId] === undefined
        const newestMissing = ch => Math.max(0, ...feeds.videos[ch.id].items.filter(missing).map(v => v.publishedAt || 0))
        const queue = subscriptions.filter(ch => feeds.videos[ch.id] && feeds.videos[ch.id].items.some(missing))
            .map(ch => ({ ch: ch, t: newestMissing(ch) })).sort((a, b) => b.t - a.t).map(e => e.ch)
        if (!queue.length) return
        fillingDurations = true
        let inFlight = 0, pending = 0, found = {}
        const flush = () => { AppState.addDurations(found); found = {}; pending = 0 }
        const step = () => {
            if (!queue.length) {
                if (inFlight === 0) { flush(); fillingDurations = false }
                return
            }
            const ch = queue.shift()
            inFlight++
            Helper.call("channelTab", { channelId: ch.id, tab: "videos" }, function (r) {
                inFlight--
                if (r.ok) {
                    const lengths = {}
                    for (const v of r.items) if (v.duration) lengths[v.videoId] = v.duration
                    for (const v of (feeds.videos[ch.id] || { items: [] }).items)
                        if (missing(v)) found[v.videoId] = lengths[v.videoId] || ""
                    if (++pending >= 20) flush()        // show them as they come
                }
                step()
            })
        }
        for (let i = 0; i < 8; i++) step()
    }

    // Rebuilds a tab's list, unless the user is scrolled down in it (then a button offers the new videos) or is
    // at it: the pointer over it or a card's menu open. Then it waits until the pointer leaves / the menu closes
    // (no button: that is a moment later anyway). While a refresh rebuilt the list every 0.7 s, the card being
    // aimed at could turn into another video just before the click, and an open menu jumped with its card.
    function show(st, force) {
        const grid = gridFor(st.tab)
        if (!force && grid.count > 0) {
            if (!grid.atYBeginning) { st.held = st.held || st.dirty; return }
            if (grid.busy) return       // still dirty: applied by onBusyChanged
        }
        st.dirty = false
        st.held = false
        rebuild(st.tab)
    }

    function count(text) {
        const m = String(text).match(/([\d.,]+)\s*([KMB])?/i)
        if (!m) return 0
        return parseFloat(m[1].replace(/,/g, "")) * ({ K: 1e3, M: 1e6, B: 1e9 }[(m[2] || "").toUpperCase()] || 1)
    }

    function rebuild(tab) {
        const subscribed = new Set(subscriptions.map(s => s.id))
        let all = []
        for (const id in feeds[tab])
            if (subscribed.has(id))
                for (const it of feeds[tab][id].items)
                    all.push(it)
        let list
        if (tab === "videos") {
            // RSS can't tell live streams apart, so take that from the Live tab's data.
            const fromLiveTab = new Map()
            for (const id in feeds.streams)
                for (const v of feeds.streams[id].items)
                    if (v.live || v.upcoming) fromLiveTab.set(v.videoId, v)
            const s = AppState.settings
            list = all.filter(v => !(s.hideShorts && v.short) && !(s.hideWatched && AppState.historyIndex[v.videoId]))
                .map(v => {
                    const l = fromLiveTab.get(v.videoId)
                    return l ? Object.assign({}, v, { live: l.live, upcoming: l.upcoming && !l.live, scheduleText: l.published }) : v
                })
                .map(withState)
                // streams live now and upcoming ones belong to the Live tab (RSS lists them as videos); premieres
                // (upcoming or playing) stay here, and so do streams once over (their recordings)
                .filter(v => !((v.live || v.upcoming) && !v.premiere) && !(s.hideUpcomingPremieres && v.upcoming))
                .sort((a, b) => b.publishedAt - a.publishedAt).slice(0, 1000)
        } else {
            all = all.filter(isStream)
            // scheduled streams found in the Videos feed too (before the Live tab's next refresh)
            const have = new Set(all.map(v => v.videoId))
            for (const id in feeds.videos)
                if (subscribed.has(id))
                    for (const v of feeds.videos[id].items) {
                        const st = AppState.videoStates[v.videoId]
                        if (st && st.u && st.p === false && !have.has(v.videoId)) { all.push(v); have.add(v.videoId) }
                    }
            all = all.map(withState)
                .filter(v => !(v.upcoming && v.premiere) && !(AppState.settings.hideUpcomingLive && v.upcoming))
            const live = all.filter(v => v.live).sort((a, b) => count(b.views) - count(a.views))
            const upcoming = all.filter(v => v.upcoming && !v.live).sort((a, b) => (a.startAt || 9e15) - (b.startAt || 9e15))
            const past = all.filter(v => !v.live && !v.upcoming).sort((a, b) => b.publishedAt - a.publishedAt)
            list = live.concat(upcoming, past.slice(0, 400))
        }
        const model = tab === "videos" ? videosModel : liveModel
        model.clear()
        model.append(list)
    }

    function lastUpdate(tab) {
        let t = 0
        for (const id in feeds[tab])
            t = Math.max(t, feeds[tab][id].t)
        return t
    }

    function ago(t) {
        const s = Math.max(0, (now - t) / 1000)
        if (s < 60) return "just now"
        if (s < 3600) return Math.floor(s / 60) + " min ago"
        if (s < 86400) return Math.floor(s / 3600) + " h ago"
        return Math.floor(s / 86400) + " d ago"
    }

    function statusText(st) {
        if (st.running)
            return "Refreshing " + st.done + " / " + st.total + " channels"
        let s = st.updated ? "Updated " + ago(st.updated) : "Not loaded yet"
        if (st.failed)
            s += "  •  " + st.failed + " channels could not be loaded"
        return s
    }

    // Live status changes quickly, so the Live tab refreshes when opened if it is a few minutes old.
    function maybeRefreshLive() {
        if (tabs.currentIndex === 1 && !liveState.running && now - liveState.updated > liveMaxAge)
            refresh("streams")
    }

    Component.onCompleted: {
        videosState.updated = lastUpdate("videos")
        liveState.updated = lastUpdate("streams")
        rebuild("videos")
        rebuild("streams")
        // A feed updated in the last 15 minutes (e.g. by another window) is shown as it is.
        if (Date.now() - videosState.updated > 15 * 60 * 1000)
            refresh("videos")
        else {
            fillDurations()
            checkUpcoming()
        }
    }

    function refreshCurrent() { refresh(tabs.currentIndex === 0 ? "videos" : "streams") }

    // New channels are fetched right away; removed ones simply disappear from the lists.
    onSubscriptionsChanged: {
        for (const st of [videosState, liveState]) {
            const missing = subscriptions.filter(s => !feeds[st.tab][s.id])
            if (missing.length && (st.tab === "videos" || st.updated))
                refresh(st.tab, missing)
            rebuild(st.tab)
        }
    }
    Connections {
        target: AppState
        // Feed filters (Shorts, watched videos) and the feed source can change in Settings.
        function onSettingsChanged() { page.rebuild("videos"); page.rebuild("streams") }
    }

    Timer {
        interval: 700
        repeat: true
        running: videosState.running || liveState.running
        onTriggered: {
            for (const st of [videosState, liveState])
                if (st.dirty)
                    page.show(st, false)
        }
    }
    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: { page.now = Date.now(); page.maybeRefreshLive() }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 6
        visible: page.subscriptions.length > 0

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            TabBar {
                id: tabs
                TabButton { text: "Videos"; width: implicitWidth + 24 }
                TabButton { text: "Live"; width: implicitWidth + 24 }
                Component.onCompleted: currentIndex = AppState.subscriptionsTab
                onCurrentIndexChanged: { AppState.subscriptionsTab = currentIndex; page.now = Date.now(); page.maybeRefreshLive() }
            }
            Label {
                readonly property var st: tabs.currentIndex === 0 ? videosState : liveState
                text: page.statusText(st)
                color: AppState.colors.tertiary
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Button {
                readonly property var st: tabs.currentIndex === 0 ? videosState : liveState
                visible: st.held
                text: "Show new videos"
                highlighted: true
                onClicked: { page.show(st, true); page.gridFor(st.tab).positionViewAtBeginning() }
            }
            ToolButton {
                text: "⟳"
                font.pixelSize: 20
                enabled: !(tabs.currentIndex === 0 ? videosState : liveState).running
                onClicked: page.refresh(tabs.currentIndex === 0 ? "videos" : "streams")
                ToolTip.visible: hovered
                ToolTip.text: "Refresh"
            }
        }

        StackLayout {
            currentIndex: tabs.currentIndex
            Layout.fillWidth: true
            Layout.fillHeight: true

            VideoGrid {
                id: videosGrid
                model: videosModel
                onOpenVideo: (video) => page.openVideo(video)
                onOpenVideoInNewWindow: (video) => page.openVideoInNewWindow(video)
                onOpenChannel: (channel) => page.openChannel(channel)
                onOpenChannelInNewWindow: (channel) => page.openChannelInNewWindow(channel)
                onAtYBeginningChanged: if (atYBeginning && videosState.dirty) page.show(videosState, false)
                onBusyChanged: if (!busy && videosState.dirty) page.show(videosState, false)
            }
            VideoGrid {
                id: liveGrid
                model: liveModel
                onOpenVideo: (video) => page.openVideo(video)
                onOpenVideoInNewWindow: (video) => page.openVideoInNewWindow(video)
                onOpenChannel: (channel) => page.openChannel(channel)
                onOpenChannelInNewWindow: (channel) => page.openChannelInNewWindow(channel)
                onAtYBeginningChanged: if (atYBeginning && liveState.dirty) page.show(liveState, false)
                onBusyChanged: if (!busy && liveState.dirty) page.show(liveState, false)
            }
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        visible: page.subscriptions.length === 0
        spacing: 12
        width: Math.min(parent.width - 48, 520)

        Label {
            text: "No subscriptions yet"
            font.pixelSize: 20
            font.bold: true
            Layout.alignment: Qt.AlignHCenter
        }
        Label {
            text: "Subscribe to channels from a video's page, or import a subscription file exported from "
                  + "FreeTube, YouTube (Google Takeout), NewPipe or an RSS reader (OPML)."
            color: AppState.colors.secondary
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }
        Button {
            text: "Import subscriptions…"
            highlighted: true
            Layout.alignment: Qt.AlignHCenter
            onClicked: page.importRequested()
        }
    }
}
