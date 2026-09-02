terraform {
  required_version = ">= 1.6.0"
  required_providers {
    opnsense = {
      source  = "browningluke/opnsense"
      version = "~> 0.16"
    }
  }
}

locals {
  services_conf = templatefile("${path.module}/templates/services.conf.tftpl", {
    services   = var.services
    domain     = var.domain
    cert_refid = var.cert_refid
  })
}
