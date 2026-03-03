{ config, pkgs, ... }:

{
  environment.systemPackages = [
    # PowerShell 7
    pkgs.powershell
  ];

  # Pre-install DBATools PowerShell Module for the labuser user
  system.activationScripts.installDbatools = ''
    sudo -u labuser ${pkgs.powershell}/bin/pwsh -Command "
      if (-not (Get-Module -ListAvailable -Name dbatools)) {
        Install-Module -Name dbatools -Scope CurrentUser -Force -AllowClobber -AcceptLicense
      }
      if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -AcceptLicense
      }
    "
  '';
}
