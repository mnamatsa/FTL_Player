#!/usr/bin/env bash
# Sets up the toolchain build.sh uses, in dev/tools, on a fresh clone (none of it is in the repository):
#   - a Python environment (tools/pyenv) with py7zr (Qt's archives) and Pillow (the test tools)
#   - Qt 6.11.3 for MinGW, MinGW 13.1, CMake and Ninja (tools/get_qt.py, into tools/Qt)
#   - Deno (tools/deno), libmpv's development package (tools/mpv) and 7-Zip's 7zr.exe (it unpacks libmpv)
# Each download is checked against its SHA-256; parts already there are skipped, so it can be run again.
# Needs Git for Windows (this Git Bash, curl) and Python 3 (the "py" launcher or "python" on PATH).
# Run from Git Bash in the repository folder:  bash tools/setup.sh
set -euo pipefail

DEV="$(cd "$(dirname "$0")/.." && pwd)"
T="$DEV/tools"
DL="$DEV/downloads"
mkdir -p "$DL"

DENO_VERSION=2.9.7
DENO_SHA256=a0c3101b4158d1dfb7d6a78a7bf0f3de80c96bb423c152beec8beb22786f2238
# The libmpv build the app (and src/mpv/osc.lua, taken from the same mpv commit) is made for. Its builder keeps
# only the last ~30 daily builds online: keep a copy of this file, and put it in downloads/ as mpv-dev.7z when
# it is gone (it is used from there, after the same check).
MPV_URL=https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261014/mpv-dev-x86_64-20261014-git-ec38361c56.7z
MPV_SHA256=325555b4e0b1d87fb7c92c96010776581599c64e4988052cb9d05e130b52f939

sha_ok() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }

# fetch URL FILE SHA256: downloads FILE unless it is there with the right checksum
fetch() {
    if sha_ok "$2" "$3"; then return; fi
    echo "download $(basename "$1")"
    curl -fL --retry 3 -o "$2.part" "$1"
    mv -f "$2.part" "$2"
    sha_ok "$2" "$3" || { echo "SHA-256 mismatch for $2 (delete it and run again)"; exit 1; }
}

echo "== Python"
PY="$T/pyenv/Scripts/python.exe"
if [ ! -x "$PY" ]; then
    if command -v py >/dev/null; then py -3 -m venv "$T/pyenv"; else python -m venv "$T/pyenv"; fi
fi
"$PY" -m pip install --quiet --disable-pip-version-check py7zr==1.1.4 pillow==13.0.0

echo "== Qt, MinGW, CMake, Ninja"
if [ -f "$T/Qt/bin/windeployqt.exe" ] && [ -f "$T/Qt/bin/cmake.exe" ] && [ -f "$T/Qt/ninja.exe" ] && [ -d "$T/Qt/Tools/mingw1310_64" ]; then
    echo "already there"
else
    "$PY" "$T/get_qt.py"
fi

echo "== Deno $DENO_VERSION"
if [ -f "$T/deno/deno.exe" ] && "$T/deno/deno.exe" --version | grep -q "deno $DENO_VERSION "; then
    echo "already there"
else
    fetch "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-x86_64-pc-windows-msvc.zip" "$DL/deno.zip" "$DENO_SHA256"
    mkdir -p "$T/deno"
    "$PY" -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$(cygpath -w "$DL/deno.zip")" "$(cygpath -w "$T/deno")"
fi

echo "== libmpv"
if [ -f "$T/mpv/libmpv-2.dll" ] && [ -f "$T/mpv/libmpv.dll.a" ] && [ -f "$T/mpv/include/mpv/client.h" ]; then
    echo "already there"
else
    # 7zr.exe: py7zr can't unpack this archive (BCJ2 filter). 7-Zip's own site, latest version (no fixed checksum).
    [ -f "$T/7zr.exe" ] || curl -fL --retry 3 -o "$T/7zr.exe" https://www.7-zip.org/a/7zr.exe
    fetch "$MPV_URL" "$DL/mpv-dev.7z" "$MPV_SHA256"
    mkdir -p "$T/mpv"
    "$T/7zr.exe" x -y -bso0 -bsp0 "-o$(cygpath -w "$T/mpv")" "$(cygpath -w "$DL/mpv-dev.7z")"
fi

echo "done: build with  bash build.sh  (then  bash portable.sh <folder>  for a copy to run or share)"
