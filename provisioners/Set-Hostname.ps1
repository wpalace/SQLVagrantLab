<#
.SYNOPSIS
    Renames the computer to match the YAML-specified hostname.

.DESCRIPTION
    Runs as a Vagrant provisioner immediately after Set-StaticIP.
    Vagrant is configured with 'reboot: true' for this step so the VM
    restarts before subsequent provisioners run.

.PARAMETER Hostname
    The desired computer name (e.g. dc01, sql01).
#>
param(
    [Parameter(Mandatory)][string]$Hostname
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$current = $env:COMPUTERNAME
Write-Host "==> [Set-Hostname] $current -> $Hostname" -ForegroundColor Cyan

if ($current -ieq $Hostname) {
    Write-Host "  ✅  Hostname already set to '$Hostname' — no change needed." -ForegroundColor Green
    exit 0
}

Rename-Computer -NewName $Hostname -Force
Write-Host "  ✅  Computer renamed to '$Hostname'. Vagrant will reboot now." -ForegroundColor Green
# Reboot is triggered by Vagrant's 'reboot: true' setting, not this script.
