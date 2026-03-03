{
  description = "NixOS configuration for SQLVagrantLab on GCP";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.sqlvagrantlab = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # GCE Support
        "${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
        
        # Custom Modules
        ./modules/virtualisation.nix
        ./modules/tooling.nix
        ./modules/powershell.nix
        ./modules/vscode.nix

        {
          # Required for GCE image creation
          system.stateVersion = "24.05";
          
          # Enable flakes
          nix.settings.experimental-features = [ "nix-command" "flakes" ];
          
          # Setup default user
          users.users.labuser = {
            isNormalUser = true;
            extraGroups = [ "wheel" "libvirtd" "kvm" ];
            password = "P@ssw0rd"; # For RDP access, ideally this should be replaced with ssh keys or set via GCP metadata.
          };

          # Allow unfree packages (vscode, etc)
          nixpkgs.config.allowUnfree = true;
        }
      ];
    };
  };
}
