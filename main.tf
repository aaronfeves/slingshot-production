terraform {
  backend "gcs" {} 
}

resource "google_compute_instance" "slingshot_server" {
  name         = var.server_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["rdp"] # Keeps it compatible with existing network rules

  boot_disk {
    initialize_params {
      image = "windows-cloud/windows-2022"
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
          net user adminuser "${var.admin_password}"
          New-Item -Path "C:\SlingshotInstall" -ItemType Directory -Force
          gsutil cp gs://${var.master_bucket}/installers/SlingshotSetup.exe C:\SlingshotInstall\SlingshotSetup.exe
          Start-Process -FilePath "C:\SlingshotInstall\SlingshotSetup.exe" -ArgumentList "/S" -Wait
          "Setup completed on $(Get-Date)" | Out-File $flagFile
      }
EOF
  }

  service_account {
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-ip"
  region = join("-", slice(split("-", var.zone), 0, 2))
}

# FIREWALL REMOVED TO PREVENT ERRORS
