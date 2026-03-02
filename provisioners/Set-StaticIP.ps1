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

# ── Remove existing IPv4 config on the lab adapter ────────────────────────────
Get-NetIPAddress -InterfaceIndex $labAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
ForEach-Object { Remove-NetIPAddress -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue }

Get-NetRoute -InterfaceIndex $labAdapter.InterfaceIndex -ErrorAction SilentlyContinue |
ForEach-Object { Remove-NetRoute -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue }

# ── Disable DHCP only if it is currently enabled ──────────────────────────────
# A freshly added virtual NIC (e.g. QEMU socket NIC) may not be in DHCP mode;
# calling Set-NetIPInterface -Dhcp Disabled on it throws "The parameter is incorrect".
$iface = Get-NetIPInterface -InterfaceIndex $labAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
if ($iface -and $iface.Dhcp -eq 'Enabled') {
    Set-NetIPInterface -InterfaceIndex $labAdapter.InterfaceIndex -Dhcp Disabled
}

# ── Assign static IP ──────────────────────────────────────────────────────────
New-NetIPAddress `
    -InterfaceIndex $labAdapter.InterfaceIndex `
    -IPAddress      $StaticIP `
    -PrefixLength   $PrefixLength `
    -DefaultGateway $Gateway | Out-Null

# ── Point DNS at the Domain Controller ────────────────────────────────────────
Set-DnsClientServerAddress `
    -InterfaceIndex $labAdapter.InterfaceIndex `
    -ServerAddresses $DnsServer

Write-Host "  ✅  Static IP $StaticIP/$PrefixLength assigned on $($labAdapter.Name)" -ForegroundColor Green
