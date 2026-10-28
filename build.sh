#!/usr/bin/env bash
# Builds FTL Player into a complete portable copy at dev/build/stage (for testing). It never touches the
# installed app in the folder above dev/: install.sh copies the stage there once that copy is closed.
# Run from Git Bash in this folder:  bash build.sh   (on a fresh clone, bash tools/setup.sh first)
set -euo pipefail

DEV="$(cd "$(dirname "$0")" && pwd)"
STAGE="$DEV/build/stage"
QT="$DEV/tools/Qt"
export PATH="$QT/Tools/mingw1310_64/bin:$QT/bin:$QT:$PATH"
cd "$DEV"

# Test copies run from the stage and lock its files; stop only those (never the installed app).
powershell -NoProfile -Command "
    \$stage = '$(cygpath -w "$STAGE")'
    Get-CimInstance Win32_Process -Filter \"Name='FTL Player.exe' OR Name='FreeTube Light.exe' OR Name='deno.exe'\" |
        Where-Object { \$_.ExecutablePath -and \$_.ExecutablePath.StartsWith(\$stage, 'OrdinalIgnoreCase') } |
        ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }"

echo "== app"
cmake -G Ninja -S src -B build/app -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT" -DCMAKE_MAKE_PROGRAM="$QT/ninja.exe" \
    -DCMAKE_CXX_COMPILER=g++ -DCMAKE_RC_COMPILER=windres >/dev/null
cmake --build build/app

echo "== helper"
for part in helper potoken; do
    DENO_DIR="$DEV/helper/.deno-cache" NO_COLOR=1 tools/deno/deno.exe bundle --config helper/deno.json \
        --platform=deno -o build/$part.js helper/$part.ts
done
tools/deno/deno.exe run --no-config --allow-read --allow-write helper/postbundle.ts build/potoken.js \
    "$(ls -d helper/node_modules/.deno/jsdom@*/node_modules/jsdom | head -1)/lib/jsdom/browser/default-stylesheet.css"

echo "== stage at $STAGE"
# The stage lock keeps install.sh from copying a half-written stage (and this from writing while it copies).
LOCK="$DEV/build/.stage-lock"
[ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null   # left by a killed run
until mkdir "$LOCK" 2>/dev/null; do sleep 1; done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
mkdir -p "$STAGE"
rm -f "$STAGE/.build-id" "$STAGE/.ready"   # a new build is not tested yet (release.sh)
rm -f "$STAGE/FreeTube Light.exe"   # the exe before the app was renamed to FTL Player
cp "build/app/FTL Player.exe" "$STAGE/"
windeployqt --release --qmldir src --no-translations --no-system-d3d-compiler --no-opengl-sw \
    "$STAGE/FTL Player.exe" >/dev/null
cp tools/mpv/libmpv-2.dll "$STAGE/"
mkdir -p "$STAGE/mpv"
cp src/mpv/osc.lua "$STAGE/mpv/"   # control bar with the speed/quality/captions buttons
mkdir -p "$STAGE/helper"
cp tools/deno/deno.exe build/helper.js build/potoken.js "$STAGE/helper/"
mkdir -p "$STAGE/extension"
cp extension/* "$STAGE/extension/"   # "Open in FTL Player" for Brave / Chrome (Load unpacked)
date +%Y%m%d-%H%M%S > "$STAGE/.build-id"   # written last: marks a complete build (watch-install.ps1)
echo "done (install with dev/install.sh once FTL Player is closed)"
