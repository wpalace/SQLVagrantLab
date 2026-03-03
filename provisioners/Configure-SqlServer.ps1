<#
.SYNOPSIS
    Post-install SQL Server configuration using dbatools.

.DESCRIPTION
    Runs after Complete-SqlImage.ps1. Installs dbatools if absent, then
    configures the local SQL Server instance for remote access, safe memory
    limits, and proper SPN registration.

.PARAMETER AdminPassword
    The sa / sysadmin password — used to create a SqlCredential for dbatools
    commands that require authentication.
#>
param(
    [Parameter(Mandatory)][string]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step ([string]$m) { Write-Host "==> [Configure-SQL] $m" -ForegroundColor Cyan }
function Write-Ok   ([string]$m) { Write-Host "  ✅  $m" -ForegroundColor Green }

$instance = $env:COMPUTERNAME   # Default instance on local machine

# ── 1. Ensure dbatools is installed ──────────────────────────────────────────

Write-Step 'Checking dbatools...'
if (-not (Get-Module -ListAvailable -Name dbatools)) {
    Write-Host '  Installing dbatools (this may take a few minutes)...'
    # Set TLS 1.2 for older PS Gallery connections
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-Module dbatools -Scope AllUsers -Force -AllowClobber
}
Import-Module dbatools -MinimumVersion 2.0.0 -Force
Write-Ok "dbatools $((Get-Module dbatools).Version)"

# Build a SqlCredential using sa (avoids Windows auth issues before full domain config)
$secPass  = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
$sqlCred  = New-Object System.Management.Automation.PSCredential('sa', $secPass)

# ── 2. Enable TCP/IP ──────────────────────────────────────────────────────────

Write-Step 'Enabling TCP/IP protocol...'
Enable-DbaTcpIp -SqlInstance $instance -Credential $sqlCred -Force | Out-Null
Write-Ok 'TCP/IP enabled on port 1433'

# ── 3. Open Firewall Rules ────────────────────────────────────────────────────

Write-Step 'Configuring Windows Firewall rules...'
Set-DbaFirewallRule -Type AllSqlServices -Action Allow -Force | Out-Null
Write-Ok 'Firewall rules set (1433 TCP, 1434 UDP SQL Browser, DAC)'

# Enable ICMPv4 (ping) — DC promotion opens this automatically, but plain
# member servers have it blocked. Required for domain-join reachability checks
# and general lab diagnostics (sql01 → dc01 ping).
$icmpRule = Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue
if (-not $icmpRule -or $icmpRule.Enabled -ne 'True') {
    Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue
    # If the built-in rule doesn't exist, create one
    if (-not (Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'Lab-ICMPv4-In' -DisplayName 'Lab ICMPv4 Echo Request' `
            -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -Profile Any | Out-Null
    }
}
Write-Ok 'ICMPv4 echo (ping) enabled'

# ── 4. Set Max Server Memory ──────────────────────────────────────────────────

Write-Step 'Setting safe max memory...'
# Set-DbaMaxMemory automatically calculates a safe limit (leaves 10-15% for OS)
$memResult = Set-DbaMaxMemory -SqlInstance $instance -SqlCredential $sqlCred
Write-Ok "Max memory set to $($memResult.MaxValue) MB (was $($memResult.PreviousMaxValue) MB)"

# ── 5. Register SPNs ──────────────────────────────────────────────────────────

Write-Step 'Checking and registering SPNs...'
$spnProblems = Test-DbaSpn -ComputerName $env:COMPUTERNAME -EnableException:$false
if ($spnProblems) {
    $spnProblems | Register-DbaSpn -EnableException:$false | Out-Null
    Write-Ok "$($spnProblems.Count) SPN(s) registered"
} else {
    Write-Ok 'SPNs already correct'
}

# ── 6. Restart SQL to apply TCP changes ──────────────────────────────────────

Write-Step 'Restarting SQL Server service to apply protocol changes...'
Restart-DbaService -ComputerName $env:COMPUTERNAME -Type Engine -Force | Out-Null
Start-Sleep 8
Write-Ok 'SQL Server service restarted'

# ── 7. Health check ───────────────────────────────────────────────────────────

Write-Step 'Running health check...'
$services = Get-DbaService -ComputerName $env:COMPUTERNAME
$services | Format-Table ComputerName, ServiceName, State, StartMode -AutoSize

$engine = $services | Where-Object ServiceName -like 'MSSQLSERVER'
if ($engine.State -ne 'Running') {
    throw "SQL Server Engine is NOT running! State: $($engine.State)"
}

Write-Host ''
Write-Host "  ✅  SQL Server on $($env:COMPUTERNAME) fully configured:" -ForegroundColor Green
Write-Host "       TCP/IP: enabled | Port: 1433 | Edition: Developer | Memory: auto-tuned"
