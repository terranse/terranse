# Plan-only: what each container's net0 asks Proxmox to write into
# /etc/network/interfaces and /etc/resolv.conf at every container start.

mock_provider "proxmox" {}
mock_provider "ansible" {}
mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = { name = "debian-13-standard_13.1-2_amd64.tar.zst" }
    }
  }
}

variables {
  ansible_root = "/nonexistent"
  ssh_key      = "ssh-ed25519 AAAA test"
  host         = "workstation"
  domain       = "edholm.cc"
  gateway      = "192.168.1.1"
  reserved_ips = {
    gitlab-runner = "192.168.1.49"
    herdr         = "192.168.1.52"
  }
  configuration = {
    gitlab-runner = {}
    unreserved    = {}
    herdr         = { ostype = "nixos" }
  }
}

run "reserved_container_gets_its_address_without_dhcp" {
  command = plan

  # The address has to be configured statically. Debian 13 ships ifupdown2,
  # and a DHCP-configured container got no address after a host reboot twice
  # (2026-09-20, 2026-11-15). A static address also does not depend on the
  # DHCP server being up when the container boots.
  assert {
    condition     = one(proxmox_lxc.lxcs["gitlab-runner"].network).ip == "192.168.1.49/24"
    error_message = "a container with a reserved address must get it statically, as <ip>/24"
  }
  assert {
    condition     = one(proxmox_lxc.lxcs["gitlab-runner"].network).gw == "192.168.1.1"
    error_message = "a static address needs the gateway for its default route"
  }
}

run "no_inet6_stanza_is_written" {
  command = plan

  # Any ip6 value makes Proxmox write `iface eth0 inet6 <method>` ahead of the
  # inet stanza. ifupdown2 then never starts dhclient, and even deletes the
  # address (verified with `ifup -n -v` in LXC 109 on 2026-11-18).
  assert {
    condition     = alltrue([for c in proxmox_lxc.lxcs : one(c.network).ip6 == null])
    error_message = "ip6 must stay unset so Proxmox writes no inet6 stanza"
  }
}

run "unreserved_container_still_uses_dhcp" {
  command = plan

  assert {
    condition     = one(proxmox_lxc.lxcs["unreserved"].network).ip == "dhcp"
    error_message = "a container without a reservation has no address to pin and must use DHCP"
  }
}

run "dns_is_the_lan_resolver_not_the_hosts" {
  command = plan

  # With neither set, Proxmox copies the host's resolv.conf into the
  # container. On a NetBird host that names 100.95.207.19, which a container
  # outside NetBird cannot reach. DHCP used to overwrite it; a static address
  # does not.
  assert {
    condition     = alltrue([for k, c in proxmox_lxc.lxcs : c.nameserver == "192.168.1.1" if k != "herdr"])
    error_message = "every Debian container must resolve through the LAN gateway"
  }
  assert {
    condition     = alltrue([for k, c in proxmox_lxc.lxcs : c.searchdomain == "edholm.cc" if k != "herdr"])
    error_message = "every Debian container must search the deployment domain"
  }
}

run "nixos_container_keeps_dhcp_and_its_own_dns" {
  command = plan

  # The ifupdown2 bug is Debian's. NixOS brings eth0 up with systemd-networkd,
  # which keeps retrying DHCP, and feeds the lease's DNS servers to
  # systemd-resolved (nix/profiles/lxc.nix). A static net0 gives resolved no
  # DNS servers, and a Proxmox-written resolv.conf would fight the stub.
  assert {
    condition     = one(proxmox_lxc.lxcs["herdr"].network).ip == "dhcp"
    error_message = "a NixOS container stays on DHCP even when it has a reservation"
  }
  assert {
    condition     = proxmox_lxc.lxcs["herdr"].nameserver == null && proxmox_lxc.lxcs["herdr"].searchdomain == null
    error_message = "Proxmox must not write DNS settings into a NixOS container"
  }
}
