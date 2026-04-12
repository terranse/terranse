#!/usr/bin/env bash
# Resolves an LXC template prefix (e.g. "debian-13") to the latest
# full template name from the Proxmox image repository.
# Called by the external data source — reads JSON from stdin.
set -euo pipefail

prefix=$(jq -r '.prefix' < /dev/stdin)

name=$(curl -sf http://download.proxmox.com/images/system/ \
  | grep -oP 'href="\K[^"]+' \
  | grep "^${prefix}-" \
  | grep -E '\.tar\.(zst|gz)$' \
  | sort -V \
  | tail -1)

if [ -z "$name" ]; then
  echo "no template matching prefix '${prefix}'" >&2
  exit 1
fi

echo "{\"name\":\"${name}\"}"
