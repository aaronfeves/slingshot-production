# ==========================================================
# SLINGSHOT VARIABLES CONFIGURATION
# ==========================================================

variable "project_id" {
  description = "The GCP Project ID where resources are deployed"
  type        = string
}

variable "server_name" {
  description = "The unique name for the VM instance"
  type        = string
}

variable "nt_username" {
  description = "NinjaTrader Username/Email"
  type        = string
}

variable "nt_password" {
  description = "NinjaTrader Password"
  type        = string
}

variable "admin_password" {
  description = "Windows Administrator Password"
  type        = string
}

# This matches the CLIENT_HASH calculated in your bash scripts
variable "client_hash" {
  description = "The 10-character MD5 hash of the user's email"
  type        = string
}

variable "master_bucket" {
  description = "Central bucket for binaries and installers"
  type        = string
  default     = "slingshot-public-release"
}

variable "zone" {
  description = "GCP Zone for deployment"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "Machine resource specification"
  type        = string
  default     = "e2-highmem-2"
}
