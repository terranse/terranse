# Fill it will variables, e.g. ssh keys, hostnames, etc

variable "ssh_key" {
  default = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGtvvMTZnu76+JxfBR+N6bAbxvUkZRvzwIKf7xWKxhDWLsQLpPwuOLDZ+YSl3mnMVX2nsY48Gnx/l/qFjyw9PrQy0M0zZ8ZEQ4xxbZgS2ttM+pK7EKMYqEYdftBlcjgfsVNUsXO1wBJXDBFmIwyU3t/mA5qg4eNbKmmXY5ZC53bdPoTCpbjxMEC5nagyQfGGRaqmkLbHuv9Z15nfvEms2Lufi88rju0KmPMwwxgi+0vlOklIhzB4llM/Lv/7PvZ9mktw8YXhr1YSZTTruHS7k2X3cxYPy0FayIEGgmTkw7oIPGsBN51Ipsrv67maYdIAjJ+rAFM6RgWPFDdyHa8mtt daniel@DESKTOP-ABOD49E"
}

variable "latest_debian" {
    type = string
    default = "debian-11-standard_11.3-1_amd64.tar.zst"
}

variable "user" {
  type = string
  default = "terraform-prov"
}
