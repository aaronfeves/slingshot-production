terraform {
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = "us-central1"
}

# --- 1. IAM PERMISSIONS FOR AUTOMATED SCHEDULING ---
# Allows the GCP system account to start/stop the VM unattended
data "google_project" "project" {}

resource "google_project_iam_member" "instance_schedule_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:service-${data.google_project.project.number}@compute-system.iam.gserviceaccount.com"
}

# --- 2. STATIC IP ALLOCATION ---
resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-${var.bucket_name}-ip"
  region = "us-central1"
}

# --- 3. INSTANCE SCHEDULE POLICY (6 AM - 7 AM Mon-Fri) ---
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
  
  # Attach the wake/sleep policy
  resource_policies = [google_compute_resource_policy.daily_schedule.id]

  boot_disk {
    initialize_params {
      image = "projects/linen-cargo-476801-f0/global/images/slingshot-image-main" 
      type  = "pd-ssd" 
      size  = 50
    }
  }

  network_interface {
    network = "default"
    access_config { nat_ip = google_compute_address.static_ip.address }
  }

  metadata = {
    windows-startup-script-ps1 = <<EOF
      # 1. Create Directories
      $SlingshotDir = "C:\Slingshot"
      $InstallDir = "C:\SlingshotInstall"
      if (!(Test-Path $SlingshotDir)) { New-Item -ItemType Directory -Force -Path $SlingshotDir }
      if (!(Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir }

      # 2. Set Environment Variables for C# Orchestrator
      # Combined path for the backup task logic
      [Environment]::SetEnvironmentVariable("SLINGSHOT_BACKUP_PATH", "${var.bucket_name}/backup", "Machine")

      # 3. Pull Binaries from Master Bucket
      gsutil cp "gs://${var.master_bucket}/binaries/SlingshotWorker.exe" "$SlingshotDir/"
      gsutil cp "gs://${var.master_bucket}/installers/SlingshotSetup.exe" "$InstallDir/"

      # 4. Execute Orchestrator with Credentials
      $exePath = "$InstallDir\SlingshotSetup.exe"
      $args = "${var.nt_username} ${var.nt_password} ${var.admin_password}"
      Start-Process -FilePath $exePath -ArgumentList $args -Wait
EOF
  }

  service_account {
    # cloud-platform scope allows gsutil to function
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # Ensure permissions exist before applying the schedule
  depends_on = [google_project_iam_member.instance_schedule_admin]
}

# --- 5. REMOTE ADMIN ACCESS ---
# Grants you the master key to destroy/manage this specific VM
resource "google_compute_instance_iam_member" "slingshot_admin_access" {
  project       = var.project_id
  zone          = var.zone
  instance_name = google_compute_instance.slingshot_server.name
  role          = "roles/compute.admin"
  member        = "user:aaronfeves@gmail.com"
}
