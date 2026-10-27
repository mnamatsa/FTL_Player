#!/usr/bin/env bash
# Copies the staged build (build.sh) into a portable folder with only the files the app needs: no Data
# (it starts empty and the app creates it next to the exe), no install markers, and none of the Qt files
# windeployqt adds that the app never loads (other Controls styles, the QML debugger, touch input, unused
# QML modules, loose .qml / .qmltypes files: the QML is compiled into the DLLs, see "prefer" in each qmldir).
# A Data folder already in the destination is kept.
# usage: portable.sh <destination folder>      e.g. portable.sh "D:/Applications/FreeTube Light V1"
set -euo pipefail

DEV="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$DEV/.." && pwd)"
STAGE="$DEV/build/stage"
[ $# -eq 1 ] || { echo "usage: portable.sh <destination folder>"; exit 1; }
mkdir -p "$1"
DEST="$(cd "$1" && pwd)"
[ "$DEST" != "$APP" ] && [ "$DEST" != "$STAGE" ] || { echo "not into the app or the stage itself"; exit 1; }
[ -f "$STAGE/FTL Player.exe" ] || { echo "nothing staged: run build.sh first"; exit 1; }

LOCK="$DEV/build/.stage-lock"
[ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null   # left by a killed run
until mkdir "$LOCK" 2>/dev/null; do sleep 1; done   # not while build.sh is writing the stage
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
[ -f "$STAGE/.build-id" ] || { echo "the staged build is incomplete: run build.sh again"; exit 1; }

running=$(powershell -NoProfile -Command "
    \$dest = '$(cygpath -w "$DEST")\'
    @(Get-CimInstance Win32_Process -Filter \"Name='FTL Player.exe' OR Name='FreeTube Light.exe' OR Name='deno.exe'\" |
        Where-Object { \$_.ExecutablePath -and \$_.ExecutablePath.StartsWith(\$dest, 'OrdinalIgnoreCase') }).Count")
[ "${running//[$'\r\n ']/}" = "0" ] || { echo "FTL Player is running from $DEST: close it first"; exit 1; }

cd "$STAGE"
find . -type f | sed 's|^\./||' | grep -v -E \
    -e '^\.(build-id|ready)$' \
    -e '^(qmltooling|generic)/' \
    -e '\.(qml|qmltypes)$' \
    -e '^qml/QtQuick/Controls/(Fusion|Imagine|Universal|FluentWinUI3|Windows|macOS|iOS)/' \
    -e '^qml/QtQuick/(NativeStyle|Particles|LocalStorage|VectorImage)/' \
    -e '^qml/QtQml/XmlListModel/' \
    -e '^Qt6QuickControls2(Fusion|FusionStyleImpl|Imagine|ImagineStyleImpl|Universal|UniversalStyleImpl|FluentWinUI3StyleImpl|WindowsStyleImpl)\.dll$' \
    | while IFS= read -r f; do
        mkdir -p "$DEST/$(dirname "$f")"
        cp "$f" "$DEST/$f"
    done
echo "portable build $(cat .build-id) in $DEST: $(find "$DEST" -type f -not -path "$DEST/Data/*" | wc -l) files, $(du -sh --exclude=Data "$DEST" | cut -f1)"
