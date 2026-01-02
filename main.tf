terraform {
  backend "gcs" {}
}

resource "google_compute_instance" "slingshot_server" {
  name         = var.server_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["rdp"]

  boot_disk {
    initialize_params {
      # THE CRITICAL FIX: Re-linked to your custom Slingshot build
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
      
      # This block only runs on the VERY FIRST boot of a new instance
      if (!(Test-Path $flagFile)) {
          
          # 1. Wait for the OS to initialize the local SAM database
          $count = 0
          while (!(Get-LocalUser -Name "adminuser" -ErrorAction SilentlyContinue) -and $count -lt 30) {
              Start-Sleep -Seconds 2
              $count++
          }

          # 2. Reset the password for your existing 'adminuser'
          net user adminuser "${var.admin_password}" /active:yes
          Add-LocalGroupMember -Group "Administrators" -Member "adminuser" -ErrorAction SilentlyContinue

          # 3. Pull newest Installer to fix "Outdated Version" errors
          if (!(Test-Path "C:\SlingshotInstall")) { New-Item -Path "C:\SlingshotInstall" -ItemType Directory -Force }
          gsutil cp gs://${var.master_bucket}/installers/SlingshotSetup.exe C:\SlingshotInstall\SlingshotSetup.exe
          
          # 4. Run the installer silently to update the image's software
          Start-Process -FilePath "C:\SlingshotInstall\SlingshotSetup.exe" -ArgumentList "/S" -Wait
          
          # 5. Mark setup finished
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
