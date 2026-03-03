<#
.SYNOPSIS
    Runs SQL Server /ACTION=CompleteImage to finalize the pre-staged instance.

.DESCRIPTION
    SQL Server was pre-staged with /ACTION=PrepareImage during the Packer build.
    This script completes the installation now that the machine has a hostname
    and is joined to the domain. Always uses Developer Edition.

    Runs after Join-Domain.ps1 (and its reboot) so the computer name and domain
    membership are stable before SQL Server binds to them.

.PARAMETER DomainName
    FQDN of the domain (e.g. test.dev).

.PARAMETER AdminUser
    Domain admin username (used as the SQL service account).

.PARAMETER AdminPassword
    Domain admin password (used for sa and service accounts).
#>
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$AdminUser,
    [Parameter(Mandatory)][string]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==> [Complete-SqlImage] Finalising SQL Server instance on $env:COMPUTERNAME" -ForegroundColor Cyan

# ── Locate setup.exe in the prepared instance ─────────────────────────────────
# After PrepareImage, SQL bootstrapper lives under Program Files

$setupSearch = @(
    'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\*\setup.exe'
    'C:\SQLServerSetup\setup.exe'
)

$setupExe = $null
foreach ($pattern in $setupSearch) {
    $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($found) { $setupExe = $found.FullName; break }
}

if (-not $setupExe) {
    throw 'SQL Server setup.exe not found. Was PrepareImage run during Packer build?'
}

Write-Host "  Using setup: $setupExe"

# ── Determine service identity ────────────────────────────────────────────────

$netbios        = $DomainName.Split('.')[0].ToUpper()
$svcAccount     = "$netbios\$AdminUser"

# ── Run /ACTION=CompleteImage ─────────────────────────────────────────────────

$args = @(
    '/ACTION=CompleteImage'
    '/QUIET'
    '/IACCEPTSQLSERVERLICENSETERMS'
    '/INSTANCENAME=MSSQLSERVER'
    '/INSTANCEID=MSSQLSERVER'
    "/SQLSVCACCOUNT=$svcAccount"
    "/SQLSVCPASSWORD=$AdminPassword"
    '/SECURITYMODE=SQL'
    "/SAPWD=$AdminPassword"
    "/SQLSYSADMINACCOUNTS=$svcAccount"
    "/AGTSVCACCOUNT=$svcAccount"
    "/AGTSVCPASSWORD=$AdminPassword"
    '/AGTSVCSTARTUPTYPE=Automatic'
    '/SQLSVCSTARTUPTYPE=Automatic'
    '/BROWSERSVCSTARTUPTYPE=Automatic'
    '/TCPENABLED=1'
    '/INDICATEPROGRESS'
)

Write-Host "  Running CompleteImage as $svcAccount..."
$proc = Start-Process -FilePath $setupExe -ArgumentList $args `
    -Wait -PassThru `
    -RedirectStandardOutput "$env:TEMP\sql_complete_stdout.txt" `
    -RedirectStandardError  "$env:TEMP\sql_complete_stderr.txt"

Get-Content "$env:TEMP\sql_complete_stdout.txt" | ForEach-Object { Write-Host "  [sql] $_" }

if ($proc.ExitCode -ne 0) {
    Write-Host '=== SQL Setup stderr ===' -ForegroundColor Red
    Get-Content "$env:TEMP\sql_complete_stderr.txt"
    $log = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($log) { Get-Content $log.FullName | Select-Object -Last 50 }
    throw "SQL Server CompleteImage failed (exit $($proc.ExitCode))"
}

# ── Restart SQL Server service to ensure clean state ─────────────────────────

Write-Host '  Restarting SQL Server service...'
Restart-Service MSSQLSERVER -Force
Start-Sleep 5

Write-Host "  ✅  SQL Server Developer Edition is running on $env:COMPUTERNAME." -ForegroundColor Green
