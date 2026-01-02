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
      # This points to your specific build
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
          
          # 1. Wait for system user initialization
          $count = 0
          while (!(Get-LocalUser -Name "adminuser" -ErrorAction SilentlyContinue) -and $count -lt 30) {
              Start-Sleep -Seconds 2
              $count++
          }

          # 2. CREATE THE DIRECTORIES (Mandatory for the C# code)
          # The C# code expects C:\Slingshot\SlingshotWorker.exe 
          if (!(Test-Path "C:\Slingshot")) { New-Item -Path "C:\Slingshot" -ItemType Directory -Force }
          if (!(Test-Path "C:\SlingshotInstall")) { New-Item -Path "C:\SlingshotInstall" -ItemType Directory -Force }

          # 3. PULL BOTH BINARIES (Must be in the bucket)
          gsutil cp gs://${var.master_bucket}/binaries/SlingshotWorker.exe C:\Slingshot\SlingshotWorker.exe
          gsutil cp gs://${var.master_bucket}/installers/SlingshotSetup.exe C:\SlingshotInstall\SlingshotSetup.exe

          # This satisfies the 'if (args.Length < 3)' check in your C# code
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
}

resource "google_compute_address" "static_ip" {
  name   = "${var.server_name}-ip"
  region = join("-", slice(split("-", var.zone), 0, 2))
}
