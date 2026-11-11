pragma Singleton
import QtQuick

// State shared by all windows: subscriptions, settings and watch history, each kept in Data/<name>.json.
QtObject {
    id: app

    // --- settings

    readonly property var defaults: ({
        quality: 0,             // preferred maximum height; 0 = the screen's height
        speed: 1,               // default playback speed
        speedStep: 0.25,        // S / D keys
        hardwareDecoding: true,
        feedSource: "rss",      // "rss" (fast) or "full" (slower, with durations)
        hideShorts: true,
        hideMembersOnly: false, // members-only videos (they can't be played here) left out of the feeds
        rememberHistory: true,
        resume: true,           // continue videos where you left off
        hideWatched: false,     // in the subscription feed
        hideUpcomingPremieres: false,   // in the Videos feed
        hideUpcomingLive: false,        // scheduled live streams, in the Live feed
        autoplay: true,         // start playing as soon as a video opens
        captions: false,        // show captions when available
        captionLanguage: "en",
        theme: "dark",          // "dark", "light" or "system" (as Windows is set)
        gridScale: 1,           // size of the cards in video grids
        scrollSpeed: 1,         // mouse wheel scrolling of pages and lists, times the usual distance
        cardPreview: true,      // the pointer along a video card's bar previews the video (its storyboard)
        wheelVolume: 2,         // wheel over the video: 2 = volume, 1 = volume in fullscreen only, 0 = never
        wheelSeek: 2,           // wheel over the seek bar: 2 = seeks, 1 = in fullscreen only, 0 = never
        wheelSpeed: 2,          // wheel over the speed button: 2 = changes the speed, 1 = in fullscreen only, 0 = never
        volume: 100,            // kept between videos
        muted: false,
        timeTotal: false,       // right timecode: total time (true) or time left (false)
        openInBackground: false,    // "Open in new window" opens it behind the current one
        startMaximized: false,      // windows open maximized (not the ones opened in the background)
        openUnloaded: true,         // a video opened in a background window starts without its player
        unloadMode: "count",        // how background videos unload: "count" (loadedPlayers) or "time" (unloadPausedAfter)
        loadedPlayers: 2,           // count: videos (across the windows) whose player stays loaded, the last used (0 all)
        unloadPausedAfter: 3,       // time: minutes a video is paused with its window in the background before it unloads
        externalNewWindow: true,    // links from other apps (the browser extension) open in a new window
        externalBackground: false,  // ... behind the other windows, without taking the focus
        codec: "auto",              // preferred video codec: auto | vp9 | h264 | av1
        preview: true,              // seek bar preview pictures
        previewScale: 1,            // seek bar preview size, times the usual
        gpu: "auto",                // auto | integrated | dedicated (Windows' power saving / high performance GPU)
        seekStep: 5,                // short jump (left / right arrow), seconds
        jumpMultiplier: 2,          // long jump (J / L) = short jump x this
        chapters: true,             // chapters in the seek bar, on hover and under the description
        sponsorBlock: true,         // SponsorBlock segments: skipped / shown per category (sb_<category>, sponsorCategories)
        sb_sponsor: "skip", sb_selfpromo: "show", sb_interaction: "show", sb_intro: "show", sb_outro: "show",
        sb_preview: "show", sb_music_offtopic: "show", sb_filler: "off", sb_poi_highlight: "show", sb_exclusive_access: "show",
        hotkeys: ({})               // action -> mpv key name; missing actions use defaultHotkeys
    })
    // Rebindable player keys (mpv key names). "," and "." are the keys marked < and >.
    readonly property var defaultHotkeys: ({
        speedDown: "s", speedUp: "d",
        seekBack: "LEFT", seekForward: "RIGHT",
        jumpBack: "j", jumpForward: "l",
        frameBack: ",", frameForward: "."
    })
    readonly property var hotkeys: Object.assign({}, defaultHotkeys, settings.hotkeys || {})

    property var settings: {
        const saved = Store.load("settings", {})
        if (saved.hideUpcoming !== undefined && saved.hideUpcomingLive === undefined)    // the former single switch
            saved.hideUpcomingPremieres = saved.hideUpcomingLive = saved.hideUpcoming
        delete saved.hideUpcoming
        return Object.assign({}, defaults, saved)
    }

    function setSetting(name, value) {
        const patch = {}
        patch[name] = value
        setSettings(patch)
    }
    // Ctrl + mouse wheel over a grid: one step bigger (dir > 0) or smaller.
    readonly property var gridScales: [0.7, 0.8, 0.9, 1, 1.15, 1.3, 1.5, 1.75]
    function stepGridScale(dir) {
        const cur = settings.gridScale || 1
        let i = gridScales.findIndex(v => v >= cur - 0.001)
        if (i < 0) i = gridScales.length - 1
        i = Math.max(0, Math.min(gridScales.length - 1, i + (dir > 0 ? 1 : -1)))
        if (gridScales[i] !== cur) setSetting("gridScale", gridScales[i])
    }
    function setSettings(patch) {
        settings = Object.assign({}, settings, patch)
        Store.save("settings", settings)
    }

    // --- subscriptions: [{id, name, thumbnail}]

    property var subscriptions: Store.load("subscriptions", [])

    // Saved playlists (Data/playlists.json): [{id, name, videos: [video ...], created, updated}], newest video last;
    // "Watch later" is always there (id "watchlater"). playlistsRevision changes with every edit (for bindings).
    property var playlists: {
        const saved = Store.load("playlists", [])
        if (!saved.some(p => p.id === "watchlater"))
            saved.unshift({ id: "watchlater", name: "Watch later", videos: [], created: Date.now(), updated: Date.now() })
        return saved
    }
    property int playlistsRevision: 0
    function savePlaylists() {
        playlists = playlists.slice()
        playlistsRevision++
        Store.save("playlists", playlists)
    }
    function playlistById(id) { return playlists.find(p => p.id === id) || null }
    function createPlaylist(name) {
        const p = { id: "pl" + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36), name: name.trim() || "Playlist",
                    videos: [], created: Date.now(), updated: Date.now() }
        playlists.push(p)
        savePlaylists()
        return p.id
    }
    function renamePlaylist(id, name) {
        const p = playlistById(id)
        if (!p || !name.trim()) return
        p.name = name.trim()
        p.updated = Date.now()
        savePlaylists()
    }
    function deletePlaylist(id) {
        if (id === "watchlater") return
        playlists = playlists.filter(p => p.id !== id)
        savePlaylists()
    }
    function inPlaylist(id, videoId) {
        const p = playlistsRevision >= 0 ? playlistById(id) : null
        return !!p && p.videos.some(v => v.videoId === videoId)
    }
    // the fields of a playlist's (and the player's playlist list's) videos, all of them always set
    function playlistEntry(v) {
        return { videoId: v.videoId, title: v.title || "", channel: v.channel || "", channelId: v.channelId || "",
                 duration: v.duration || "", views: v.views || "", published: v.published || "", live: false, upcoming: false,
                 thumbnail: v.thumbnail || "https://i.ytimg.com/vi/" + v.videoId + "/mqdefault.jpg", addedAt: Date.now() }
    }
    function addToPlaylist(id, v) {
        const p = playlistById(id)
        if (!p || !v || !v.videoId || p.videos.some(x => x.videoId === v.videoId)) return
        p.videos.push(playlistEntry(v))
        p.updated = Date.now()
        savePlaylists()
    }
    function removeFromPlaylist(id, videoId) {
        const p = playlistById(id)
        if (!p) return
        p.videos = p.videos.filter(v => v.videoId !== videoId)
        p.updated = Date.now()
        savePlaylists()
    }

    // --- theme (Settings > Layout > Theme): the interface's colours, the icon (black laser on dark, white on
    // light), and Windows' title bars (WindowTools.setColorScheme). "system" follows Windows' app mode.
    readonly property bool dark: settings.theme === "system" ? Qt.styleHints.colorScheme !== Qt.ColorScheme.Light
                                                             : settings.theme !== "light"
    readonly property string theme: settings.theme || "dark"
    // (main.cpp sets both before the first window; acting while this object was still being made, on the first
    // value, had the windows ask for colors before it had them)
    property bool started: false
    onThemeChanged: if (started) WindowTools.setColorScheme(theme)
    onDarkChanged: if (started) WindowTools.setAppIcon(dark)
    // What the pages draw with (things over thumbnails and the video keep their own colours in both)
    // (a palette each, picked: written as one expression, "dark ? ({..}) : ({..})", the dark one came out
    // undefined from Qt's compiled QML)
    readonly property var colors: dark ? darkColors : lightColors
    readonly property var darkColors: ({
        window: "#181818", sidebar: "#1f1f1f", header: "#212121",
        card: "#262626", box: "#272727", boxHover: "#303030", placeholder: "#2a2a2a",
        popup: "#232323", popupBorder: "#3a3a3a", panel: "#1c1c1c",
        hover: "#333333", chipOn: "#3a2626", selected: "#3a2a2a", listening: "#5a2626",
        border: "#555555", badge: "#555555",
        text: "#ffffff", body: "#e6e6e6", textSoft: "#dddddd",
        secondary: "#aaaaaa", tertiary: "#909090", muted: "#888888", faint: "#777777",
        link: "#3ea6ff", error: "#ff6b6b", success: "#a5d6a7", warning: "#f9a825"
    })
    readonly property var lightColors: ({
        window: "#f9f9f9", sidebar: "#f0f0f0", header: "#ffffff",
        card: "#ececec", box: "#efefef", boxHover: "#e5e5e5", placeholder: "#dedede",
        popup: "#ffffff", popupBorder: "#d0d0d0", panel: "#f5f5f5",
        hover: "#e3e3e3", chipOn: "#fde3e3", selected: "#fbe4e4", listening: "#f9cfcf",
        border: "#bdbdbd", badge: "#757575",
        text: "#0f0f0f", body: "#1a1a1a", textSoft: "#262626",
        secondary: "#606060", tertiary: "#6a6a6a", muted: "#717171", faint: "#7a7a7a",
        link: "#065fd4", error: "#d32f2f", success: "#2e7d32", warning: "#b26a00"
    })

    property var windows: []            // extra main windows opened with "Open in new window"
    // Makes such a window (Main.newWindow) here rather than in the window asking: a created object's QML context
    // hangs off the one its component was created in, so closing the asking window destroyed it, and the windows
    // it had opened stopped running their scripts (they showed and typed, but no click, binding or handler
    // reacted: the search placeholder stayed, the video didn't follow the window's size, nor go fullscreen).
    // This one lives as long as the app.
    function createWindow(props) {
        const c = Qt.createComponent("Main.qml")
        if (c.status !== Component.Ready) { console.warn(c.errorString()); return null }
        const w = c.createObject(null, props)
        if (!w) return null
        windows = windows.concat([w])
        w.closing.connect(() => {
            windows = windows.filter(x => x !== w)
            Qt.callLater(() => w.destroy())
        })
        return w
    }

    // Loaded players across the windows (PlayerView), the last used first: opened, or their window brought
    // forward. Settings > Windows: "count" keeps only loadedPlayers of them loaded (using one unloads the paused
    // ones past that; one past that unloads as soon as it is paused in the background); "time" unloads any paused
    // for unloadPausedAfter minutes with its window in the background (PlayerView). Each loaded video takes
    // ~300-400 MB (decoder, picture buffers, GPU memory).
    property var players: []
    readonly property bool unloadByCount: settings.unloadMode !== "time"
    // (loadedPlayers 0: unlimited)
    readonly property real maxLoadedPlayers: !unloadByCount || settings.loadedPlayers === 0 ? 1e9 : Math.max(1, settings.loadedPlayers || 2)
    function usePlayer(p) {
        players = [p].concat(players.filter(x => x !== p))
        for (const q of players.slice(maxLoadedPlayers))
            if (q.player.paused) q.unloadPlayer()
    }
    function dropPlayer(p) { if (players.indexOf(p) >= 0) players = players.filter(x => x !== p) }
    function keptLoaded(p) { return players.indexOf(p) >= 0 && players.indexOf(p) < maxLoadedPlayers }

    // SponsorBlock's categories with their colours on sponsor.ajay.app (RRGGBB), and which can be skipped (the
    // highlight is a point, exclusive access means the whole video). Settings: sb_<id> = "skip" | "show" | "off".
    readonly property var sponsorCategories: [
        { id: "sponsor", name: "Sponsor", color: "00d400", skippable: true },
        { id: "selfpromo", name: "Unpaid / self promotion", color: "ffff00", skippable: true },
        { id: "interaction", name: "Interaction reminder", color: "cc00ff", skippable: true },
        { id: "intro", name: "Intermission / intro", color: "00ffff", skippable: true },
        { id: "outro", name: "Endcards / credits", color: "0202ed", skippable: true },
        { id: "preview", name: "Preview / recap", color: "008fd6", skippable: true },
        { id: "music_offtopic", name: "Non-music section", color: "ff9900", skippable: true },
        { id: "filler", name: "Filler tangent", color: "7300ff", skippable: true },
        { id: "poi_highlight", name: "Highlight", color: "ff1684", skippable: false },
        { id: "exclusive_access", name: "Exclusive access", color: "008a5c", skippable: false }
    ]
    // The Subscriptions page's tab (0 Videos, 1 Live), shared by the windows: one opened from the Live tab
    // (a video in a new window) shows the Live tab when its player is closed, not Videos.
    property int subscriptionsTab: 0

    function isSubscribed(id) { return !!id && subscriptions.some(s => s.id === id) }

    function setSubscribed(channel, on) {
        const list = subscriptions.filter(s => s.id !== channel.id)
        if (on)
            list.push({ id: channel.id, name: channel.name || channel.id, thumbnail: channel.thumbnail || "" })
        subscriptions = list
        Store.save("subscriptions", list)
    }

    // Adds channels that are not subscribed yet; returns how many were new.
    function addSubscriptions(channels) {
        const known = new Set(subscriptions.map(s => s.id))
        const added = channels.filter(c => c.id && !known.has(c.id))
        if (added.length) {
            subscriptions = subscriptions.concat(added)
            Store.save("subscriptions", subscriptions)
        }
        return added.length
    }

    // Fills in a subscribed channel's name/avatar once its page has been seen.
    function updateChannel(info) {
        const i = subscriptions.findIndex(s => s.id === info.id)
        if (i < 0) return
        const s = subscriptions[i]
        const name = info.name || s.name, thumbnail = info.avatar || s.thumbnail
        if (name === s.name && thumbnail === s.thumbnail) return
        const list = subscriptions.slice()
        list[i] = Object.assign({}, s, { name: name, thumbnail: thumbnail })
        subscriptions = list
        Store.save("subscriptions", list)
    }

    // --- whether feed videos have started (the RSS feed can't tell), in Data/video-states.json:
    //     videoId -> {u: upcoming, p: premiere (else a scheduled stream), l: live, s: scheduled start (ms),
    //     t: when looked up}

    property var videoStates: Store.load("video-states", {})
    property int videoStatesRevision: 0

    function addVideoStates(found) {
        const now = Date.now()
        for (const id in found)
            videoStates[id] = { u: found[id].upcoming, p: found[id].premiere, l: found[id].live, s: found[id].start, t: now }
        const all = Object.keys(videoStates)
        for (const k of all.slice(0, Math.max(0, all.length - 5000))) delete videoStates[k]   // oldest go first
        videoStatesRevision++
        Store.save("video-states", videoStates)
    }

    // --- what was chosen for a video, used when it is opened again: videoId -> {speed, quality (height,
    //     0 = Auto), caption (track label, "" = off)}, in Data/video-prefs.json

    property var videoPrefs: Store.load("video-prefs", {})
    function videoPref(id) { return videoPrefs[id] || {} }
    function setVideoPref(id, patch) {
        if (!id) return
        const p = Object.assign({}, videoPrefs[id] || {}, patch)
        delete videoPrefs[id]               // re-added last: the oldest go first
        videoPrefs[id] = p
        const all = Object.keys(videoPrefs)
        for (const k of all.slice(0, Math.max(0, all.length - 3000))) delete videoPrefs[k]
        Store.save("video-prefs", videoPrefs)
    }

    // --- durations the RSS feed lacks: videoId -> "12:34" ("" = looked up, none found), in Data/durations.json

    property var durations: Store.load("durations", {})
    property int durationsRevision: 0       // bumped when durations are added (for bindings)

    function addDurations(found) {
        const keys = Object.keys(found)
        if (!keys.length) return
        for (const k of keys)
            if (found[k] || durations[k] === undefined) durations[k] = found[k]
        const all = Object.keys(durations)
        for (const k of all.slice(0, Math.max(0, all.length - 30000))) delete durations[k]   // oldest go first
        durationsRevision++
        Store.save("durations", durations)
    }

    // --- members-only videos (only the channel's members can watch them; YouTube sends this app no stream):
    // videoId -> true / false (looked up), in Data/members-only.json. RSS doesn't tell: the channels' Videos tabs
    // do (SubscriptionsPage.fillDurations), and a video YouTube refused as members-only is added (PlayerView).
    property var membersOnly: Store.load("members-only", {})
    property int membersOnlyRevision: 0
    function addMembersOnly(found) {
        const keys = Object.keys(found)
        if (!keys.length) return
        for (const k of keys) membersOnly[k] = !!found[k]
        const all = Object.keys(membersOnly)
        for (const k of all.slice(0, Math.max(0, all.length - 30000))) delete membersOnly[k]   // oldest go first
        membersOnlyRevision++
        Store.save("members-only", membersOnly)
    }
    function isMembersOnly(id) { return membersOnlyRevision >= 0 && membersOnly[id] === true }

    // --- history: newest first, [{videoId, title, channel, channelId, duration, thumbnail, watchedAt, position, length}]

    property var history: Store.load("history", [])
    property var historyIndex: ({})     // videoId -> entry
    property int historyRevision: 0     // bumps on every change, for bindings that read historyIndex

    function rebuildIndex() {
        const index = {}
        for (const h of history)
            index[h.videoId] = h
        historyIndex = index
        historyRevision++
    }

    function recordWatch(video) {
        if (!settings.rememberHistory || !video || !video.videoId) return
        const old = historyIndex[video.videoId]
        const entry = {
            videoId: video.videoId, title: video.title || (old ? old.title : ""), channel: video.channel || "",
            channelId: video.channelId || "", duration: video.duration || (old ? old.duration : ""),
            thumbnail: video.thumbnail || "https://i.ytimg.com/vi/" + video.videoId + "/mqdefault.jpg",
            watchedAt: Date.now(), position: old ? old.position : 0, length: old ? old.length : 0
        }
        history = [entry].concat(history.filter(h => h.videoId !== video.videoId)).slice(0, 5000)
        rebuildIndex()
        saveSoon()
    }

    function updateProgress(videoId, position, length) {
        const h = historyIndex[videoId]
        if (!h || !(length > 0)) return
        h.position = position
        h.length = length
        if (!h.duration) {          // RSS items have no duration; take it from the player
            const t = Math.round(length), hh = Math.floor(t / 3600), mm = Math.floor(t % 3600 / 60), ss = t % 60
            h.duration = (hh ? hh + ":" + String(mm).padStart(2, "0") : mm) + ":" + String(ss).padStart(2, "0")
        }
        historyRevision++
        saveSoon()
    }

    // Where to continue a video, or 0 (not near the start or end, and resuming enabled).
    function resumePosition(videoId) {
        const h = historyIndex[videoId]
        if (!settings.resume || !h || !(h.length > 0)) return 0
        return h.position > 10 && h.position < h.length - 20 ? h.position : 0
    }

    function removeHistory(videoId) {
        history = history.filter(h => h.videoId !== videoId)
        rebuildIndex()
        saveSoon()
    }

    function clearHistory() {
        history = []
        rebuildIndex()
        Store.save("history", [])
    }

    property Timer saveTimer: Timer {
        interval: 2000
        onTriggered: Store.save("history", app.history)
    }
    function saveSoon() { saveTimer.restart() }
    function flush() { if (saveTimer.running) { saveTimer.stop(); Store.save("history", history) } }

    Component.onCompleted: { rebuildIndex(); started = true }
}
