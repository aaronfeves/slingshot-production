resource "google_compute_instance" "slingshot_server" {
  name         = var.server_name
  machine_type = var.machine_type
  zone         = var.zone

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

  # --- CRITICAL STARTUP LOGIC ---
  metadata = {
    windows-startup-script-ps1 = <<EOF
      $flagFile = "C:\slingshot_setup_complete.txt"
      
      # Only run this block if the flag file DOES NOT exist
      if (!(Test-Path $flagFile)) {
          # 1. Set the Windows Admin Password
          net user admin "${var.admin_password}"
          
          # 2. Create local directory
          New-Item -Path "C:\SlingshotInstall" -ItemType Directory -Force
          
          # 3. Pull latest Setup from your Public Release bucket
          # This ensures the "Outdated Version" error is fixed by getting the newest EXE
          gsutil cp gs://${var.master_bucket}/installers/SlingshotSetup.exe C:\SlingshotInstall\SlingshotSetup.exe
          
          # 4. Run the installer silently
          Start-Process -FilePath "C:\SlingshotInstall\SlingshotSetup.exe" -ArgumentList "/S" -Wait
          
          # 5. Create the flag file so this doesn't run again on reboot
          "Setup completed on $(Get-Date)" | Out-File $flagFile
      }
EOF
  }

  service_account {
    scopes = ["cloud-platform"]
  }
}

# --- FIREWALL & IP RESOURCES ---

resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-ip"
  region = join("-", slice(split("-", var.zone), 0, 2))
}

resource "google_compute_firewall" "allow_rdp" {
  name    = "${var.server_name}-allow-rdp"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["rdp"]
}

# --- RESOURCE POLICY (DAILY SCHEDULE) ---
resource "google_compute_resource_policy" "daily_schedule" {
  name   = "${var.server_name}-schedule"
  region = join("-", slice(split("-", var.zone), 0, 2))
  
  instance_schedule_policy {
    vm_start_schedule {
      schedule = "0 8 * * 1-5" # Start at 8 AM UTC Mon-Fri
    }
    vm_stop_schedule {
      schedule = "0 17 * * 1-5" # Stop at 5 PM UTC Mon-Fri
    }
    time_zone = "UTC"
  }
}
