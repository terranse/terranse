output "items" {
  value = merge(
    local.top_level_fields,
    local.section_fields
  )
  sensitive = true
}
