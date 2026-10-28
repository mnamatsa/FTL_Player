#!/usr/bin/env bash
# Copies the build from dev/build/stage (made by build.sh) into the portable app in the folder above dev/.
# Refuses while that copy of FTL Player is running (it is never closed from here). Data/ is not touched.
# Run from Git Bash in this folder:  bash install.sh
set -euo pipefail

DEV="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$DEV/.." && pwd)"
STAGE="$DEV/build/stage"
[ -f "$STAGE/FTL Player.exe" ] || { echo "nothing staged: run build.sh first"; exit 1; }
LOCK="$DEV/build/.stage-lock"
[ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null   # left by a killed run
until mkdir "$LOCK" 2>/dev/null; do sleep 1; done   # not while build.sh is writing the stage
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
[ -f "$STAGE/.build-id" ] || { echo "the staged build is incomplete: run build.sh again"; exit 1; }

running=$(powershell -NoProfile -Command "
    \$app = '$(cygpath -w "$APP")\'; \$dev = '$(cygpath -w "$DEV")\'
    @(Get-CimInstance Win32_Process -Filter \"Name='FTL Player.exe' OR Name='FreeTube Light.exe' OR Name='deno.exe'\" |
        Where-Object { \$_.ExecutablePath -and \$_.ExecutablePath.StartsWith(\$app, 'OrdinalIgnoreCase') -and
                       -not \$_.ExecutablePath.StartsWith(\$dev, 'OrdinalIgnoreCase') }).Count")
if [ "${running//[$'\r\n ']/}" != "0" ]; then
    echo "FTL Player is running from $APP: close it, then run install.sh again"
    exit 1
fi

cp -r "$STAGE/." "$APP/"
# The app was called FreeTube Light: its old exe goes (it would start the old version), and its shortcuts (in
# the app folder, and in the Start menu if it points here) are replaced by ones for FTL Player.exe.
rm -f "$APP/FreeTube Light.exe"
powershell -NoProfile -Command "
    \$app = '$(cygpath -w "$APP")'; \$shell = New-Object -ComObject WScript.Shell
    \$start = Join-Path \$env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    foreach (\$dir in @(\$app, \$start)) {
        \$old = Join-Path \$dir 'FreeTube Light.lnk'
        \$here = (\$dir -eq \$app) -and -not (Test-Path (Join-Path \$dir 'FTL Player.lnk'))
        if ((Test-Path \$old) -and \$shell.CreateShortcut(\$old).TargetPath -like (\$app + '\*')) { \$here = \$true }
        if (-not \$here) { continue }
        \$s = \$shell.CreateShortcut((Join-Path \$dir 'FTL Player.lnk'))
        \$s.TargetPath = Join-Path \$app 'FTL Player.exe'; \$s.WorkingDirectory = \$app
        \$s.IconLocation = (Join-Path \$app 'FTL Player.exe') + ',0'; \$s.Save()
        if (Test-Path \$old) { Remove-Item \$old }
    }"
echo "installed build $(cat "$STAGE/.build-id") into $APP"
