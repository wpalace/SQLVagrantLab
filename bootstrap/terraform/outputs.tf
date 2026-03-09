output "vm_public_ip" {
  description = "The public IP address of the deployed SQLVagrantLab host VM."
  value       = google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip
}

output "connection_instructions" {
  description = "Instructions for connecting to the VM"
  value       = <<EOF
The VM has been provisioned! Please wait a few minutes for the startup script
to install prerequisites, setup RDP, and download the ISOs.

Connect via SSH:
  ssh labuser@${google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip}

Connect via RDP (GUI for VSCode/QEMU):
  Point your RDP client to ${google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip}
  Username: labuser
  Password: P@ssw0rd

To watch the bootstrap progress via SSH in one command, run:
  ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null labuser@${google_compute_instance.sqlvagrantlab_vm.network_interface[0].access_config[0].nat_ip} "tail -f /var/log/bootstrap-vm.log"

Or, to view the serial console output directly via GCP:
  gcloud compute instances tail-serial-port-output ${google_compute_instance.sqlvagrantlab_vm.name} --project ${var.project_id} --zone ${var.zone}
EOF
}
