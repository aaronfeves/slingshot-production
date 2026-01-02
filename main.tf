terraform {
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
}

# --- 1. IAM PERMISSIONS FOR SCHEDULING ---
# This allows the GCP system to start/stop VMs without manual intervention
data "google_project" "project" {}

resource "google_project_iam_member" "instance_schedule_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:service-${data.google_project.project.number}@compute-system.iam.gserviceaccount.com"
}

# --- 2. INSTANCE SCHEDULE POLICY (6 AM - 7 AM Mon-Fri) ---
resource "google_compute_resource_policy" "daily_trading_schedule" {
  name   = "slingshot-trading-hours"
  region = join("-", slice(split("-", var.zone), 0, 2))

  instance_schedule_policy {
    vm_start_schedule {
      schedule = "0 6 * * 1-5" 
    }
    vm_stop_schedule {
      schedule = "0 7 * * 1-5" 
    }
    time_zone = "America/Los_Angeles" 
  }
}

# --- 3. THE SLINGSHOT SERVER ---
resource "google_compute_instance" "slingshot_server" {
  name         = var.server_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["rdp"]

  resource_policies = [google_compute_resource_policy.daily_trading_schedule.id]

  boot_disk {
    initialize_params {
      image = "projects/linen-cargo-476801-f0/global/images/slingshot-image-main"
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
      $flagFile = "C:\slingshot_setup_complete.txt"
      if (!(Test-Path $flagFile)) {
          $count = 0
          while (!(Get-LocalUser -Name "adminuser" -ErrorAction SilentlyContinue) -and $count -lt 30) {
              Start-Sleep -Seconds 2
              $count++
          }
          if (!(Test-Path "C:\Slingshot")) { New-Item -Path "C:\Slingshot" -ItemType Directory -Force }
          if (!(Test-Path "C:\SlingshotInstall")) { New-Item -Path "C:\SlingshotInstall" -ItemType Directory -Force }

          gsutil cp gs://${var.master_bucket}/binaries/SlingshotWorker.exe C:\Slingshot\SlingshotWorker.exe
          gsutil cp gs://${var.master_bucket}/installers/SlingshotSetup.exe C:\SlingshotInstall\SlingshotSetup.exe
          
          $exePath = "C:\SlingshotInstall\SlingshotSetup.exe"
          $args = "${var.nt_username} ${var.nt_password} ${var.admin_password}"
          Start-Process -FilePath $exePath -ArgumentList $args -Wait
          "Setup completed on $(Get-Date)" | Out-File $flagFile
      }
EOF
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  # This ensures the IAM permission is granted BEFORE the instance tries to use the policy
  depends_on = [google_project_iam_member.instance_schedule_admin]
}

resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-ip"
  region = join("-", slice(split("-", var.zone), 0, 2))
}

variable "project_id" {}
variable "server_name" {}
variable "nt_username" {}
variable "nt_password" {}
variable "admin_password" {}
variable "zone" { default = "us-central1-a" }
variable "machine_type" { default = "e2-standard-4" }
variable "master_bucket" { default = "slingshot-public-release" }

output "rdp_address" {
  value = google_compute_address.static_ip.address
}
