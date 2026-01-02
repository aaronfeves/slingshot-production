variable "project_id" {
  description = "The Google Cloud Project ID"
  type        = string
}

variable "server_name" {
  description = "Name of the VM instance"
  type        = string
  default     = "slingshot-server"
}

variable "nt_username" {
  description = "NinjaTrader Email/Username"
  type        = string
}

variable "nt_password" {
  description = "NinjaTrader Password"
  type        = string
  sensitive   = true
}

variable "admin_password" {
  description = "Windows Admin Password"
  type        = string
  sensitive   = true
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "Machine type for the VM"
  type        = string
  default     = "e2-highmem-2"
}

variable "master_bucket" {
  description = "Public bucket containing the binaries"
  type        = string
  default     = "slingshot-public-release"
}

# ADD THIS BLOCK - This was the missing piece causing the error
variable "client_hash" {
  description = "Unique hash for user folder isolation"
  type        = string
}
variable "bucket_name" {
  description = "The client hash calculated by the bash script"
}
