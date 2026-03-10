#Requires -Version 7.0
<#
.SYNOPSIS
    One-time prerequisite installer for the SqlVagrantLab project.

.DESCRIPTION
    Run this script ONCE on the Linux host before building Packer images or
    running Deploy-Lab.ps1. It installs all required tools and downloads the
    Windows Server Evaluation and SQL Server Developer ISOs.

.PARAMETER MediaPath
    Directory to download ISOs into. Defaults to ~/packer-media.

.PARAMETER SkipDownloads
    Skip ISO downloads (assume media is already present at MediaPath).

.PARAMETER DryRun
    Print what would be done without making any changes.

.EXAMPLE
    sudo pwsh -File Install-Prerequisites.ps1
    sudo pwsh -File Install-Prerequisites.ps1 -MediaPath /data/isos -SkipDownloads
#>
[CmdletBinding()]
param(
    [string]$MediaPath = '/opt/packer-media',
    [switch]$SkipDownloads,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step ([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   ([string]$msg) { Write-Host "  ✅  $msg" -ForegroundColor Green }
function Write-Warn ([string]$msg) { Write-Host "  ⚠️   $msg" -ForegroundColor Yellow }
function Write-Fail ([string]$msg) { Write-Host "  ❌  $msg" -ForegroundColor Red }

function Invoke-Step ([string]$Description, [scriptblock]$Action) {
    Write-Step $Description
    if ($DryRun) { Write-Warn "[DryRun] Would execute: $Description"; return }
    try { & $Action; Write-Ok $Description }
    catch { Write-Fail "Failed: $_"; throw }
}

function Test-Command ([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-OsDistro {
    # Use bash sourcing — more reliable than ConvertFrom-StringData on /etc/os-release
    if (Test-Path /etc/os-release) {
        $id = & bash -c '. /etc/os-release && echo "$ID"' 2>/dev/null
        return $id.Trim().ToLower()
    }
    return 'unknown'
}

function Get-OsCodename {
    & bash -c '. /etc/os-release && echo "$VERSION_CODENAME"' 2>/dev/null | ForEach-Object { $_.Trim() }
}

function Install-AptPackage ([string[]]$Packages) {
    foreach ($pkg in $Packages) {
        # dpkg -s exits 0 only when package status is 'install ok installed'
        $rc = & bash -c "dpkg -s '$pkg' > /dev/null 2>&1; echo \$?"
        if ($rc.Trim() -ne '0') {
            Write-Host "  Installing $pkg..."
            & bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y '$pkg'"
            if ($LASTEXITCODE -ne 0) { throw "apt-get install $pkg failed" }
        }
        else {
            Write-Host "  $pkg already installed — skipping"
        }
    }
}


function Add-AptRepo ([string]$KeyUrl, [string]$KeyPath, [string]$RepoLine, [string]$ListFile) {
    if (-not (Test-Path $ListFile)) {
        Write-Host "  Adding repo: $ListFile"
        & bash -c "curl -fsSL '$KeyUrl' | gpg --dearmor -o '$KeyPath'"
        & bash -c "echo '$RepoLine' > '$ListFile'"
        & bash -c 'apt-get update -qq'
    }
    else {
        Write-Host "  Repo already configured: $ListFile"
    }
}


function Get-FileWithProgress ([string]$Uri, [string]$Destination, [string]$ExpectedSha256) {
    if (Test-Path $Destination) {
        Write-Warn "Already exists: $Destination — verifying checksum..."
    }
    else {
        Write-Host "  ⬇️  Downloading $(Split-Path $Destination -Leaf) ..."
        $tmpFile = "$Destination.tmp"
        try {
            $client = [System.Net.Http.HttpClient]::new()
            $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $total = $response.Content.Headers.ContentLength
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $out = [System.IO.File]::OpenWrite($tmpFile)
            $buffer = [byte[]]::new(1MB)
            $read = 0; $bytes = 0
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $out.Write($buffer, 0, $read)
                $bytes += $read
                if ($total -gt 0) {
                    $pct = [int](($bytes / $total) * 100)
                    Write-Progress -Activity "Downloading $(Split-Path $Destination -Leaf)" -PercentComplete $pct
                }
            }
            $out.Close(); $stream.Close()
            Write-Progress -Completed -Activity 'Done'
            Move-Item $tmpFile $Destination -Force
        }
        catch {
            Remove-Item $tmpFile -ErrorAction SilentlyContinue
            throw
        }
    }

    # Checksum
    if ($ExpectedSha256) {
        $actual = (Get-FileHash -Algorithm SHA256 $Destination).Hash
        if ($actual.ToLower() -ne $ExpectedSha256.ToLower()) {
            throw "Checksum mismatch for $Destination`n  Expected: $ExpectedSha256`n  Got:      $actual"
        }
        Write-Ok "Checksum verified: $(Split-Path $Destination -Leaf)"
    }
    else {
        Write-Warn "No checksum provided for $(Split-Path $Destination -Leaf) — skipping verification"
    }
}

# ── ISO Catalogue ─────────────────────────────────────────────────────────────
# NOTE: Microsoft frequently rotates Evaluation ISO URLs. If a URL is stale,
#       visit https://www.microsoft.com/evalcenter and update accordingly.
#       SHA-256 checksums are left empty where Microsoft does not publish them;
#       update after downloading if you want strict verification.

$Isos = @(
    @{
        Name   = 'Windows Server 2022 Evaluation (180-day)'
        File   = 'WinServer2022Eval.iso'
        Url    = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
        Sha256 = ''   # Populate after first download: (Get-FileHash WinServer2022Eval.iso).Hash
    }
    @{
        Name   = 'Windows Server 2025 Evaluation (180-day)'
        File   = 'WinServer2025Eval.iso'
        Url    = 'https://go.microsoft.com/fwlink/?linkid=2293176&clcid=0x409&culture=en-us&country=US'
        Sha256 = ''
    }
    @{
        Name   = 'SQL Server 2022 Developer Edition'
        File   = 'SQLServer2022-Dev.iso'
        # The SQL Developer ISO is download-manager gated. Use the offline bootstrapper:
        # Run: Setup.exe /Action=Download /MediaPath=<dir> /MediaType=ISO /Quiet
        # Set Url to the bootstrapper .exe, or pre-download the ISO and set SkipDownloads.
        Url    = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-DEV-x64-ENU.iso'
        Sha256 = ''
    }
    @{
        Name            = 'SQL Server 2025 Developer Edition'
        File            = 'SQLServer2025-Dev.iso'
        # SQL 2025 ships a bootstrapper .exe that downloads the real ISO silently.
        # We download the bootstrapper, run it with /Action=Download /MediaType=ISO, then delete the exe.
        Url             = 'https://go.microsoft.com/fwlink/?linkid=2257477'  # SQL 2025 Dev bootstrapper
        BootstrapperExe = 'SQLServer2025-Dev-Setup.exe'
        Sha256          = ''
        UseBootstrapper = $true
    }
)

# ── Script Summary ────────────────────────────────────────────────────────────

$Results = [ordered]@{}

# ── 1. Detect distro ─────────────────────────────────────────────────────────

$distro = Get-OsDistro
Write-Host "Detected Linux distro: $distro" -ForegroundColor Magenta

if ($distro -notin @('ubuntu', 'debian', 'fedora', 'rhel', 'centos', 'rocky')) {
    Write-Warn "Distro '$distro' not explicitly tested. Attempting apt-based installation."
}
$useApt = $distro -in @('ubuntu', 'debian')

# ── 2. QEMU ──────────────────────────────────────────────────────────────────

Invoke-Step 'Install QEMU + KVM + utilities' {
    if ($useApt) {
        & bash -c 'apt-get update -qq'
        Install-AptPackage @('qemu-system-x86', 'qemu-utils', 'qemu-kvm', 'libvirt-daemon-system', 'virtinst', 'bridge-utils', 'sshpass')
        $labUser = $env:SUDO_USER ?? (& bash -c 'logname 2>/dev/null || echo $SUDO_USER')
        if ($labUser) { & bash -c "usermod -aG kvm,libvirt '$labUser'" }
    }
    else {
        & bash -c 'dnf install -y qemu-kvm qemu-img libvirt libvirt-client virt-install sshpass'
        & bash -c 'systemctl enable --now libvirtd'
    }
}
$Results['QEMU'] = Test-Command 'qemu-system-x86_64'

# ── 2b. Configure lab network bridges ─────────────────────────────────────────
# Creates br0 (RegionA: 10.0.50.1/24) and br1 (RegionB: 10.0.51.1/24).
# Both bridges are created now even if RegionB is not yet active, so they
# are ready when the second region is enabled in config.yaml.

$LabBridges = @(
    @{ Name = 'br0'; HostIp = '10.0.50.1'; Prefix = '24'; Region = 'RegionA' }
    @{ Name = 'br1'; HostIp = '10.0.51.1'; Prefix = '24'; Region = 'RegionB' }
)

Invoke-Step 'Configure lab network bridges (br0 = RegionA, br1 = RegionB)' {
    # ── Netplan persistence (Ubuntu/Debian with systemd-networkd or NetworkManager) ──
    $netplanDir = '/etc/netplan'
    if ($useApt -and (Test-Path $netplanDir)) {
        $netplanFile = "$netplanDir/60-lab-bridges.yaml"
        if (-not (Test-Path $netplanFile)) {
            Write-Host '  Writing netplan config for lab bridges...'
            $bridgeEntries = ($LabBridges | ForEach-Object {
                @"
    $($_.Name):
      interfaces: []
      addresses:
        - $($_.HostIp)/$($_.Prefix)
      dhcp4: false
      dhcp6: false
"@
            }) -join "`n"
            @"
network:
  version: 2
  bridges:
$bridgeEntries
"@ | Set-Content $netplanFile -Encoding Utf8
            & bash -c 'netplan apply' 2>&1 | Write-Host
        }
        else {
            Write-Host "  Netplan config already exists: $netplanFile"
        }
    }

    # ── Bring bridges up immediately (idempotent — safe to re-run) ───────────
    foreach ($br in $LabBridges) {
        $exists = (& bash -c "ip link show '$($br.Name)' 2>/dev/null; echo $?").Trim()
        if ($exists -eq '0') {
            Write-Host "  $($br.Name) already exists — skipping creation"
        }
        else {
            Write-Host "  Creating $($br.Name) ($($br.Region): $($br.HostIp)/$($br.Prefix))..."
            & bash -c "ip link add name '$($br.Name)' type bridge"
            & bash -c "ip addr add '$($br.HostIp)/$($br.Prefix)' dev '$($br.Name)'"
            & bash -c "ip link set '$($br.Name)' up"
        }
    }

    # ── /etc/qemu/bridge.conf — allow QEMU to attach TAP devices ─────────────
    $qemuConfDir  = '/etc/qemu'
    $bridgeConf   = "$qemuConfDir/bridge.conf"
    if (-not (Test-Path $qemuConfDir)) { New-Item -ItemType Directory -Path $qemuConfDir -Force | Out-Null }
    $allowLines   = $LabBridges | ForEach-Object { "allow $($_.Name)" }
    $confContent  = $allowLines -join "`n"
    # Always rewrite to ensure both bridges are listed
    $confContent | Set-Content $bridgeConf -Encoding Utf8
    Write-Host "  Wrote $bridgeConf :"
    $allowLines | ForEach-Object { Write-Host "    $_" }

    # ── SUID on qemu-bridge-helper ────────────────────────────────────────────
    # Required so QEMU (running as the vagrant user under sudo) can create TAP
    # devices and attach them to the bridge without a separate root process.
    $helperPaths = @(
        '/usr/lib/qemu/qemu-bridge-helper'
        '/usr/libexec/qemu-bridge-helper'
    )
    $helperFound = $false
    foreach ($h in $helperPaths) {
        if (Test-Path $h) {
            & bash -c "chmod u+s '$h'"
            Write-Ok "SUID set on $h"
            $helperFound = $true
            break
        }
    }
    if (-not $helperFound) {
        Write-Warn 'qemu-bridge-helper not found at expected paths. Bridge networking may require sudo for TAP creation.'
    }

    # ── dnsmasq (DHCP for the bridges) ────────────────────────────────────────
    if ($useApt) {
        Install-AptPackage @('dnsmasq')
    } else {
        & bash -c 'dnf install -y dnsmasq'
    }

    $dnsmasqConfDir = '/etc/dnsmasq.d'
    if (-not (Test-Path $dnsmasqConfDir)) { New-Item -ItemType Directory -Path $dnsmasqConfDir -Force | Out-Null }
    
    $dnsmasqConfFile = "$dnsmasqConfDir/sqlvagrantlab.conf"
    Write-Host "  Writing DHCP configuration to $dnsmasqConfFile..."
    @"
# Managed by Install-Prerequisites.ps1
# Bind only to the lab bridges
interface=br0
interface=br1
bind-interfaces

# Do not provide DNS, only DHCP
port=0

# RegionA (br0) DHCP range
dhcp-range=interface:br0,10.0.50.100,10.0.50.254,24h
# RegionB (br1) DHCP range
dhcp-range=interface:br1,10.0.51.100,10.0.51.254,24h

# Static DHCP reservations (MAC address -> IP)
# These MACs are generated deterministically in Deploy-Lab.ps1
# Domain Controllers (10-19)
dhcp-host=52:54:0a:00:32:0a,10.0.50.10,dc01
dhcp-host=52:54:0a:00:33:0a,10.0.51.10,dc02

# Region A (br0) SQL hosts (20-29)
dhcp-host=52:54:0a:00:32:14,10.0.50.20
dhcp-host=52:54:0a:00:32:15,10.0.50.21
dhcp-host=52:54:0a:00:32:16,10.0.50.22
dhcp-host=52:54:0a:00:32:17,10.0.50.23
dhcp-host=52:54:0a:00:32:18,10.0.50.24
dhcp-host=52:54:0a:00:32:19,10.0.50.25
dhcp-host=52:54:0a:00:32:1a,10.0.50.26
dhcp-host=52:54:0a:00:32:1b,10.0.50.27
dhcp-host=52:54:0a:00:32:1c,10.0.50.28
dhcp-host=52:54:0a:00:32:1d,10.0.50.29

# Region B (br1) SQL hosts (20-29)
dhcp-host=52:54:0a:00:33:14,10.0.51.20
dhcp-host=52:54:0a:00:33:15,10.0.51.21
dhcp-host=52:54:0a:00:33:16,10.0.51.22
dhcp-host=52:54:0a:00:33:17,10.0.51.23
dhcp-host=52:54:0a:00:33:18,10.0.51.24
dhcp-host=52:54:0a:00:33:19,10.0.51.25
dhcp-host=52:54:0a:00:33:1a,10.0.51.26
dhcp-host=52:54:0a:00:33:1b,10.0.51.27
dhcp-host=52:54:0a:00:33:1c,10.0.51.28
dhcp-host=52:54:0a:00:33:1d,10.0.51.29
"@ | Set-Content $dnsmasqConfFile -Encoding Utf8

    & bash -c 'systemctl restart dnsmasq || systemctl enable --now dnsmasq'
    Write-Ok 'dnsmasq configured and restarted'
}
$Results['Bridges (br0/br1)'] = $LabBridges | ForEach-Object {
    (& bash -c "ip link show '$($_.Name)' 2>/dev/null; echo $?").Trim() -eq '0'
} | Where-Object { $_ -eq $false } | Measure-Object | Select-Object -ExpandProperty Count
$Results['Bridges (br0/br1)'] = ($Results['Bridges (br0/br1)'] -eq 0)  # true if all up

& bash -c "systemctl is-active --quiet dnsmasq"
$Results['dnsmasq'] = ($LASTEXITCODE -eq 0)

# ── 3. Packer ─────────────────────────────────────────────────────────────────

Invoke-Step 'Install HashiCorp Packer' {
    if (-not (Test-Command 'packer')) {
        if ($useApt) {
            $codename = Get-OsCodename
            $keyPath = '/usr/share/keyrings/hashicorp-archive-keyring.gpg'
            $repoLine = "deb [signed-by=$keyPath] https://apt.releases.hashicorp.com $codename main"
            Add-AptRepo 'https://apt.releases.hashicorp.com/gpg' $keyPath $repoLine '/etc/apt/sources.list.d/hashicorp.list'
            Install-AptPackage @('packer')
        }
        else {
            & bash -c 'dnf install -y dnf-plugins-core && dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo && dnf install -y packer'
        }
    }
    else {
        Write-Ok 'packer already installed'
    }
}
$Results['Packer'] = Test-Command 'packer'

# ── 4. Vagrant ────────────────────────────────────────────────────────────────

Invoke-Step 'Install HashiCorp Vagrant' {
    if (-not (Test-Command 'vagrant')) {
        if ($useApt) {
            $codename = Get-OsCodename
            $keyPath = '/usr/share/keyrings/hashicorp-archive-keyring.gpg'
            $repoLine = "deb [signed-by=$keyPath] https://apt.releases.hashicorp.com $codename main"
            Add-AptRepo 'https://apt.releases.hashicorp.com/gpg' $keyPath $repoLine '/etc/apt/sources.list.d/hashicorp.list'
            Install-AptPackage @('vagrant')
        }
        else {
            & bash -c 'dnf install -y vagrant'
        }
    }
    else {
        Write-Ok 'vagrant already installed'
    }
}
$Results['Vagrant'] = Test-Command 'vagrant'

# ── 5. Vagrant plugins ──────────────────────────────────────────────────────────

Invoke-Step 'Install Vagrant plugins (qemu, reload)' {
    if (-not (Test-Command 'vagrant')) { Write-Warn 'vagrant not installed yet — skipping plugin install'; return }
    $plugins = & vagrant plugin list 2>&1
    
    if ($plugins -notmatch 'vagrant-qemu') {
        & vagrant plugin install vagrant-qemu
    }
    else {
        Write-Ok 'vagrant-qemu already installed'
    }

    if ($plugins -notmatch 'vagrant-reload') {
        & vagrant plugin install vagrant-reload
    }
    else {
        Write-Ok 'vagrant-reload already installed'
    }
}
$Results['vagrant-qemu'] = (Test-Command 'vagrant') -and ((& vagrant plugin list 2>&1) -match 'vagrant-qemu')
$Results['vagrant-reload'] = (Test-Command 'vagrant') -and ((& vagrant plugin list 2>&1) -match 'vagrant-reload')

# ── 6. PowerShell 7.5.1 ──────────────────────────────────────────────────────

Invoke-Step 'Install PowerShell 7.5.1' {
    $pwshOk = $false
    if (Test-Command 'pwsh') {
        $ver = & pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        if ($ver -ge '7.5.1') { Write-Ok "pwsh $ver already installed"; $pwshOk = $true }
    }
    if (-not $pwshOk) {
        if ($useApt) {
            & bash -c @'
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/microsoft-debian-bullseye-prod bullseye main" > /etc/apt/sources.list.d/microsoft.list
apt-get update -qq && apt-get install -y powershell
'@
        }
        else {
            & bash -c 'rpm --import https://packages.microsoft.com/keys/microsoft.asc && curl -fsSL https://packages.microsoft.com/config/rhel/8/prod.repo > /etc/yum.repos.d/microsoft.repo && dnf install -y powershell'
        }
    }
}
$Results['PowerShell'] = Test-Command 'pwsh'

# ── 7. powershell-yaml module ─────────────────────────────────────────────────

Invoke-Step 'Install powershell-yaml PS module' {
    $mod = Get-Module -ListAvailable -Name powershell-yaml
    if (-not $mod) {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
    }
    else {
        Write-Ok "powershell-yaml $($mod.Version) already installed"
    }
}
$Results['powershell-yaml'] = $null -ne (Get-Module -ListAvailable -Name powershell-yaml)

# ── 8. dbatools module ────────────────────────────────────────────────────────

Invoke-Step 'Download dbatools PS module for VMs' {
    $installsDir = Join-Path $PSScriptRoot 'data' 'installs'
    if (-not (Test-Path $installsDir)) { New-Item -ItemType Directory -Path $installsDir -Force | Out-Null }
    
    $mod = Get-Module -ListAvailable -Name dbatools
    if (-not $mod) {
        Write-Host "  Installing dbatools on host..."
        Install-Module -Name dbatools -Scope CurrentUser -Force -AllowClobber
    }
    
    $dbatoolsDest = Join-Path $installsDir 'dbatools'
    if (-not (Test-Path $dbatoolsDest)) {
        Write-Host "  Downloading dbatools and dependencies for VMs..."
        Save-Module -Name dbatools -Path $installsDir -Force
        Save-Module -Name dbatools.library -Path $installsDir -Force
        Write-Ok "dbatools saved to $dbatoolsDest"
    } else {
        Write-Ok "dbatools already saved in data/installs"
    }
}
$Results['dbatools'] = $null -ne (Get-Module -ListAvailable -Name dbatools)

# ── 9-12. ISO Downloads ───────────────────────────────────────────────────────

if (-not (Test-Path $MediaPath)) {
    New-Item -ItemType Directory -Path $MediaPath -Force | Out-Null
}

if (-not $SkipDownloads) {
    foreach ($iso in $Isos) {
        $dest = Join-Path $MediaPath $iso.File
        Invoke-Step "Download: $($iso.Name)" {
            if (-not $iso.Url) {
                Write-Warn "$($iso.Name) — URL not yet set. Please download manually to: $dest"
                return
            }

            if ($iso.UseBootstrapper) {
                # ── Bootstrapper mode ────────────────────────────────────────────
                # Download the small setup bootstrapper .exe, run it with /Action=Download
                # to pull the real ISO, then remove the bootstrapper.
                if (Test-Path $dest) {
                    Write-Warn "Already exists: $dest — skipping bootstrapper download"
                    return
                }
                $exePath = Join-Path $MediaPath $iso.BootstrapperExe
                Write-Host "  ⬇️  Downloading bootstrapper: $($iso.BootstrapperExe) ..."
                Get-FileWithProgress -Uri $iso.Url -Destination $exePath -ExpectedSha256 ''

                Write-Host "  ⬇️  Running bootstrapper to download ISO (this may take a while)..."
                # The bootstrapper must be run on Windows — note this for cross-platform builds.
                # On Linux, this step requires Wine or must be run on a Windows host.
                if ($IsLinux) {
                    Write-Warn "SQL bootstrapper is a Windows .exe — cannot run on Linux directly."
                    Write-Warn "Options:"
                    Write-Warn "  1. Copy $exePath to a Windows machine, run:"
                    Write-Warn "     SQLServer2025-Dev-Setup.exe /Action=Download /MediaPath='$MediaPath' /MediaType=ISO /Quiet"
                    Write-Warn "  2. Use Wine: wine '$exePath' /Action=Download /MediaPath='$MediaPath' /MediaType=ISO /Quiet"
                    Write-Warn "  3. Download the ISO manually from https://www.microsoft.com/evalcenter"
                }
                else {
                    & $exePath /Action=Download /MediaPath=$MediaPath /MediaType=ISO /Quiet
                    Remove-Item $exePath -ErrorAction SilentlyContinue
                }
            }
            else {
                Get-FileWithProgress -Uri $iso.Url -Destination $dest -ExpectedSha256 $iso.Sha256
            }
        }
        $Results[$iso.File] = Test-Path $dest
    }
}
else {
    Write-Warn '-SkipDownloads specified — skipping ISO downloads'
    foreach ($iso in $Isos) {
        $Results[$iso.File] = Test-Path (Join-Path $MediaPath $iso.File)
    }
}

# ── 12. Readiness Summary ─────────────────────────────────────────────────────

Write-Host "`n$('─' * 60)" -ForegroundColor DarkGray
Write-Host ' Readiness Summary' -ForegroundColor White
Write-Host "$('─' * 60)" -ForegroundColor DarkGray
Write-Host "  📁  Media path : $MediaPath" -ForegroundColor White

$allGreen = $true
foreach ($key in $Results.Keys) {
    $ok = $Results[$key]
    if ($ok) {
        Write-Host "  ✅  $key" -ForegroundColor Green
    }
    else {
        Write-Host "  ❌  $key" -ForegroundColor Red
        $allGreen = $false
    }
}

Write-Host "$('─' * 60)" -ForegroundColor DarkGray
if ($allGreen) {
    Write-Host "`n  All prerequisites satisfied — ready to build Packer images!`n" -ForegroundColor Green
}
else {
    Write-Host "`n  One or more prerequisites are missing. Resolve the ❌ items above.`n" -ForegroundColor Red
    exit 1
}

Write-Host "  💡  Tip: To watch or debug the Packer build in real time, connect to" -ForegroundColor DarkCyan
Write-Host "       the VM's VNC console. Install a VNC viewer if you don't have one:" -ForegroundColor DarkCyan
Write-Host "         sudo apt-get install -y vinagre          # GNOME VNC viewer" -ForegroundColor DarkCyan
Write-Host "         sudo apt-get install -y virt-viewer      # virt-viewer (recommended with libvirt)" -ForegroundColor DarkCyan
Write-Host "         sudo apt-get install -y tigervnc-viewer  # TigerVNC" -ForegroundColor DarkCyan
Write-Host "       Then connect to the VNC address shown in the packer build output.`n" -ForegroundColor DarkCyan
