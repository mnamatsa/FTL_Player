import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Window

// The video player with its details: title, channel (clickable) with Subscribe, speed and quality.
// Used in the main window and in separate player windows.
Item {
    id: view
    clip: true                          // the video window is cut to this (see MpvItem::syncChildWindow)

    property var video: null            // the video being watched (card object)
    property var stream: null           // the helper's stream reply for it
    property string status: ""
    readonly property alias player: player
    signal openChannel(var channel)     // {id, name}

    // "Auto" quality: the height of the screen the window is on.
    readonly property int screenHeight: Math.max(720, Math.round(Screen.height * Screen.devicePixelRatio))
    readonly property int maxHeight: AppState.settings.quality > 0 ? AppState.settings.quality : screenHeight

    function ago(t) {
        // years and months by the calendar (365-day years made Oct 25, 2009 "17 years ago" on Oct 24, 2026)
        const now = new Date(), then = new Date(t)
        let months = (now.getFullYear() - then.getFullYear()) * 12 + now.getMonth() - then.getMonth()
        if (now.getDate() < then.getDate()) months--
        if (months >= 12) { const v = Math.floor(months / 12); return v + " year" + (v > 1 ? "s" : "") + " ago" }
        if (months >= 1) return months + " month" + (months > 1 ? "s" : "") + " ago"
        const s = Math.max(0, (Date.now() - t) / 1000)
        const units = [[604800, "week"], [86400, "day"], [3600, "hour"], [60, "minute"]]
        for (const [n, name] of units)
            if (s >= n) { const v = Math.floor(s / n); return v + " " + name + (v > 1 ? "s" : "") + " ago" }
        return "just now"
    }

    // 19495992 -> "19M", 1234 -> "1.2K", as YouTube shortens counts (one decimal below 10).
    function shortCount(n) {
        for (const [v, unit] of [[1e9, "B"], [1e6, "M"], [1e3, "K"]])
            if (n >= v) { const x = n / v; return (x < 10 ? Math.floor(x * 10) / 10 : Math.floor(x)) + unit }
        return String(n)
    }

    function codecName(c) { return ({ avc1: "H.264", vp9: "VP9", vp09: "VP9", av01: "AV1" })[c] || c.toUpperCase() }
    function streamStatus(r) {
        if (r.hls) return "Live · " + (r.liveHeight ? r.liveHeight + "p" : "HLS") + " " + codecName(r.liveCodec || "avc1") + " · via " + (r.liveVia || r.client)
        return r.video.label + " " + r.video.codec.toUpperCase() + " · " + r.audio.codec + " · via " + r.client
    }

    // --- playlist (when the video was opened from a playlist): a panel beside the player, next video at the end
    property var playlist: null         // {playlistId, title, channel, channelId, count}
    property int playlistIndex: -1
    property string playlistContinuation: ""
    property bool playlistLoading: false
    readonly property bool showPlaylist: !!playlist && !player.fullscreen
    ListModel { id: playlistModel }
    readonly property ListModel playlistItems: playlistModel   // for PlaylistList

    function playlistVideo(i) {
        const m = playlistModel.get(i)
        return { videoId: m.videoId, title: m.title, channel: m.channel, channelId: m.channelId, duration: m.duration,
                 views: m.views, published: m.published, live: m.live, upcoming: m.upcoming, thumbnail: m.thumbnail }
    }

    function openPlaylist(info, startIndex) {
        saveProgress()
        player.endTyping()     // keys go to the player, not the search field typed in before
        player.stop()
        playlist = info
        playlistModel.clear()
        playlistIndex = -1
        playlistContinuation = ""
        playlistLoading = true
        stream = null
        video = { videoId: "", title: info.title || "Playlist", channel: info.channel || "", channelId: info.channelId || "" }
        if (info.localId) {     // a saved playlist: its videos are here already (fields as playlistVideo reads them)
            const p = AppState.playlistById(info.localId)
            playlistLoading = false
            playlist = Object.assign({}, info, { title: p ? p.name : info.title, playlistId: "local:" + info.localId })
            for (const v of p ? p.videos : [])
                playlistModel.append({ videoId: v.videoId, title: v.title, channel: v.channel, channelId: v.channelId,
                                       duration: v.duration, views: v.views, published: v.published, live: false,
                                       upcoming: false, thumbnail: v.thumbnail })
            if (playlistModel.count) playIndex(Math.min(startIndex || 0, playlistModel.count - 1))
            else status = "This playlist is empty."
            return
        }
        status = "Loading playlist…"
        const pid = info.playlistId
        Helper.call("playlist", { playlistId: pid }, function (r) {
            if (!playlist || playlist.playlistId !== pid) return
            playlistLoading = false
            if (!r.ok) { status = r.error; return }
            playlist = Object.assign({}, info, r.info)
            playlistModel.append(r.items)
            playlistContinuation = r.continuation || ""
            if (playlistModel.count) playIndex(Math.min(startIndex || 0, playlistModel.count - 1))
            else status = "This playlist has no playable videos."
        })
    }

    function loadMorePlaylist(then) {
        if (!playlist || playlistLoading || !playlistContinuation) return
        playlistLoading = true
        const pid = playlist.playlistId
        Helper.call("playlist", { continuation: playlistContinuation }, function (r) {
            if (!playlist || playlist.playlistId !== pid) return
            playlistLoading = false
            if (!r.ok) { playlistContinuation = ""; return }
            playlistModel.append(r.items)
            playlistContinuation = r.continuation || ""
            if (then) then()
        })
    }

    function playIndex(i) {
        if (i < 0 || i >= playlistModel.count) return
        playlistIndex = i
        open(playlistVideo(i), true)
    }
    function nextInPlaylist() {
        if (!playlist) return
        if (playlistIndex + 1 < playlistModel.count) playIndex(playlistIndex + 1)
        else loadMorePlaylist(() => playIndex(playlistIndex + 1))
    }
    function previousInPlaylist() { if (playlist && playlistIndex > 0) playIndex(playlistIndex - 1) }

    // Reopens the current video at the current position (e.g. when a stream got stuck).
    function reload() {
        if (!video || !video.videoId) return
        open(video, !!playlist, unloaded ? unloadedAt : player.timePos())
    }

    // A video whose stream broke off (the network gone, e.g. after the PC slept: the helper's own retries gave
    // up, or the stream links expired) is opened again where it stopped, with new links: after 2, 5, 10, 20,
    // 30 and 30 s, while the lookup fails too. Tries count again once it played for a minute.
    property var recovering: null       // {videoId, at, tries, last}
    readonly property var recoveryDelays: [2, 5, 10, 20, 30, 30]
    function recover(at) {
        if (!video || !video.videoId) return
        const now = Date.now()
        if (!recovering || recovering.videoId !== video.videoId || now - recovering.last > 60000)
            recovering = { videoId: video.videoId, at: at, tries: 0, last: now }
        if (recovering.tries >= recoveryDelays.length) {
            status = "Connection lost. Reopen the video (F5) to try again."
            recovering = null
            return
        }
        const delay = recoveryDelays[recovering.tries]
        recovering = Object.assign({}, recovering, { at: at > 0 ? at : recovering.at, tries: recovering.tries + 1, last: now })
        status = "Connection lost: retrying in " + delay + " s…"
        recoveryTimer.interval = delay * 1000
        recoveryTimer.restart()
    }
    Timer {
        id: recoveryTimer
        onTriggered: if (view.recovering && view.video && view.video.videoId === view.recovering.videoId)
                         view.open(view.video, !!view.playlist, view.recovering.at)
    }

    // --- Memory (Settings > Windows): a video whose player isn't needed shows without it (details, comments, its
    // thumbnail with a play button where the video was); the player starts again where it was when the window
    // comes forward or the thumbnail is clicked. AppState.usePlayer keeps the last used ones loaded.
    property bool unloaded: false
    property real unloadedAt: 0
    property bool unloadedPaused: true
    property double streamAt: 0         // when `stream` was looked up: its links last a few hours
    property bool startDeferred: false  // (Main) opened in a background window: starts unloaded (if set so)
    readonly property bool windowActive: !!view.Window.window && view.Window.window.active
    onWindowActiveChanged: {
        if (!windowActive || !video || !stream) return
        if (unloaded) { loadPlayer(unloadedPaused); return }
        AppState.usePlayer(view)
        player.redrawVideo()     // (a paused video behind other windows may not have been drawn: see there)
    }
    Component.onDestruction: AppState.dropPlayer(view)

    function unloadPlayer() {
        if (!video || !stream || unloaded || player.fullscreen) return
        saveProgress()
        unloadedAt = Math.max(0, player.timePos())
        unloadedPaused = player.paused
        player.release()
        unloaded = true
        AppState.dropPlayer(view)
        console.info("unloaded the player of \"" + video.title + "\" at " + Math.round(unloadedAt) + " s")
        gc()        // (the interface's script memory, which is otherwise freed now and then)
    }
    function loadPlayer(pause) {
        if (!unloaded || !video) return
        unloaded = false
        if (!stream || Date.now() - streamAt > 3600000) { open(video, !!playlist, unloadedAt, pause); return }   // new links
        player.play(Object.assign({}, stream, { start: unloadedAt, pause: pause, subtitle: currentCaption() }))
        AppState.usePlayer(view)
    }
    // Settings > Windows, "time": a video paused with its window in the background unloads after a while.
    Timer {
        interval: Math.max(1, AppState.settings.unloadPausedAfter || 3) * 60000
        running: !AppState.unloadByCount && !!view.stream && !view.unloaded && view.player.paused && !view.windowActive
        onTriggered: view.unloadPlayer()
    }
    // "count": one past the ones kept loaded (it was playing when it fell behind) unloads once paused in the background.
    Connections {
        target: view.player
        function onPausedChanged() {
            if (AppState.unloadByCount && view.player.paused && !view.windowActive && view.stream && !view.unloaded
                    && AppState.players.indexOf(view) >= 0 && !AppState.keptLoaded(view))
                view.unloadPlayer()
        }
    }

    // `pause`: start paused or not (else as Settings > "Start playing automatically" says)
    function open(v, fromPlaylist, startAt, pause) {
        saveProgress()
        unloaded = false
        player.endTyping()     // keys go to the player, not the search field typed in before
        if (recovering && recovering.videoId !== v.videoId) { recovering = null; recoveryTimer.stop() }
        if (!fromPlaylist) {
            playlist = null
            playlistModel.clear()
            playlistIndex = -1
        }
        video = v
        stream = null
        sponsorSegments = []
        sendSegments()
        page.toTop()
        player.stop()
        // what was chosen for this video before (speed, quality, captions), else the defaults
        prefsLive = false
        pref = AppState.videoPref(v.videoId)
        player.speed = pref.speed || AppState.settings.speed
        status = "Loading…"
        AppState.recordWatch(v)
        const id = v.videoId
        const height = pref.quality !== undefined ? (pref.quality > 0 ? pref.quality : screenHeight) : maxHeight
        Helper.call("streams", { videoId: id, maxHeight: height, codec: AppState.settings.codec }, function (r) {
            if (!video || video.videoId !== id) return     // moved on meanwhile
            if (!r.ok) {
                if (recovering && recovering.videoId === id) recover(recovering.at)   // still no network
                else status = r.error
                return
            }
            video = Object.assign({}, v, { title: r.title || v.title, channel: r.channel || v.channel,
                                           channelId: r.channelId || v.channelId, live: r.live })
            AppState.recordWatch(video)
            stream = Object.assign({ title: video.title }, r)
            status = streamStatus(r)
            captionIndex = pickCaption(r.captions || [])
            setStoryboard(r.storyboard && !r.storyboard.live ? r.storyboard : {})   // live: liveStoryboard()
            streamAt = Date.now()
            const start = startAt > 0 ? startAt : r.hls ? 0 : AppState.resumePosition(id)
            const paused = pause !== undefined ? pause : !AppState.settings.autoplay
            if (!r.live) loadSponsorSegments(id, r.lengthSeconds || 0)
            // opened in a background window (Settings > Windows > "Open videos in background windows unloaded"):
            // it waits for its window
            const deferred = startDeferred && AppState.settings.openUnloaded !== false
            startDeferred = false
            if (deferred) {
                unloaded = true; unloadedAt = start; unloadedPaused = paused
                console.info("\"" + video.title + "\" opened without its player (" + AppState.players.length + " loaded)")
                return
            }
            player.play(Object.assign({}, stream, { start: start, pause: paused, subtitle: currentCaption() }))
            AppState.usePlayer(view)
        })
    }

    // SponsorBlock: the video's segments (helper: sponsorSegments), sent to the control bar as the settings say
    // (sb_<category>: skip / show / off); a segment for the whole video ("exclusive access") shows in the status.
    property var sponsorSegments: []
    function loadSponsorSegments(id, seconds) {
        if (!AppState.settings.sponsorBlock) return
        Helper.call("sponsorSegments", { videoId: id, duration: seconds }, function (r) {
            if (!video || video.videoId !== id || !r.ok) return
            sponsorSegments = r.segments || []
            sendSegments()
            if (!(stream && stream.chapters && stream.chapters.length)) sendChapters()   // SponsorBlock's may do
        })
    }

    // Chapters: YouTube's or the description's (helper: chapters), else SponsorBlock's community ones; given to
    // mpv as its chapter list once the video has loaded (seek bar gaps, "Chapter: ..." on hover).
    readonly property var chapters: {
        if (!AppState.settings.chapters) return []        // turned off in Settings
        if (stream && stream.chapters && stream.chapters.length) return stream.chapters
        return sponsorSegments.filter(s => s.category === "chapter" && s.description)
            .map(s => ({ start: s.start, title: s.description })).sort((a, b) => a.start - b.start)
    }
    function sendChapters() {
        player.controlBarMessage("ftl-chapters", JSON.stringify(chapters.map(c => ({ time: c.start, title: c.title }))))
    }
    property int chapterIndex: -1           // the chapter playing (the chapter list below the description)
    Timer {
        interval: 1000
        repeat: true
        running: view.chapters.length > 0 && view.visible
        onTriggered: {
            const t = player.timePos()
            let i = -1
            for (let k = 0; k < view.chapters.length && view.chapters[k].start <= t + 0.5; k++) i = k
            view.chapterIndex = i
        }
    }
    function timeText(s) {
        s = Math.floor(s)
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60
        return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(sec).padStart(2, "0")
    }
    function sendSegments() {
        const s = AppState.settings, list = [], whole = []
        for (const seg of s.sponsorBlock ? sponsorSegments : []) {
            const cat = AppState.sponsorCategories.find(c => c.id === seg.category)
            const mode = cat ? s["sb_" + cat.id] || "off" : "off"
            if (mode === "off") continue
            if (seg.action === "full") { whole.push(cat.name); continue }
            const bgr = cat.color.slice(4, 6) + cat.color.slice(2, 4) + cat.color.slice(0, 2)    // ASS colours
            const a = seg.action === "poi" ? "poi" : mode !== "skip" ? "show" : seg.action === "mute" ? "mute" : "skip"
            list.push({ s: seg.start, e: seg.end, a: a, n: cat.name.toLowerCase(), c: bgr })
        }
        player.controlBarMessage("ftl-segments", JSON.stringify(list))
        sponsorWhole = whole.join(", ")
    }
    property string sponsorWhole: ""     // e.g. "Exclusive access": shown with the stream status
    Connections {
        target: AppState
        function onSettingsChanged() {
            view.sendSegments()
            view.sendChapters()
            if (view.previewOn !== (AppState.settings.preview !== false)) view.setStoryboard(view.storyboardData)
        }
    }

    // Seek bar previews: the video's storyboard, given to the player unless Settings > Player > "Show seek bar
    // preview" is off (then the control bar shows the chapter name above the time instead of above the picture).
    property var storyboardData: ({})
    property bool previewOn: true
    function setStoryboard(board) {
        storyboardData = board
        previewOn = AppState.settings.preview !== false
        player.setStoryboard(previewOn ? board : {})
    }

    property var liveRecoveries: []     // when onEnded reopened a live stream (times)
    function liveRecovery() {
        const now = Date.now()
        liveRecoveries = liveRecoveries.filter(t => now - t < 30000)
        if (liveRecoveries.length >= 3) return false
        liveRecoveries = liveRecoveries.concat([now])
        return true
    }

    // Seek bar previews of a live (DVR) stream: its storyboard has one picture per segment, numbered like the
    // segments. Once the stream has loaded, the helper knows which segment the player's timeline starts with and
    // how long segments are (also again after a quality change: another playlist).
    function liveStoryboard() {
        const s = stream
        if (!s || !s.hls || !s.storyboard || !s.storyboard.live) return
        const url = s.hls
        Helper.call("liveTimeline", { url: url }, function (r) {
            if (!stream || stream.hls !== url || !r.ok || !(r.first >= 0) || !(r.segment > 0)) return
            setStoryboard(Object.assign({}, s.storyboard, { offset: r.first, interval: r.segment * 1000, count: 2147483647 }))
        })
    }

    // The current video's saved choices; changes are recorded once it plays (not the defaults it opens with).
    property var pref: ({})
    property bool prefsLive: false
    function rememberChoice(patch) {
        if (!video || !video.videoId) return
        AppState.setVideoPref(video.videoId, patch)
        pref = AppState.videoPref(video.videoId)
    }

    // The shutdown timer's time is up: pause, with the position saved.
    function pauseForTimer() {
        if (!video || !stream) return
        player.setPaused(true)
        saveProgress()
    }

    function close() {
        saveProgress()
        recovering = null
        recoveryTimer.stop()
        playlist = null
        playlistModel.clear()
        playlistIndex = -1
        setStoryboard({})
        player.release()
        unloaded = false
        AppState.dropPlayer(view)
        video = null
        stream = null
        status = ""
    }

    function saveProgress() {
        if (video && stream && !stream.hls && !unloaded)     // (an unloaded player has no position: it was saved)
            AppState.updateProgress(video.videoId, player.timePos(), player.duration())
    }

    // Quality picker entries: Auto, then every resolution the video offers.
    readonly property var qualityOptions: {
        if (stream && stream.hls) {
            const ls = stream.liveQualities || []
            if (!ls.length) return []
            const auto = ls.find(q => q.height <= screenHeight) || ls[ls.length - 1]
            return [{ text: "Auto (" + auto.label + ")", height: 0, url: auto.url }]
                .concat(ls.map(q => ({ text: q.label, height: q.height, url: q.url })))
        }
        const qs = stream && stream.qualities ? stream.qualities : []
        if (!qs.length) return []
        const auto = qs.find(q => q.height <= screenHeight) || qs[qs.length - 1]
        const codec = { av01: " AV1", avc1: " H.264" }
        const playing = AppState.settings.quality > 0 || !stream.video ? auto : stream.video
        return [{ text: "Auto (" + playing.label + ")", height: 0, itag: playing.itag }]
            .concat(qs.map(q => ({ text: q.label + (codec[q.codec] || ""), height: q.height, itag: q.itag })))
    }
    readonly property int qualityIndex: {
        const chosen = pref.quality !== undefined ? pref.quality : AppState.settings.quality
        if (stream && stream.hls && chosen > 0)
            return Math.max(0, qualityOptions.findIndex((o, n) => n > 0 && o.url === stream.hls))
        if (!stream || !stream.video || !(chosen > 0)) return 0
        return Math.max(0, qualityOptions.findIndex((o, n) => n > 0 && o.itag === stream.video.itag))
    }

    function chooseQuality(index) {
        const o = qualityOptions[index]
        if (!o) return
        AppState.setSetting("quality", o.height)     // also used for the next videos
        rememberChoice({ quality: o.height })        // and for this one when it is opened again
        if (stream.hls) {                            // live: play that resolution's playlist from here
            if (o.url === stream.hls) return
            const resumeAt = player.timePos()
            const q = stream.liveQualities.find(q => q.url === o.url) || {}
            stream = Object.assign({}, stream, { hls: o.url, liveHeight: q.height || 0, liveCodec: q.codec || "avc1", liveVia: q.via || "" })
            player.play(Object.assign({}, stream, { start: resumeAt, pause: player.paused, subtitle: currentCaption() }))
            status = streamStatus(stream)
            return
        }
        if (o.itag === stream.video.itag) return
        const id = video.videoId
        status = "Switching to " + o.text + "…"
        Helper.call("format", { videoId: id, itag: o.itag }, function (r) {
            if (!video || video.videoId !== id) return
            if (!r.ok) { status = r.error; return }
            const resumeAt = player.timePos()
            stream = Object.assign({}, stream, { video: r.video })
            player.play(Object.assign({}, stream, { start: resumeAt, pause: player.paused, subtitle: currentCaption() }))
            status = streamStatus(stream)
        })
    }

    // Audio tracks (dubbed languages): the original first, then alphabetically.
    readonly property var audioOptions: stream && stream.audioTracks
        ? stream.audioTracks.slice().sort((a, b) => (b.original - a.original) || a.label.localeCompare(b.label)) : []
    function audioLabel(t) { return t.label + (t.original && !/original/i.test(t.label) ? " (original)" : "") }
    readonly property int audioIndex: stream && stream.audio
        ? audioOptions.findIndex(t => t.itag === stream.audio.itag && t.track === stream.audio.track) : -1

    // Switches the audio track at the current position (like a quality change).
    function chooseAudio(index) {
        const t = audioOptions[index]
        if (!t || index === audioIndex) return
        const id = video.videoId
        status = "Switching audio to " + t.label + "…"
        Helper.call("format", { videoId: id, itag: t.itag, track: t.track }, function (r) {
            if (!video || video.videoId !== id) return
            if (!r.ok) { status = r.error; return }
            const resumeAt = player.timePos()
            stream = Object.assign({}, stream, { audio: r.audio })
            player.play(Object.assign({}, stream, { start: resumeAt, pause: player.paused, subtitle: currentCaption() }))
            status = streamStatus(stream) + " · " + r.audio.label
        })
    }

    // Captions: "Off", then the video's tracks (made by people first, then auto-generated).
    property int captionIndex: 0        // 0 = off, n = stream.captions[n - 1]
    readonly property var captionOptions: stream && stream.captions && stream.captions.length
                                          ? ["Off"].concat(stream.captions.map(t => t.label)) : []

    // With captions turned on, the first track in the preferred language (people-made over auto-generated).
    function pickCaption(tracks) {
        if (!tracks.length) return 0
        if (pref.caption !== undefined) {           // chosen for this video before: that track, or off
            if (!pref.caption) return 0
            const same = tracks.findIndex(t => t.label === pref.caption)
            if (same >= 0) return same + 1
        }
        if (!AppState.settings.captions) return 0
        const want = (AppState.settings.captionLanguage || "en").split("-")[0]
        const match = t => t.lang.split("-")[0] === want
        let i = tracks.findIndex(t => match(t) && !t.auto)
        if (i < 0) i = tracks.findIndex(match)
        return i + 1
    }
    function currentCaption() {
        const t = captionIndex > 0 && stream && stream.captions ? stream.captions[captionIndex - 1] : null
        return t ? { url: t.url, title: t.label, lang: t.lang } : null
    }
    function chooseCaption(index) {
        captionIndex = index
        const t = currentCaption()
        if (t) AppState.setSettings({ captions: true, captionLanguage: t.lang })
        else AppState.setSetting("captions", false)
        rememberChoice({ caption: t ? t.title : "" })
        player.setSubtitle(t ? t.url : "", t ? t.title : "", t ? t.lang : "")
    }

    readonly property var speeds: [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    function speedText(s) { return (Math.round(s * 100) / 100) + "×" }

    Timer {
        interval: 5000
        repeat: true
        running: !!view.stream && !view.unloaded && !view.player.paused
        onTriggered: view.saveProgress()
    }
    Connections {
        target: player
        function onFailed(error) {
            if (view.stream && !view.stream.hls) { view.recover(player.timePos()); return }   // (see recover)
            view.status = "Playback error: " + error
        }
        function onEnded() {
            // A video that "ended" well before its length: its stream broke off (see recover)
            const length = view.stream && !view.stream.hls ? view.stream.lengthSeconds || player.duration() : 0
            const pos = player.timePos()
            if (length > 0 && pos > 0 && pos < length - 5) { view.recover(pos); return }
            // A live stream that "ended" right after a seek broke off there: in the 4K streams (WebM segments)
            // a seek that interrupts a read made mpv give up and go to the end. Opened again where that seek
            // went (at most 3 times in 30 s, so a stream that really ended stays ended).
            const at = view.stream && view.stream.hls ? player.recentSeekTarget() : -1
            if (at >= 0 && view.liveRecovery()) {
                player.play(Object.assign({}, view.stream, { start: at, pause: false, subtitle: view.currentCaption() }))
                return
            }
            view.saveProgress()
            // the shutdown timer set for the end of this video / playlist takes over (no next video then)
            const last = !view.playlist || (view.playlistIndex + 1 >= playlistModel.count && !view.playlistContinuation)
            if (SleepTimer.videoEnded(last)) return
            if (view.playlist) view.nextInPlaylist()   // playlists continue with the next video
        }
        function onPlaylistRequested(which) {
            if (which === "next") view.nextInPlaylist()
            else view.previousInPlaylist()
        }
    }

    // Speed, quality and captions buttons in mpv's control bar (also in fullscreen). Clicking one opens
    // its menu at the pointer, as a native window above the video.
    readonly property string qualityButton: !stream ? "Auto" : stream.hls ? (stream.liveHeight ? stream.liveHeight + "p" : "Auto")
                                            : stream.video ? stream.video.label : "Auto"
    // Captions and audio use the control bar's own subtitle / audio icons (mpv-osd-symbols U+E107 / U+E106).
    readonly property string captionsButton: "{\\fnmpv-osd-symbols" + (captionIndex > 0 ? "\\1c&H4242F0&}" : "\\alpha&H70&}") + ""
    readonly property string audioButton: audioOptions.length > 1 ? "{\\fnmpv-osd-symbols}" : ""
    function updateControlButtons() {
        player.setControlButtons(speedText(player.speed), qualityButton, captionsButton, audioButton)
        player.setControlBarOption("ftl_playlist", playlist ? "yes" : "no")
        player.setControlBarOption("ftl_live", stream && stream.hls ? "yes" : "no")
        player.setControlBarOption("ftl_thumb_scale", String(previewScale))
    }
    readonly property real previewScale: AppState.settings.previewScale || 1
    onPreviewScaleChanged: updateControlButtons()
    onStreamChanged: updateControlButtons()
    onQualityButtonChanged: updateControlButtons()
    onCaptionsButtonChanged: updateControlButtons()
    onAudioButtonChanged: updateControlButtons()
    onPlaylistChanged: updateControlButtons()

    Connections {
        target: player
        function onSpeedChanged() {
            view.updateControlButtons()
            if (view.prefsLive) view.rememberChoice({ speed: player.speed })
        }
        function onStarted() { view.updateControlButtons(); view.prefsLive = true; view.liveStoryboard(); view.sendSegments(); view.sendChapters() }
        function onSpeedStepRequested(direction) {
            const s = Math.round((player.speed + direction * AppState.settings.speedStep) * 100) / 100
            player.speed = Math.max(0.25, Math.min(4, s))
        }
        function onMenuRequested(which, x, y, barTop) {
            const menus = { speed: speedMenu, quality: qualityMenu, captions: captionsMenu, audio: audioMenu }
            if (menus[which]) view.openMenu(menus[which], x, barTop)
        }
    }

    // A control bar menu opens above the bar (barTop over the video), centred on the clicked button (px),
    // inside the player.
    function openMenu(m, px, barTop) {
        // (the height from the entries: a menu that hasn't been shown yet doesn't know its own height)
        const w = m.width, h = Math.max(m.implicitHeight, Math.max(1, m.labels.length) * 30 + m.topPadding + m.bottomPadding)
        const x = Math.max(player.x + 4, Math.min(player.x + player.width - w - 4, player.x + px - w / 2))
        const y = Math.max(player.y + 4, player.y + barTop - h - 8)
        m.popup(x, y)
    }

    // Compact and see-through, like YouTube's player menus.
    component ChoiceMenu: Menu {
        id: choiceMenu
        property var labels: []
        property int current: -1
        property string emptyText: ""
        signal chosen(int index)
        popupType: Popup.Window
        width: 150
        topPadding: 4
        bottomPadding: 4
        leftPadding: 4
        rightPadding: 4
        background: Rectangle { color: "#cc161616"; radius: 10 }
        // the menu takes the pointer from the video, which would otherwise hide the bar
        onOpened: player.holdControlBar(true)
        onClosed: { player.holdControlBar(false); player.focusVideo() }
        Instantiator {
            model: choiceMenu.labels
            delegate: MenuItem {
                id: choice
                required property int index
                required property var modelData
                text: modelData
                checkable: true
                checked: index === choiceMenu.current
                implicitHeight: 30
                leftPadding: 30
                font.pixelSize: 13
                // a small check mark instead of the style's check box
                indicator: Label {
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: choice.checked ? "✓" : ""
                    color: "#f04242"
                    font.pixelSize: 14
                    font.bold: true
                }
                contentItem: Label {
                    text: choice.text
                    font: choice.font
                    color: "white"
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle { radius: 6; color: choice.highlighted ? "#33ffffff" : "transparent" }
                onTriggered: choiceMenu.chosen(index)
            }
            onObjectAdded: (index, object) => choiceMenu.insertItem(index, object)
            onObjectRemoved: (index, object) => choiceMenu.removeItem(object)
        }
        MenuItem { text: choiceMenu.emptyText; enabled: false; visible: choiceMenu.labels.length === 0; height: visible ? implicitHeight : 0 }
    }
    ChoiceMenu {
        id: speedMenu
        labels: view.speeds.map(s => view.speedText(s))
        current: view.speeds.indexOf(Math.round(player.speed * 100) / 100)
        onChosen: (index) => player.speed = view.speeds[index]
    }
    ChoiceMenu {
        id: qualityMenu
        labels: view.qualityOptions.map(o => o.text)
        current: view.qualityIndex
        emptyText: "Loading…"
        onChosen: (index) => view.chooseQuality(index)
    }
    ChoiceMenu {
        id: captionsMenu
        width: 230
        labels: view.captionOptions
        current: view.captionIndex
        emptyText: "This video has no captions"
        onChosen: (index) => view.chooseCaption(index)
    }
    ChoiceMenu {
        id: audioMenu
        width: 230
        labels: view.audioOptions.map(t => view.audioLabel(t))
        current: view.audioIndex
        onChosen: (index) => view.chooseAudio(index)
    }

    Timer {         // saves the volume once it stops changing (dragging the slider changes it a lot)
        id: saveVolume
        interval: 600
        onTriggered: AppState.setSettings({ volume: Math.round(player.volume), muted: player.muted })
    }
    MpvVideo {
        id: player
        speedStep: AppState.settings.speedStep
        // key -> command, from the hotkey settings
        hotkeys: {
            const k = AppState.hotkeys, s = AppState.settings
            const shortJump = s.seekStep || 5, longJump = Math.round(shortJump * (s.jumpMultiplier || 2) * 100) / 100
            const commands = {
                speedDown: "no-osd script-message ftl-speed -1", speedUp: "no-osd script-message ftl-speed 1",
                seekBack: "script-message-to osc ftl-jump -" + shortJump, seekForward: "script-message-to osc ftl-jump " + shortJump,
                jumpBack: "script-message-to osc ftl-jump -" + longJump, jumpForward: "script-message-to osc ftl-jump " + longJump,
                frameBack: "script-message-to osc ftl-frame -1", frameForward: "script-message-to osc ftl-frame 1"
            }
            const map = {}
            for (const action in commands)
                if (k[action]) map[k[action]] = commands[action]
            return map
        }
        hardwareDecoding: AppState.settings.hardwareDecoding
        gpu: AppState.settings.gpu || "auto"
        wheelVolume: AppState.settings.wheelVolume
        wheelSeek: AppState.settings.wheelSeek
        wheelSpeed: AppState.settings.wheelSpeed
        // the volume carries over between videos (and windows)
        Component.onCompleted: { volume = AppState.settings.volume; muted = AppState.settings.muted }
        onVolumeChanged: if (Math.abs(volume - AppState.settings.volume) >= 0.5) saveVolume.restart()
        onMutedChanged: if (muted !== AppState.settings.muted) saveVolume.restart()
        // total time or time left on the right: kept too (other windows follow)
        timeTotal: AppState.settings.timeTotal
        onTimeTotalChanged: if (timeTotal !== AppState.settings.timeTotal) AppState.setSetting("timeTotal", timeTotal)
        onWheelScroll: (delta) => { if (!player.fullscreen) page.wheelScroll(delta) }
        x: player.fullscreen ? 0 : 16
        y: player.fullscreen ? 0 : 16 - (page.contentY - page.originY)    // scrolls up with the page below it
        width: player.fullscreen ? view.width
                                 : Math.min(view.width - 32 - (view.showPlaylist ? playlistPanel.width + 16 : 0),
                                            (view.height - 120) * 16 / 9)
        height: player.fullscreen ? view.height : width * 9 / 16
        visible: view.visible && view.video !== null && !view.unloaded
    }
    // An unloaded player (see unloadPlayer): the video's thumbnail where it was, a click goes on from there
    Rectangle {
        x: player.x
        y: player.y
        width: player.width
        height: player.height
        visible: view.visible && view.unloaded && view.video !== null
        z: 1                // (above the page below, whose top is room for the video)
        color: "black"
        // the video's large thumbnail, over the card's smaller one (shown until it loads, or if it can't)
        Image {
            anchors.fill: parent
            source: view.video && view.video.thumbnail ? view.video.thumbnail : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            opacity: 0.6
        }
        Image {
            anchors.fill: parent
            source: view.video && view.video.videoId ? "https://i.ytimg.com/vi/" + view.video.videoId + "/hqdefault.jpg" : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            opacity: 0.6
            visible: status === Image.Ready
        }
        Rectangle {
            anchors.centerIn: parent
            width: 84
            height: 84
            radius: 42
            color: unloadedHover.hovered ? "#e53935" : "#cc000000"
            Label {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: 4
                text: "▶"
                font.pixelSize: 38
                color: "white"
            }
        }
        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18
            text: view.unloadedAt > 0 ? "Unloaded to save memory · continues at " + view.timeText(view.unloadedAt)
                                      : "Not loaded yet, to save memory · click to play"
            color: "white"
            font.pixelSize: 14
            style: Text.Outline
            styleColor: "#000000"
        }
        HoverHandler { id: unloadedHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: view.loadPlayer(false) }
    }

    // Below the video: its details and the comments, as one list that scrolls; the video moves up with it.
    Comments {
        id: page
        visible: !player.fullscreen && view.video !== null
        anchors.fill: parent
        anchors.rightMargin: view.showPlaylist ? playlistPanel.width + 16 : 0
        columnX: 16
        columnWidth: player.width
        topSpace: 16 + player.height + 12
        // Live streams have a live chat instead.
        showComments: !!view.video && !view.video.live
        videoId: view.video && view.video.videoId && !view.video.live ? view.video.videoId : ""
        onOpenChannel: (channel) => view.openChannel(channel)
        textHtml: (s) => view.descriptionHtml(s)
        onLinkActivated: (link) => view.openDescriptionLink(link)
        linkClick: (item, pos, button) => view.linkClick(item, pos, button)
        details: ColumnLayout {
            spacing: 4
            Label {
                text: view.video ? view.video.title : ""
                font.pixelSize: 19
                font.bold: true
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                // The channel: its picture (the watch page's, else the subscription's) and name, both opening it
                RowLayout {
                    readonly property bool linked: !!view.video && !!view.video.channelId
                    spacing: 10
                    Avatar {
                        readonly property var sub: view.video && view.video.channelId
                                                   ? AppState.subscriptions.find(s => s.id === view.video.channelId) : null
                        visible: !!view.video && !!view.video.channel
                        source: view.stream && view.stream.channelThumbnail ? view.stream.channelThumbnail : sub ? sub.thumbnail || "" : ""
                        name: view.video ? view.video.channel || "" : ""
                        size: 36
                    }
                    Label {
                        text: view.video ? view.video.channel || "" : ""
                        font.pixelSize: 15
                        font.bold: true
                        font.underline: parent.linked && channelHover.hovered
                    }
                    HoverHandler { id: channelHover; cursorShape: parent.linked ? Qt.PointingHandCursor : Qt.ArrowCursor }
                    TapHandler {
                        enabled: parent.linked
                        onTapped: view.openChannel({ id: view.video.channelId, name: view.video.channel })
                    }
                    // middle click: the channel in a new window (as on a card); right click: a menu with both
                    TapHandler {
                        enabled: parent.linked
                        acceptedButtons: Qt.MiddleButton | Qt.RightButton
                        onTapped: (point, button) => {
                            if (button === Qt.MiddleButton) view.Window.window.openChannelInNewWindow({ id: view.video.channelId, name: view.video.channel })
                            else channelMenu.popup(parent, point.position.x, point.position.y)
                        }
                    }
                    Menu {
                        id: channelMenu
                        popupType: Popup.Window     // a window of its own: the video's native window can't cover it
                        width: 270
                        MenuItem {
                            text: "Open channel"
                            onTriggered: view.openChannel({ id: view.video.channelId, name: view.video.channel })
                        }
                        MenuItem {
                            text: "Open channel in new window"
                            onTriggered: view.Window.window.openChannelInNewWindow({ id: view.video.channelId, name: view.video.channel })
                        }
                    }
                }
                Button {
                    readonly property bool subscribed: view.video ? AppState.isSubscribed(view.video.channelId) : false
                    visible: !!view.video && !!view.video.channelId
                    text: subscribed ? "Subscribed" : "Subscribe"
                    highlighted: !subscribed
                    flat: subscribed
                    onClicked: AppState.setSubscribed({ id: view.video.channelId, name: view.video.channel }, !subscribed)
                }
                // Save to a playlist (the window's dialog; Watch later is one of them)
                Button {
                    readonly property bool saved: !!view.video && AppState.playlistsRevision >= 0
                                                  && AppState.playlists.some(p => p.videos.some(v => v.videoId === view.video.videoId))
                    visible: !!view.video && !!view.video.videoId
                    text: saved ? "Saved" : "Save"
                    flat: true
                    onClicked: view.Window.window.saveToPlaylist(view.video)
                }
                // Likes (not shown when the channel hides them); the exact number on hover
                Row {
                    readonly property real likes: view.stream && view.stream.likes > 0 ? view.stream.likes : 0
                    visible: likes > 0
                    spacing: 6
                    Image {
                        source: AppState.dark ? "assets/thumb_up.svg" : "assets/thumb_up_dark.svg"   // (white on dark, black on light)
                        sourceSize: Qt.size(20, 20)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Label {
                        text: view.shortCount(parent.likes)
                        font.pixelSize: 15
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    HoverHandler { id: likesHover }
                    ToolTip.visible: likesHover.hovered
                    ToolTip.text: Number(likes).toLocaleString(Qt.locale(), "f", 0) + " likes"
                }
                // The card's views and date, until the description box shows the exact ones (live: the box has
                // no viewer count, so "watching" stays here)
                Label {
                    text: {
                        const v = view.video
                        if (!v) return ""
                        const views = v.views ? v.views + (v.live ? " watching" : " views") : ""
                        if (descBox.visible && descBox.facts) return v.live ? views : ""
                        return [views, v.published || (v.publishedAt > 0 ? view.ago(v.publishedAt) : "")].filter(s => s).join("  •  ")
                    }
                    color: AppState.colors.secondary
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
            Label {
                text: view.status + (view.sponsorWhole ? "  ·  SponsorBlock: the whole video is " + view.sponsorWhole.toLowerCase() : "")
                color: view.status.startsWith("Playback error") || view.status.startsWith("No playable") ? AppState.colors.error : AppState.colors.faint
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            // The description, as on YouTube: a box with the exact views and date, three lines of text until
            // clicked ("...more"). Links open in the browser (YouTube videos here), timestamps seek.
            Rectangle {
                id: descBox
                property bool expanded: false
                readonly property string videoId: view.video ? view.video.videoId : ""
                onVideoIdChanged: expanded = false
                readonly property string text: view.stream && view.stream.description || ""
                readonly property string facts: {
                    const s = view.stream
                    if (!s) return ""
                    const views = !s.live && s.views > 0 ? Number(s.views).toLocaleString(Qt.locale(), "f", 0) + " views" : ""
                    const date = s.publishDate ? new Date(s.publishDate) : null
                    // "Published Oct 24, 2009 (17 years ago)" ("Premiered ...", "Streamed live on ..." as YouTube
                    // says); without a date (helper: publishedOn) the card's "3 years ago", if it came from one
                    return [views, date && !isNaN(date)
                                   ? (s.publishLabel || "Published") + " " + date.toLocaleDateString(Qt.locale(), "MMM d, yyyy")
                                     + " (" + view.ago(date.getTime()) + ")"
                                   : view.video && view.video.published || ""]
                           .filter(t => t).join("  •  ")
                }
                readonly property real collapsedHeight: descMetrics.lineSpacing * 3
                readonly property bool overflows: descText.implicitHeight > collapsedHeight + 2
                visible: text !== ""
                color: descHover.hovered && !expanded ? AppState.colors.boxHover : AppState.colors.box
                radius: 10
                implicitHeight: descColumn.implicitHeight + 20
                Layout.fillWidth: true
                Layout.topMargin: 8
                HoverHandler { id: descHover; cursorShape: descBox.expanded ? Qt.ArrowCursor : Qt.PointingHandCursor }
                TapHandler { enabled: !descBox.expanded; onTapped: descBox.expanded = true }
                FontMetrics { id: descMetrics; font: descText.font }

                ColumnLayout {
                    id: descColumn
                    x: 12
                    y: 10
                    width: parent.width - 24
                    spacing: 4
                    Label {
                        visible: text !== ""
                        text: descBox.facts
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Item {
                        clip: true
                        implicitHeight: descBox.expanded || !descBox.overflows ? descText.implicitHeight : descBox.collapsedHeight
                        Layout.fillWidth: true
                        TextEdit {
                            id: descText
                            width: parent.width
                            text: view.descriptionHtml(descBox.text)
                            textFormat: TextEdit.RichText
                            color: AppState.colors.body
                            font.pixelSize: 14
                            wrapMode: TextEdit.Wrap
                            readOnly: true
                            selectByMouse: true
                            selectionColor: "#f04242"
                            enabled: descBox.expanded || !descBox.overflows    // collapsed, a click opens the box
                            onLinkActivated: (link) => view.openDescriptionLink(link)
                            HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
                            TapHandler {
                                acceptedButtons: Qt.MiddleButton | Qt.RightButton
                                onTapped: (point, button) => view.linkClick(descText, point.position, button)
                            }
                        }
                    }
                    Label {
                        visible: descBox.overflows
                        text: descBox.expanded ? "Show less" : "...more"
                        font.pixelSize: 14
                        font.bold: true
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: descBox.expanded = !descBox.expanded }
                    }
                }
            }
            // The chapters: the one playing, and all of them when opened; a click on one goes there.
            Rectangle {
                id: chapterBox
                property bool expanded: false
                readonly property string videoId: view.video ? view.video.videoId : ""
                onVideoIdChanged: expanded = false
                visible: view.chapters.length > 0
                color: AppState.colors.box
                radius: 10
                implicitHeight: chapterColumn.implicitHeight + 20
                Layout.fillWidth: true
                Layout.topMargin: 8
                ColumnLayout {
                    id: chapterColumn
                    x: 12
                    y: 10
                    width: parent.width - 24
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            text: "Chapters"
                            font.pixelSize: 14
                            font.bold: true
                        }
                        Label {
                            text: view.chapterIndex >= 0 && view.chapters[view.chapterIndex] ? view.chapters[view.chapterIndex].title : ""
                            color: AppState.colors.secondary
                            font.pixelSize: 14
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Label {
                            text: chapterBox.expanded ? "Hide" : "All " + view.chapters.length
                            font.pixelSize: 14
                            font.bold: true
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: chapterBox.expanded = !chapterBox.expanded }
                        }
                    }
                    Repeater {
                        model: chapterBox.expanded ? view.chapters : []
                        delegate: ItemDelegate {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            implicitHeight: 32
                            topPadding: 0
                            bottomPadding: 0
                            highlighted: index === view.chapterIndex
                            contentItem: RowLayout {
                                spacing: 12
                                Label {
                                    text: view.timeText(modelData.start)
                                    color: AppState.colors.link
                                    font.pixelSize: 13
                                    Layout.preferredWidth: 56
                                }
                                Label {
                                    text: modelData.title
                                    font.pixelSize: 13
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                            onClicked: { player.seek(modelData.start); view.chapterIndex = index; page.toTop() }
                        }
                    }
                }
            }
        }
    }

    // The description as rich text: URLs and timestamps (1:23, 1:02:03) become links, the rest stays as written.
    function descriptionHtml(s) {
        const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
        const link = (href, label) => '<a href="' + esc(href) + '" style="color:#3ea6ff; text-decoration:none">' + esc(label) + "</a>"
        const re = /https?:\/\/[^\s<>"]+|\b(?:\d{1,2}:)?\d{1,2}:\d{2}\b/g
        let out = "", last = 0, m
        while ((m = re.exec(s)) !== null) {
            let token = m[0]
            if (/^http/.test(token)) token = token.replace(/[).,!?;:'"]+$/, "")     // punctuation after a URL
            out += esc(s.slice(last, m.index))
            out += /^http/.test(token) ? link(token, token)
                 : link("t:" + token.split(":").reduce((acc, p) => acc * 60 + Number(p), 0), token)
            last = m.index + token.length
            re.lastIndex = last
        }
        return '<div style="white-space:pre-wrap">' + out + esc(s.slice(last)) + "</div>"
    }
    // A timestamp seeks (and brings the video into view); a YouTube video link opens it here, at its t= if any;
    // other links open in the browser.
    function openDescriptionLink(link) {
        if (link.startsWith("t:")) {
            const t = Number(link.slice(2))
            if (t < player.duration() || player.duration() <= 0) { player.seek(t); page.toTop() }
            return
        }
        const yt = link.match(/^https?:\/\/(?:(?:www\.|m\.)?youtube\.com\/(?:watch\?(?:[^#]*&)?v=|shorts\/|live\/)|youtu\.be\/)([\w-]{11})/)
        if (yt) {
            const t = link.match(/[?&#]t=(?:(\d+)h)?(?:(\d+)m)?(\d+)?s?\b/)
            const start = t ? 3600 * (+t[1] || 0) + 60 * (+t[2] || 0) + (+t[3] || 0) : 0
            if (yt[1] === (video && video.videoId)) { if (start) { player.seek(start); page.toTop() } }
            else open({ videoId: yt[1], title: "", channel: "", channelId: "" }, false, start)
            return
        }
        Qt.openUrlExternally(link)
    }

    // The same in a new window (Main.newWindow, as "Open in new window" on a card): a timestamp opens this video
    // there at that time, a YouTube video link that video. Links that open in the browser anyway just do that.
    function videoLinkFor(link) {
        if (link.startsWith("t:"))
            return video && video.videoId ? "https://www.youtube.com/watch?v=" + video.videoId + "&t=" + link.slice(2) + "s" : ""
        return /^https?:\/\/(?:(?:www\.|m\.)?youtube\.com\/(?:watch\?(?:[^#]*&)?v=|shorts\/|live\/)|youtu\.be\/)[\w-]{11}/.test(link) ? link : ""
    }
    function openLinkInNewWindow(link) {
        const v = videoLinkFor(link)
        if (v) view.Window.window.newWindow({ startLink: v })
        else Qt.openUrlExternally(link)
    }
    // Middle click on a link in the description or a comment: a new window; right click: the link menu.
    function linkClick(item, pos, button) {
        const link = item.linkAt(pos.x, pos.y)
        if (!link) return
        if (button === Qt.MiddleButton) { openLinkInNewWindow(link); return }
        linkMenu.link = link
        linkMenu.popup(item, pos.x, pos.y)
    }
    Menu {
        id: linkMenu
        property string link: ""
        readonly property bool inApp: view.videoLinkFor(link) !== ""
        popupType: Popup.Window     // a window of its own: the video's native window can't cover it
        width: 220
        MenuItem { text: "Open"; onTriggered: view.openDescriptionLink(linkMenu.link) }
        MenuItem {
            text: "Open in new window"
            visible: linkMenu.inApp
            height: visible ? implicitHeight : 0
            onTriggered: view.openLinkInNewWindow(linkMenu.link)
        }
        MenuItem {
            text: "Open in browser"
            visible: linkMenu.inApp
            height: visible ? implicitHeight : 0
            onTriggered: Qt.openUrlExternally(view.videoLinkFor(linkMenu.link))
        }
    }

    // Fullscreen + playlist: moving the pointer to the middle of the right edge shows an arrow; clicking it opens
    // the playlist over the video. Both are small native windows, so mpv's video window can't cover them.
    property bool edgeArrowShown: false
    property bool playlistOverlayOpen: false
    readonly property var hostWindow: view.Window.window
    Timer {
        id: hideEdgeArrow
        interval: 2000
        onTriggered: if (edgeArrowHover.hovered) restart(); else view.edgeArrowShown = false
    }
    Connections {
        target: player
        function onMouseMoved(x, y) {
            if (!player.fullscreen || !view.playlist) return
            if (x > player.width - 160 && Math.abs(y - player.height / 2) < player.height * 0.22) {
                view.edgeArrowShown = true
                hideEdgeArrow.restart()
            }
        }
        function onFullscreenChanged() {
            view.edgeArrowShown = false
            view.playlistOverlayOpen = false
        }
    }
    function closePlaylistOverlay() {
        playlistOverlayOpen = false
        player.focusVideo()
    }
    Window {
        id: edgeArrow
        transientParent: view.hostWindow
        flags: Qt.Tool | Qt.FramelessWindowHint
        color: "#262626"
        width: 40
        height: 96
        x: view.hostWindow ? view.hostWindow.x + view.hostWindow.width - width - (view.playlistOverlayOpen ? playlistOverlay.width : 0) : 0
        y: view.hostWindow ? view.hostWindow.y + (view.hostWindow.height - height) / 2 : 0
        visible: player.fullscreen && !!view.playlist && (view.edgeArrowShown || view.playlistOverlayOpen)
        // Chevron pointing left (opens) or right (closes), drawn so it is centred exactly.
        Canvas {
            anchors.centerIn: parent
            width: 14
            height: 28
            readonly property bool pointRight: view.playlistOverlayOpen
            onPointRightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                ctx.strokeStyle = "white"
                ctx.lineWidth = 3
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                const a = pointRight ? 2 : width - 2, b = pointRight ? width - 2 : 2
                ctx.beginPath()
                ctx.moveTo(a, 2)
                ctx.lineTo(b, height / 2)
                ctx.lineTo(a, height - 2)
                ctx.stroke()
            }
        }
        HoverHandler { id: edgeArrowHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: view.playlistOverlayOpen ? view.closePlaylistOverlay() : view.playlistOverlayOpen = true }
    }
    Window {
        id: playlistOverlay
        transientParent: view.hostWindow
        flags: Qt.Tool | Qt.FramelessWindowHint
        color: AppState.colors.panel
        width: 420
        height: view.hostWindow ? view.hostWindow.height : 600
        x: view.hostWindow ? view.hostWindow.x + view.hostWindow.width - width : 0
        y: view.hostWindow ? view.hostWindow.y : 0
        visible: player.fullscreen && !!view.playlist && view.playlistOverlayOpen
        Material.theme: AppState.dark ? Material.Dark : Material.Light
        Material.accent: "#f04242"
        Shortcut { sequence: "Esc"; onActivated: view.closePlaylistOverlay() }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: view.playlist ? view.playlist.title || "" : ""
                    font.pixelSize: 17
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                ToolButton { text: "\u2715"; onClicked: view.closePlaylistOverlay() }
            }
            Label {
                text: view.playlist ? [view.playlist.channel, (view.playlistIndex + 1) + " / " + playlistModel.count]
                                      .filter(s => s).join("  \u2022  ") : ""
                color: AppState.colors.secondary
                font.pixelSize: 12
                Layout.bottomMargin: 6
            }
            PlaylistList {
                view: view
                Layout.fillWidth: true
                Layout.fillHeight: true
                onChosen: view.closePlaylistOverlay()
            }
        }
    }

    // Playlist panel beside the player: the playlist's videos, the current one highlighted.
    Rectangle {
        id: playlistPanel
        visible: view.showPlaylist
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: 16
        width: Math.min(400, Math.max(300, view.width * 0.28))
        radius: 8
        color: AppState.colors.header

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 4

            Label {
                text: view.playlist ? view.playlist.title || "" : ""
                font.pixelSize: 16
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Label {
                text: view.playlist ? [view.playlist.channel,
                                       (view.playlistIndex + 1) + " / " + (view.playlist.count ? parseInt(view.playlist.count) || playlistModel.count : playlistModel.count)]
                                      .filter(s => s).join("  •  ") : ""
                color: AppState.colors.secondary
                font.pixelSize: 12
                Layout.fillWidth: true
                Layout.bottomMargin: 6
            }
            PlaylistList {
                view: view
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}
