# =============================================================================
# vagrant/lib/provider_hyperv.rb
# Hyper-V provider stub for future implementation.
#
# Satisfies the same configure_provider(machine, opts) contract as
# provider_qemu.rb.  To activate, change the require_relative line in
# Vagrantfile.erb from "lib/provider_qemu" to "lib/provider_hyperv".
# =============================================================================

def configure_provider(machine, opts)
  machine.vm.provider :hyperv do |hv|
    hv.vmname        = opts[:name]
    hv.cpus          = opts[:cpus]
    hv.memory        = opts[:memory_mb]
    hv.maxmemory     = opts[:memory_mb]  # Disable dynamic memory for lab stability
    hv.enable_virtualization_extensions = true  # Nested virtualisation
    hv.linked_clone  = true   # Fast clones from parent disk

    # TODO: configure virtual switch name once Hyper-V networking is designed
    # hv.vm_integration_services = { "Guest Service Interface" => true }
    raise NotImplementedError, <<~MSG
      Hyper-V provider is not yet fully implemented.
      Please complete vagrant/lib/provider_hyperv.rb before switching providers.
      See the implementation plan for guidance.
    MSG
  end
end
