<#
.SYNOPSIS
    Phase 2 WinRM hardening script — runs from the virtual floppy (A:\) during
    Windows OOBE after the inline winrm quickconfig commands in Autounattend.xml.

.DESCRIPTION
    Autounattend.xml FirstLogonCommands performs Phase 1 (inline winrm quickconfig)
    to get WinRM listening quickly. This script is Phase 2: it re-applies the
    authentication and encryption settings, adds an explicit firewall rule, and
    restarts the service cleanly.

    This script is intentionally PS 5.1-compatible — it runs before PS7 is installed.

    After Packer finishes its build, WinRM is NOT used at runtime. Vagrant connects
    via SSH (OpenSSH), which is configured later by configure-openssh.ps1.
#>

# Ensure WinRM service is running before we try to configure it
Set-Service WinRM -StartupType Automatic
Start-Service WinRM

# Fix Remote UAC token filtering: without this, local Administrators GROUP members
# (like the 'vagrant' user) get a filtered (non-admin) token for remote WinRM
# connections, which causes authentication to fail even with the correct password.
# This registry key allows full admin tokens for remote sessions.
$uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -Path $uacPath -Name LocalAccountTokenFilterPolicy `
    -Value 1 -PropertyType DWORD -Force | Out-Null
Write-Host '    LocalAccountTokenFilterPolicy = 1 (Remote UAC token filtering disabled)'

# Force network to Private. WinRM setup often fails on Public networks.
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Allow basic authentication and unencrypted traffic for the Packer WinRM communicator
Set-Item WSMan:\localhost\Service\AllowUnencrypted  -Value $true
Set-Item WSMan:\localhost\Service\Auth\Basic        -Value $true
Set-Item WSMan:\localhost\Client\AllowUnencrypted   -Value $true
Set-Item WSMan:\localhost\Client\Auth\Basic         -Value $true

# Set generous timeouts for long Packer provisioner steps (SQL install, etc.)
winrm set winrm/config '@{MaxTimeoutms=7200000}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB=2048}'

# Enable the WinRM built-in firewall rules
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"

# Belt-and-suspenders: explicit inbound rule on 5985 in case the built-in rule
# is missing (can happen on Server Core or freshly imaged systems)
$existingRule = netsh advfirewall firewall show rule name="WinRM-Packer" 2>&1
if ($existingRule -notmatch 'WinRM-Packer') {
    netsh advfirewall firewall add rule name="WinRM-Packer" protocol=TCP dir=in localport=5985 action=allow
}

# Disable the firewall entirely during the Packer build phase for reliability.
# The Vagrant runtime image will have its own firewall posture via provisioners.
netsh advfirewall set allprofiles state off

# Clean service restart to apply all settings
Restart-Service WinRM

Write-Host "==> [enable-winrm] WinRM hardening complete. Service is running on port 5985."
