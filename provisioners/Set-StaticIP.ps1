<#
.SYNOPSIS
    Assigns a static IP address to the lab NIC on a Windows Server VM.

.DESCRIPTION
    Runs as a Vagrant provisioner. Identifies the non-NAT (lab) adapter and
    applies a static IP, subnet mask, gateway, and DNS server address.
    Safely handles the QEMU single-NIC case (exits 0 with a warning).

.PARAMETER StaticIP
    The IP address to assign (e.g. 192.168.10.20).

.PARAMETER PrefixLength
    Subnet prefix length (e.g. 24 for /24).

.PARAMETER Gateway
    Default gateway IP (e.g. 192.168.10.1).

.PARAMETER DnsServer
    Primary DNS server IP — should point at the first Domain Controller.
#>
param(
    [Parameter(Mandatory)][string]$StaticIP,
    [Parameter(Mandatory)][int]   $PrefixLength,
    [Parameter(Mandatory)][string]$Gateway,
    [Parameter(Mandatory)][string]$DnsServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==> [Set-StaticIP] Binding $StaticIP/$PrefixLength gw=$Gateway dns=$DnsServer" -ForegroundColor Cyan

# ── Find the lab adapter ───────────────────────────────────────────────────────
# Strategy 1: adapter that has an IPv4 address that is NOT the QEMU NAT range (10.0.2.x)
$labAdapter = Get-NetAdapter -Physical |
Where-Object Status -eq 'Up' |
Where-Object {
    $ip = (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $ip -and $ip.IPAddress -notmatch '^10\.0\.2\.'
} | Select-Object -First 1

# Strategy 2: any UP adapter that does NOT have a 10.0.2.x address
#             (covers the case where the lab NIC has no IP yet, e.g. socket/multicast NIC)
if (-not $labAdapter) {
    $labAdapter = Get-NetAdapter -Physical |
    Where-Object Status -eq 'Up' |
    Where-Object {
        $ip = (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        -not ($ip -and $ip.IPAddress -match '^10\.0\.2\.')
    } | Sort-Object InterfaceIndex | Select-Object -Last 1
}

# Strategy 3: give up gracefully — only the NAT NIC exists (single-NIC QEMU user networking)
if (-not $labAdapter) {
    Write-Host '  ⚠️  No non-NAT adapter found — only the QEMU NAT NIC (10.0.2.x) is present.' -ForegroundColor Yellow
    Write-Host '      Static IP assignment skipped to avoid breaking SSH connectivity.' -ForegroundColor Yellow
    Write-Host '      Inter-VM communication requires a second NIC (e.g. QEMU socket/bridge networking).' -ForegroundColor Yellow
    exit 0
}

Write-Host "  Adapter: $($labAdapter.Name) [$($labAdapter.InterfaceDescription)]"

# ── Launch the rest of the configuration asynchronously ─────────────────────────
# Removing the DHCP address and applying the static IP will severe the SSH session.
# If we do it synchronously, the SSH client (sshpass) will receive a Broken Pipe
# and the provisioning orchestrator will fail. We launch a detached background
# process to apply the changes.

$asyncScript = {
    param($InterfaceIndex, $StaticIP, $PrefixLength, $Gateway, $DnsServer)
    
    # Wait a few seconds for the SSH session that launched us to complete and disconnect safely
    Start-Sleep -Seconds 5

    # Remove existing IPv4 config on the lab adapter
    Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-NetIPAddress -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue }

    Get-NetRoute -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-NetRoute -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue }

    # Disable DHCP
    $iface = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($iface -and $iface.Dhcp -eq 'Enabled') {
        Set-NetIPInterface -InterfaceIndex $InterfaceIndex -Dhcp Disabled
    }

    # Assign static IP
    New-NetIPAddress `
        -InterfaceIndex $InterfaceIndex `
        -IPAddress      $StaticIP `
        -PrefixLength   $PrefixLength `
        -DefaultGateway $Gateway | Out-Null

    # Point DNS at the Domain Controller
    Set-DnsClientServerAddress `
        -InterfaceIndex $InterfaceIndex `
        -ServerAddresses $DnsServer
}

$encodedArgs = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(
    "& {$asyncScript} -InterfaceIndex $($labAdapter.InterfaceIndex) -StaticIP '$StaticIP' -PrefixLength $PrefixLength -Gateway '$Gateway' -DnsServer '$DnsServer'"
))

$wrapperScript = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedArgs"
$scriptPath = 'C:\Windows\Temp\Apply-StaticIP.ps1'
Set-Content -Path $scriptPath -Value $wrapperScript -Encoding utf8

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -NoProfile -File `"$scriptPath`""
$Principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$Trigger = New-ScheduledTaskTrigger -AtStartup
$TaskName = 'ApplyLabStaticIP'

Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal -Trigger $Trigger -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "  ✅  Static IP $StaticIP/$PrefixLength assignment launched via Scheduled Task" -ForegroundColor Green


# ── Set network profile to Private ────────────────────────────────────────────
# Without DHCP or a domain controller responding, Windows classifies the bridge
# NIC as a "Public" network. The Public firewall profile blocks ALL inbound and
# most outbound traffic, including ICMP and SMB — which breaks domain join and
# VM-to-VM communication. Force it to Private so the Domain firewall profile
# takes over once the VM joins the domain.
$netProfile = Get-NetConnectionProfile -InterfaceIndex $labAdapter.InterfaceIndex -ErrorAction SilentlyContinue
if ($netProfile -and $netProfile.NetworkCategory -ne 'DomainAuthenticated') {
    try {
        Set-NetConnectionProfile -InterfaceIndex $labAdapter.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
        Write-Host "  OK  Network profile set to Private on $($labAdapter.Name)" -ForegroundColor Green
    } catch {
        # PermissionDenied can occur when already DomainAuthenticated or Group Policy
        # prevents the change. Both states are fine for lab connectivity.
        Write-Host "  OK  Network profile is '$($netProfile.NetworkCategory)' -- no change needed" -ForegroundColor DarkGray
    }
} elseif ($netProfile) {
    Write-Host "  OK  Network profile is '$($netProfile.NetworkCategory)' -- no change needed" -ForegroundColor DarkGray
} else {
    Write-Host "  WARNING: Could not read network profile -- skipping category change" -ForegroundColor Yellow
}

# ── Allow ICMPv4 echo (ping) through all firewall profiles ────────────────────
# The built-in ICMPv4 Echo rule (FPS-ICMP4-ERQ-In) is scoped to the Domain
# profile by default. VMs are Private-profiled until domain join completes, so
# we must widen it to Any to allow pings during and after provisioning.
$icmpRules = Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue
if ($icmpRules) {
    $icmpRules | Set-NetFirewallRule -Profile Any -Enabled True
    Write-Host "  OK  ICMPv4 Echo rule enabled (Profile: Any)" -ForegroundColor Green
} else {
    # Fallback: create a permissive ICMP allow rule
    New-NetFirewallRule -DisplayName "Lab-Allow-ICMPv4-In" `
        -Direction Inbound -Protocol ICMPv4 -IcmpType 8 `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  OK  ICMPv4 Echo allow rule created (Profile: Any)" -ForegroundColor Green
}
