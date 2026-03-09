output "vm_public_ip" {
  description = "The public IP address of the restored SQLVagrantLab host VM."
  value       = google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip
}

output "connection_instructions" {
  description = "Instructions for connecting to the restored VM"
  value       = <<EOF
The VM has been successfully restored from your snapshot!
Because it's a restored snapshot, there is no bootstrap waiting period.

Connect via SSH:
  ssh labuser@${google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip}

Connect via RDP (GUI for VSCode/QEMU):
  Point your RDP client to ${google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip}
  Username: labuser
  Password: P@ssw0rd (or your changed password from the snapshot)
EOF
}
