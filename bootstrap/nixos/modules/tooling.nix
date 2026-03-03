{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    git
    sshpass
  ];

  # Preload the SQLVagrantLab repository
  system.activationScripts.preloadRepo = ''
    if [ ! -d /home/labuser/SQLVagrantLab ]; then
      sudo -u labuser git clone https://github.com/wpalace/SQLVagrantLab /home/labuser/SQLVagrantLab
    fi
  '';
}
