#Requires -Version 7.0
<#
.SYNOPSIS
    Assigns a static IP address to the lab NIC on a Windows Server VM.

.DESCRIPTION
    Runs as a Vagrant provisioner. Identifies the non-NAT (lab) adapter and
    applies a static IP, subnet mask, gateway, and DNS server address.

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

# Identify the lab adapter — it is NOT the NAT adapter (which has a 10.0.2.x address in QEMU)
$labAdapter = Get-NetAdapter -Physical |
    Where-Object Status -eq 'Up' |
    Where-Object {
        $ip = (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $ip -and $ip.IPAddress -notmatch '^10\.0\.2\.'
    } | Select-Object -First 1

if (-not $labAdapter) {
    # Fallback: pick any adapter that isn't the default Vagrant NAT NIC
    $labAdapter = Get-NetAdapter -Physical |
        Where-Object Status -eq 'Up' |
        Select-Object -Last 1
}

if (-not $labAdapter) { throw 'Could not identify a suitable network adapter' }

Write-Host "  Adapter: $($labAdapter.Name) [$($labAdapter.InterfaceDescription)]"

# Remove existing IP configuration on this adapter
Get-NetIPAddress -InterfaceIndex $labAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

Get-NetRoute -InterfaceIndex $labAdapter.InterfaceIndex -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

# Disable DHCP on this adapter
Set-NetIPInterface -InterfaceIndex $labAdapter.InterfaceIndex -Dhcp Disabled

# Assign static IP
New-NetIPAddress `
    -InterfaceIndex $labAdapter.InterfaceIndex `
    -IPAddress      $StaticIP `
    -PrefixLength   $PrefixLength `
    -DefaultGateway $Gateway | Out-Null

# Point DNS at the Domain Controller
Set-DnsClientServerAddress `
    -InterfaceIndex $labAdapter.InterfaceIndex `
    -ServerAddresses $DnsServer

Write-Host "  ✅  Static IP $StaticIP/$PrefixLength assigned on $($labAdapter.Name)" -ForegroundColor Green
