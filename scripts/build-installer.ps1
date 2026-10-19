param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $ProjectRoot).Path
$version = [regex]::Match([IO.File]::ReadAllText((Join-Path $rootPath 'pubspec.yaml')), '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Groups[1].Value
if (!$version) { throw 'No application version found.' }
$packagePath = Join-Path $rootPath "dist/Hongputao-Windows-$version"
$applicationPath = Join-Path $packagePath 'hongguo_studio.exe'
if (!(Test-Path -LiteralPath $applicationPath)) { throw 'Run scripts/package.ps1 first.' }
if ((Get-Item -LiteralPath $applicationPath).VersionInfo.ProductVersion -notlike "$version+*") {
    throw 'Windows executable version does not match pubspec.yaml. Rebuild before packaging.'
}
$compiler = Get-Command ISCC.exe -ErrorAction Stop
& $compiler.Source "/DAppVersion=$version" "/DPackageDir=$packagePath" "/DOutputPath=$(Join-Path $rootPath 'dist')" (Join-Path $rootPath 'installer/windows.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
$lines = Get-ChildItem -LiteralPath (Join-Path $rootPath 'dist') -File |
    Where-Object { $_.Name -match ('-' + [regex]::Escape($version) + '(?:-Setup)?\.(zip|apk|exe)$') } | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
        "$hash  $($_.Name)"
    }
$lines | Set-Content -LiteralPath (Join-Path $rootPath 'dist/SHA256SUMS.txt') -Encoding utf8
Write-Output "Windows installer ready: dist/Hongputao-Windows-$version-Setup.exe"
