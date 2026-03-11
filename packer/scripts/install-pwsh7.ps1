<#
.SYNOPSIS
    Installs PowerShell 7 on the guest VM during the Packer build.

.DESCRIPTION
    This script MUST remain compatible with Windows PowerShell 5.1 — it runs
    before PowerShell 7 is present and intentionally has NO #Requires directive.

    Uses the ZIP package (not MSI) to avoid Windows Installer service conflicts
    (e.g. exit code 16001 when Windows Installer is busy with post-setup tasks).
    Extracts directly to C:\Program Files\PowerShell\7\, which is the standard
    install path that execute_command overrides in windows-sql.pkr.hcl rely on.

    To update the version, change $PwshVersion below and rebuild the image.
#>

$PwshVersion = '7.5.0'
$ZipName = "PowerShell-$PwshVersion-win-x64.zip"
$ZipUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/$ZipName"
$ZipPath = Join-Path $env:TEMP $ZipName
$InstallDir = 'C:\Program Files\PowerShell\7'

Write-Host "==> [install-pwsh7] Downloading PowerShell $PwshVersion ZIP..."
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
}
catch {
    Write-Error "Failed to download PowerShell ZIP from $ZipUrl : $_"
    exit 1
}

Write-Host "==> [install-pwsh7] Extracting to $InstallDir ..."
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
Remove-Item $ZipPath -ErrorAction SilentlyContinue

# Verify pwsh is reachable
$pwshExe = Join-Path $InstallDir 'pwsh.exe'
if (Test-Path $pwshExe) {
    $ver = & $pwshExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    Write-Host "==> [install-pwsh7] PowerShell $ver ready at $pwshExe"
}
else {
    Write-Error "pwsh.exe not found at '$pwshExe' after extraction."
    exit 1
}
