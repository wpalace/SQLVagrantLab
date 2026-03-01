# =============================================================================
# windows-sql.pkr.hcl
# Parameterized Packer HCL2 template for Windows Server + SQL Server images.
# Usage: packer build -var-file=variables/win2022-sql2022.pkrvars.hcl .
# =============================================================================

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
    vagrant = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "os_version" {
  type        = string
  description = "Windows Server version: 2022 or 2025"
}

variable "sql_version" {
  type        = string
  description = "SQL Server version: 2022 or 2025"
}

variable "os_iso_path" {
  type        = string
  description = "Absolute path to Windows Server Evaluation ISO on the host"
}

variable "os_iso_checksum" {
  type        = string
  default     = ""
  description = "SHA256 checksum of the OS ISO (leave empty to skip verification)"
}

variable "sql_iso_path" {
  type        = string
  description = "Absolute path to SQL Server Developer ISO on the host"
}

variable "output_dir" {
  type        = string
  default     = "~/vagrant-boxes"
  description = "Where to write the finished .box file"
}

variable "box_name" {
  type        = string
  description = "Name of the output .box, e.g. win2022-sql2022"
}

variable "headless" {
  type    = bool
  default = true
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "disk_size_mb" {
  type    = number
  default = 61440   # 60 GB
}

variable "vagrant_insecure_key" {
  type        = string
  default     = "https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub"
  description = "URL to the Vagrant insecure public key, written to authorized_keys"
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  output_path = "${var.output_dir}/${var.box_name}"
}

# ── Source ────────────────────────────────────────────────────────────────────

source "qemu" "windows_sql" {
  # --- Boot / ISO ---
  iso_url      = var.os_iso_path
  iso_checksum = var.os_iso_checksum != "" ? "sha256:${var.os_iso_checksum}" : "none"

  # disk_interface MUST be ide (not virtio-scsi) — Windows PE has no
  # built-in virtio-scsi driver and cannot see the disk during install.
  disk_interface = "ide"
  disk_size      = var.disk_size_mb
  format         = "qcow2"

  output_directory = local.output_path
  vm_name          = var.box_name

  cpus   = var.cpus
  memory = var.memory_mb

  headless         = var.headless
  display          = "none"

  # MUST be "pc" (i440fx), NOT q35.
  # q35 has no ISA floppy controller, so Packer's -fda flag is silently
  # ignored and Windows PE never reads Autounattend.xml from the floppy.
  machine_type = "pc"
  accelerator  = "kvm"     # KVM hardware acceleration — requires /dev/kvm access
  net_device   = "e1000"   # More compatible than virtio-net during OS install

  boot_wait    = "2s"
  boot_command = ["<spacebar><wait><spacebar><wait><spacebar>"]

  # WinRM communicator — used during the build phase only.
  # The finished image switches to OpenSSH at runtime (configured by configure-openssh.ps1).
  communicator   = "winrm"
  winrm_username = "vagrant"
  winrm_password = "vagrant"
  winrm_timeout  = "90m"   # Windows install + WinRM setup takes 30-60 min
  winrm_use_ssl  = false

  floppy_files = [
    "${path.root}/answer_files/win${var.os_version}/Autounattend.xml",
    "${path.root}/scripts/enable-winrm.ps1",
    "${path.root}/scripts/configure-openssh.ps1",
    "${path.root}/scripts/prepare-image.ps1",
  ]

  # SQL ISO as a second CD-ROM (OS ISO is index=0 on the IDE bus)
  qemuargs = [
    ["-cdrom", "${var.sql_iso_path}"]
  ]

  shutdown_command = "powershell -Command Stop-Computer -Force"
}

# ── Build ─────────────────────────────────────────────────────────────────────

build {
  sources = ["source.qemu.windows_sql"]

  # ── Step 0: Install PowerShell 7 ─────────────────────────────────────────────
  # Must run before the scripts below, which declare #Requires -Version 7.0.
  # This script is intentionally PS 5.1-compatible (no #Requires directive).
  provisioner "powershell" {
    script = "${path.root}/scripts/install-pwsh7.ps1"
  }

  # ── Step 1: Install OpenSSH Server & configure for Vagrant SSH ──────────────
  # elevated_user makes Packer run this via a scheduled task with a fully
  # elevated token. Required because Add-WindowsCapability (DISM API) fails
  # with the filtered token that WinRM Basic auth provides, even for admins.
  # elevated_execute_command routes the scheduled task through pwsh.exe (PS7)
  # to satisfy the script's #Requires -Version 7.0 directive.
  provisioner "powershell" {
    script = "${path.root}/scripts/configure-openssh.ps1"
    environment_vars = [
      "VAGRANT_KEY_URL=${var.vagrant_insecure_key}",
    ]
    elevated_user             = "vagrant"
    elevated_password         = "vagrant"
    elevated_execute_command  = "powershell -ExecutionPolicy Bypass -Command \". {{.Vars}}; & 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' -NoLogo -NoProfile -ExecutionPolicy Bypass -File '{{.Path}}'; exit $LASTEXITCODE\""
  }

  # ── Step 2: Install SetupComplete.cmd to re-configure WinRM after Sysprep ─────
  # Sysprep resets WinRM to an unconfigured/Manual-startup state. We install a
  # SetupComplete.cmd before Sysprep runs. Windows executes this file exactly
  # once after Sysprep/OOBE — when Vagrant first boots the box — re-enabling
  # WinRM so Vagrant's communicator can connect.
  # Requires elevation to write to C:\Windows\Setup\Scripts\.
  provisioner "powershell" {
    script = "${path.root}/scripts/configure-winrm-runtime.ps1"
    elevated_user             = "vagrant"
    elevated_password         = "vagrant"
    elevated_execute_command  = "powershell -ExecutionPolicy Bypass -Command \". {{.Vars}}; & 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' -NoLogo -NoProfile -ExecutionPolicy Bypass -File '{{.Path}}'; exit $LASTEXITCODE\""
  }

  # ── Step 3: SQL Server PrepareImage (stages binaries, no hostname binding) ───
  # Same elevation requirement as Step 1 — SQL Server setup.exe also requires
  # a fully elevated token.
  provisioner "powershell" {
    script = "${path.root}/scripts/prepare-image.ps1"
    environment_vars = [
      "SQL_ISO_DRIVE=E:",     # Second CD-ROM is typically D: or E: on Windows
      "SQL_VERSION=${var.sql_version}",
    ]
    elevated_user             = "vagrant"
    elevated_password         = "vagrant"
    elevated_execute_command  = "powershell -ExecutionPolicy Bypass -Command \". {{.Vars}}; & 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' -NoLogo -NoProfile -ExecutionPolicy Bypass -File '{{.Path}}'; exit $LASTEXITCODE\""
  }

  # ── Step 3: Sysprep (generalize image — Packer shuts down the VM after this) ─
  provisioner "powershell" {
    inline = [
      "Write-Host 'Block WinRM on first boot to prevent timing issues with vagrant'",
      "netsh advfirewall firewall set rule name=\"Windows Remote Management (HTTP-In)\" new action=block | Out-Null",
      "netsh advfirewall firewall set rule name=\"Windows Remote Management (HTTPS-In)\" new action=block | Out-Null",
      "Write-Host 'Running Sysprep (generalize + shutdown)...'",
      "$sysprep = \"$env:SystemRoot\\System32\\Sysprep\\sysprep.exe\"",
      "$sysprepArgs = '/generalize', '/oobe', '/shutdown', '/quiet'",
      "Write-Host \"    Executing: $sysprep $($sysprepArgs -join ' ')\"",
      "# Packer detects the shutdown itself. We must exit 0 so Packer knows the provisioner succeeded.",
      "Start-Process -FilePath $sysprep -ArgumentList $sysprepArgs -NoNewWindow",
      "exit 0"
    ]
    environment_vars = [
      "SQL_ISO_DRIVE=E:",     # Second CD-ROM is typically D: or E: on Windows
      "SQL_VERSION=${var.sql_version}",
    ]
    elevated_user             = "vagrant"
    elevated_password         = "vagrant"
    elevated_execute_command  = "powershell -ExecutionPolicy Bypass -Command \". {{.Vars}}; & 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' -NoLogo -NoProfile -ExecutionPolicy Bypass -File '{{.Path}}'; exit $LASTEXITCODE\""
  }

  # ── Step 4: Package as a Vagrant .box ────────────────────────────────────────
  post-processor "vagrant" {
    output               = "${var.output_dir}/${var.box_name}.box"
    vagrantfile_template = "${path.root}/vagrant_box_template.rb"
    keep_input_artifact  = false
  }
}
