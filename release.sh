#!/usr/bin/env bash
# Marks the staged build (dev/build/stage) as tested and ready: watch-install.ps1 installs only ready builds,
# as soon as the installed FTL Player is closed. build.sh clears the mark when it stages a new build.
set -euo pipefail
STAGE="$(cd "$(dirname "$0")" && pwd)/build/stage"
[ -f "$STAGE/.build-id" ] || { echo "no complete staged build: run build.sh first"; exit 1; }
cp "$STAGE/.build-id" "$STAGE/.ready"
echo "build $(cat "$STAGE/.build-id") is ready to install"
