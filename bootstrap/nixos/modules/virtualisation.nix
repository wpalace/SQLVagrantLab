{ config, pkgs, ... }:

{
  # Virtualisation Configuration
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
    };
  };

  # Network Configuration for Bridges
  networking.bridges = {
    br0 = { interfaces = []; };
    br1 = { interfaces = []; };
  };

  networking.interfaces.br0.ipv4.addresses = [ { address = "10.0.50.1"; prefixLength = 24; } ];
  networking.interfaces.br1.ipv4.addresses = [ { address = "10.0.51.1"; prefixLength = 24; } ];

  # DNSMasq for Bridges
  services.dnsmasq = {
    enable = true;
    settings = {
      interface = [ "br0" "br1" ];
      bind-interfaces = true;
      port = 0; # Disable DNS, DHCP only
      dhcp-range = [
        "interface:br0,10.0.50.100,10.0.50.254,24h"
        "interface:br1,10.0.51.100,10.0.51.254,24h"
      ];
      dhcp-host = [
        # Domain Controllers
        "52:54:0a:00:32:0a,10.0.50.10,dc01"
        "52:54:0a:00:33:0a,10.0.51.10,dc02"
        # Region A SQL Hosts
        "52:54:0a:00:32:14,10.0.50.20"
        "52:54:0a:00:32:15,10.0.50.21"
        "52:54:0a:00:32:16,10.0.50.22"
        "52:54:0a:00:32:17,10.0.50.23"
        "52:54:0a:00:32:18,10.0.50.24"
        "52:54:0a:00:32:19,10.0.50.25"
        "52:54:0a:00:32:1a,10.0.50.26"
        "52:54:0a:00:32:1b,10.0.50.27"
        "52:54:0a:00:32:1c,10.0.50.28"
        "52:54:0a:00:32:1d,10.0.50.29"
        # Region B SQL Hosts
        "52:54:0a:00:33:14,10.0.51.20"
        "52:54:0a:00:33:15,10.0.51.21"
        "52:54:0a:00:33:16,10.0.51.22"
        "52:54:0a:00:33:17,10.0.51.23"
        "52:54:0a:00:33:18,10.0.51.24"
        "52:54:0a:00:33:19,10.0.51.25"
        "52:54:0a:00:33:1a,10.0.51.26"
        "52:54:0a:00:33:1b,10.0.51.27"
        "52:54:0a:00:33:1c,10.0.51.28"
        "52:54:0a:00:33:1d,10.0.51.29"
      ];
    };
  };

  # Allow QEMU bridge helper
  security.wrappers.qemu-bridge-helper = {
    source = "${pkgs.qemu_kvm}/libexec/qemu-bridge-helper";
    owner = "root";
    group = "root";
    setuid = true;
    setgid = true;
  };

  environment.etc."qemu/bridge.conf".text = ''
    allow br0
    allow br1
  '';

  # Packages
  environment.systemPackages = with pkgs; [
    qemu_kvm
    libvirt
    bridge-utils
    dnsmasq
    vagrant
    packer
  ];
  
  # Install Vagrant Plugins on activation
  system.activationScripts.vagrantPlugins = ''
    if ! ${pkgs.vagrant}/bin/vagrant plugin list | grep -q vagrant-qemu; then
      sudo -u labuser ${pkgs.vagrant}/bin/vagrant plugin install vagrant-qemu
    fi
    if ! ${pkgs.vagrant}/bin/vagrant plugin list | grep -q vagrant-reload; then
      sudo -u labuser ${pkgs.vagrant}/bin/vagrant plugin install vagrant-reload
    fi
  '';
}
