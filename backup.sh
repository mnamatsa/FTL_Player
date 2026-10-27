#!/usr/bin/env bash
# Backs up FreeTube Light before bigger changes, into "D:/Applications/FreeTube Light Backups/<time> <label>/":
#   source/  the code, scripts and test tools (not the downloaded toolchain, dependencies or build output)
#   app/     the installed app, trimmed like portable.sh (it runs as is)
#   Data/    the user's data files (subscriptions, history, settings ...; not the caches)
# usage: backup.sh [label]      e.g. backup.sh "before SponsorBlock"
set -euo pipefail

DEV="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$DEV/.." && pwd)"
DEST="$APP/../FreeTube Light Backups/$(date +%Y%m%d-%H%M%S)${1:+ $1}"
mkdir -p "$DEST/source" "$DEST/Data"

cd "$DEV"
# source: everything but the toolchain (tools/ binaries), dependencies, caches and build output
find . -type f \( -path './build/*' -o -path './helper/node_modules/*' -o -path './helper/.deno-cache/*' \
    -o -path './downloads/*' -o -path './tools/*/*' \) -prune -o -type f -print | sed 's|^\./||' |
    while IFS= read -r f; do mkdir -p "$DEST/source/$(dirname "$f")"; cp "$f" "$DEST/source/$f"; done

# the installed app (its program files, as portable.sh copies them from the stage it was installed from)
if [ "$(cat "$DEV/build/stage/.build-id" 2>/dev/null)" = "$(cat "$APP/.build-id" 2>/dev/null)" ]; then
    bash "$DEV/portable.sh" "$DEST/app" >/dev/null
else
    echo "(the stage holds another build than the installed one: app/ copied from the app folder)"
    mkdir -p "$DEST/app"
    (cd "$APP" && find . -type f -not -path './Data/*' -not -path './dev/*' -not -name '*.lnk' | sed 's|^\./||' |
        while IFS= read -r f; do mkdir -p "$DEST/app/$(dirname "$f")"; cp "$f" "$DEST/app/$f"; done)
fi
cp "$APP/.build-id" "$DEST/app/.build-id" 2>/dev/null || true

# the user's data, without caches (cache/, deno/) and logs
(cd "$APP/Data" && find . -maxdepth 1 -type f \( -name '*.json' \) -exec cp {} "$DEST/Data/" \;)

echo "backup of build $(cat "$APP/.build-id" 2>/dev/null) in $DEST: source $(du -sh "$DEST/source" | cut -f1), app $(du -sh "$DEST/app" | cut -f1), Data $(du -sh "$DEST/Data" | cut -f1)"
