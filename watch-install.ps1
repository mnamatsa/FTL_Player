# Watches for a new build in dev\build\stage that is marked ready (release.sh, after testing) and installs it
# (install.sh) as soon as the installed FTL Player is closed. Meant to run as a background task of a working session, ending with it; it can
# also be stopped with:
#   powershell -File watch-install.ps1 -Stop
# One copy runs at a time. What it does is logged to dev\build\install.log.
param([switch]$Stop)

$dev   = $PSScriptRoot
$app   = Split-Path $dev -Parent
$stage = Join-Path $dev 'build\stage'
$log   = Join-Path $dev 'build\install.log'
$bash  = 'C:\Program Files\Git\bin\bash.exe'
$pidFile = Join-Path $dev 'build\watch-install.pid'

# Each event goes to stdout (a session's monitor turns the lines into notifications) and to the log; the log
# write is retried, as another reader can hold the file for a moment.
function Log($text) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $text
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
    for ($i = 0; $i -lt 10; $i++) {
        try { Add-Content -Path $log -Value $line -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 200 }
    }
}

if ($Stop) {
    if (Test-Path $pidFile) {
        $old = Get-Content $pidFile
        Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
        Remove-Item $pidFile -ErrorAction SilentlyContinue
        Log "watcher $old stopped"
        "watcher stopped"
    } else { "no watcher running" }
    return
}

$mutex = New-Object System.Threading.Mutex($false, 'FreeTubeLight-watch-install')
if (-not $mutex.WaitOne(0)) { "a watcher is already running"; return }
Set-Content -Path $pidFile -Value $PID
Log "watcher $PID started"

function Read-Id($dir) {
    $f = Join-Path $dir '.build-id'
    if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { '' }
}
# The installed app (not test copies, which run from dev\build\stage), or its helper, still running?
function Installed-Running {
    @(Get-Process -Name 'FTL Player', 'FreeTube Light', 'deno' -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($app + '\', 'OrdinalIgnoreCase') -and
        -not $_.Path.StartsWith($dev + '\', 'OrdinalIgnoreCase') }).Count -gt 0
}

while ($true) {
    $staged = Read-Id $stage
    $readyFile = Join-Path $stage '.ready'
    $ready = if (Test-Path $readyFile) { (Get-Content $readyFile -Raw).Trim() } else { '' }
    if ($staged -and $ready -eq $staged -and $staged -ne (Read-Id $app) -and -not (Installed-Running)) {
        Start-Sleep -Seconds 2   # let the helper finish exiting, and make sure it wasn't just reopened
        if (-not (Installed-Running)) {
            $out = & $bash (Join-Path $dev 'install.sh') 2>&1 | Out-String
            Log ("build $staged`: " + $out.Trim())
        }
    }
    Start-Sleep -Seconds 3
}
