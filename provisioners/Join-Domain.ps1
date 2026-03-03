<#
.SYNOPSIS
    Joins a member server (or SQL node) to the lab domain.

.DESCRIPTION
    Waits for the Domain Controller to be reachable (up to 10 minutes),
    then joins the machine to the specified domain. Vagrant is configured
    with 'reboot: true' so the VM restarts after joining.

.PARAMETER DomainName
    FQDN of the domain to join (e.g. test.dev).

.PARAMETER DcIpAddress
    IP address of the forest root DC (used for connectivity check).

.PARAMETER AdminUser
    Domain administrator username (without domain prefix).

.PARAMETER AdminPassword
    Domain administrator password.
#>
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$DcIpAddress,
    [Parameter(Mandatory)][string]$AdminUser,
    [Parameter(Mandatory)][string]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==> [Join-Domain] Joining $DomainName (DC: $DcIpAddress)" -ForegroundColor Cyan

# ── Already joined? ───────────────────────────────────────────────────────────

$currentDomain = (Get-WmiObject Win32_ComputerSystem).Domain
if ($currentDomain -ieq $DomainName) {
    Write-Host "  ✅  Already a member of $DomainName — skipping." -ForegroundColor Green
    exit 0
}

# ── Wait for DC to be reachable ───────────────────────────────────────────────

Write-Host "  Waiting for DC at $DcIpAddress (up to 10 min)..."
$deadline = (Get-Date).AddMinutes(10)
$reached  = $false

while ((Get-Date) -lt $deadline) {
    if (Test-Connection -ComputerName $DcIpAddress -Count 1 -Quiet) {
        # Also verify LDAP port 389 is open
        $tcp = Test-NetConnection -ComputerName $DcIpAddress -Port 389 -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) { $reached = $true; break }
    }
    Write-Host '    DC not yet reachable, retrying in 20s...'
    Start-Sleep 20
}

if (-not $reached) { throw "Timed out waiting for DC at $DcIpAddress" }
Write-Host "  DC reachable at $DcIpAddress"

# ── Set DNS to DC so domain name resolves ────────────────────────────────────

$adapter = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $DcIpAddress

# ── Join domain ───────────────────────────────────────────────────────────────

$netbios   = $DomainName.Split('.')[0].ToUpper()
$secPass   = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
$cred      = New-Object System.Management.Automation.PSCredential("$netbios\$AdminUser", $secPass)

Add-Computer -DomainName $DomainName -Credential $cred -Force
Write-Host "  ✅  Joined $DomainName. Vagrant will reboot now." -ForegroundColor Green
exit 2
