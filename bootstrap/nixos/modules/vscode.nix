{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    vscode
  ];

  # Enable X11 windowing system
  services.xserver = {
    enable = true;
    desktopManager = {
      xterm.enable = false;
      xfce = {
        enable = true;
      };
    };
  };

  # Enable xrdp for remote desktop access
  services.xrdp = {
    enable = true;
    defaultWindowManager = "xfce4-session";
    openFirewall = true;
  };

  # Make sure the user's desktop starts automatically with XRDP
  systemd.services.xrdp.environment = {
    PULSE_SERVER = "127.0.0.1";
  };
}
