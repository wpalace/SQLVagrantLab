output "vm_public_ip" {
  description = "The public IP address of the deployed SQLVagrantLab host VM."
  value       = google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip
}

output "connection_instructions" {
  description = "Instructions for connecting to the VM"
  value       = <<EOF
The VM has been provisioned!
Connect via SSH:
  ssh vagrant@${google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip}
Connect via RDP (GUI for VSCode/QEMU):
  Point your RDP client to ${google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip}
  Username: vagrant
  Password: password
EOF
}
