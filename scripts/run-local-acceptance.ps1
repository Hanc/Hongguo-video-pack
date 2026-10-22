# Run one of the local acceptance flows against the built Windows release.
#
# Why this wrapper exists: the acceptance flows use media_kit, which writes
# temporary files through Directory.systemTemp (i.e. %TEMP%). On machines where
# %TEMP% is not writable for this process - a poisoned ACL, a redirected
# profile, or an executable that the host confines to one drive - the run dies
# with "PathAccessException: Cannot create file ... errno = 5" and, before
# 0.8.1, exited silently with code 1.
#
# So this script points TEMP/TMP at a directory inside the repository, which is
# always writable here, and only then launches the release executable.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-local-acceptance.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-local-acceptance.ps1 -Mode switch
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-local-acceptance.ps1 -Mode playback
param(
    [ValidateSet('switch', 'playback', 'fullscreen', 'search', 'smoke')]
    [string]$Mode = 'switch'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$exe = Join-Path $root 'build\windows\x64\runner\Release\hongguo_studio.exe'
if (-not (Test-Path $exe)) {
    throw "Release executable not found: $exe. Run 'flutter build windows --release' first."
}

$temp = Join-Path $root '.local\tmp'
New-Item -ItemType Directory -Force -Path $temp | Out-Null

$reportPath = switch ($Mode) {
    'switch' { '.local\switch-acceptance\result.json' }
    'playback' { '.local\playback-acceptance\result.json' }
    'fullscreen' { '.local\fullscreen-acceptance\result.json' }
    'search' { '.local\search-acceptance\result.json' }
    default { '.local\native-smoke\result.json' }
}

$log = Join-Path $root ".local\acceptance-$Mode.log"
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
$env:TEMP = $temp
$env:TMP = $temp
try {
    # The acceptance flows resolve .local/... relative to the working directory,
    # so the process must start in the repository root.
    #
    # Launch through cmd.exe: this executable writes through the console handle,
    # so PowerShell's own pipe redirection captures nothing while cmd's file
    # redirection keeps both streams.
    & cmd /c "`"$exe`" --$Mode-acceptance > `"$log`" 2>&1"
    $code = $LASTEXITCODE
}
finally {
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
}

$full = Join-Path $root $reportPath
Write-Output "mode=$Mode exit=$code log=$log"
if (Test-Path $full) {
    Get-Content $full -Raw
}
else {
    Write-Output "no report written; see $log"
    Get-Content $log -Tail 40
}
if ($code -ne 0) { exit $code }
