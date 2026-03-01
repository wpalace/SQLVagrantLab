#Requires -Version 7.0
<#
.SYNOPSIS
    Runs SQL Server /ACTION=PrepareImage then Sysprep during Packer build.

.DESCRIPTION
    This script runs via the WinRM communicator during Packer image construction.
    It:
      1. Locates the SQL Server setup.exe on the mounted ISO drive.
      2. Runs setup.exe /ACTION=PrepareImage to stage binaries without binding
         to a hostname or instance name.
      3. Runs Windows Sysprep to generalize the image for cloning.

    Packer shuts the VM down after Sysprep completes.

.ENVIRONMENT
    SQL_ISO_DRIVE   Drive letter where the SQL Server ISO is mounted (e.g. E:).
    SQL_VERSION     SQL Server version (2022 or 2025) — informational only.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step ([string]$msg) { Write-Host "==> [PrepareImage] $msg" -ForegroundColor Cyan }
function Wait-ForFile ([string]$path, [int]$TimeoutSec = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path $path) -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
    if (-not (Test-Path $path)) { throw "Timed out waiting for: $path" }
}

$sqlDrive = $env:SQL_ISO_DRIVE ?? 'E:'
$sqlVersion = $env:SQL_VERSION ?? '2022'

# ── 1. Locate SQL Server setup.exe ───────────────────────────────────────────

Write-Step "Locating SQL Server $sqlVersion media on drive $sqlDrive ..."

Wait-ForFile "$sqlDrive\setup.exe" -TimeoutSec 60
$setupExe = "$sqlDrive\setup.exe"
Write-Host "    Found: $setupExe"

# ── 2. SQL Server PrepareImage ────────────────────────────────────────────────
# /ACTION=PrepareImage stages binaries without binding to a machine name.
# /ACTION=CompleteImage (run later in the provisioner) finalises the install.

Write-Step 'Running SQL Server /ACTION=PrepareImage...'

$prepareArgs = @(
    '/ACTION=PrepareImage'
    '/QUIET'
    '/IACCEPTSQLSERVERLICENSETERMS'
    '/FEATURES=SQLEngine,FullText,Conn'
    '/INSTANCEID=MSSQLSERVER'
    '/INDICATEPROGRESS'
)

$proc = Start-Process -FilePath $setupExe -ArgumentList $prepareArgs `
    -Wait -PassThru -RedirectStandardOutput "$env:TEMP\sql_prepare_stdout.txt" `
    -RedirectStandardError  "$env:TEMP\sql_prepare_stderr.txt"

Get-Content "$env:TEMP\sql_prepare_stdout.txt" | ForEach-Object { Write-Host "  [sql] $_" }

if ($proc.ExitCode -ne 0) {
    Write-Host ''
    Write-Host '=== SQL Setup stderr ===' -ForegroundColor Red
    Get-Content "$env:TEMP\sql_prepare_stderr.txt"
    $summaryLog = Get-ChildItem "$env:ProgramFiles\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($summaryLog) { Get-Content $summaryLog.FullName | Select-Object -Last 50 }
    throw "SQL Server PrepareImage failed with exit code $($proc.ExitCode)"
}

Write-Host '    SQL Server PrepareImage completed successfully' -ForegroundColor Green