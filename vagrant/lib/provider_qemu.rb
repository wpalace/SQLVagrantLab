# =============================================================================
# vagrant/lib/provider_qemu.rb
#
# The global QEMU hardware configuration (machine type, drivers, extra args)
# is now declared directly in Vagrantfile.erb as a config.vm.provider block
# so it is visible in the rendered Vagrantfile and matches the README exactly.
#
# Per-VM settings (name, cpus, memory, ssh.port) are set inline in each
# machine block in Vagrantfile.erb.
#
# This file is kept as a required stub so the require_relative in the
# Vagrantfile does not raise LoadError. It provides no configuration.
# =============================================================================
