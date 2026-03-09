variable "project_id" {
  description = "The GCP Project ID to deploy to"
  type        = string
}

variable "region" {
  description = "The GCP Region to deploy to"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP Zone to deploy to"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "The predefined machine type. Keep this consistent with the snapshot's machine type to avoid nested virt issues, or adjust custom types."
  type        = string
  default     = "custom"
}

variable "custom_cpu" {
  description = "Number of vCPUs if machine_type is 'custom'"
  type        = number
  default     = 4
}

variable "custom_memory_mb" {
  description = "Amount of memory in MB if machine_type is 'custom'"
  type        = number
  default     = 8192
}

variable "snapshot_bucket_name" {
  description = "The name of the GCS bucket where your snapshots are stored"
  type        = string
}

variable "snapshot_archive_name" {
  description = "The filename of the .tar.gz archive in the snapshot_bucket_name (e.g., 'lab-base-installed.tar.gz')"
  type        = string
}
