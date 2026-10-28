# FTL Player: development

A light native YouTube player for Windows: Qt/QML (C++) with libmpv for the video and a Deno helper using
youtubei.js. The portable app lives in the folder above this one (`FTL Player.exe`; settings and caches go in
`Data\`). This folder holds the source; the toolchain and build output, which aren't in the repository, go in
`tools/`, `downloads/` and `build/` here.

## Building from a fresh clone

Needs Windows 10/11 (x64), [Git for Windows](https://git-scm.com/download/win) (its Git Bash runs the
scripts) and [Python 3](https://www.python.org/downloads/) (only for the setup). About 3 GB of disk space.

The scripts install the app into the folder *above* this one, so clone it as the `dev` folder of where the app
should go (any path, spaces are fine):

```sh
git clone https://github.com/mnamatsa/FTL_Player.git "D:/Apps/FTL Player/dev"
cd "D:/Apps/FTL Player/dev"
bash tools/setup.sh                  # once: downloads Qt + MinGW + CMake + Ninja, Deno, libmpv into tools/ (~1 GB)
bash build.sh                        # builds a complete copy into build/stage
bash install.sh                      # copies it to the folder above: D:/Apps/FTL Player/FTL Player.exe
bash portable.sh "D:/FTL Player"     # or: a trimmed copy anywhere, to run or share (zip that folder)
```

`tools/setup.sh` checks every download's SHA-256 and skips what is already there. The libmpv build it uses
(`mpv-dev-x86_64-20261014-git-ec38361c56.7z` from shinchiro/mpv-winbuild-cmake, which `src/mpv/osc.lua` comes from)
is kept online by its builder for about a month only: keep a copy, and put it in `downloads/mpv-dev.7z` when it
is gone. The helper's npm packages (versions pinned in `helper/deno.json` / `deno.lock`) are fetched by Deno during
the first build.

## Build

```sh
bash build.sh     # build into build/stage (for testing)
bash install.sh   # copy the stage into the app folder (the one above this)
```

`build.sh` compiles the app, bundles the helper and puts a complete portable copy in `dev/build/stage`. It never
touches the installed app (only test copies running from the stage are stopped). `install.sh` copies the stage
into the app folder; it refuses while the installed FTL Player is running, which is never closed from
here. `Data/` is not touched. Each finished build gets an ID (`stage/.build-id`, written last); both scripts
hold `build/.stage-lock` while they touch the stage. `release.sh` marks the staged build as tested; `watch-install.ps1`,
run as a background task of a working session (it ends with it, or `-Stop`), installs a marked build as soon
as the installed copy is closed and logs to `build/install.log`.

```sh
bash portable.sh "D:/FTL Player"   # a trimmed portable copy (any folder)
```

`portable.sh` copies the stage to another folder with only what the app loads (about 80 files instead of
~1,460): no `Data` (an empty one is created on first start; one already there is kept), no install markers, no
QML debugger or touch plugins, no Fusion / Imagine / Universal / Fluent / Windows styles or unused QML modules,
and no loose `.qml` / `.qmltypes` files (Qt's QML is compiled into its DLLs: `prefer :/qt-project.org/...` in each
qmldir). The Dialogs, Shapes and folder-list modules stay for Qt's non-native file dialog. Its output is tried
out in `dev/build/portable`, which the test tools (`testwin.py`) treat like the stage.

## Layout

| Path | What |
|---|---|
| `src/` | Qt/QML app (C++17, Qt 6.11). `mpvitem.*` embeds libmpv, `helperclient.*` runs the helper |
| `helper/helper.ts` | Deno helper: youtubei.js search / stream lookup, local stream proxy, PO token session |
| `helper/potoken.ts` | BotGuard worker (jsdom + bgutils-js) that mints the session's PO token |
| `helper/postbundle.ts` | Build step that embeds jsdom's assets into the bundled worker |
| `extension/` | Brave / Chrome extension "Open in FTL Player" (copied to `extension` in the app folder) |
| `tools/` | Qt + MinGW 13.1 + CMake + Ninja (`get_qt.py`), Deno, libmpv, 7zr, test helpers |

Library versions are pinned in `helper/deno.json`.

## How playback works (and why)

- **PO token:** without one, googlevideo serves only the first ~60 s of a stream. `potoken.ts` runs BotGuard
  once, mints a token bound to the visitor ID, and the helper saves both in `Data/cache/session.json`
  (valid ~12 h).
- **Client order:** TV_SIMPLY with the visitor-bound token plays to the end of every video tested.
  MWEB, IOS and ANDROID_VR are fallbacks. Before a client's streams are used, a byte at 90 % of each stream
  is probed. Live streams use the HLS playlist of the VISIONOS client (yt-dlp's "visionos", called with a
  plain InnerTube request because youtubei.js lacks it) without a PO token. Since August 2026 YouTube
  refuses ANDROID_VR's live segments after about 30 s, so ANDROID_VR is only the fallback.
  The helper reads the master playlist's resolutions (`liveQualities`) and plays the best one up to the
  quality setting directly; the quality button switches between them. Since October 2026 VISIONOS's
  variants are video only and name an audio group (`AUDIO="234"`, an `EXT-X-MEDIA` playlist of its own):
  the helper then serves a small master playlist of that one variant and its audio (`liveMaster`, `/m/`),
  so mpv plays both in sync, also after seeking back in DVR streams (both go through the DVR proxy). Played
  alone, the variant had no sound. The control bar shows a LIVE
  indicator (`osc-ftl_live=yes`) between play/pause and volume: red within 30 s of the live edge, grey
  further back, and clicking it seeks back to the edge.
  YouTube's live playlists list only the last hour (`playlist_duration`, signed), but googlevideo serves
  DVR streams' older segments for about 12 hours (their URLs differ only in `/sq/`). For DVR streams
  the proxy serves the playlist (`/l/<token>.m3u8`) with up to 12 h of older segments added in front,
  fetched through `/l/<token>/<sq>.ts`. All playlists of a stream start at one fixed segment (`liveFirst`,
  12 h before the newest when it opens; all formats number segments alike), so mpv's timeline stays the same
  after a quality change or reopening (before, the window slid and a quality change jumped ahead by the time
  watched); the playlists grow meanwhile (~720 entries an hour).
- **4K live:** YouTube's live HLS stops at 1080p H.264, also for 4K streams; their 1440p / 2160p exist only as
  live DASH formats (VP9 WebM). TV_SIMPLY's, with the PO token, keep loading (iOS's are refused after ~30 s,
  ANDROID's have no URLs). `liveDash` takes one per resolution above the HLS ones plus the best AAC audio; the
  proxy writes an HLS playlist for each (`dashPlaylist`: segments `&sq=N` up to googlevideo's `X-Head-Seqnum`,
  asked with HEAD; every segment is a complete WebM / MP4 file, which mpv plays one after the other) and a
  master playlist pairs them. They show in the quality menu above the HLS ones (`liveCodec` tells MpvItem the
  codec for the GPU choice, `liveVia` the client for the status line). A seek that interrupts a WebM read makes
  mpv give up and go to the end (lavf "Immediate exit requested ... treating it as fatal error", after quick
  seeks or a drag); PlayerView then reopens the stream where the seek went (`MpvItem::recentSeekTarget`, from
  MPV_EVENT_SEEK; at most 3 times in 30 s).
- **Live seek bar previews:** live streams have a `PlayerLiveStoryboardSpec`: one picture per segment, sheet
  `$M` = segment number / (columns * rows). The app asks `liveTimeline` for the first segment of the playing
  playlist and the segment length and passes them as the storyboard's `offset` / `interval`.
- **Links in the search field:** a YouTube link (pasted: opens at once; typed: on Enter) opens what it links to
  (`Main.openLink`): a video (watch / youtu.be / shorts / live / embed, at its `t=`), a playlist, or a channel
  (`/channel/UC...`; `@handle`, `/c/`, `/user/` through the helper's `resolveChannel`, InnerTube `resolve_url`).
  Anything else is searched for. Channel requests are tried once more after a 5xx.
- **SponsorBlock:** the helper's `sponsorSegments` asks sponsor.ajay.app by the first 4 hex digits of the video ID's
  SHA-256 (the answer covers ~150 videos; the server doesn't learn which one plays), drops segments marked for
  another video length (edited since), and the app sends the ones its settings keep (`sb_<category>`: skip / show /
  off; categories and colours in `AppState.sponsorCategories`) to osc.lua (`ftl-segments`), which draws them on
  the seek bar and jumps over "skip" ones when playback runs into them (not when a seek lands inside one), and
  silences "mute" ones with an audio filter of its own (`@ftlsb`; mpv's mute is the viewer's setting). A segment
  for the whole video (exclusive access) shows in the status line. The helper's `--allow-net` includes
  sponsor.ajay.app.
- **Chapters:** the helper's `chapterList` takes YouTube's own (the player bar's chapter markers, also in TV_SIMPLY's
  answer), else the description's timestamps as YouTube reads them (3 or more, from 0:00, in order); PlayerView
  falls back to SponsorBlock's community chapters. They become mpv's chapter list (`ftl-chapters` sets
  `chapter-list` once the video has loaded): gaps in the seek bar, "Chapter: ..." in the title row on hover, and a
  Chapters box under the description (the one playing; opened, all of them, a click seeks). On hover the chapter
  shows in a see-through black box above the preview picture (`ftl_draw_label`; the title row keeps the video's
  title: `chapter_fmt=no`), or above the time without a preview (`ftl_preview`, set by MpvItem::setStoryboard; also
  Settings > Player > "Show seek bar preview", `preview`, which gives the player no storyboard). Settings > Player >
  "Show chapters" (`chapters`) turns all of it off.
- **Search filters:** `SearchPage.qml` (its own page now) has YouTube's filters: type (videos / channels / playlists),
  upload date, length, order (relevance / popularity) and features (live, 4K, HD, subtitles ...); changing one searches
  again, and they stay for the next searches. The helper's `search` takes `filters` (checked against the values
  youtubei.js knows) and answers by kind: videos, channels (`channelResult`: YouTube puts the handle where the
  subscriber count belongs) or playlists (`playlistItem`, as on channel pages).
- **Saved playlists:** `AppState.playlists` (Data/playlists.json, "Watch later" always there): a card's menu saves to
  Watch later or opens the window's "Save to playlist" dialog (`SavePopup`, a window of its own; `Main.saveToPlaylist`,
  also the player's Save button), with a new playlist by name. The Playlists page (`PlaylistsPage`) shows them as cards
  (a click opens one: Play all, rename, delete; a card's menu removes a video). They play like YouTube playlists:
  `openPlaylist({localId})` fills the player's playlist from the saved list.
- **Open maximized:** Settings > Windows > "Open maximized" (`startMaximized`) maximizes a window as it opens (Main
  `Component.onCompleted`), the app's first one and new ones, not those opened in the background.
- **Volume keys:** the keyboard's volume / mute keys are not passed to mpv (`mpvKeyName`): they set Windows' volume, and
  mpv's default bindings changed the player's volume too.
- **End of a video:** the picture goes black (osc.lua puts a black overlay under the controller while `eof-reached`;
  a seek back or the next video removes it); the time left never shows below zero (it read "--00:00:00").
- **Typing ends with a click elsewhere:** keys go to the player unless a text field has the focus, and the search
  field kept it after a search, also behind the player and in fullscreen (where it is hidden), so hotkeys typed
  into it. `MpvItem::endTyping` takes the focus from a text field (the field lets go itself: the root item would
  hand it straight back) on a click outside it (the window's event filter, and on the video), when a video or
  playlist opens, and when fullscreen begins.
- **Fullscreen check:** once a window stayed as it was when fullscreen was asked for (button, double-click; mpv's
  state did change; not reproduced). `WindowTools.checkFullScreen` looks 0.4 s after every change whether the window
  really is fullscreen (no caption) and, if Qt and Windows disagree, sets the state anew. Warnings and
  `console.info` lines (fullscreen changes among them) go to `Data/app.log` (`main.cpp`, new after 1 MB).
- **Subscription lists while refreshing:** `show()` holds a rebuild while the user is at the list (`VideoGrid.busy`:
  the pointer over it, or a card's right-click menu open, which takes the pointer onto the menu) and applies it
  when that ends, without a button ("Show new videos" is for scrolled-down lists only); a card counts a click
  only if it still shows the video it was pressed on (cards are reused). Rebuilds every 0.7 s turned the
  aimed-at card into another video, and an open menu jumped with its card. The Videos / Live tab is shared by the windows (`AppState.subscriptionsTab`).
- **Live preview pictures:** a live sheet holds 9 pictures (45 s) and the bar spans up to 12 h, so the preview
  takes a picture from a sheet already loaded when it is within ~0.2 % of the pointer's time, and only the
  newest sheet asked for is downloaded (older downloads are aborted); before, the downloads queued up and the
  picture trailed the pointer.
- **Seek bar drag:** the control bar seeks to times (`ftl_seek_to`), not percentages: a keyframe seek to a
  percentage seeks by byte position where mpv can, which in a live stream went to its beginning. In live
  streams it stops 15 s before the end, like the LIVE button.
- **Proxy:** googlevideo refuses open-ended ranges and ranges longer than ~1 min of media. mpv therefore
  reads from `127.0.0.1` and the helper fetches ~45 s chunks (at most 8 MB).
- **Subscriptions:** channel tabs (`videos`, `streams`) are fetched with InnerTube `browse` and parsed from
  LockupView components. YouTube answers bursts with HTTP 429, so the helper paces these requests at
  20/s and backs off on a 429. At that rate 545 channels refresh in ~33 s; the UI shows the saved feed
  meanwhile. The feed caches are `Data/feed-videos.json` and `Data/feed-streams.json`.
- **Feed (RSS):** the Videos tab normally uses each channel's RSS feed (`rssFeed`, paced at 60/s; 545
  channels in ~10-16 s). It has exact dates and marks Shorts, but no durations. Live status comes from the
  Live tab's data. The Live tab checks every channel (~33 s), live / upcoming ones and the latest streamers
  first (`latestStream`), so their streams show within the first seconds; it used to check only channels that
  streamed in the last 90 days (32 of 537) and the rest once a day, which missed channels streaming after a break.
- **Live tabs:** channel Live tabs also list premieres. Only items that are live, "Scheduled for…" or
  "Streamed …" ago are kept (`stream` flag in `lockupItem`, `isStream()` in SubscriptionsPage.qml).
- **Captions:** `streams` returns the caption tracks. The proxy serves them as WebVTT at `/c/<token>`, and
  the player adds the chosen track once the video has loaded.
- **Control bar buttons:** `src/mpv/osc.lua` is mpv's controller from the bundled libmpv's commit, changed
  so custom buttons are as wide as their text. It is loaded instead of the built-in one (`osc=no`). Its
  speed / quality / captions / audio buttons sit in the seek bar row and send `script-message ftl-menu
  <which>`; `PlayerView` opens the matching menu at the pointer. The audio button shows only for videos with
  several audio tracks. The bar layout also drops the playlist arrows, the chapter buttons and mpv's
  track buttons, and puts the volume button next to play/pause. Hovering it lays out a vertical volume
  slider above the bar (`volumebar`, element type `ftl_vslider` added to the controller, drawn with
  `an = 7`: bottom-anchored drawings came out higher than their hitbox). The column from the button up to
  the slider counts as hovering, losing it waits 0.5 s, and the slider is an `input` area so clicks on it
  don't pause; it sets the volume with `osd-msg` so "Volume: N%" shows like for the wheel. mpv's own OSD
  bar is off (`osd-bar=no`). The seek bar uses `seekrangestyle=slider`, edited to draw a thick played part
  from the start and a thin line for what is buffered ahead (nothing else). The speed / quality / captions /
  audio menus are compact and see-through, and open above the whole bar, centred on the clicked button
  (`ftl-menu` passes mpv's `mouse-pos` and the bar top from `user-data/osc/margins`), inside the player. The bar hides 4 s after the pointer stops (`osc-hidetimeout`), the
  cursor with it; while a menu is open it stays (`MpvItem::holdControlBar` sends `osc-visibility always`,
  then `auto` and `osc-show` when the menu closes). A click on the video toggles pause (`keybind MBTN_LEFT`); a double-click (detected from
  the presses in MpvVideoWindow; Qt's double-click event didn't always arrive, and mpv's own
  `MBTN_LEFT_DBL` is bound to `ignore` because it toggled a second time) toggles fullscreen and undoes
  that pause. Volume and mute are kept in the settings (`volume`, `muted`) and given to mpv at start, and
  so is the right timecode's mode (`timeTotal`: clicking it sends `ftl-timetotal`; the app sets
  `osc-timetotal`). When updating libmpv, refresh this file from the same mpv commit and re-apply the edits
  marked "FTL Player".
- **Seek bar previews:** the controller publishes `user-data/osc/draw-preview` (position, size, hover
  time) while the pointer is over the seek bar. `MpvItem` cuts the matching tile from YouTube's storyboard
  sprite sheets (`storyboard` in the `streams` reply; sheets are downloaded once per video) and draws it
  with `overlay-add`. The controller's frame goes behind it with `osd-overlay`. The seek bar is styled like
  FreeTube's: red played part with a knob (`osc-seekbar_color`, added to the controller copy).
- **Playlists:** channel Playlists tab (`channelPage` with tab `playlists`, playlist LockupViews) and
  `playlist` (youtubei.js `getPlaylist`, paged). `PlayerView.openPlaylist()` shows the panel beside the
  player, moves to the next video at the end, and handles Shift+N / Shift+P (`ftl-playlist` messages).
  While a playlist plays, the control bar shows previous / next buttons (`osc-ftl_playlist=yes`). In
  fullscreen, an arrow at the middle of the right edge opens the playlist in an overlay (both are native
  tool windows over the video).
- **Comments:** `comments` ({videoId, sort} or {more}) and `replies` ({commentId[, more]}; not `id`, which
  is the request number) use youtubei.js `getComments` / `CommentThread.getReplies`. The page under the
  video is one ListView (`Comments.qml`: the details are its header, comments are made as they scroll into
  view, opened replies are kept in `replyState`, more load near the end) and the video moves up with it.
  MpvItem cuts its native window to the visible part and hides it when scrolled away; on Windows it moves
  and clips it with `SetWindowPos(SWP_NOREDRAW)` / `SetWindowRgn(..., FALSE)`, because Qt's setGeometry /
  setMask repaint at once and wait for mpv's thread; resizes go through `SetWindowPos` too, in real pixels
  (`m_videoPx`; Qt's whole logical pixels made fullscreen 2561 px wide at 150 %, scaled by mpv). Fullscreen
  coming or going took the layout through 3-5 sizes in ~0.15 s, each drawn by mpv (~4-5 dropped frames per
  switch with a 60 fps video): for 0.4 s after a switch the video window takes a new size only once it has
  been the same for 50 ms (`startSettling`, `m_settle`), one resize ~0.1 s after the switch (~0.5 dropped
  frames). No BusyIndicator there: its animation added ~4 ms to
  every frame. Live streams show no comments.
- **Mouse wheel over the video:** `wheelVolume` setting (2 = volume, 1 = volume in fullscreen only, 0 =
  never). Where it doesn't change the volume, the wheel scrolls the page (`MpvItem::wheelScroll`); near the
  control bar (bottom 90 px) it goes to mpv, where WHEEL_UP/DOWN are bound to `add volume ±2` or
  `script-message ftl-scroll ±120`. Over the bar itself, a wheel turn no element uses (empty space, title,
  time, quality / captions / audio buttons) runs the same command (`ftl_wheel_up/down_command`, osc.lua
  `process_event`). `wheelSeek` and `wheelSpeed` do the same for the seek bar and the speed button: they set
  `seekbar_wheel_up/down_command` to `seek ±10` and `custom_button_1_wheel_up/down_command` to `ftl-speed ±1`,
  or to `ftl-scroll ±120` (scrolls the page). The volume button / slider always change the volume. All follow
  fullscreen changes from either side (the app's double-click or mpv's f / Esc / button).
- **RSS fallback:** YouTube's RSS fails for many channels at times (in October 2026 it answered 404 or 500
  for about 70 % of the subscriptions, also when asked slowly or with a browser user agent, and the
  uploads-playlist feed failed the same way). `rssFeed` then reads the channel's Videos tab (InnerTube,
  paced like other browse requests), so a refresh still loads every channel, a little slower.
- **Upcoming videos:** scheduled streams and premieres look like normal uploads in RSS (0 views). Those
  and the Live tab's upcoming items are looked up with `videoStates` (youtubei.js `getBasicInfo`: upcoming,
  live, scheduled start, and premiere = upcoming but not live content), once and again after their start
  time passes, and kept in `Data/video-states.json`. Upcoming items show "Starts in …" and sort by their
  start time. Upcoming premieres show in the Videos tab, upcoming live streams only in the Live tab (also
  ones only the Videos feed found); `hideUpcomingPremieres` / `hideUpcomingLive` hide them. Streams live now
  (which RSS lists as uploads) are also left out of the Videos tab; premieres playing now and ended streams stay.
- **Durations in the feed:** RSS has none, so after a refresh `SubscriptionsPage.fillDurations()` fetches the
  Videos tab of channels whose uploads have no known length (8 at a time; ~25 s for 545 channels the first
  time, then only channels with new uploads; like the refresh, channels with the newest videos go first).
  Past streams take theirs from the Live tab's data. They are
  kept in `Data/durations.json` (`AppState.durations`, "" = none found, e.g. Shorts).
- **Scrolling:** `SmoothScroll.qml` makes wheel scrolling of the grids, lists and the video page follow a
  critically damped spring (speed carries over between notches), also the Settings page (on its ScrollView's
  content, which gets the wheel first). A notch moves 40 px per Windows wheel line times `scrollSpeed`
  (Settings > Layout > Scroll speed, 0.25-4). Video grids reuse their cards
  (`reuseItems`, `cacheBuffer`) and cards create their context menu only on right click: building those
  for each new row stalled frames for ~60 ms.
- **History / resume:** `Data/history.json` (newest first). The player saves the position every 5 s and
  resumes there when a video is reopened.
- **Windows:** "Open in new window" creates another complete `Main` window in the same process (shared
  helper and state; `AppState.windows` keeps them referenced). `AppState.createWindow` makes them, not the
  window asking: a created object's QML context hangs off the context its component was made in, so closing
  a window that had opened others destroyed theirs, and they stopped running their scripts (they still drew
  and took typing, but no click, binding or handler reacted; the video didn't follow the window or go
  fullscreen). The log has each new window, each press on a window and each fullscreen request (`MpvItem`),
  to tell such a case apart. `AppState.qml` is the shared singleton for
  settings, subscriptions and history. Middle click on a card opens the video in a new window; on the
  card's channel name, or on a Channels page entry, it opens the channel (`startChannelInfo`). The refresh
  button (F5) reloads the video at its position, the feed, a channel, search results or history.
- **Background windows:** with `openInBackground`, "Open in new window" shows the new window without
  activating it (`WindowTools.showInBackground`): Windows shows it directly behind the current window in one
  step (`SetWindowPos` with `SWP_SHOWWINDOW` and the current window as its place in the stack, the same outer
  rectangle, or its screen's work area when that one is maximized), so it never shows in front even for a
  frame; Qt's `show()` (with `_q_showWithoutActivating`) then only records it. 0.3 s later the taskbar button
  flashes for 2.2 s (`FlashWindowEx` with `FLASHW_ALL` and a count of 4, as Chromium's `flashFrame` does in the
  patched FreeTube). `FLASHW_TIMERNOFG` showed nothing in real use (fine in test copies, which are never in the
  foreground): the new window shares the active window's thread, apparently counted as the foreground. Hiding the
  window with DWM's cloak while showing it kept the taskbar from showing the flash. Such a window doesn't
  take the focus when its video starts or its channel page opens.
- **Hotkeys:** `settings.hotkeys` (action -> mpv key name; missing actions use `AppState.defaultHotkeys`:
  S/D speed, Left/Right short jump, J/L long jump, `,`/`.` frame step). PlayerView turns them into a key ->
  command map (`MpvItem.hotkeys`, bound with `keybind`; keys no longer used are bound to `ignore`). The short
  jump is `seekStep` (1-20 s), the long one `seekStep` x `jumpMultiplier` (1.25-10), both sliders in Settings.
  Jumps and frame steps go to the controller (`script-message-to osc ftl-jump N` / `ftl-frame ±1`), which
  seeks exactly and shows the rounded message box at the top middle (`ftl-flash`, also used for the speed,
  e.g. "1.25×"; centred on the capitals' height, as the measured text bounds include room below the line);
  jumps in the same direction add up while it shows. They run with `no-osd`, and `osd-on-seek=no`: mpv's own
  message drew an empty box in the top left corner. The box drawing also sets `a`/`a` to transparent: with
  `osd-border-style=background-box` libass drew a background box at the drawing's origin (top left). Key names come from `keynames.cpp` (also
  `KeyNames.name()` for the settings page, where a key is recorded by clicking it and pressing the new one).
- **Per-video choices:** speed, quality and captions chosen while a video plays are kept for it
  (`AppState.videoPrefs`, `Data/video-prefs.json`, the last 3000 videos) and used when it is opened again;
  other videos use the defaults.
- **Pages load when first shown** (`Main.shownPages`, Loaders): a window opened for a video doesn't build the
  feed, which took 0.5-0.7 s per new window; now ~30 ms.
- **Keys reach the player** wherever the keyboard is in the window: `MpvItem` filters the window's key presses
  while a video shows and passes them to mpv, except while typing in a text field (and Ctrl+key in
  selectable comment text, for copying); the window's shortcuts (Esc, F5) still come first.
- **0-9:** jump to 0 %, 10 % ... 90 % of the video (`ftl-percent`, fixed bindings bound before the hotkeys, so a
  digit given to a hotkey keeps that); the message box shows "50%".
- **Up / Down:** volume +5 % / -5 % (fixed bindings like the digits; mpv's own: seek 1 min).
- **Description** under the player (`PlayerView` `descBox`), from the `streams` reply (`short_description` and
  the date, so no extra request): the exact views, "Published Oct 25, 2009 (16 years ago)", then three lines
  until clicked ("...more" / "Show less"). The date (helper `publishedOn`) is the player's `publish_date` (MWEB
  only) or else the watch page's `primary_info.published` ("Premiered Oct 25, 2009": its words replace
  "Published"), as local noon. The row by the likes shows the card's views and "x ago" only until the box has
  them (live streams keep "N watching" there: the box has no viewer count). "x years / months ago" counts calendar months (`ago`, also on the cards).
  `descriptionHtml` turns URLs and timestamps into links: a timestamp seeks (`MpvItem::seek`) and scrolls the
  video back into view, a YouTube video link (watch / youtu.be / shorts / live, with `t=`) opens here, any other
  link in the browser.
  Comments use the same (`Comments.textHtml` / `linkActivated`): their timestamps seek, their links open.
  Middle click on a link (description or comment) opens it in a new window (`openLinkInNewWindow`: a
  timestamp as this video at that time, a YouTube video link as that video, via `startLink`); right click shows
  `linkMenu` (Open / Open in new window / Open in browser). Other links just open in the browser.
- **Shutdown timer** (`SleepTimer`, shared by all windows; `TimerButton.qml`, the clock in the top bar), as in the
  patched FreeTube: shut down / restart / sleep / hibernate / sign out / lock, pause the video or close the app,
  in h:min (presets 15 min - 2 h), at the end of the video or of the playlist (then a 60 s countdown for PC
  actions, none for the others; the playlist doesn't go on). PC actions get a 60 s warning in every window
  (Cancel / Snooze 10 min; the first window comes forward); videos are paused and their position saved before.
  "Graceful" off adds `/f` to `shutdown`; "Keep the screen awake" uses `SetThreadExecutionState`. Running:
  Pause / Resume, +10 min, Restart, Cancel. The last choices are kept (`settings.timerPrefs`).
  `FTL_TIMER_DRYRUN=file` only writes the commands to that file; `testrun.sh` always sets it.
- **Codec setting** (`settings.codec`: auto | vp9 | h264 | av1, passed to `streams`): a preferred codec is used
  whenever the video has it up to the quality limit, even at a lower resolution; auto = highest resolution and
  frame rate first, then VP9 > H.264 > AV1. The quality list prefers it per resolution too.
- **GPU setting** (`settings.gpu`: auto | integrated | dedicated, `gpus.cpp`): integrated / dedicated are the
  adapters Windows ranks first for power saving / high performance (`EnumAdapterByGpuPreference`). mpv gets
  `d3d11-adapter=<name>` when it starts (hardware decoding follows it), the interface `QT_D3D_ADAPTER_INDEX` at
  app start (main.cpp reads settings.json). "auto" plays on Windows' default GPU unless it can't decode the
  video's codec in hardware and another GPU can (checked once per GPU through the D3D11 decoder profiles for
  H.264 / VP9 / AV1, `Gpus::decodes`); mpv is restarted on the other GPU between videos when needed
  (`MpvItem::play`). Settings shows which GPU each choice is on this PC and what it decodes, and hides the
  setting when both are the same GPU (`FTL_TEST_ONE_GPU=1` acts like such a PC, for tests).
- **Seek bar preview size** (`settings.previewScale`, 0.5-3): the controller's `ftl_thumb_scale` scales its size
  limits; the helper picks the sharpest storyboard.
- **Grid size:** `gridScale` (Settings > Layout, or Ctrl + mouse wheel over a grid) scales the card width
  and text of the video and playlist grids.
- **Quality:** `streams` returns the quality list (best codec per resolution: VP9 > H.264 > AV1, no HDR).
  `format` switches to another itag, and the app reloads at the current position. The preference
  (`Data/settings.json`, `quality` = height, 0 = screen height) applies to later videos.
- **Connection loss** (Wi-Fi dropping, the PC waking from sleep): the stream proxy picks a broken upstream
  read up again from the byte it stopped at (up to 5 times in a row), and `fetchChunk` keeps retrying network
  errors for 45 s (`patience`; live segments 20 s), within mpv's 60 s network timeout. If the stream still
  breaks off (or its links expired), `PlayerView.recover` reopens the video where it stopped with a new
  lookup: when mpv fails, or a video ends more than 5 s before its length; after 2, 5, 10, 20, 30, 30 s
  ("Connection lost: retrying in …"), counting again once it played a minute.
- **Sandbox:** the helper may only reach YouTube/Google hosts and 127.0.0.1, write `Data/cache`, and read
  the token worker. YouTube's player code runs in a worker with no permissions.
- **Back button:** `pageStack` holds pages, and a video left for another page (a sidebar tab, a channel, a
  search) as `{page, video, playlist, playlistIndex}`: back reopens it, at its saved position, over the page it
  was opened from.
- **Memory across windows** (Settings > Windows): each loaded video takes ~300-400 MB (decoder, picture
  buffers, GPU memory). A video opened in a background window (`newWindow` in the background, `deferPlayer`)
  starts without its player when `openUnloaded` (default on): its details and comments show, with the
  thumbnail and a play button where the video goes. `AppState.players` lists the loaded players, the last used
  first (opened, or their window brought forward). `unloadMode` picks one of two ways, not both: "count" keeps
  `loadedPlayers` (default 2; 0 unlimited) loaded: using one unloads the paused ones past that, and one past
  that (it was playing then) unloads as soon as it is paused in the background; "time" unloads any video
  paused for `unloadPausedAfter` minutes (default 3) with its window in the background, however many are
  loaded. `PlayerView.unloadPlayer` saves the position, releases mpv and runs `gc()`; the player starts again
  where it was when the window comes forward (paused if it was) or the thumbnail is clicked (playing), with the
  same stream links if looked up within the hour. A paused video started in a window behind others showed the
  frame mpv drew while the layout settled, cut and shifted, until a resize: `MpvItem::redrawVideo` marks the
  video window for repainting after a file loads and when the window comes forward.
- **One copy:** started again with nothing to do (no link, no options), the app hands `ftl:new-window` to the
  running copy (the same `QLocalServer` as links) and exits; that copy opens another window in front. Each
  copy cost ~300 MB plus its helper.
- **Links from the browser:** `extension/` (MV3, `Load unpacked` in `brave://extensions` from the app's
  `extension` folder) adds "Open in FTL Player" to the right-click menu of YouTube links, and "Open this
  video in FTL Player" on video pages (also the toolbar button): it reads the position and pauses the
  browser's player, like FreeTube's extension, then opens `ftlplayer://<link>` (`freetubelight://`, the name before, still works). YouTube's player shows its
  own menu on the first right-click; the second shows the browser's. The app registers that protocol for itself
  at each start when the exe has moved (`HKCU\Software\Classes\ftlplayer`, and `freetubelight` from before the rename; not for test copies). A start
  with a link (`"FTL Player.exe" <link>`) hands it to an already running app over a `QLocalServer` named
  after the Data folder, so test copies have their own, and exits; the first window comes forward (restored if
  minimized; the new process allows that with `AllowSetForegroundWindow`) and opens it with `openLink`, or, with
  `externalNewWindow` (on by default), a new window opens it in front (`newWindow(props, "front")`). With
  `externalBackground` the window opening it stays behind (a new one goes behind the first window, or behind all
  windows when that is minimized) and its taskbar button flashes.
- **Channel under the video:** its picture (`streams` `channelThumbnail`, the watch page's owner, 88 px; else the
  subscription's, else the initial) and name open the channel; middle click opens it in a new window, right
  click shows `channelMenu` (Open channel / Open channel in new window).
- **Theme** (`theme`, Settings > Layout): dark (default), light, or system (Windows' app mode, followed as it
  changes: `QStyleHints::unsetColorScheme`). `AppState.colors` is the palette the pages use (`darkColors` /
  `lightColors`, picked by `AppState.dark`; as one `dark ? ({..}) : ({..})` expression the dark one came out
  undefined from the compiled QML); `Material.theme` follows. Things over thumbnails and the video (badges, the
  player's menus and overlay texts) keep their colours. `WindowTools.setColorScheme` sets Qt's colour scheme
  (also the title bars) and `setAppIcon` the window icon: the red play icon with a black laser and "FTL" on
  dark, a white one on light (`assets/icon_dark|light.svg/png`; the exe's `icon.ico` and the extension's icon
  are the dark one). main.cpp sets both from settings.json before the first window; AppState only acts on changes
  once it is complete (`started`: changing the icon while it was being made had the windows read `colors` early).
- **Card previews** (`cardPreview`, Settings > Layout, on by default): with the pointer on a card, its bar
  shows along the thumbnail's bottom; along the lower third of the thumbnail (`scrubArea`) the card shows the
  storyboard picture at that point (all the video's sheets load at once, an image each kept while the pointer
  is on the card, each moved inside a clipping item; a picture whose sheet hasn't arrived keeps the last one:
  re-sourcing one image showed the thumbnail at every new sheet) with the
  time and a marker on the bar. The storyboard comes from helper `cardStoryboard` (the iOS client's player
  response alone, ~0.2 s: the web / TV clients' basic info has none; the last 300 kept), asked the first time
  the card previews. Storyboards are 160x90 at most (storyboard3_L2, the same the player's seek bar uses), so
  the picture is soft at card size. Not for live or upcoming videos, or without a known length. Tests:
  `FTL_TEST_CARD_SCRUB=0.4` previews every card at 40 % (posted mouse moves don't make Qt hover).
- **Likes:** `streams` gives `likes` (`basic_info.like_count`, every client has it; 0 when hidden), shown after
  the Save button shortened as YouTube does (`shortCount`), the exact number on hover. The thumb is Material
  Symbols' `thumb_up` (outlined, `assets/thumb_up.svg`), also on comments.

## Testing hooks

- `"FTL Player.exe" --search "query"`, `--play VIDEO_ID`, `--channel ID`, `--playlist ID`, `--import FILE`, `--export FILE` (.db/.csv/.opml/.json)
- `FTL_MPV_OPTS="mute=yes;start=600"`: extra mpv options. `FTL_MPV_LOG=path`: mpv log file.
- `FTL_DEBUG=1`: the helper logs each upstream request to `Data/helper.log`.
- `FTL_SCRIPT_OPTS=osc-visibility=always`: extra controller options. `FTL_TEST_IGNORE_LEAVE=1`: simulated clicks
  (`tools/vclick.py X Y`) reach the control bar.
- `tools/testrun.sh NAME [args]` starts a test copy **from the stage** with its own data folder `build/NAME`,
  muted, on the laptop display, behind all other windows and without taking the focus
  (`FTL_TEST_BACKGROUND=1`), with the control bar always visible and mpv's IPC pipe `ftl-test`. The window
  tools (`tools/testwin.py`) only ever act on windows of processes running from `dev/build/stage`, never on
  the installed app. Covered windows still screenshot fine (`shot.py` uses PrintWindow). `tools/mpvipc.py '["mouse",x,y]'`
  sends mpv commands, e.g. to hover over the seek bar.
- `FTL_DATA_DIR=path`: use another data folder, so tests don't touch your real subscriptions.
- Run tests on the **laptop display**: `tools/onlaptop.py` moves the test window there without activating it.
- `tools/shot.py out.png` saves a window screenshot. `tools/click.py X Y` clicks inside the window (physical
  pixels, as in the screenshot) without moving the mouse.
- `tools/popup.py shot out.png | click X Y` does the same for menus and the quality list, which open as
  separate native windows so mpv's video window can't cover them.
