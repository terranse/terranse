# OS Catalog — central lookup table for ISO and cloud image sources
#
# Linux entries use cloud_img_url (imported directly into Proxmox, no installer).
# Windows entries use iso_file (must be pre-uploaded to Proxmox storage).
# ISO fields are kept for Windows Packer builds.
#
# Add new OS versions by appending an entry with the URL + checksum.
# Find checksums on the distro's release page (SHA256SUMS / SHA512SUMS file).

os_catalog = {
  "debian-12" = {
    iso_url            = "https://cdimage.debian.org/debian-cd/12.9.0/amd64/iso-cd/debian-12.9.0-amd64-netinst.iso"
    iso_checksum       = "sha256:PLACEHOLDER_UPDATE_WITH_ACTUAL_CHECKSUM"
    iso_file           = ""
    os_type            = "l26"
    cloud_img_url      = ""
    cloud_img_checksum = ""
  }
  "debian-13" = {
    iso_url            = ""
    iso_checksum       = ""
    iso_file           = ""
    os_type            = "l26"
    cloud_img_url      = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
    cloud_img_checksum = "sha512:df0f1b09350658b0f42b83337682f36d7b821ea3a438d8257906e25350d2f92b0dcce810b0e6958887fb5210fd48625b8330339673df1ded127ffc0a969c12e5"
  }
  "ubuntu-2510" = {
    iso_url            = ""
    iso_checksum       = ""
    iso_file           = ""
    os_type            = "l26"
    cloud_img_url      = "https://cloud-images.ubuntu.com/releases/25.10/release/ubuntu-25.10-server-cloudimg-amd64.img"
    cloud_img_checksum = "sha256:1fe3479463842ea8166762d0aac910aa55137a6a46b9d98bce4b681921eb5af0"
  }
  "ubuntu-2604" = {
    iso_url            = ""
    iso_checksum       = ""
    iso_file           = ""
    os_type            = "l26"
    cloud_img_url      = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    cloud_img_checksum = "sha256:8ed228c9f08a50122fa72307623d9f88d9209ba26e7e849edd584fa675e34863"
  }
  "windows-11" = {
    iso_url            = ""
    iso_checksum       = ""
    iso_file           = "local:iso/Win11_25H2_EnglishInternational_x64_v2.iso"
    os_type            = "win11"
    cloud_img_url      = ""
    cloud_img_checksum = ""
  }
}

virtio_iso_url      = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
virtio_iso_checksum = "sha256:PLACEHOLDER_UPDATE_WITH_ACTUAL_CHECKSUM"
