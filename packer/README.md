# Building Packer Images for SQL Vagrant Lab

This directory contains the Packer configuration for building Windows Server Vagrant boxes pre-installed with SQL Server Developer Edition.

## Prerequisites

1. **Packer Plugins**: Ensure the QEMU and Vagrant plugins are installed:
   ```bash
   packer init .
   ```

2. **Required Media (ISOs)**:
   You will need the evaluation ISOs for Windows Server and the developer ISO for SQL Server.
   
   > **Important: ISO Location and Permissions**
   > Do **NOT** store the ISO files in `/root/` or any other directory restricted to the root user. When QEMU launches the virtual machine, it drops root privileges for security reasons. If the ISOs are in `/root/`, QEMU will get a "Permission Denied" error and silently fail to boot from the CD-ROM, causing Packer to hang indefinitely waiting for WinRM.
   > 
   > **Recommended Location for ISOs**:
   > Move your `.iso` files to a globally readable location like `/opt/packer-media/`:
   > ```bash
   > sudo mkdir -p /opt/packer-media
   > sudo mv ~/downloads/*.iso /opt/packer-media/
   > sudo chmod -R 755 /opt/packer-media
   > ```

3. **Verify ISO Integrity**:
   Make sure you actually downloaded the ISO files and not an HTML redirect page. Microsoft's download pages sometimes download HTML linking to the ISO if clicked incorrectly.
   Verify with the `file` command:
   ```bash
   file /opt/packer-media/*.iso
   ```
   They should show up as `ISO 9660 CD-ROM filesystem data` and not `HTML document`.

## Building the Images

Run Packer targeting one of the variable files in the `variables/` directory.

Example for Windows Server 2022 and SQL Server 2022:
```bash
PACKER_PLUGIN_PATH=~/.config/packer/plugins packer build -force -var-file=variables/win2022-sql2022.pkrvars.hcl .
```

*Note: You do not need `sudo` to run Packer if your user is a member of the `kvm` group.*

## Output

By default, the `.box` files will be output to `/opt/vagrant-boxes/`. You must ensure the directory exists and your user has write permissions prior to running Packer.
```bash
sudo mkdir -p /opt/vagrant-boxes
sudo chown -R $USER:$USER /opt/vagrant-boxes
```

---

## Troubleshooting & "Gotchas"

### 1. QEMU and Custom Drives (`qemuargs`)
When passing arguments via the `qemuargs` block in the Packer template, **never** use the `-drive` argument to attach the second (SQL Server) ISO. 

If QEMU receives a `-drive` parameter from the command line, it assumes you are manually overriding all default block devices. As a result, it will discard the automatically generated OS CD-ROM and Hard Disk that Packer usually attaches. The VM will boot into SeaBIOS with no bootable devices.

**Fix**: Always use the `-cdrom` argument to attach additional ISOs:
```hcl
# Correct ✅
qemuargs = [
  ["-cdrom", "${var.sql_iso_path}"]
]

# Incorrect ❌
qemuargs = [
  ["-drive", "file=${var.sql_iso_path},media=cdrom,index=3,readonly=on"]
]
```

### 2. Autounattend.xml Floppy Controller
The Windows Server initialization process reads `Autounattend.xml` from a virtual floppy disk to silently install Windows without user input. For this to work in QEMU, the machine type must support floppy drives. 
- Use `machine_type = "pc"` (the legacy i440fx chipset).
- Do not use `q35`, as Q35 does not possess a floppy controller, and Windows PE will ignore the unattended setup file.
