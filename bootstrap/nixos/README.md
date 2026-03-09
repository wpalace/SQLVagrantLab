# SQLVagrantLab NixOS GCP Builder

This directory contains the NixOS flake used to build the custom base image for the Google Cloud Platform deployment. It uses `nixos-generators` to output an image compatible with Google Compute Engine.

## Prerequisites

To build the image, you must have the **Nix package manager** installed on your system. If you are using NixOS, it is already installed. If you are on another Linux distribution or macOS, you can install it via:

```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
```

## Enable Nix Flakes

By default, the `nix-command` and `flakes` experimental features might be disabled on your system. If you see an error like:

> `error: experimental Nix feature 'nix-command' is disabled; add '--extra-experimental-features nix-command' to enable it`

You have two options to fix this:

### Option 1: Temporary (Per Command)
Append the `--extra-experimental-features "nix-command flakes"` flag to your `nix build` command:
```bash
nix --extra-experimental-features "nix-command flakes" build .#nixosConfigurations.sqlvagrantlab.config.system.build.googleComputeImage -o sqlvagrantlab
```

### Option 2: Permanent (Recommended)
Add the settings to your nix configuration file. Edit `~/.config/nix/nix.conf` (or `/etc/nix/nix.conf` for system-wide configuration):

```ini
experimental-features = nix-command flakes
```
Then you can run commands normally:
```bash
nix build .#nixosConfigurations.sqlvagrantlab.config.system.build.googleComputeImage -o sqlvagrantlab
```

## Building the Image

1. Change direction to this folder:
```bash
cd bootstrap/nixos
```

2. Run the build command:
```bash
nix build .#nixosConfigurations.sqlvagrantlab.config.system.build.googleComputeImage -o sqlvagrantlab
```

This will run for a few minutes and output a `.tar.gz` file located in the `./sqlvagrantlab/` directory.

3. Complete the deployment:
Upload this file to a GCS bucket, create a custom Machine Image using the tarball, and then deploy it using the Terraform setup in `bootstrap/terraform/`.
