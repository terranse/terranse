#!/usr/bin/env bash
# Build a NixOS container's rootfs tarball from this flake and put it where
# Proxmox looks for templates.
#
# /var/lib/vz/template/cache IS the vztmpl directory of the `local`
# dir-storage, and pveam is only a downloader -- a file dropped there is a
# first-class template with no registration step, addressable as
# local:vztmpl/<name>.
#
# Only needed to CREATE the container. Updates go through
# `just deploy-nixos <machine>`, not through a new template. But because tofu
# has `ostemplate` under ignore_changes, a stale template here is invisible to
# it: re-run this before re-creating a container you have tainted.
#
#   scripts/push-lxc-template.sh herdr workstation
set -euo pipefail

machine="${1:?usage: push-lxc-template.sh <machine> [proxmox-node-ssh-address]}"
node="${2:-192.168.1.200}"

flake_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$flake_root"

# The filename is pinned by image.baseName in nix/hosts/<machine>/default.nix,
# so tofu's ostemplate string never has to chase a nixpkgs revision. Read it
# rather than assuming it.
name="$(nix eval --raw ".#nixosConfigurations.${machine}.config.image.fileName")"

nix build ".#${machine}-lxc-template" --out-link "result-${machine}-template"
tarball="result-${machine}-template/tarball/${name}"
[ -f "$tarball" ] || { echo "no tarball at ${tarball}" >&2; exit 1; }

scp -O "$tarball" "root@${node}:/var/lib/vz/template/cache/${name}"
ssh "root@${node}" "pveam list local | grep -F '${name}'"

echo "ok: local:vztmpl/${name} is on ${node}"
