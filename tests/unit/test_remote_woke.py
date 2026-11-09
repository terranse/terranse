"""nix/hosts/htpc/remote-woke.sh against kernel log lines captured on the HTPC:
two wakes from the remote, one from Wake-on-LAN, one from the RTC alarm."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "nix" / "hosts" / "htpc" / "remote-woke.sh"

ENTRY = "PM: suspend entry (deep)"
HOST = "xhci_hcd 0000:00:14.0"
REMOTE_WAKE = f"""{ENTRY}
usb 1-2: usb suspend, wakeup 0
ACPI: PM: Low-level resume complete
{HOST}: Port change event, 1-2, id 2, portsc: 0x4007e3
{HOST}: port resume event for port 2
{HOST}: Port change event, 1-1, id 1, portsc: 0x603
{HOST}: Port change event, 1-2, id 2, portsc: 0x603
{HOST}: Port change event, 1-5, id 5, portsc: 0x400e03
{HOST}: Port change event, 1-2, id 2, portsc: 0x200603
PM: suspend exit
"""
OTHER_WAKE = f"""{ENTRY}
{HOST}: Port change event, 1-1, id 1, portsc: 0x603
{HOST}: Port change event, 1-2, id 2, portsc: 0x603
{HOST}: Port change event, 1-4, id 4, portsc: 0x603
{HOST}: Port change event, 1-5, id 5, portsc: 0x400e03
PM: suspend exit
"""


def run(tmp_path, log, port="1-2"):
    marker = tmp_path / "run" / "remote-woke"
    subprocess.run(["bash", str(SCRIPT), port, str(marker)], input=log, text=True, check=True)
    return marker.exists()


def test_the_remote_waking_the_box_leaves_the_marker(tmp_path):
    assert run(tmp_path, REMOTE_WAKE)


def test_wake_on_lan_or_the_alarm_leaves_none(tmp_path):
    assert not run(tmp_path, OTHER_WAKE)


def test_only_the_latest_sleep_counts(tmp_path):
    assert not run(tmp_path, REMOTE_WAKE + OTHER_WAKE)
    assert run(tmp_path, OTHER_WAKE + REMOTE_WAKE)


def test_another_port_resuming_says_nothing_about_the_remote(tmp_path):
    assert not run(tmp_path, REMOTE_WAKE, port="1-4")


def test_a_port_name_is_not_matched_by_its_prefix(tmp_path):
    log = f"{ENTRY}\n{HOST}: Port change event, 1-2.1, id 2, portsc: 0x4007e3\n"
    assert not run(tmp_path, log)


def test_a_log_without_the_debug_lines_leaves_none(tmp_path):
    assert not run(tmp_path, f"{ENTRY}\nPM: suspend exit\n")
