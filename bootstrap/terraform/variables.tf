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
  default     = "custom" # Can be e.g. "n2-standard-4"
}

variable "custom_cpu" {
  description = "Number of vCPUs for custom machine type"
  type        = number
  default     = 4
}

variable "custom_memory_mb" {
  description = "Memory in MB for custom machine type"
  type        = number
  default     = 8192
}

variable "nixos_image" {
  description = "The name or family of the NixOS image created via flakes"
  type        = string
  default     = "sqlvagrantlab-nixos-image"
}
