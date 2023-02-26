# Fill it will variables, e.g. ssh keys, hostnames, etc

variable "ssh_key" {
  default = <<EOT
    ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGtvvMTZnu76+JxfBR+N6bAbxvUkZRvzwIKf7xWKxhDWLsQLpPwuOLDZ+YSl3mnMVX2nsY48Gnx/l/qFjyw9PrQy0M0zZ8ZEQ4xxbZgS2ttM+pK7EKMYqEYdftBlcjgfsVNUsXO1wBJXDBFmIwyU3t/mA5qg4eNbKmmXY5ZC53bdPoTCpbjxMEC5nagyQfGGRaqmkLbHuv9Z15nfvEms2Lufi88rju0KmPMwwxgi+0vlOklIhzB4llM/Lv/7PvZ9mktw8YXhr1YSZTTruHS7k2X3cxYPy0FayIEGgmTkw7oIPGsBN51Ipsrv67maYdIAjJ+rAFM6RgWPFDdyHa8mtt daniel@DESKTOP-ABOD49E
    ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDi8t84mx77FeaPQb0uUdugu7NS7dVvQ1t/JfqlQXHMURvNguMO2puYZf8J6EnXLJ7syCCHdXRVdEodlcpZlD6YihT8irbJMKOHe/5CwAi852SiS3zn6tgliAOktJLgfrgYWX5UPLY8DtNCJxvt3K7UJV+1tTQR/Vg0dC7JM/+JkLROavdsj54M3s0PMFX+DceVnD3tU3p5XFNhT0Y/TAOhxcC1TUiydj2Jx1mJHDJZLq9+IDaNH6eR/JKDIseHg7WiiR48KQfEpe2y2fjUVRA99bJG7lZ+y1iX9Knt3fzM5GL+MJZhWb+9yVKFEbkopTrlhu4yvxNseDYKdVuGzMxK5aZDSmSAMMKsaD+TDlEApnylawYLaxJZfjjzYzZdKOQG+JsJWFUUAn4AVv82ffHAY/ovSHFnOaTjTEGmD/5VXHe7YXXYdjavdGQj8fPxffo1X5TvhVMZlL5ouxhO3i2MbRorIyeY1Js7qplUsOqngcAMLORYx3jbfBbRH95Bg5c=
  EOT
}

variable "latest_debian" {
    type = string
    default = "debian-11-standard_11.3-1_amd64.tar.zst"
}

data "github_release" "example" {
    repository  = "operating-system"
    owner       = "home-assistant"
    retrieve_by = "latest"
}

variable "user" {
  type = string
  # default = "terraform-prov"
  default = "root"
}
