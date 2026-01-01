# ==========================================================
# SLINGSHOT PRODUCTION - main.tf v1.6.67 (User Release)
# ==========================================================

terraform {
  # Backend is typically handled via 'terraform init -backend-config' in setup.sh
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = "us-central1"
}

# --- 1. FIREWALL ---
resource "google_compute_firewall" "allow_rdp" {
  name    = "${var.server_name}-allow-rdp"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["slingshot-rdp"]
}

# --- 2. STATIC IP ---
resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-ip"
  region = "us-central1"
}

# --- 3. INSTANCE SCHEDULE ---
resource "google_compute_resource_policy" "daily_schedule" {
  name   = "${var.server_name}-schedule"
  region = "us-central1"

  instance_schedule_policy {
    vm_start_schedule { schedule = "0 13 * * 1-5" } # 8:00 AM EST
    vm_stop_schedule  { schedule = "0 22 * * 1-5" } # 5:00 PM EST
    time_zone = "America/New_York"
  }
}

# --- 4. THE VM INSTANCE ---
resource "google_compute_instance" "slingshot_server" {
  name         = var.server_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["slingshot-rdp"]

  allow_stopping_for_update = true
  resource_policies         = [google_compute_resource_policy.daily_schedule.id]

  boot_disk {
    initialize_params {
      image = "projects/linen-cargo-476801-f0/global/images/slingshot-image-main"
      type  = "pd-ssd"
      size  = 50
    }
  }

  network_interface {
    network = "default"
    access_config { 
      nat_ip = google_compute_address.static_ip.address
    }
  }

  metadata = {
    windows-startup-script-ps1 = <<EOF
$ErrorActionPreference = "Stop"
$SlingshotDir = "C:\Slingshot"

# Ensure directory exists
if (!(Test-Path $SlingshotDir)) { New-Item -ItemType Directory -Force -Path $SlingshotDir }

# Download binaries from evergreen public bucket
Write-Host ">>> Fetching latest Slingshot Binaries..."
gsutil cp "gs://${var.master_bucket}/installers/SlingshotWorker.exe" "$SlingshotDir/"
gsutil cp "gs://${var.master_bucket}/installers/SlingshotSetup.exe" "$SlingshotDir/"

# Run the C# Orchestrator
# This handles User creation, Registry, and Scheduled Tasks
Write-Host ">>> Starting Setup Orchestrator..."
Start-Process "$SlingshotDir\SlingshotSetup.exe" `
    -ArgumentList "${var.nt_username}", "${var.nt_password}", "${var.admin_password}" `
    -WorkingDirectory $SlingshotDir `
    -Wait -NoNewWindow

# Cleanup for security
Remove-Item "$SlingshotDir\SlingshotSetup.exe" -Force
Write-Host ">>> Startup Complete."
EOF
  }

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# --- 5. OUTPUTS ---
output "rdp_address" {
  value       = google_compute_address.static_ip.address
  description = "Connect to this IP via RDP"
}
