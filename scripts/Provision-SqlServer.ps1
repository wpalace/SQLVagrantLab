#Requires -Version 7.0
<#
.SYNOPSIS
    SSH-based provisioner for SQL Server member nodes.

.DESCRIPTION
    Runs on the HOST after 'vagrant up' completes AND after
    Provision-DomainController.ps1 has finished for all DC nodes.

    Connects to the SQL guest via SSH (sshpass) and executes steps in order:

        1. Set hostname + ACPI registry keys  →  reboot + wait
        2. Join domain                         →  reboot + wait
        3. Complete SQL Server post-Sysprep (CompleteImage)
        4. Configure SQL Server (dbatools: TCP, firewall, memory, SPNs)

    DC readiness is enforced inside Join-Domain.ps1 (it waits up to 10 min
    for ICMP + LDAP port 389 to the DC IP before proceeding).  Because the
    host-side Deploy-Lab.ps1 calls DC provisioner first and waits for it to
    return, by the time this script is invoked the DC should already be live.

.PARAMETER Hostname
    Guest computer name to assign (e.g. sql01).

.PARAMETER SshPort
    Host-side port forwarded to guest SSH (e.g. 50023).

.PARAMETER StaticIP
    IP address to assign to the lab NIC (e.g. 192.168.10.20).

.PARAMETER PrefixLength
    Subnet prefix length (e.g. 24).

.PARAMETER Gateway
    Default gateway for the lab network (e.g. 192.168.10.1).

.PARAMETER DcIpAddress
    IP of the forest root DC — used by Join-Domain.ps1 for the readiness check
    and to point DNS at the DC before joining.

.PARAMETER DomainName
    FQDN of the Active Directory domain (e.g. test.dev).

.PARAMETER AdminUser
    Domain admin username (e.g. admin).

.PARAMETER AdminPassword
    Domain admin password (e.g. P@ssw0rd).

.PARAMETER ProvisionersDir
    Absolute path to the provisioners/ folder on the host.

.PARAMETER SshPassword
    Password used for SSH authentication (default: vagrant).

.PARAMETER WaitTimeoutMinutes
    Maximum minutes to wait for SSH to reconnect after a reboot (default: 25).

.EXAMPLE
    pwsh -File scripts/Provision-SqlServer.ps1 `
        -Hostname sql01 -SshPort 50023 -StaticIP 192.168.10.20 `
        -PrefixLength 24 -Gateway 192.168.10.1 -DcIpAddress 192.168.10.10 `
        -DomainName test.dev -AdminUser admin -AdminPassword 'P@ssw0rd' `
        -ProvisionersDir ./provisioners
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Hostname,
    [Parameter(Mandatory)][int]   $SshPort,
    [Parameter(Mandatory)][string]$StaticIP,
    [Parameter(Mandatory)][int]   $PrefixLength,
    [Parameter(Mandatory)][string]$Gateway,
    [Parameter(Mandatory)][string]$DcIpAddress,
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$AdminUser,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$ProvisionersDir,
    [string]$SshPassword        = 'vagrant',
    [int]   $WaitTimeoutMinutes = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Helpers  (identical to Provision-DomainController.ps1)
# =============================================================================

function Write-Step  ([string]$m) { Write-Host "`n==> [SQL:$Hostname] $m" -ForegroundColor Cyan }
function Write-Ok    ([string]$m) { Write-Host "    ✅  $m" -ForegroundColor Green }
function Write-Info  ([string]$m) { Write-Host "    ℹ️   $m" -ForegroundColor DarkGray }
function Write-Fail  ([string]$m) { Write-Host "    ❌  $m" -ForegroundColor Red; throw $m }

$SshOpts = @(
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'ConnectTimeout=8',
    '-o', 'ServerAliveInterval=10',
    '-o', 'ServerAliveCountMax=3',
    '-p', $SshPort,
    'vagrant@localhost'
)

function Invoke-RemotePS {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Description = ''
    )
    if ($Description) { Write-Info "Remote: $Description" }
    $encoded   = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    $remoteCmd = "powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded"
    $proc = Start-Process -FilePath 'sshpass' `
        -ArgumentList (@('-p', $SshPassword, 'ssh') + $SshOpts + @($remoteCmd)) `
        -NoNewWindow -PassThru -Wait
    return $proc.ExitCode
}

function Copy-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string[]]$ScriptArgs = @()
    )
    $localPath = Join-Path $ProvisionersDir $ScriptName
    if (-not (Test-Path $localPath)) { Write-Fail "Script not found: $localPath" }

    $guestPath = "C:\Windows\Temp\$ScriptName"
    Write-Info "Uploading $ScriptName → $guestPath"

    # scp upload (plain — pwsh.exe handles UTF-8 natively, no BOM needed)
    $scpArgs = @(
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-P', $SshPort,
        $localPath,
        "vagrant@localhost:$guestPath"
    )
    $scpProc = Start-Process -FilePath 'sshpass' `
        -ArgumentList (@('-p', $SshPassword, 'scp') + $scpArgs) `
        -NoNewWindow -PassThru -Wait

    if ($scpProc.ExitCode -ne 0) {
        Write-Fail "scp upload failed for $ScriptName (exit $($scpProc.ExitCode))"
    }

    # Execute via pwsh.exe (PowerShell 7 — installed by Packer build).
    # PS7 handles all parameters and UTF-8 source files natively.
    $quotedArgs = ($ScriptArgs | ForEach-Object { "'$_'" }) -join ' '
    $remoteCmd  = "pwsh.exe -NoProfile -NonInteractive -File `"$guestPath`" $quotedArgs"
    Write-Info "Executing $ScriptName on guest..."
    $execProc = Start-Process -FilePath 'sshpass' `
        -ArgumentList (@('-p', $SshPassword, 'ssh') + $SshOpts + @($remoteCmd)) `
        -NoNewWindow -PassThru -Wait
    return $execProc.ExitCode
}

function Wait-SshReady {
    param([string]$Reason = 'reboot')
    Write-Info "Waiting for SSH to come back after $Reason (timeout: ${WaitTimeoutMinutes}m)..."
    $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
    $attempt  = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        Start-Sleep -Seconds 10
        $null = & sshpass -p $SshPassword ssh @SshOpts 'echo ready' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "SSH reconnected (attempt $attempt)"
            return
        }
        Write-Info "  Still waiting... (attempt $attempt)"
    }
    Write-Fail "SSH did not reconnect within ${WaitTimeoutMinutes} minutes after $Reason."
}

function Invoke-RebootAndWait {
    param([string]$Reason = 'provisioning step')
    Write-Info "Rebooting guest for: $Reason"
    Start-Process -FilePath 'sshpass' `
        -ArgumentList (@('-p', $SshPassword, 'ssh') + $SshOpts + @(
            'powershell.exe -NoProfile -NonInteractive -Command "Restart-Computer -Force"'
        )) `
        -NoNewWindow -PassThru -Wait | Out-Null
    Write-Info "Giving VM 20 seconds to begin shutdown..."
    Start-Sleep -Seconds 20
    Wait-SshReady -Reason $Reason
}

# =============================================================================
# Main provisioning sequence
# =============================================================================

Write-Host ''
Write-Host ('═' * 70) -ForegroundColor Magenta
Write-Host " SQL Provisioner  →  $Hostname  port=$SshPort" -ForegroundColor Magenta
Write-Host ('═' * 70) -ForegroundColor Magenta

# ── Step 1: Set hostname ──────────────────────────────────────────────────────

Write-Step 'Step 1/4 — Set hostname + ACPI registry'

$renameCmd = @"
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' ``
    -Name 'shutdownwithoutlogon' -Value 1 -PropertyType DWORD -Force | Out-Null
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' ``
    -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' ``
    -Name 'ShutdownReasonOn' -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' ``
    -Name 'ShutdownReasonUI' -Value 0 -PropertyType DWORD -Force | Out-Null
`$current = (Get-ComputerInfo).CsName
if (`$current -ne '$Hostname') {
    Rename-Computer -NewName '$Hostname' -Force
    Write-Host 'Renamed to $Hostname'
} else {
    Write-Host 'Hostname already $Hostname -- skipping rename'
}
"@

$rc = Invoke-RemotePS -Command $renameCmd -Description "Set hostname to $Hostname"
if ($rc -ne 0) { Write-Fail "Step 1 failed (exit $rc)" }

Invoke-RebootAndWait -Reason 'hostname rename'
Write-Ok 'Hostname set and VM back online'

# ── Step 2: Set static IP + join domain ──────────────────────────────────────
#
# Set-StaticIP must run BEFORE Join-Domain so that the lab NIC has an address
# on the inter-VM socket network and can reach the DC (192.168.10.x).
# Join-Domain.ps1 has its own inner wait loop (ICMP + LDAP 389) so even if
# the DC is still finishing its last boot we will poll until it answers.

Write-Step 'Step 2/4 — Set static IP + join domain'

$rc = Copy-RemoteScript -ScriptName 'Set-StaticIP.ps1' `
    -ScriptArgs @($StaticIP, $PrefixLength, $Gateway, $DcIpAddress)
if ($rc -ne 0) { Write-Fail "Step 2 (Set-StaticIP) failed (exit $rc)" }
Write-Info "Static IP $StaticIP/$PrefixLength set — lab NIC can now reach the DC"

$rc = Copy-RemoteScript -ScriptName 'Join-Domain.ps1' `
    -ScriptArgs @($DomainName, $DcIpAddress, $AdminUser, $AdminPassword)
if ($rc -ne 0) { Write-Fail "Step 2 (Join-Domain) failed (exit $rc)" }

Invoke-RebootAndWait -Reason 'domain join'
Write-Ok "Joined $DomainName and VM back online"

# ── Step 3: Complete SQL Server post-Sysprep ──────────────────────────────────

Write-Step 'Step 3/4 — Complete SQL Server image (CompleteImage)'

$rc = Copy-RemoteScript -ScriptName 'Complete-SqlImage.ps1' `
    -ScriptArgs @($DomainName, $AdminUser, $AdminPassword)
if ($rc -ne 0) { Write-Fail "Step 3 (Complete-SqlImage) failed (exit $rc)" }

Write-Ok 'SQL Server CompleteImage finished'

# ── Step 4: Configure SQL Server with dbatools ────────────────────────────────

Write-Step 'Step 4/4 — Configure SQL Server (dbatools)'

$rc = Copy-RemoteScript -ScriptName 'Configure-SqlServer.ps1' `
    -ScriptArgs @($AdminPassword)
if ($rc -ne 0) { Write-Fail "Step 4 (Configure-SqlServer) failed (exit $rc)" }

Write-Ok 'SQL Server configuration complete'

# =============================================================================
# Done
# =============================================================================

Write-Host ''
Write-Host ('═' * 70) -ForegroundColor Green
Write-Host " ✅  $Hostname provisioning complete!" -ForegroundColor Green
Write-Host "     Domain   : $DomainName" -ForegroundColor Green
Write-Host "     Static IP: $StaticIP/$PrefixLength" -ForegroundColor Green
Write-Host "     DC       : $DcIpAddress" -ForegroundColor Green
Write-Host ('═' * 70) -ForegroundColor Green
Write-Host ''
