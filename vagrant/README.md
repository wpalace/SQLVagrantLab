# Testing Packer Output with Vagrant (QEMU & Windows Server)

This guide explains how to spin up a Packer-built Windows Server `.box` file locally using Vagrant and the `vagrant-qemu` plugin, specifically isolating and troubleshooting the image outside of higher-level deploy scripts.

## Prerequisites

- Vagrant
- QEMU (`sudo apt install qemu-system-x86`)
- Vagrant QEMU Plugin (`vagrant plugin install vagrant-qemu`)
- A completed Packer `.box` build located at `/opt/vagrant-boxes/win2022-sql2022.box`

## 1. Initializing the Test Environment

Start by creating an isolated test directory and initializing a new Vagrant environment.

```bash
mkdir -p ~/vagrant-test
cd ~/vagrant-test
vagrant init test-sql /opt/vagrant-boxes/win2022-sql2022.box
```

This will create a default `Vagrantfile` in the directory pointing to your box. However, because Vagrant defaults to Linux/VirtualBox configurations, **it will fail to boot Windows on QEMU** unless modified.

## 2. Modifying the Vagrantfile (The Windows Quirks)

Open the generated `Vagrantfile` in a text editor. You must replace the default configurations with the block below.

**Important Quirks to Understand:**

1. **Machine Architecture:** QEMU defaults to a PCIe (`q35`) motherboard, but Packer builds Windows PE on an older ISA (`pc`) architecture. If these don't match, Windows will crash with a Blue Screen of Death (`INACCESSIBLE_BOOT_DEVICE`).
2. **Storage Controller:** `vagrant-qemu` defaults to `virtio` generic storage interfaces, but the Windows ISO does not include VirtIO disk drivers. The image must be booted with an `ide` interface.
3. **Network Adapters:** Similarly, Windows lacks native `virtio-net` drivers. You must specify a native Intel Gigabit adapter (`e1000e`).
4. **SSH Authentication:** Vagrant tries to inject a new secure SSH key on the first boot (`insert_key = true`), but its key-insertion script relies on POSIX `chmod` commands which fail on Windows PowerShell. You must turn this off and rely on the password.
5. **Shell Command Syntax:** Vagrant assumes the SSH shell is `bash` by default and validates the connection using POSIX commands like `sh -c`. You must declare the guest as `:windows` and explicitly define `config.ssh.shell` to match exactly what OpenSSH uses (e.g., `pwsh`).

### The Working Vagrantfile

Replace the contents of your `Vagrantfile` with this exact configuration:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "test-sql"
  config.vm.box_url = "/opt/vagrant-boxes/win2022-sql2022.box"

  # ==========================================================
  # WINDOWS GUEST & SSH QUIRKS
  # ==========================================================
  config.vm.guest          = :windows
  config.vm.communicator   = "ssh"
  config.ssh.username      = "vagrant"
  config.ssh.password      = "vagrant"
  
  # Vagrant attempts to run POSIX "chmod 0600" to secure authorized_keys.
  # This crashes PowerShell/Windows NTFS, so we disable key injection.
  config.ssh.insert_key    = false
  
  # Must match the DefaultShell configured in OpenSSH in the HKLM registry
  config.ssh.shell         = "pwsh"
  config.vm.boot_timeout   = 600

  # Disable rsync folder sharing (Rsync attempts POSIX mkdir on guest)
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # ==========================================================
  # QEMU HARDWARE QUIRKS (Matching the Packer Build)
  # ==========================================================
  config.vm.provider "qemu" do |qe|
    # Explicitly set qemu_dir to avoid vagrant-qemu defaulting to macOS path on Linux
    qe.qemu_dir = "/usr/share/qemu"
    
    # Machine Architecture: MUST match Packer build or Windows HAL panics on boot
    qe.machine         = "pc"
    qe.arch            = "x86_64"
    qe.cpu_model       = "host"
    
    # Drivers: Windows native drivers only. No VirtIO out of the box.
    qe.net_device      = "e1000e" 
    qe.drive_interface = "ide"    
    
    # Headless Mode (Background Task):
    # This is the default. Change to `-display gtk` if you need to debug the boot sequence visually.
    qe.extra_qemu_args = %w[-enable-kvm -display none]
  end
end
```

## 3. Launching the Box

With the `Vagrantfile` correctly configured, build the environment using the QEMU provider flag (this requires `sudo` for KVM/Networking access):

```bash
sudo vagrant up --provider=qemu
```

*(Note: Depending on your exact Vagrant/OpenSSH version combinations, `vagrant up` might sometimes hang after printing the "SSH address" despite the VM fully booting. If it hangs, the VM is actually running perfectly in the background.)*

### SSH Access

If `vagrant up` hangs at the SSH prompt, simply open a new terminal tab and connect manually over the loopback adapter:

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 50022 vagrant@localhost
```
*Password: `vagrant`*

You will be dropped directly into the PowerShell 7 `pwsh` prompt.

## 4. Visual Debugging (QEMU GUI)

If the VM refuses to respond to SSH and you suspect Windows is crashing during the boot sequence, you can turn off "Headless" mode to see what Windows is doing.

Modify the `qe.extra_qemu_args` array in your `Vagrantfile` to open a GTK window:

```ruby
    qe.extra_qemu_args = %w[-enable-kvm -display gtk -vga std]
```

Then run `vagrant up` again. A desktop window will appear showing the BIOS and Windows load screens, allowing you to identify Blue Screens (`INACCESSIBLE_BOOT_DEVICE`), infinite lock screen loading, or Windows UI Critical Errors.

## 5. Teardown

To shut down and completely delete the QEMU instance and its virtual disks:

```bash
sudo killall qemu-system-x86_64
sudo rm -rf .vagrant
sudo vagrant destroy -f
```

*(Note: If you change physical hardware properties like `qe.machine` or `qe.net_device`, you **must** run `vagrant destroy` to wipe the disk before running `vagrant up` again. QEMU and Windows cache the hardware profile from the first boot.)*

## 6. Troubleshooting

### Port Conflicts

If you run into a port conflict while trying to start the VM (e.g., Vagrant complains that port `50022` is already in use), there is likely a zombie QEMU background process from a previous aborted run. 

You can identify and address the conflict with:

```bash
sudo lsof -i :50022
sudo kill -9 <pid>
```
