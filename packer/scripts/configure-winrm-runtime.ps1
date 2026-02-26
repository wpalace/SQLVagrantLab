#Requires -Version 5.1
<#
.SYNOPSIS
    Installs a startup scheduled task + ConfigureWinRM.ps1 to re-configure WinRM
    on first boot after Sysprep so Vagrant's WinRM communicator can connect.

.DESCRIPTION
    Sysprep resets LocalAccountTokenFilterPolicy (the registry key that allows
    WinRM Basic/NTLM auth to work for local Administrators group members).
    The WinRM service itself stays configured (AllowUnencrypted, Basic auth,
    service startup type) because those registry settings survive Sysprep.

    This script (run as a Packer provisioner BEFORE Sysprep) does two things:

    1. Writes C:\Windows\Setup\Scripts\ConfigureWinRM.ps1 — the actual fix logic.

    2. Creates a startup scheduled task (AtStartup, runs as SYSTEM) that calls
       ConfigureWinRM.ps1. This is the key improvement over SetupComplete.cmd:
         - Scheduled task fires at SYSTEM STARTUP (before OOBE, before logon)
         - SetupComplete.cmd fires after OOBE completes (~8-15 min after boot)
       Starting WinRM auth configuration early means Vagrant can connect within
       its retry window (120 x 10s = 20 min), rather than waiting for OOBE.

    The task unregisters itself after running (one-shot).
#>

$SetupScriptsDir = 'C:\Windows\Setup\Scripts'

Write-Host "==> [winrm-runtime] Creating $SetupScriptsDir ..."
if (-not (Test-Path $SetupScriptsDir)) {
  New-Item -ItemType Directory -Path $SetupScriptsDir -Force | Out-Null
}

# ── 1. ConfigureWinRM.ps1 ─────────────────────────────────────────────────────
# Called by the scheduled task on first Vagrant boot.
# Also kept as SetupComplete.cmd target (belt-and-suspenders).

$ps1Content = @'
# ConfigureWinRM.ps1 — first boot after Sysprep (runs as SYSTEM via scheduled task).
# Restores LocalAccountTokenFilterPolicy and ensures WinRM is usable for Vagrant.

# Fix Remote UAC: local Administrators group members need this to authenticate
# over WinRM without the token being filtered down to a restricted token.
$sysPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -Path $sysPath -Name LocalAccountTokenFilterPolicy `
    -Value 1 -PropertyType DWORD -Force | Out-Null

# Disable firewall for Vagrant provisioning phase
netsh advfirewall set allprofiles state off

# Ensure WinRM service is running
Set-Service WinRM -StartupType Automatic
Start-Service WinRM -ErrorAction SilentlyContinue

# Set network profile to Private (WinRM quickconfig requires non-Public)
Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

# Core WinRM settings (belt-and-suspenders; most survive Sysprep, but re-apply)
winrm set winrm/config '@{MaxTimeoutms=7200000}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB=2048}'
winrm set winrm/config/service '@{AllowUnencrypted=true}'
winrm set winrm/config/service/auth '@{Basic=true}'
winrm set winrm/config/service/auth '@{Negotiate=true}'

# Explicit inbound rule for WinRM HTTP (5985)
netsh advfirewall firewall add rule name="WinRM-Vagrant" protocol=TCP dir=in localport=5985 action=allow

Restart-Service WinRM

# Unregister this task so it only runs once
Unregister-ScheduledTask -TaskName 'Configure-WinRM-Vagrant' -Confirm:$false -ErrorAction SilentlyContinue
'@

$ps1Path = Join-Path $SetupScriptsDir 'ConfigureWinRM.ps1'
Set-Content -Path $ps1Path -Value $ps1Content -Encoding Ascii -Force
Write-Host "==> [winrm-runtime] ConfigureWinRM.ps1 written."

# ── 2. Startup scheduled task (primary mechanism) ────────────────────────────
# Fires at SYSTEM STARTUP — much earlier than SetupComplete.cmd (which fires
# after OOBE completes, requiring logon to happen first).

$taskAction = New-ScheduledTaskAction `
  -Execute    'powershell.exe' `
  -Argument   "-NoProfile -ExecutionPolicy Bypass -File `"$ps1Path`""

$taskTrigger = New-ScheduledTaskTrigger -AtStartup

$taskSettings = New-ScheduledTaskSettingsSet `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
  -StartWhenAvailable $true

$taskPrincipal = New-ScheduledTaskPrincipal `
  -UserId    'SYSTEM' `
  -LogonType ServiceAccount `
  -RunLevel  Highest

Register-ScheduledTask `
  -TaskName  'Configure-WinRM-Vagrant' `
  -Action    $taskAction `
  -Trigger   $taskTrigger `
  -Settings  $taskSettings `
  -Principal $taskPrincipal `
  -Force | Out-Null

Write-Host "==> [winrm-runtime] Startup scheduled task 'Configure-WinRM-Vagrant' registered."

# ── 3. SetupComplete.cmd (belt-and-suspenders fallback) ──────────────────────
# Runs after OOBE as a fallback in case the scheduled task doesn't fire in time.
$cmdContent = @'
@echo off
REM SetupComplete.cmd — fallback, runs after OOBE completes on first Vagrant boot.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\ConfigureWinRM.ps1"
'@

$cmdPath = Join-Path $SetupScriptsDir 'SetupComplete.cmd'
Set-Content -Path $cmdPath -Value $cmdContent -Encoding Ascii -Force
Write-Host "==> [winrm-runtime] SetupComplete.cmd (fallback) written."
Write-Host "==> [winrm-runtime] WinRM will be auto-configured on first Vagrant boot."
