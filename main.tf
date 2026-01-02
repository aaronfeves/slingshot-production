# --- BACKEND CONFIGURATION ---
# This allows Terraform to store the "receipt" (state file) in your central bucket
terraform {
  backend "gcs" {}
}

# --- VIRTUAL MACHINE INSTANCE ---
resource "google_compute_instance" "slingshot_server" {
  name         = var.server_name
  machine_type = var.machine_type
  zone         = var.zone
  
  # The "rdp" tag is used by default GCP network rules to allow access
  tags         = ["rdp"]

  boot_disk {
    initialize_params {
      image = "windows-cloud/windows-2022"
      size  = 50
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Associates the static IP created below
      nat_ip = google_compute_address.static_ip.address
    }
  }

  # --- STARTUP LOGIC: USER SETUP & INSTALLATION ---
  metadata = {
    windows-startup-script-ps1 = <<EOF
      $flagFile = "C:\slingshot_setup_complete.txt"
      
      if (!(Test-Path $flagFile)) {
          # 1. Wait for 'adminuser' to be initialized by the OS
          $count = 0
          while (!(Get-LocalUser -Name "adminuser" -ErrorAction SilentlyContinue) -and $count -lt 30) {
              Start-Sleep -Seconds 1
              $count++
          }

          # 2. Set the password for adminuser (Targeting the specific base image user)
          net user adminuser "${var.admin_password}" /active:yes

          # 3. Create install directory
          New-Item -Path "C:\SlingshotInstall" -ItemType Directory -Force

          # 4. Download latest Slingshot version (Fixes 'outdated version' prompt)
          gsutil cp gs://${var.master_bucket}/installers/SlingshotSetup.exe C:\SlingshotInstall\SlingshotSetup.exe

          # 5. Silent Installation
          Start-Process -FilePath "C:\SlingshotInstall\SlingshotSetup.exe" -ArgumentList "/S" -Wait

          # 6. Mark setup as complete
          "Setup completed on $(Get-Date)" | Out-File $flagFile
      }
EOF
  }

  service_account {
    # Allows the VM to download from your Google Cloud Storage buckets
    scopes = ["cloud-platform"]
  }
}

# --- STATIC IP ALLOCATION ---
resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-ip"
  region = join("-", slice(split("-", var.zone), 0, 2))
}

# NOTE: Firewall resources were removed to prevent "Already Exists" crashes. 
# Ensure your project has the 'default-allow-rdp' rule enabled in VPC Network.
