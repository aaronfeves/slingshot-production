output "rdp_address" {
  description = "The public IP address of the Windows server"
  value       = google_compute_address.static_ip.address
}

output "nt_username" {
  description = "The NinjaTrader User associated with this build"
  value       = var.nt_username
}
