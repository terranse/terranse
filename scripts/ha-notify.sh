#!/usr/bin/env bash
# Send one push notification through Home Assistant.
#
#   ha-notify.sh <title> <message>
#
# Reads HA_URL, HA_TOKEN and HA_NOTIFY_SERVICE (e.g. notify.mobile_app_pixel_8)
# from the environment. Always exits 0 and gives up after 10 seconds: telling
# someone is never allowed to break what it reports on. A failure goes to
# stderr, and to the file named by HA_NOTIFY_FAILED_FLAG when one is set, for
# a caller that wants to try again later.
#
# The token reaches curl as a config file on stdin, never as an argument, so it
# is not in any process listing.

set +e
set -u

title="${1:-}"
message="${2:-}"

give_up() {
  echo "ha-notify: $*" >&2
  [ -z "${HA_NOTIFY_FAILED_FLAG:-}" ] || : >"$HA_NOTIFY_FAILED_FLAG"
  exit 0
}

[ -n "${HA_URL:-}" ] || give_up "HA_URL is not set"
[ -n "${HA_TOKEN:-}" ] || give_up "HA_TOKEN is not set"
[ -n "${HA_NOTIFY_SERVICE:-}" ] || give_up "HA_NOTIFY_SERVICE is not set"

service="${HA_NOTIFY_SERVICE#notify.}"
body="$(mktemp)" || give_up "no temporary file"
trap 'rm -f "$body"' EXIT
jq -n --arg title "$title" --arg message "$message" \
  '{ title: $title, message: $message }' >"$body" || give_up "could not build the request"

code="$(
  printf 'header = "Authorization: Bearer %s"\n' "$HA_TOKEN" |
    curl -sS --max-time 10 -K - -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' --data-binary "@$body" \
      "${HA_URL%/}/api/services/notify/$service"
)"
case "$code" in
  2??) ;;
  *) give_up "Home Assistant did not accept the notification (HTTP ${code:-none})" ;;
esac
exit 0
