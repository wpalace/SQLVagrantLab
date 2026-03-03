# Allow SSH (22) and RDP (3389)
resource "google_compute_firewall" "allow-remote-management" {
  name    = "allow-remote-management"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }

  source_ranges = ["0.0.0.0/0"] # Consider restricting this in production
  target_tags   = ["sqlvagrantlab-host"]
}

# The GCP VM Instance
resource "google_compute_instance" "sqlvagrantlab_vm" {
  name = "sqlvagrantlab-host"

  # Logic to handle predefined vs custom machine types
  machine_type = var.machine_type == "custom" ? "custom-${var.custom_cpu}-${var.custom_memory_mb}" : var.machine_type

  zone = var.zone

  tags = ["sqlvagrantlab-host"]

  boot_disk {
    initialize_params {
      image = var.nixos_image
      size  = 100 # Adjust as needed for the vagrant boxes
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {
      // Ephemeral public IP assigned automatically
    }
  }

  advanced_machine_features {
    enable_nested_virtualization = true
  }

  metadata = {
    # If the image expects ssh keys through metadata:
    # ssh-keys = "vagrant:${file("~/.ssh/id_rsa.pub")}"
  }
}
