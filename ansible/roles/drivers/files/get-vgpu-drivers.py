#!/usr/bin/env python3
"""
Download NVIDIA vGPU host + guest drivers from the foxipan community alist.

Usage
-----
    get-vgpu-drivers.py [-v VERSION] [-d DEST_DIR] [--host-only | --guest-only]

    • VERSION   – vGPU branch version (e.g., "20.0"). Default: latest available.
    • DEST_DIR  – directory where files are saved (default: /opt/nvidia-vgpu-drivers)

The script organises downloads into:
    DEST_DIR/
    ├── host/          NVIDIA-Linux-x86_64-*-vgpu-kvm.run
    └── guest/
        ├── linux/     NVIDIA-Linux-x86_64-*-grid.run  (+.deb if available)
        └── windows/   *_grid_win*_international.exe
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path
from typing import Final

# ---------------------------------------------------------------------------#
# Constants                                                                   #
# ---------------------------------------------------------------------------#
ALIST_BASE: Final[str] = "https://alist.homelabproject.cc"
ALIST_API: Final[str] = f"{ALIST_BASE}/api/fs/list"
ALIST_DOWNLOAD: Final[str] = f"{ALIST_BASE}/d"
VGPU_PATH: Final[str] = "/foxipan/vGPU"


# ---------------------------------------------------------------------------#
# Helpers                                                                     #
# ---------------------------------------------------------------------------#
def alist_list(path: str) -> list[dict]:
    """List directory contents via alist API."""
    payload = json.dumps({
        "path": path,
        "password": "",
        "page": 1,
        "per_page": 100,
        "refresh": False,
    }).encode()

    req = urllib.request.Request(
        ALIST_API,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "get-vgpu-drivers/1.0",
        },
    )

    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())

    if data.get("code") != 200:
        sys.exit(f"ERROR: alist API returned code {data.get('code')}: {data.get('message')}")

    return data["data"]["content"] or []


def find_latest_version() -> str:
    """Find the highest numbered vGPU version directory."""
    entries = alist_list(VGPU_PATH)
    versions = []
    for entry in entries:
        if entry["is_dir"]:
            match = re.match(r"^(\d+\.\d+)$", entry["name"])
            if match:
                versions.append(entry["name"])

    if not versions:
        sys.exit("ERROR: no version directories found in foxipan vGPU listing")

    versions.sort(key=lambda v: [int(x) for x in v.split(".")])
    return versions[-1]


def find_bundle_dir(version: str) -> str:
    """Find the NVIDIA-GRID-Linux-KVM-* directory inside a version."""
    entries = alist_list(f"{VGPU_PATH}/{version}")
    for entry in entries:
        if entry["is_dir"] and entry["name"].startswith("NVIDIA-GRID-Linux-KVM-"):
            return entry["name"]
    sys.exit(f"ERROR: no NVIDIA-GRID-Linux-KVM-* directory found in version {version}")


def download_file(remote_path: str, dest_dir: Path) -> Path:
    """Download a file from alist to dest_dir. Returns the local path."""
    url = f"{ALIST_DOWNLOAD}{remote_path}"
    filename = remote_path.rsplit("/", 1)[-1]
    dest = dest_dir / filename

    if dest.exists():
        print(f"  [skip] {filename} (already exists)")
        return dest

    print(f"  [downloading] {filename} ...")
    req = urllib.request.Request(url, headers={"User-Agent": "get-vgpu-drivers/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            with open(dest, "wb") as f:
                while chunk := resp.read(1024 * 1024):
                    f.write(chunk)
    except urllib.error.HTTPError as e:
        print(f"  [FAILED] {filename}: HTTP {e.code}", file=sys.stderr)
        dest.unlink(missing_ok=True)
        raise
    print(f"  [done] {filename}")
    return dest


# ---------------------------------------------------------------------------#
# Main logic                                                                  #
# ---------------------------------------------------------------------------#
def main(dest_dir: Path, version: str | None, host_only: bool, guest_only: bool) -> None:
    # Resolve version
    if version is None:
        print("Detecting latest vGPU version ...")
        version = find_latest_version()
    print(f"Using vGPU version: {version}")

    # Find bundle directory
    bundle_name = find_bundle_dir(version)
    bundle_path = f"{VGPU_PATH}/{version}/{bundle_name}"
    print(f"Bundle: {bundle_name}")

    # Parse version numbers from bundle name
    # Pattern: NVIDIA-GRID-Linux-KVM-{host_ver}-{linux_guest_ver}-{win_guest_ver}
    match = re.match(
        r"NVIDIA-GRID-Linux-KVM-([\d.]+)-([\d.]+)-([\d.]+)",
        bundle_name,
    )
    if match:
        host_ver, guest_linux_ver, guest_win_ver = match.groups()
        print(f"  Host driver:    {host_ver}")
        print(f"  Linux guest:    {guest_linux_ver}")
        print(f"  Windows guest:  {guest_win_ver}")

    # Create directory structure
    host_dir = dest_dir / "host"
    guest_linux_dir = dest_dir / "guest" / "linux"
    guest_windows_dir = dest_dir / "guest" / "windows"

    for d in (host_dir, guest_linux_dir, guest_windows_dir):
        d.mkdir(parents=True, exist_ok=True)

    # Download host driver
    if not guest_only:
        print("\nHost driver:")
        host_entries = alist_list(f"{bundle_path}/Host_Drivers")
        for entry in host_entries:
            if entry["name"].endswith("-vgpu-kvm.run"):
                download_file(
                    f"{bundle_path}/Host_Drivers/{entry['name']}",
                    host_dir,
                )
                break
        else:
            print("  [WARNING] No host driver found!", file=sys.stderr)

    # Download guest drivers
    if not host_only:
        print("\nGuest drivers:")
        guest_entries = alist_list(f"{bundle_path}/Guest_Drivers")
        for entry in guest_entries:
            name = entry["name"]
            if name.endswith("-grid.run"):
                download_file(f"{bundle_path}/Guest_Drivers/{name}", guest_linux_dir)
            elif name.endswith("_amd64.deb"):
                download_file(f"{bundle_path}/Guest_Drivers/{name}", guest_linux_dir)
            elif "_grid_win" in name and name.endswith(".exe"):
                download_file(f"{bundle_path}/Guest_Drivers/{name}", guest_windows_dir)

    # Write version metadata
    meta = {
        "vgpu_version": version,
        "bundle": bundle_name,
        "host_driver_version": host_ver if match else "unknown",
        "guest_linux_version": guest_linux_ver if match else "unknown",
        "guest_windows_version": guest_win_ver if match else "unknown",
    }
    meta_path = dest_dir / "VERSION.json"
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    print(f"\nMetadata written to {meta_path}")
    print("Done.")


# ---------------------------------------------------------------------------#
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Fetch NVIDIA vGPU drivers from foxipan community alist"
    )
    parser.add_argument(
        "-v", "--version",
        default=None,
        help="vGPU branch version (e.g., 20.0). Default: latest available.",
    )
    parser.add_argument(
        "-d", "--dest",
        default="/opt/nvidia-vgpu-drivers",
        help="Destination directory (default: /opt/nvidia-vgpu-drivers)",
    )
    parser.add_argument(
        "--host-only",
        action="store_true",
        help="Only download host driver",
    )
    parser.add_argument(
        "--guest-only",
        action="store_true",
        help="Only download guest drivers",
    )

    args = parser.parse_args()
    main(
        dest_dir=Path(args.dest).expanduser(),
        version=args.version,
        host_only=args.host_only,
        guest_only=args.guest_only,
    )
