param(
    [ValidateSet('Enable', 'Disable', 'Status')][string]$Action = 'Status',
    [string]$Serial = 'emulator-5554',
    [string]$Adb = 'C:/leidian/LDPlayer9/adb.exe',
    [string]$CertificateName
)
$ErrorActionPreference = 'Stop'
function Invoke-Device([string]$Command) {
    $result = & $Adb -s $Serial shell $Command
    if ($LASTEXITCODE -ne 0) { throw "Device command failed: $Command" }
    return $result
}
$target = '/system/etc/security/cacerts'
$overlay = '/data/local/tmp/pcapdroid-system-ca'
if ($Action -eq 'Status') {
    Invoke-Device 'id'
    Invoke-Device "mount | grep ' $target '"
    exit
}
if ((Invoke-Device 'id') -notmatch 'uid=0') {
    throw 'Root ADB is required. Enable Root in this emulator, restart it, then run adb root.'
}
$mounted = (Invoke-Device 'mount') -match " $target "
if ($Action -eq 'Disable') {
    if ($mounted) { Invoke-Device "umount $target" }
    Write-Output 'Temporary system CA mount removed. Restart target apps before testing.'
    exit
}
if ($CertificateName -notmatch '^[0-9a-f]{8}\.[0-9]+$') {
    throw 'Supply the verified PCAPdroid public CA filename from /data/misc/user/0/cacerts-added. Never supply a private key.'
}
if ($mounted) { throw 'Certificate directory already mounted. Inspect Status or Disable first.' }
$source = "/data/misc/user/0/cacerts-added/$CertificateName"
Invoke-Device "test -f $source"
Invoke-Device "test ! -e $target/$CertificateName"
Invoke-Device "mkdir -p $overlay"
Invoke-Device "cp $target/* $overlay/"
$temporaryCa = Join-Path ([IO.Path]::GetTempPath()) ('pcapdroid-public-ca-' + [guid]::NewGuid().ToString('N'))
try {
    & $Adb -s $Serial pull $source $temporaryCa | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read public CA.' }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($temporaryCa)
    if ($certificate.Subject -notmatch 'CN=PCAPdroid CA') { throw 'Selected certificate is not the PCAPdroid CA.' }
    $base64 = [Convert]::ToBase64String($certificate.RawData, [Base64FormattingOptions]::InsertLineBreaks)
    [IO.File]::WriteAllText($temporaryCa, "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----`n", [Text.Encoding]::ASCII)
    $certificate.Dispose()
    & $Adb -s $Serial push $temporaryCa "$overlay/$CertificateName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not install public CA.' }
} finally {
    if (Test-Path -LiteralPath $temporaryCa) { Remove-Item -LiteralPath $temporaryCa }
}
Invoke-Device "chown 0:0 $overlay/$CertificateName"
Invoke-Device "chmod 644 $overlay/$CertificateName"
Invoke-Device "chcon -R u:object_r:system_file:s0 $overlay"
Invoke-Device "mount --bind $overlay $target"
Invoke-Device "ls -lZ $target/$CertificateName"
Write-Output 'Temporary system CA mount enabled. Restart target apps. Reboot or Disable removes the mount; HTTPS decryption still requires verification.'
