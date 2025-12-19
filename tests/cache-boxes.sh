#!/bin/bash
# Pre-download Vagrant boxes for faster/offline testing
#
# This script caches Vagrant boxes locally in the libvirt storage pool.
# Run this before running Molecule tests to avoid downloading during tests.
#
# Usage:
#   ./tests/cache-boxes.sh
#   just cache-boxes

set -euo pipefail

# Boxes to cache with pinned versions for reproducibility
BOXES=(
    "debian/bookworm64"
)

echo "Caching Vagrant boxes for libvirt provider..."
echo "============================================="

for box_name in "${BOXES[@]}"; do
    echo ""
    echo "Processing: ${box_name}"

    # Check if already cached
    if vagrant box list 2>/dev/null | grep -q "${box_name}.*libvirt"; then
        echo "  Already cached, skipping."
        continue
    fi

    # Download with libvirt provider
    echo "  Downloading..."
    if vagrant box add "${box_name}" --provider libvirt; then
        echo "  Successfully cached."
    else
        echo "  Warning: Failed to cache ${box_name}"
    fi
done

echo ""
echo "============================================="
echo "Box caching complete!"
echo ""
echo "Cached boxes:"
vagrant box list 2>/dev/null | grep libvirt || echo "  (none)"
