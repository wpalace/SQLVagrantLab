# =============================================================================
# vagrant/lib/provider_qemu.rb
# QEMU provider abstraction for the SqlVagrantLab Vagrantfile.
#
# Interface contract (must be honoured by all provider_*.rb files):
#   configure_provider(machine_config, opts)
#   opts keys: :cpus, :memory_mb, :name
#
# To swap to Hyper-V: change the require_relative line in Vagrantfile.erb to
# point at provider_hyperv.rb — no other changes needed.
# =============================================================================

def configure_provider(machine, opts)
  machine.vm.provider :qemu do |qe|
    qe.name   = opts[:name]
    qe.cpus   = opts[:cpus]
    qe.memory = "#{opts[:memory_mb]}M"

    # Use QCOW2 disk (copy-on-write, efficient for throwaway lab VMs)
    qe.image_type = "qcow2"

    # Explicitly set qemu_dir to avoid vagrant-qemu defaulting to macOS path
    qe.qemu_dir = "/usr/share/qemu"

    # Machine type: Use 'pc' to match the Packer build architecture (q35 crashes Windows HAL)
    qe.machine     = "pc"
    qe.arch        = "x86_64"
    qe.cpu_model   = "host"   # Pass through host CPU for best performance
    qe.net_device  = "e1000e" # Intel Gigabit NIC is natively supported by Windows
    qe.drive_interface = "ide" # Ah, SATA is unsupported on if=, use IDE directly

    # Enable KVM hardware virtualisation (requires kvm kernel module)
    qe.extra_qemu_args = %w[-enable-kvm]

    # Boot firmware: use OVMF (UEFI) which Windows Server 2022/2025 prefer.
    # Packer must build the image with the same firmware.
    # Adjust path if OVMF is installed elsewhere on your distro.
    ovmf_paths = [
      "/usr/share/OVMF/OVMF_CODE.fd",
      "/usr/share/edk2/ovmf/OVMF_CODE.fd",
      "/usr/share/qemu/OVMF.fd",
    ]
    ovmf = ovmf_paths.find { |p| File.exist?(p) }
    if ovmf
      qe.extra_qemu_args += ["-bios", ovmf]
    else
      warn "[provider_qemu] WARNING: OVMF firmware not found — falling back to SeaBIOS"
    end
  end
end
