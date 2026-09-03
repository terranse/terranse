output "services_conf" {
  description = "Rendered Caddy drop-in"
  value       = local.services_conf
}

output "service_urls" {
  description = "Resulting URLs, for verification"
  value       = [for s in var.services : "https://${s.name}.${var.domain}"]
}

output "service_records" {
  description = "DNS names created for exposed services"
  value       = [for k, v in opnsense_dnsmasq_host.service : "${v.hostname}.${v.domain}"]
}

output "reservation_records" {
  description = "Container name -> reserved address"
  value       = { for k, v in opnsense_dnsmasq_host.reservation : k => one(v.ip_addresses) }
}
