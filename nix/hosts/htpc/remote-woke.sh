# Whether the remote's USB dongle woke the box from its last sleep: leaves a
# marker the Home Player shell reads, to bring the TV on by itself.
#
#   dmesg | remote-woke <usb-port> <marker>
#
# Nothing else can tell. The key that wakes the box never arrives, and the
# wakeup counters are the same for the remote, Wake-on-LAN and the RTC alarm.
# Only the xHCI driver sees it: the port that signalled the wake comes back in
# link state Resume (PORTSC bits 5-8 = 15), every other port does not. That
# line is debug output, turned on by the xhci-wake-log unit.
set -euo pipefail

port=$1
marker=$2

portscs=$(awk -v needle="Port change event, ${port}, " '
  /PM: suspend entry/ { hits = "" }
  index($0, needle) { hits = hits " " $NF }
  END { print hits }
')

for portsc in $portscs; do
  if (( (portsc >> 5 & 15) == 15 )); then
    mkdir -p "$(dirname "$marker")"
    touch "$marker"
    exit 0
  fi
done
