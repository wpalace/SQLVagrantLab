#Requires -Version 7.0
<#
.SYNOPSIS
    SSH-based provisioner for Domain Controller nodes.

.DESCRIPTION
    Runs on the HOST after 'vagrant up' completes. Connects to the DC guest via
    SSH (using sshpass) and executes every provisioning step in order:

        1. Set hostname + ACPI registry keys  →  reboot + wait
        2. Disable SQL Server services
        3. Promote to Domain Controller       →  reboot + wait
        4. Create lab admin account (Forest DC only)
        5. Set static IP on lab NIC

    Each step uploads the relevant script from the provisioners/ directory to
    the guest using scp (via sshpass) and calls it remotely. Reboots are handled
    by issuing a remote Restart-Computer, sleeping briefly, then looping on
    'echo ready' until SSH reconnects.

.PARAMETER Hostname
    Guest computer name to assign (e.g. dc01).

.PARAMETER SshPort
    Host-side port forwarded to guest SSH (e.g. 50022).

.PARAMETER StaticIP
    IP address to assign to the lab NIC (e.g. 192.168.10.10).

.PARAMETER PrefixLength
    Subnet prefix length (e.g. 24).

.PARAMETER Gateway
    Default gateway for the lab network (e.g. 192.168.10.1).

.PARAMETER DnsServer
    DNS server for the lab NIC. For the forest DC this is its own IP.

.PARAMETER DomainName
    FQDN of the Active Directory domain (e.g. test.dev).

.PARAMETER AdminUser
    Username for the lab domain admin account (e.g. admin).

.PARAMETER AdminPassword
    Password for DSRM and the lab admin account (e.g. P@ssw0rd).

.PARAMETER DcMode
    'Forest' to create a new forest, 'Replica' to join an existing one.

.PARAMETER ProvisionersDir
    Absolute path to the provisioners/ folder on the host.

.PARAMETER SshPassword
    Password used for SSH authentication (default: vagrant).

.PARAMETER WaitTimeoutMinutes
    Maximum minutes to wait for SSH to reconnect after a reboot (default: 20).

.EXAMPLE
    pwsh -File scripts/Provision-DomainController.ps1 `
        -Hostname dc01 -SshPort 50022 -StaticIP 192.168.10.10 `
        -PrefixLength 24 -Gateway 192.168.10.1 -DnsServer 192.168.10.10 `
        -DomainName test.dev -AdminUser admin -AdminPassword 'P@ssw0rd' `
        -DcMode Forest -ProvisionersDir ./provisioners
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Hostname,
    [Parameter(Mandatory)][int]   $SshPort,
    [Parameter(Mandatory)][string]$StaticIP,
    [Parameter(Mandatory)][int]   $PrefixLength,
    [Parameter(Mandatory)][string]$Gateway,
    [Parameter(Mandatory)][string]$DnsServer,
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$AdminUser,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][ValidateSet('Forest', 'Replica')][string]$DcMode,
    [Parameter(Mandatory)][string]$ProvisionersDir,
    [string]$SshPassword         = 'vagrant',
    [int]   $WaitTimeoutMinutes  = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Helpers
# =============================================================================

function Write-Step  ([string]$m) { Write-Host "`n==> [DC:$Hostname] $m" -ForegroundColor Cyan }
function Write-Ok    ([string]$m) { Write-Host "    ✅  $m" -ForegroundColor Green }
function Write-Info  ([string]$m) { Write-Host "    ℹ️   $m" -ForegroundColor DarkGray }
function Write-Warn  ([string]$m) { Write-Host "    ⚠️   $m" -ForegroundColor Yellow }
function Write-Fail  ([string]$m) { Write-Host "    ❌  $m" -ForegroundColor Red; throw $m }

# Base SSH options shared by every call
$SshOpts = @(
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'ConnectTimeout=8',
    '-o', 'ServerAliveInterval=10',
    '-o', 'ServerAliveCountMax=3',
    '-p', $SshPort,
    'vagrant@localhost'
)

# ---------------------------------------------------------------------------
# Invoke-RemotePS
#   Runs a PowerShell command string on the guest via sshpass + ssh.
#   Uses -EncodedCommand (base64) to safely pass multi-line scripts through
#   the SSH channel without shell quoting issues.
#   Returns the remote exit code.
# ---------------------------------------------------------------------------
function Invoke-RemotePS {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Description = ''
    )

    if ($Description) { Write-Info "Remote: $Description" }

    # Encode as UTF-16LE base64 — the format powershell.exe -EncodedCommand expects.
    # This avoids all quoting/newline issues when passing complex scripts over SSH.
    $encoded    = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    $remoteCmd  = "powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded"

    $proc = Start-Process -FilePath 'sshpass' `
        -ArgumentList (@("-p", $SshPassword, 'ssh') + $SshOpts + @($remoteCmd)) `
        -NoNewWindow -PassThru -Wait

    return $proc.ExitCode
}

# ---------------------------------------------------------------------------
# Copy-RemoteScript
#   Uploads a .ps1 file from the host provisioners directory to a temp path
#   on the guest using sshpass + scp, then executes it with any extra args.
#   Returns the remote exit code.
# ---------------------------------------------------------------------------
function Copy-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string[]]$ScriptArgs = @(),
        # Use 'powershell.exe' for scripts that load WinPS-only modules (e.g. ADDSDeployment).
        # PS7 (pwsh.exe) cannot load CustomPSSnapIn-based modules at all.
        [string]$Shell = 'pwsh.exe'
    )

    $localPath  = Join-Path $ProvisionersDir $ScriptName
    if (-not (Test-Path $localPath)) { Write-Fail "Script not found: $localPath" }

    # Destination on the guest (Windows temp directory accessible by vagrant user)
    $guestTemp  = 'C:\Windows\Temp'
    $guestPath  = "$guestTemp\$ScriptName"

    Write-Info "Uploading $ScriptName → $guestPath"

    # scp upload
    $scpArgs = @(
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-P', $SshPort,
        $localPath,
        "vagrant@localhost:$guestPath"
    )
    $scpProc = Start-Process -FilePath 'sshpass' `
        -ArgumentList (@("-p", $SshPassword, 'scp') + $scpArgs) `
        -NoNewWindow -PassThru -Wait

    if ($scpProc.ExitCode -ne 0) {
        Write-Fail "scp upload failed for $ScriptName (exit $($scpProc.ExitCode))"
    }

    $quotedArgs = ($ScriptArgs | ForEach-Object { "'$_'" }) -join ' '
    $remoteCmd  = "$Shell -NoProfile -NonInteractive -File `"$guestPath`" $quotedArgs"

    Write-Info "Executing $ScriptName on guest..."
    $execProc = Start-Process -FilePath 'sshpass' `
        -ArgumentList (@("-p", $SshPassword, 'ssh') + $SshOpts + @($remoteCmd)) `
        -NoNewWindow -PassThru -Wait

    return $execProc.ExitCode
}

# ---------------------------------------------------------------------------
# Wait-SshReady
#   Polls the guest SSH port until it responds successfully (exit 0 on
#   'echo ready'), or throws after $WaitTimeoutMinutes.
# ---------------------------------------------------------------------------
function Wait-SshReady {
    param(
        [string]$Reason = 'reboot'
    )

    Write-Info "Waiting for SSH to come back after $Reason (timeout: ${WaitTimeoutMinutes}m)..."
    $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
    $attempt  = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        Start-Sleep -Seconds 10

        # Use & call operator so we can discard output without Start-Process
        # redirect conflicts (Start-Process rejects stdout == stderr path on Linux).
        $null = & sshpass -p $SshPassword ssh @SshOpts 'echo ready' 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Ok "SSH reconnected (attempt $attempt)"
            return
        }

        Write-Info "  Still waiting... (attempt $attempt)"
    }

    Write-Fail "SSH did not reconnect within ${WaitTimeoutMinutes} minutes after $Reason."
}

# ---------------------------------------------------------------------------
# Invoke-RebootAndWait
#   Issues a remote Restart-Computer, waits for SSH to come back.
# ---------------------------------------------------------------------------
function Invoke-RebootAndWait {
    param([string]$Reason = 'provisioning step')

    Write-Info "Rebooting guest for: $Reason"

    # Fire-and-forget reboot (exit code will be non-zero since connection drops)
    Start-Process -FilePath 'sshpass' `
        -ArgumentList (@("-p", $SshPassword, 'ssh') + $SshOpts + @(
            'powershell.exe -NoProfile -NonInteractive -Command "Restart-Computer -Force"'
        )) `
        -NoNewWindow -PassThru -Wait | Out-Null

    # Brief grace period so the VM starts shutting down before we start polling
    Write-Info "Giving VM 20 seconds to begin shutdown..."
    Start-Sleep -Seconds 20

    Wait-SshReady -Reason $Reason
}

# =============================================================================
# Main provisioning sequence
# =============================================================================

Write-Host ''
Write-Host ('═' * 70) -ForegroundColor Magenta
Write-Host " DC Provisioner  →  $Hostname  ($DcMode DC)  port=$SshPort" -ForegroundColor Magenta
Write-Host ('═' * 70) -ForegroundColor Magenta

# ── Step 1: Set hostname ──────────────────────────────────────────────────────

Write-Step 'Step 1/4 — Set hostname + ACPI registry'

$renameCmd = @"
# Allow ACPI shutdown from lock screen (required for clean QEMU power-off)
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' ``
    -Name 'shutdownwithoutlogon' -Value 1 -PropertyType DWORD -Force | Out-Null

# Disable Shutdown Event Tracker (avoids dialog on Guest Tools shutdown)
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' ``
    -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' ``
    -Name 'ShutdownReasonOn' -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' ``
    -Name 'ShutdownReasonUI' -Value 0 -PropertyType DWORD -Force | Out-Null

# Rename computer
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

# ── Step 2: Promote to Domain Controller ─────────────────────────────────

# Windows blocks DC promotion when the built-in Administrator password is blank.
# The Packer box ships with a blank Administrator password, so we harden it first.
Write-Step 'Step 2/4 — Harden local Administrator password + Install AD DS'

$localAdminPassword = 'vagrantStr0ngP@ss'
$setPassCmd = "net user Administrator '$localAdminPassword'"
$rc = Invoke-RemotePS -Command $setPassCmd -Description 'Set local Administrator password'
if ($rc -ne 0) { Write-Fail "Step 2 (set Administrator password) failed (exit $rc)" }
Write-Info "Local Administrator password set"

$rc = Copy-RemoteScript -ScriptName 'Install-ADDSForest.ps1' `
    -ScriptArgs @($DomainName, $AdminPassword, $DcMode) `
    -Shell 'powershell.exe'   # ADDSDeployment uses CustomPSSnapIn — PS7-only shell cannot load it
if ($rc -ne 0) { Write-Fail "Step 2 (ADDS promotion) failed (exit $rc)" }

Invoke-RebootAndWait -Reason 'AD DS promotion'

Write-Ok "AD DS promotion complete ($DcMode)"

# ── Step 3: Create lab admin account (Forest DC only) ───────────────────────

if ($DcMode -eq 'Forest') {
    Write-Step 'Step 3/4 — Create lab admin account'

    $rc = Copy-RemoteScript -ScriptName 'New-LabAdminAccount.ps1' `
        -ScriptArgs @($DomainName, $AdminUser, $AdminPassword)
    if ($rc -ne 0) { Write-Fail "Step 3 failed (exit $rc)" }

    Write-Ok "Lab admin '$AdminUser@$DomainName' created"
} else {
    Write-Step 'Step 3/4 — Skipped (Replica DC — no admin account needed here)'
    Write-Ok 'Skipped'
}

# ── Step 4: Set static IP ───────────────────────────────────────────────────

Write-Step 'Step 4/4 — Set static IP on lab NIC'

$rc = Copy-RemoteScript -ScriptName 'Set-StaticIP.ps1' `
    -ScriptArgs @($StaticIP, $PrefixLength, $Gateway, $DnsServer)
if ($rc -ne 0) { Write-Fail "Step 4 failed (exit $rc)" }

Write-Ok "Static IP $StaticIP/$PrefixLength set"

# =============================================================================
# Done
# =============================================================================

Write-Host ''
Write-Host ('═' * 70) -ForegroundColor Green
Write-Host " ✅  $Hostname provisioning complete!" -ForegroundColor Green
Write-Host "     Domain   : $DomainName" -ForegroundColor Green
Write-Host "     Static IP: $StaticIP/$PrefixLength (via $Gateway)" -ForegroundColor Green
Write-Host ('═' * 70) -ForegroundColor Green
Write-Host ''
