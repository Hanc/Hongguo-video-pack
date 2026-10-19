param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $ProjectRoot).Path
$version = [regex]::Match([IO.File]::ReadAllText((Join-Path $rootPath 'pubspec.yaml')), '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Groups[1].Value
$setupPath = Join-Path $rootPath "dist/Hongputao-Windows-$version-Setup.exe"
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{D728C724-5418-4D48-A1B9-EE87CFE48DB5}_is1'
if (Test-Path -LiteralPath $uninstallKey) { throw 'An installed application already exists; refusing to replace it for QA.' }
$menuFolder = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs/红葡萄'
if (Test-Path -LiteralPath $menuFolder) { throw 'An existing Start menu folder would be overwritten; refusing to replace it for QA.' }
$qaRoot = Join-Path $rootPath ('.local/installer-qa-' + (Get-Date -Format 'yyyyMMddHHmmss'))
$installPath = Join-Path $qaRoot 'app'
New-Item -ItemType Directory -Path $qaRoot | Out-Null
$result = @{version=$version; installed=$false; smoke=$false; uninstalled=$false; userFilePreserved=$false}
$priorPath = $env:PATH
$priorJava = $env:JAVA_HOME
try {
    $installArguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',
        ('/DIR="' + $installPath + '"'),
        '/MERGETASKS=!desktopicon',('/LOG="' + (Join-Path $qaRoot 'install.log') + '"'))
    $installProcess = Start-Process -FilePath $setupPath -ArgumentList $installArguments -WindowStyle Hidden -PassThru -Wait
    if ($installProcess.ExitCode -ne 0) { throw "Installer failed: $($installProcess.ExitCode)" }
    $installedExe = Join-Path $installPath 'hongguo_studio.exe'
    if (!(Test-Path -LiteralPath $installedExe) -or !(Test-Path -LiteralPath $uninstallKey)) { throw 'Application or uninstall registration missing.' }
    $shortcut = Join-Path $menuFolder '红葡萄.lnk'
    if (!(Test-Path -LiteralPath $shortcut)) { throw 'Start menu shortcut missing.' }
    $result.installed = $true
    $sentinel = Join-Path $installPath 'user-export.keep'
    'User-created export sentinel; never delete during uninstall.' | Set-Content -LiteralPath $sentinel
    $env:PATH = 'C:/Windows/system32;C:/Windows'
    $env:JAVA_HOME = $null
    $appProcess = Start-Process -FilePath $installedExe -ArgumentList '--smoke' -WorkingDirectory $rootPath -WindowStyle Hidden -PassThru -Wait
    if ($appProcess.ExitCode -ne 0) { throw "Installed runtime check failed: $($appProcess.ExitCode)" }
    $result.smoke = $true
} finally {
    $env:PATH = $priorPath
    $env:JAVA_HOME = $priorJava
    $uninstaller = Join-Path $installPath 'unins000.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        $uninstallArguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="' + (Join-Path $qaRoot 'uninstall.log') + '"'))
        $removeProcess = Start-Process -FilePath $uninstaller -ArgumentList $uninstallArguments -WindowStyle Hidden -PassThru -Wait
        $result.uninstalled = $removeProcess.ExitCode -eq 0 -and !(Test-Path -LiteralPath (Join-Path $installPath 'hongguo_studio.exe')) -and !(Test-Path -LiteralPath $uninstallKey)
        $result.userFilePreserved = Test-Path -LiteralPath (Join-Path $installPath 'user-export.keep')
    }
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $qaRoot 'result.json') -Encoding utf8
    $result | ConvertTo-Json
}
if (!$result.uninstalled -or !$result.userFilePreserved) { throw 'Installer cleanup or data preservation check failed.' }
