terraform {
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = "us-central1"
}

# --- 1. IAM PERMISSIONS ---
data "google_project" "project" {}

resource "google_project_iam_member" "instance_schedule_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:service-${data.google_project.project.number}@compute-system.iam.gserviceaccount.com"
}

# --- 2. STATIC IP (Now using client_hash) ---
resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-${var.client_hash}-ip"
  region = "us-central1"
}

# --- 3. INSTANCE SCHEDULE (6 AM - 7 AM Mon-Fri) ---
resource "google_compute_resource_policy" "daily_schedule" {
  name   = "slingshot-trading-hours"
  region = "us-central1"
  
  instance_schedule_policy {
    vm_start_schedule { schedule = "0 6 * * 1-5" } 
    vm_stop_schedule  { schedule = "0 7 * * 1-5" } 
    time_zone = "America/Los_Angeles"
  }
}

# --- 4. VM INSTANCE ---
resource "google_compute_instance" "slingshot_server" {
  name         = var.server_name
  machine_type = var.machine_type
  zone         = var.zone
  resource_policies = [google_compute_resource_policy.daily_schedule.id]

  boot_disk {
    initialize_params {
      image = "projects/linen-cargo-476801-f0/global/images/slingshot-image-main" 
      size  = 50
    }
  }

  network_interface {
    network = "default"
    access_config { nat_ip = google_compute_address.static_ip.address }
  }

  metadata = {
    windows-startup-script-ps1 = <<EOF
      $SlingshotDir = "C:\Slingshot"
      $InstallDir = "C:\SlingshotInstall"
      if (!(Test-Path $SlingshotDir)) { New-Item -ItemType Directory -Force -Path $SlingshotDir }
      if (!(Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir }

      # Construct Backup Path using the client_hash
      [Environment]::SetEnvironmentVariable("SLINGSHOT_BACKUP_PATH", "${var.client_hash}/backup", "Machine")

      gsutil cp "gs://${var.master_bucket}/binaries/SlingshotWorker.exe" "$SlingshotDir/"
      gsutil cp "gs://${var.master_bucket}/installers/SlingshotSetup.exe" "$InstallDir/"

      $exePath = "$InstallDir\SlingshotSetup.exe"
      $args = "${var.nt_username} ${var.nt_password} ${var.admin_password}"
      Start-Process -FilePath $exePath -ArgumentList $args -Wait
EOF
  }

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [google_project_iam_member.instance_schedule_admin]
}

# --- 5. REMOTE ADMIN ACCESS ---
resource "google_compute_instance_iam_member" "slingshot_admin_access" {
  project       = var.project_id
  zone          = var.zone
  instance_name = google_compute_instance.slingshot_server.name
  role          = "roles/compute.admin"
  member        = "user:aaronfeves@gmail.com"
}
