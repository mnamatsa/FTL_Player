# FTL Player

A light native YouTube player for Windows: Qt/QML (C++) with libmpv for the video and a Deno helper using
youtubei.js. No account and no ads.

**Download:** the portable zip from [Releases](https://github.com/mnamatsa/FTL_Player/releases). Unzip it anywhere
and run `FTL Player.exe`. Settings, subscriptions and history are kept in the `Data` folder next to the exe.

## Features

- Subscriptions feed (Videos / Live tabs), channels, search with filters, playlists (YouTube's and your own),
  history with resume
- Hardware-decoded playback up to 4K and live streams (with DVR), quality / codec / GPU choice, captions,
  chapters, SponsorBlock, seek bar previews
- Several windows in one process; background windows can stay unloaded to save memory
- Description and comment links and timestamps, likes, comments with replies
- Shutdown timer (shut down, sleep, hibernate, pause, close …), rebindable hotkeys, dark and light themes
- Browser extension "Open in FTL Player" (`extension/`, load it unpacked in Brave or Chrome)
- Import / export of subscriptions (FreeTube .db, .csv, .opml, .json)

## Building from a fresh clone

Needs Windows 10/11 (x64), [Git for Windows](https://git-scm.com/download/win) (its Git Bash runs the scripts),
[Python 3](https://www.python.org/downloads/) (only for the setup) and about 3 GB of disk space. The scripts
install the app into the folder *above* this one, so clone it as the `dev` folder of where the app should go:

```sh
git clone https://github.com/mnamatsa/FTL_Player.git "D:/Apps/FTL Player/dev"
cd "D:/Apps/FTL Player/dev"
bash tools/setup.sh                  # once: Qt + MinGW + CMake + Ninja, Deno, libmpv into tools/ (~1 GB)
bash build.sh                        # builds a complete copy into build/stage
bash install.sh                      # copies it to the folder above (not while the app is running)
bash portable.sh "D:/FTL Player"     # or: a trimmed copy anywhere, to run or share
```

`setup.sh` checks every download's SHA-256. Its libmpv build
(`mpv-dev-x86_64-20261014-git-ec38361c56.7z`, shinchiro/mpv-winbuild-cmake) stays online for about a month only:
keep a copy and put it in `downloads/mpv-dev.7z` when it is gone.

## Layout

| Path | What |
|---|---|
| `src/` | Qt/QML app (C++17, Qt 6.11). `mpvitem.*` embeds libmpv, `src/mpv/osc.lua` is mpv's controller with FTL changes |
| `helper/` | Deno helper: YouTube lookups, local stream proxy, PO token (`potoken.ts`); versions pinned in `deno.json` |
| `extension/` | Browser extension "Open in FTL Player" |
| `tools/` | Setup and test scripts |
| `NOTES.md` | Design notes: how playback and each feature work and why, and the testing hooks |
