#!/usr/bin/env python3
"""
Download NVIDIA vGPU host + guest drivers from the AWS public bucket.

Usage
-----
    get_vgpu_drivers.py [-v VERSION] [-d DEST_DIR]

    • DEST_DIR  – directory where files are saved (default: ./drivers)

Prerequisites
-------------
    rclone configured with a remote called “Nvidia-vgpu-driver”:
        [Nvidia-vgpu-driver]
        type            = s3
        provider        = AWS
        region          = us-east-1
        no_sign_request = true
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Final


# ---------------------------------------------------------------------------#
# Constants that rarely change                                               #
# ---------------------------------------------------------------------------#
REMOTE: Final[str] = "Nvidia-vgpu-driver"
LINUX_BUCKET: Final[str] = "ec2-linux-nvidia-drivers"
WIN_BUCKET: Final[str] = "ec2-windows-nvidia-drivers"


# ---------------------------------------------------------------------------#
# Helper functions                                                           #
# ---------------------------------------------------------------------------#
def sh(command: list[str]) -> str:
    """Run *command* and return stdout, abort on error."""
    result = subprocess.run(
        command, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    return result.stdout.rstrip()


def get_version(version_match: str = "all") -> dict:
    """Check for all toolchain and driver versions available"""
    if version_match == "all":
        version_match = ""
    return json.loads(
        sh(
            [
                "rclone",
                "lsjson",
                "--metadata",
                f"{REMOTE}:{LINUX_BUCKET}/{version_match}",
            ]
        )[0]
    )


def latest_version() -> str:
    """Read the version string referenced by the ‘latest’ object."""
    version = get_version("latest")
    try:
        obj_name = version["Name"]
    except (KeyError, IndexError, json.JSONDecodeError):
        sys.exit("ERROR: could not parse the ‘latest’ object.")

    match = re.search(r"\d+\.\d+\.\d+", obj_name)
    if not match:
        sys.exit("ERROR: no version number found in object name.")

    return match.group(0)


def copy_from_s3(remote_path: str, dest_dir: Path) -> None:
    """Download a single object with rclone copy."""
    file_name = remote_path.split("/")[-1]
    print(f"→ {file_name}")
    sh(["rclone", "copy", "--progress", remote_path, str(dest_dir)])


def extract_version(path_string):
    """Parse Path to get version number (limited to X.Y since there has never been anything else)"""
    match = re.search(r"grid-(\d+)\.(\d+)", path_string)
    if match:
        major = int(match.group(1))
        minor = int(match.group(2))
        return (major, minor)
    return (0, 0)  # Default for non-matching items


def get_latest_tool_version():
    """Get the latest toolchain version, e.g. 18.2, not driver version"""
    all_versions = get_version("all")
    sorted_versions = sorted(all_versions, key=lambda x: extract_version(x["Path"]))
    latest_tool_version = sorted_versions[-1]
    return latest_tool_version


def main(dest_dir: Path) -> None:
    print("Detecting newest vGPU release …")
    tool_version = get_latest_tool_version()
    driver_version = latest_version()

    dest_dir.mkdir(parents=True, exist_ok=True)

    # host driver
    host_pkg = f"NVIDIA-Linux-x86_64-{driver_version}-grid.run"
    host_remote = f"{REMOTE}:{LINUX_BUCKET}/{tool_version}/{host_pkg}"
    copy_from_s3(host_remote, dest_dir)

    # Windows guest driver
    win_pkg = f"NVIDIA-GRID-Win10-Win11-{driver_version}-international.exe"
    win_remote = f"{REMOTE}:{WIN_BUCKET}/{tool_version}/{win_pkg}"
    copy_from_s3(win_remote, dest_dir)

    print(f"\nFinished – files saved to {dest_dir}")


# ---------------------------------------------------------------------------#
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Fetch NVIDIA vGPU host and guest drivers"
    )
    parser.add_argument(
        "-d",
        "--dest",
        default="drivers",
        help='Destination directory (default: "./drivers")',
    )

    args = parser.parse_args()
    try:
        main(Path(args.dest).expanduser())
    except subprocess.CalledProcessError as exc:
        print(exc.stderr or str(exc), file=sys.stderr)
        sys.exit(exc.returncode)
