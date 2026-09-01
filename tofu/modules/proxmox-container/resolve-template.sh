#!/usr/bin/env bash
# Resolves an LXC template prefix (e.g. "debian-13") to the latest
# full template name from the Proxmox image repository.
# Called by the external data source — reads JSON from stdin.
set -euo pipefail

prefix=$(jq -r '.prefix' < /dev/stdin)

# All estate hosts are x86_64; "arm64" sorts after "amd64" lexically, so an
# unfiltered `sort -V | tail -1` picks an arm64 build once the download index
# lists one, even though nothing here runs it. Restrict to amd64 explicitly.
name=$(curl -sf http://download.proxmox.com/images/system/ \
  | grep -oP 'href="\K[^"]+' \
  | grep "^${prefix}-" \
  | grep -E '_amd64\.tar\.(zst|gz)$' \
  | sort -V \
  | tail -1)

if [ -z "$name" ]; then
  echo "no template matching prefix '${prefix}'" >&2
  exit 1
fi

echo "{\"name\":\"${name}\"}"
