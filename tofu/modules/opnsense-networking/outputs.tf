output "services_conf" {
  description = "Rendered Caddy drop-in"
  value       = local.services_conf
}

output "service_urls" {
  description = "Resulting URLs, for verification"
  value       = [for s in var.services : "https://${s.name}.${var.domain}"]
}
