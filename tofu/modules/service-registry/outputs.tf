output "services" {
  description = "Exposed HTTP services discovered from the compose templates"
  value       = local.services
}
