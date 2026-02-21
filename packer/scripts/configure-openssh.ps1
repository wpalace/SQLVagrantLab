#Requires -Version 7.0
<#
.SYNOPSIS
    Configures OpenSSH Server on a Windows Server VM during Packer build.

.DESCRIPTION
    This script runs via the WinRM communicator during Packer image construction,
    BEFORE Sysprep. It installs the OpenSSH Server Windows optional feature,
    configures the service for auto-start, seeds the Vagrant insecure SSH public
    key, sets PowerShell 7 as the default SSH shell, and opens TCP 22 in the
    Windows Firewall.

    After Sysprep + box deployment, 'vagrant ssh' will use OpenSSH for all
    connections — no WinRM required at runtime.

.ENVIRONMENT
    VAGRANT_KEY_URL   URL to fetch the Vagrant insecure public key from.
                      Defaults to the canonical GitHub URL.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step ([string]$msg) { Write-Host "==> [OpenSSH] $msg" -ForegroundColor Cyan }

$vagrantKeyUrl = $env:VAGRANT_KEY_URL `
    ?? 'https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub'

# ── 1. Install OpenSSH Server optional feature ────────────────────────────────

Write-Step 'Installing OpenSSH.Server optional feature...'

$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    Write-Host '    Installed OpenSSH.Server'
} else {
    Write-Host '    OpenSSH.Server already installed'
}

# ── 2. Configure sshd service ─────────────────────────────────────────────────

Write-Step 'Configuring sshd service...'
Set-Service -Name sshd       -StartupType Automatic
Set-Service -Name ssh-agent  -StartupType Automatic
Start-Service sshd
Start-Service ssh-agent
Write-Host '    sshd service set to Automatic and started'

# ── 3. Seed Vagrant insecure public key ──────────────────────────────────────
# Vagrant expects this key to be present so it can connect on first boot.
# On first 'vagrant up', Vagrant replaces it with a machine-specific key.

Write-Step 'Seeding Vagrant insecure public key...'

$sshDir = 'C:\Users\vagrant\.ssh'
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}
$authKeys = Join-Path $sshDir 'authorized_keys'

try {
    $pubKey = (Invoke-WebRequest -Uri $vagrantKeyUrl -UseBasicParsing).Content.Trim()
} catch {
    # Fallback: hard-code the well-known Vagrant insecure key in case the build
    # environment has no internet access at image-build time.
    Write-Warning "Could not fetch key from $vagrantKeyUrl — using embedded fallback"
    $pubKey = 'ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q4Pnm5QFbmWD7L18GiL8voRRPHWG9t6EhEDKDt3Cq0eTQmmEQPtDqE98Fk2j5TXXPHqOAM7gOQ== vagrant insecure key'
}

Set-Content -Path $authKeys -Value $pubKey -Encoding Ascii -Force

# Fix permissions: sshd requires strict ownership on authorized_keys
$acl = Get-Acl $authKeys
$acl.SetAccessRuleProtection($true, $false)
$rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    'vagrant', 'FullControl', 'Allow')
$acl.SetAccessRule($rule)
$acl | Set-Acl $authKeys

Write-Host '    authorized_keys written'

# ── 4. Set PowerShell 7 as default SSH shell ─────────────────────────────────

Write-Step 'Setting PowerShell 7 as default SSH shell...'

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if ($pwsh) {
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' `
        -Name DefaultShell `
        -Value $pwsh `
        -PropertyType String `
        -Force | Out-Null
    Write-Host "    DefaultShell => $pwsh"
} else {
    Write-Warning 'pwsh not found — SSH shell will default to cmd.exe. Install PowerShell 7 before building.'
}

# ── 5. Open TCP 22 in Windows Firewall ───────────────────────────────────────

Write-Step 'Opening TCP 22 in Windows Firewall...'

$ruleName = 'OpenSSH-Server-In-TCP'
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -Name        $ruleName `
        -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled     True `
        -Direction   Inbound `
        -Protocol    TCP `
        -Action      Allow `
        -LocalPort   22 | Out-Null
    Write-Host '    Firewall rule created'
} else {
    Write-Host '    Firewall rule already exists'
}

# ── 6. Harden sshd_config ────────────────────────────────────────────────────

Write-Step 'Applying sshd_config hardening for lab...'

$sshdConfig = "$env:ProgramData\ssh\sshd_config"
$settings = @(
    'PubkeyAuthentication yes'
    'PasswordAuthentication yes'     # Vagrant needs this before key exchange
    'PermitRootLogin no'
    'AuthorizedKeysFile .ssh/authorized_keys'
    'Subsystem sftp sftp-server.exe'
)

$content = Get-Content $sshdConfig -Raw
foreach ($line in $settings) {
    $key = $line.Split(' ')[0]
    if ($content -match "(?m)^#?\s*$key\s") {
        $content = $content -replace "(?m)^#?\s*$key\s.*", $line
    } else {
        $content += "`n$line"
    }
}
Set-Content $sshdConfig -Value $content -Encoding Ascii -Force

Restart-Service sshd
Write-Host '    sshd_config updated and service restarted'

Write-Host "`n==> [OpenSSH] Configuration complete.`n" -ForegroundColor Green
