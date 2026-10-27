#!/usr/bin/env bash
# Starts a test copy of FTL Player from the build stage (dev/build/stage, never the installed app) with its
# own data folder (never the real Data), muted, with mpv's IPC pipe "ftl-test" and the control bar always
# visible. It opens behind all other windows without taking the focus (FTL_TEST_BACKGROUND), on the laptop
# display.
# usage: testrun.sh <data-folder-name> [app arguments...]     e.g. testrun.sh t1 --play dQw4w9WgXcQ
set -euo pipefail
DEV="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(cd "$DEV/.." && pwd)"
STAGE="$DEV/build/stage"
name="$1"; shift
export FTL_DATA_DIR="$DEV/build/$name"
mkdir -p "$FTL_DATA_DIR/cache"
[ -f "$FTL_DATA_DIR/cache/session.json" ] || cp "$APP/Data/cache/session.json" "$FTL_DATA_DIR/cache/" 2>/dev/null || true
export FTL_MPV_OPTS="mute=yes;input-ipc-server=ftl-test"
export FTL_SCRIPT_OPTS="${FTL_SCRIPT_OPTS-osc-visibility=always}"   # FTL_SCRIPT_OPTS= (empty): the bar hides as usual
export FTL_TEST_IGNORE_LEAVE=1
export FTL_MPV_LOG="$(cygpath -w "$FTL_DATA_DIR")\mpv.log"
export FTL_TEST_BACKGROUND=1
# the shutdown timer only logs what it would run (never shuts down, locks ... the PC from a test)
export FTL_TIMER_DRYRUN="$(cygpath -w "$FTL_DATA_DIR")\timer-dryrun.log"
("$STAGE/FTL Player.exe" "$@" >"$FTL_DATA_DIR/run.log" 2>&1 &)
sleep 3
"$DEV/tools/pyenv/Scripts/python.exe" "$DEV/tools/onlaptop.py"
