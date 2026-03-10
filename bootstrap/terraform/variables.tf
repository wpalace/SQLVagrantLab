variable "project_id" {
  description = "The GCP project ID to deploy to"
  type        = string
}

variable "region" {
  description = "The region to deploy to"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The zone to deploy to"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "The predefined GCP machine type, or a custom one defined by cpu and memory variables"
  type        = string
  default     = "n2d-standard-4" # must support nested virtualization (n series will, e will not)
}

variable "custom_cpu" {
  description = "Number of vCPUs for custom machine type"
  type        = number
  default     = 2
}

variable "custom_memory_mb" {
  description = "Memory in MB for custom machine type"
  type        = number
  default     = 4096
}

variable "iso_bucket_name" {
  description = "The name of the GCS bucket storing the ISO files"
  type        = string
}

variable "snapshot_bucket_name" {
  description = "The name of the GCS bucket storing the snapshots"
  type        = string
}
