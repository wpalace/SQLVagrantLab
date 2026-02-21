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
    [string]$MediaPath   = (Join-Path $HOME 'packer-media'),
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
        } else {
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
    } else {
        Write-Host "  Repo already configured: $ListFile"
    }
}


function Get-FileWithProgress ([string]$Uri, [string]$Destination, [string]$ExpectedSha256) {
    if (Test-Path $Destination) {
        Write-Warn "Already exists: $Destination — verifying checksum..."
    } else {
        Write-Host "  ⬇️  Downloading $(Split-Path $Destination -Leaf) ..."
        $tmpFile = "$Destination.tmp"
        try {
            $client = [System.Net.Http.HttpClient]::new()
            $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $total = $response.Content.Headers.ContentLength
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $out    = [System.IO.File]::OpenWrite($tmpFile)
            $buffer = [byte[]]::new(1MB)
            $read   = 0; $bytes = 0
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
        } catch {
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
    } else {
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
        Name     = 'Windows Server 2022 Evaluation (180-day)'
        File     = 'WinServer2022Eval.iso'
        Url      = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
        Sha256   = ''   # Populate after first download: (Get-FileHash WinServer2022Eval.iso).Hash
    }
    @{
        Name     = 'Windows Server 2025 Evaluation (180-day)'
        File     = 'WinServer2025Eval.iso'
        Url      = 'https://go.microsoft.com/fwlink/?linkid=2293176&clcid=0x409&culture=en-us&country=US'
        Sha256   = ''
    }
    @{
        Name     = 'SQL Server 2022 Developer Edition'
        File     = 'SQLServer2022-Dev.iso'
        # The SQL Developer ISO is download-manager gated. Use the offline bootstrapper:
        # Run: Setup.exe /Action=Download /MediaPath=<dir> /MediaType=ISO /Quiet
        # Set Url to the bootstrapper .exe, or pre-download the ISO and set SkipDownloads.
        Url      = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-DEV-x64-ENU.iso'
        Sha256   = ''
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

if ($distro -notin @('ubuntu','debian','fedora','rhel','centos','rocky')) {
    Write-Warn "Distro '$distro' not explicitly tested. Attempting apt-based installation."
}
$useApt = $distro -in @('ubuntu','debian')

# ── 2. QEMU ──────────────────────────────────────────────────────────────────

Invoke-Step 'Install QEMU + KVM + utilities' {
    if ($useApt) {
        & bash -c 'apt-get update -qq'
        Install-AptPackage @('qemu-system-x86','qemu-utils','qemu-kvm','libvirt-daemon-system','virtinst','bridge-utils')
        $labUser = $env:SUDO_USER ?? (& bash -c 'logname 2>/dev/null || echo $SUDO_USER')
        if ($labUser) { & bash -c "usermod -aG kvm,libvirt '$labUser'" }
    } else {
        & bash -c 'dnf install -y qemu-kvm qemu-img libvirt libvirt-client virt-install'
        & bash -c 'systemctl enable --now libvirtd'
    }
}
$Results['QEMU'] = Test-Command 'qemu-system-x86_64'

# ── 3. Packer ─────────────────────────────────────────────────────────────────

Invoke-Step 'Install HashiCorp Packer' {
    if (-not (Test-Command 'packer')) {
        if ($useApt) {
            $codename = Get-OsCodename
            $keyPath  = '/usr/share/keyrings/hashicorp-archive-keyring.gpg'
            $repoLine = "deb [signed-by=$keyPath] https://apt.releases.hashicorp.com $codename main"
            Add-AptRepo 'https://apt.releases.hashicorp.com/gpg' $keyPath $repoLine '/etc/apt/sources.list.d/hashicorp.list'
            Install-AptPackage @('packer')
        } else {
            & bash -c 'dnf install -y dnf-plugins-core && dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo && dnf install -y packer'
        }
    } else {
        Write-Ok 'packer already installed'
    }
}
$Results['Packer'] = Test-Command 'packer'

# ── 4. Vagrant ────────────────────────────────────────────────────────────────

Invoke-Step 'Install HashiCorp Vagrant' {
    if (-not (Test-Command 'vagrant')) {
        if ($useApt) {
            $codename = Get-OsCodename
            $keyPath  = '/usr/share/keyrings/hashicorp-archive-keyring.gpg'
            $repoLine = "deb [signed-by=$keyPath] https://apt.releases.hashicorp.com $codename main"
            Add-AptRepo 'https://apt.releases.hashicorp.com/gpg' $keyPath $repoLine '/etc/apt/sources.list.d/hashicorp.list'
            Install-AptPackage @('vagrant')
        } else {
            & bash -c 'dnf install -y vagrant'
        }
    } else {
        Write-Ok 'vagrant already installed'
    }
}
$Results['Vagrant'] = Test-Command 'vagrant'

# ── 5. vagrant-qemu plugin ────────────────────────────────────────────────────

Invoke-Step 'Install vagrant-qemu plugin' {
    if (-not (Test-Command 'vagrant')) { Write-Warn 'vagrant not installed yet — skipping plugin install'; return }
    $plugins = & vagrant plugin list 2>&1
    if ($plugins -notmatch 'vagrant-qemu') {
        & vagrant plugin install vagrant-qemu
    } else {
        Write-Ok 'vagrant-qemu already installed'
    }
}
$Results['vagrant-qemu'] = (Test-Command 'vagrant') -and ((& vagrant plugin list 2>&1) -match 'vagrant-qemu')

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
        } else {
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
    } else {
        Write-Ok "powershell-yaml $($mod.Version) already installed"
    }
}
$Results['powershell-yaml'] = $null -ne (Get-Module -ListAvailable -Name powershell-yaml)

# ── 8-11. ISO Downloads ───────────────────────────────────────────────────────

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
                } else {
                    & $exePath /Action=Download /MediaPath=$MediaPath /MediaType=ISO /Quiet
                    Remove-Item $exePath -ErrorAction SilentlyContinue
                }
            } else {
                Get-FileWithProgress -Uri $iso.Url -Destination $dest -ExpectedSha256 $iso.Sha256
            }
        }
        $Results[$iso.File] = Test-Path $dest
    }
} else {
    Write-Warn '-SkipDownloads specified — skipping ISO downloads'
    foreach ($iso in $Isos) {
        $Results[$iso.File] = Test-Path (Join-Path $MediaPath $iso.File)
    }
}

# ── 12. Readiness Summary ─────────────────────────────────────────────────────

Write-Host "`n$('─' * 60)" -ForegroundColor DarkGray
Write-Host ' Readiness Summary' -ForegroundColor White
Write-Host "$('─' * 60)" -ForegroundColor DarkGray

$allGreen = $true
foreach ($key in $Results.Keys) {
    $ok = $Results[$key]
    if ($ok) {
        Write-Host "  ✅  $key" -ForegroundColor Green
    } else {
        Write-Host "  ❌  $key" -ForegroundColor Red
        $allGreen = $false
    }
}

Write-Host "$('─' * 60)" -ForegroundColor DarkGray
if ($allGreen) {
    Write-Host "`n  All prerequisites satisfied — ready to build Packer images!`n" -ForegroundColor Green
} else {
    Write-Host "`n  One or more prerequisites are missing. Resolve the ❌ items above.`n" -ForegroundColor Red
    exit 1
}
