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

# Load the custom image from the GCS bucket snapshot archive
resource "google_compute_image" "restored_image" {
  name = "sqlvagrantlab-restored-image"

  raw_disk {
    source = "https://storage.googleapis.com/${var.snapshot_bucket_name}/${var.snapshot_archive_name}"
  }
}

# The GCP VM Instance
resource "google_compute_instance" "sqlvagrantlab_vm" {
  name = "sqlvagrantlab-host"

  # Logic to handle predefined vs custom machine types
  machine_type = var.machine_type == "custom" ? "custom-${var.custom_cpu}-${var.custom_memory_mb}" : var.machine_type

  zone = var.zone

  tags = ["sqlvagrantlab-host"]

  # Boot from the restored image instead of base Ubuntu
  boot_disk {
    initialize_params {
      image = google_compute_image.restored_image.self_link
      size  = 100 # Ensure this matches or exceeds your snapshot disk size!
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

  # Since the snapshot already has prerequisites and ISOs, we don't need the bootstrap script here.
  # The VM will boot up exactly as it was when the snapshot was taken.
}
