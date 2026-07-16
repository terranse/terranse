#!/bin/sh
# Build unattend-lan.iso for the LAN-party Windows prep VM.
# Run ON the Proxmox host (workstation) from this directory:
#   WIN_PASSWORD='...' ./build-unattend-iso.sh
# Output: /var/lib/vz/template/iso/unattend-lan.iso
set -eu

: "${WIN_PASSWORD:?set WIN_PASSWORD (local account password for user 'daniele')}"
OUT="${OUT:-/var/lib/vz/template/iso/unattend-lan.iso}"

command -v genisoimage >/dev/null 2>&1 || apt-get install -y genisoimage

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Substitute the password; keep everything else byte-identical
sed "s|\${WIN_PASSWORD}|$WIN_PASSWORD|g" autounattend.xml.tpl > "$tmp/autounattend.xml"
cp setup-lan.ps1 finalize-for-lan.ps1 "$tmp/"

genisoimage -quiet -J -R -V UNATTEND -o "$OUT" \
    "$tmp/autounattend.xml" "$tmp/setup-lan.ps1" "$tmp/finalize-for-lan.ps1"

echo "built: $OUT"
