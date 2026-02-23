#Requires -Version 7.0
<#
.SYNOPSIS
    Stops and disables the SQL Server service on Domain Controller nodes.

.DESCRIPTION
    DC nodes are built from the same pre-staged SQL Server box image as SQL
    Server nodes (to avoid maintaining a separate OS-only image).  This script
    ensures SQL Server never starts on a DC by stopping all MSSQL* / SQLAgent*
    services and marking them Disabled.  It is idempotent — safe to re-run.

    Run order: fires after Set-Hostname reboot, before Install-ADDSForest.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '==> [Disable-SqlServer] Disabling SQL Server services on DC node...' -ForegroundColor Cyan

$servicePatterns = 'MSSQL*', 'SQLAgent*', 'SQLBrowser', 'SQLWriter', 'MsDtsServer*', 'ReportServer*', 'MSSQLFDLauncher*'

$found = $false
foreach ($pattern in $servicePatterns) {
    $services = Get-Service -Name $pattern -ErrorAction SilentlyContinue
    foreach ($svc in $services) {
        $found = $true
        if ($svc.Status -eq 'Running') {
            Write-Host "  Stopping  : $($svc.Name)"
            Stop-Service -Name $svc.Name -Force
        }
        Write-Host "  Disabling : $($svc.Name)"
        Set-Service  -Name $svc.Name -StartupType Disabled
    }
}

if (-not $found) {
    Write-Host '  No SQL Server services found — nothing to disable.' -ForegroundColor Yellow
}

Write-Host '  ✅  SQL Server services disabled.' -ForegroundColor Green
