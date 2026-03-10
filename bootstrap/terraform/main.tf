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

# Create a devoted Service Account for this VM
resource "google_service_account" "sqlvagrantlab_sa" {
  account_id   = "sqlvagrantlab-sa"
  display_name = "SQLVagrantLab Service Account"
}

# Grant the Service Account read permission to the ISO bucket
resource "google_storage_bucket_iam_member" "iso_bucket_viewer" {
  bucket = var.iso_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.sqlvagrantlab_sa.email}"
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
      # Use a standard Ubuntu 24.04 image
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
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

  scheduling {
    preemptible                 = true # cost savings at the risk of VM being terminated
    automatic_restart           = false
    provisioning_model          = "SPOT"
    instance_termination_action = "STOP"
  }

  service_account {
    email  = google_service_account.sqlvagrantlab_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    iso-bucket-name = var.iso_bucket_name
    # Generate the startup-script by interpolating terraform variables into the bash script
    startup-script = templatefile("${path.module}/scripts/bootstrap-vm.sh", {
      iso_bucket_name = var.iso_bucket_name
    })
  }
}
