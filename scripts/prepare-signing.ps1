param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$signingDir = Join-Path $ProjectRoot '.local/signing'
$keyFile = Join-Path $signingDir 'hongguo-release.jks'
$properties = Join-Path $ProjectRoot 'android/key.properties'
if ((Test-Path -LiteralPath $keyFile) -and (Test-Path -LiteralPath $properties)) {
    Write-Output 'Existing release signing key retained.'
    exit 0
}
if ((Test-Path -LiteralPath $keyFile) -or (Test-Path -LiteralPath $properties)) { throw 'Signing state incomplete. Restore the existing key/properties; do not replace a released key.' }
New-Item -ItemType Directory -Force $signingDir | Out-Null
$keytool = (Get-Command keytool.exe -ErrorAction Stop).Source
$bytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$password = [Convert]::ToBase64String($bytes)
& $keytool -genkeypair -keystore $keyFile -alias hongguo -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=Hongguo Studio,O=Local Development,C=CN' -storepass $password -keypass $password
if ($LASTEXITCODE -ne 0) { throw 'Key generation failed' }
@("storePassword=$password", "keyPassword=$password", 'keyAlias=hongguo', ('storeFile=' + $keyFile.Replace('\','/'))) | Set-Content -LiteralPath $properties -Encoding utf8
Write-Output 'Release signing key prepared under .local/signing. Back up this directory and android/key.properties privately.'
