# --- 1. BACKEND CONFIGURATION ---
# Connects this server record to your central slingshot-states bucket
terraform {
  backend "gcs" {}
}

# --- 2. VIRTUAL MACHINE INSTANCE ---
resource "google_compute_instance" "slingshot_server" {
  name         = var.server_name
  machine_type = var.machine_type
  zone         = var.zone
  
  # "rdp" tag allows traffic through the default GCP firewall rules
  tags = ["rdp"]

  boot_disk {
    initialize_params {
      image = "windows-cloud/windows-2022"
      size  = 50
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Links the static IP address created below
      nat_ip = google_compute_address.static_ip.address
    }
  }

  # --- 3. STARTUP LOGIC (REPAIRING THE RACE CONDITION) ---
  metadata = {
    windows-startup-script-ps1 = <<EOF
      $flagFile = "C:\slingshot_setup_complete.txt"
      
      if (!(Test-Path $flagFile)) {
          # FIX: Wait for the Windows SAM database to initialize 'adminuser'
          # We check every 2 seconds for up to 60 seconds.
          $count = 0
          while (!(Get-LocalUser -Name "adminuser" -ErrorAction SilentlyContinue) -and $count -lt 30) {
              Write-Host "Waiting for adminuser account to be ready... attempt $count"
              Start-Sleep -Seconds 2
              $count++
          }

          # Reset the password for the specific user in your base image
          net user adminuser "${var.admin_password}" /active:yes

          # Create directory for the installer
          New-Item -Path "C:\SlingshotInstall" -ItemType Directory -Force

          # Download the latest version to fix 'outdated version' errors
          gsutil cp gs://${var.master_bucket}/installers/SlingshotSetup.exe C:\SlingshotInstall\SlingshotSetup.exe

          # Run the installer silently
          Start-Process -FilePath "C:\SlingshotInstall\SlingshotSetup.exe" -ArgumentList "/S" -Wait

          # Create the flag file to prevent the script from running on every reboot
          "Setup completed on $(Get-Date)" | Out-File $flagFile
      }
EOF
  }

  service_account {
    # Necessary for the VM to use 'gsutil' to talk to your buckets
    scopes = ["cloud-platform"]
  }
}

# --- 4. STATIC IP ADDRESS ---
resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-ip"
  region = join("-", slice(split("-", var.zone), 0, 2))
}
