# Start the WinRM service required for configuration
Set-Service WinRM -StartupType Automatic
Start-Service WinRM

# Force network to Private instead of Public. WinRM setup often fails on Public networks.
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Allow basic authentication and unencrypted traffic for the Packer WinRM communicator
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item WSMan:\localhost\Client\AllowUnencrypted -Value $true
Set-Item WSMan:\localhost\Client\Auth\Basic -Value $true

# Enable the WinRM firewall rules
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"
netsh advfirewall firewall add rule name="WinRM" protocol=TCP dir=in localport=5985 action=allow

# For debugging the packer build, we also disable the firewall entirely. 
# It is better to do this *after* WinRM configuration to prevent WSManFault errors.
netsh advfirewall set allprofiles state off

Restart-Service WinRM
