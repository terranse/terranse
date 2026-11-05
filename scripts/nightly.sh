#!/usr/bin/env bash
# Nightly build for one machine, run on the build host at 01:30 Europe/Stockholm
# from a clean checkout of the bare repo's branch.
#
#   nightly.sh <machine>
#
# Start from the tracked branch exactly as it is on the remote (reset, not
# pulled, so a force-push from the laptop never breaks a night), bump the flake
# inputs, build every check, publish through `ship.sh <machine> --no-push`, and
# only then force-push what was built to its own branch, nightly/<machine>. The
# tracked branch is never written to: people push there. The box fetches the
# pointer at its 03:30 wake. ship.sh's own --bump stays unused: the check has
# to run before the commit, not after it.
#
# Every run, whatever happens to the build, it also tells Home Assistant once
# per period when the root filesystem is more than 80% full.
#
# On success it writes <cache>/pointers/<machine>.last-success (a plain epoch
# integer, atomically, last) -- the record the box reads to know how old its
# newest build is. If the build host itself has gone three nights without one,
# it tells Home Assistant once per stale period. The box alerts independently
# about what it does and does not take; that logic is not repeated here.
#
# Environment (all optional):
#   NIGHTLY_REMOTE     git remote to build from and publish to (default origin:
#                      the bare repo this checkout was cloned from)
#   NIGHTLY_BRANCH     the tracked branch on that remote (default main); read only
#   NIGHTLY_PUBLISH_BRANCH  where what was built goes (default nightly/<machine>)
#   NIGHTLY_DISK_PATH  filesystem whose use is watched (default /)
#   NIGHTLY_DISK_LIMIT percent used above which it alerts (default 80)
#   NIX_CACHE_DIR      the cache ship.sh publishes to (default /srv/nix-cache)
#   NIGHTLY_STATE_DIR  where the once-per-stale-period alert stamp lives
#   NIGHTLY_KVM        device VM tests need (default /dev/kvm)
#   HA_URL, HA_TOKEN, HA_NOTIFY_SERVICE  read by ha-notify.sh from the
#                      environment; never passed on a command line
set -euo pipefail

MACHINE="${1:?usage: nightly.sh <machine>}"

REMOTE="${NIGHTLY_REMOTE:-origin}"
BRANCH="${NIGHTLY_BRANCH:-main}"
PUBLISH="${NIGHTLY_PUBLISH_BRANCH:-nightly/${MACHINE}}"
DISK_PATH="${NIGHTLY_DISK_PATH:-/}"
DISK_LIMIT="${NIGHTLY_DISK_LIMIT:-80}"
CACHE_DIR="${NIX_CACHE_DIR:-/srv/nix-cache}"
STATE_DIR="${NIGHTLY_STATE_DIR:-/var/lib/nightly-build}"
KVM="${NIGHTLY_KVM:-/dev/kvm}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIP="${NIGHTLY_SHIP:-${SCRIPT_DIR}/ship.sh}"
NOTIFY="${NIGHTLY_NOTIFY:-${SCRIPT_DIR}/ha-notify.sh}"

# Stale after three nights. The build runs at 01:30 and takes a while, so the
# last success is a little under N*24h old at the Nth failed night; the margin
# keeps that from slipping through while two nights stays well clear of it.
STALE_AFTER=$((3 * 86400 - 6 * 3600))

LAST_SUCCESS="${CACHE_DIR}/pointers/${MACHINE}.last-success"
STAMP="${STATE_DIR}/${MACHINE}.alerted"
BASELINE="${STATE_DIR}/${MACHINE}.first-failure"
DISK_STAMP="${STATE_DIR}/disk.alerted"

log() { printf '==> %s\n' "$*"; }

# Runs on every failing exit. The stamp holds the last-success value already
# alerted for, so a stale period alerts once and a new success re-arms it.
maybe_alert() {
  local ref now flag
  now="$(date +%s)"
  ref=""
  if [ -r "$LAST_SUCCESS" ]; then
    ref="$(tr -d '[:space:]' <"$LAST_SUCCESS")"
    case "$ref" in '' | *[!0-9]*) ref="" ;; esac
  fi
  if [ -z "$ref" ]; then
    # No valid last-success (never worked, wrong NIX_CACHE_DIR, garbage):
    # age is measured from the first failure seen, so this cannot stay silent.
    if [ -r "$BASELINE" ]; then
      ref="$(tr -d '[:space:]' <"$BASELINE")"
      case "$ref" in '' | *[!0-9]*) ref="" ;; esac
    fi
    if [ -z "$ref" ]; then
      mkdir -p "$STATE_DIR" && printf '%s\n' "$now" >"$BASELINE" || true
      return 0
    fi
  fi
  [ $((now - ref)) -ge "$STALE_AFTER" ] || return 0
  if [ -r "$STAMP" ] && [ "$(cat "$STAMP")" = "$ref" ]; then
    return 0
  fi
  flag="$(mktemp)" && rm -f "$flag"
  HA_NOTIFY_FAILED_FLAG="$flag" "$NOTIFY" "Nightly build stale" \
    "No successful ${MACHINE} build for $(((now - ref) / 86400)) nights; the box has nothing new to fetch." || true
  # ha-notify.sh always exits 0; the flag is how it says delivery failed. Only
  # a delivered alert is stamped, so a failed one is retried the next night.
  if [ -e "$flag" ]; then
    rm -f "$flag"
    return 0
  fi
  mkdir -p "$STATE_DIR" && printf '%s\n' "$ref" >"$STAMP" || true
}

# Once per period over the limit, the same way as above: the stamp marks a
# period already told, a failed delivery is not stamped, and dropping back under
# the limit ends the period. Never a reason for the night to fail.
check_disk() {
  local pct flag
  pct="$(df -P "$DISK_PATH" 2>/dev/null | awk 'NR==2 {sub("%", "", $5); print $5}')" || pct=""
  case "$pct" in '' | *[!0-9]*)
    echo "nightly.sh: could not read the use of ${DISK_PATH}" >&2
    return 0
    ;;
  esac
  if [ "$pct" -le "$DISK_LIMIT" ]; then
    rm -f "$DISK_STAMP"
    return 0
  fi
  [ ! -e "$DISK_STAMP" ] || return 0
  flag="$(mktemp)" && rm -f "$flag"
  HA_NOTIFY_FAILED_FLAG="$flag" "$NOTIFY" "Build host disk nearly full" \
    "$(uname -n): ${DISK_PATH} is ${pct}% full (alert above ${DISK_LIMIT}%)." || true
  if [ -e "$flag" ]; then
    rm -f "$flag"
    return 0
  fi
  mkdir -p "$STATE_DIR" && : >"$DISK_STAMP" || true
}

UPDATED=""
on_exit() {
  local rc=$?
  [ -z "$UPDATED" ] || rm -f "$UPDATED"
  if [ "$rc" -ne 0 ]; then
    maybe_alert || true
  fi
  return "$rc"
}
trap on_exit EXIT

check_disk || true

cd "$(git rev-parse --show-toplevel)"

# Refuse before touching anything: a nightly run commits and pushes, and must
# not sweep up someone's half-finished edit.
if [ -n "$(git status --porcelain)" ]; then
  echo "nightly.sh: checkout is dirty; refusing to run" >&2
  exit 1
fi

# The tracked branch as the remote has it now. Last night's bump lives only on
# the published branch, so it is not carried forward: tonight's starts again
# from what people pushed.
git fetch -q "$REMOTE" "+refs/heads/${BRANCH}:refs/remotes/${REMOTE}/${BRANCH}"
git checkout -q -B "$BRANCH" "refs/remotes/${REMOTE}/${BRANCH}"

# One line per check: "<name> vm|plain". A check with a `driver` attribute is a
# NixOS VM test (runNixOSTest); everything else builds without /dev/kvm.
# shellcheck disable=SC2016 # the apply argument is a nix expression
checks="$(nix eval --raw .#checks.x86_64-linux --apply \
  'cs: builtins.concatStringsSep "\n" (map (n: n + " " + (if cs.${n} ? driver then "vm" else "plain")) (builtins.attrNames cs))')"
if [ -z "$checks" ]; then
  echo "nightly.sh: no checks enumerated from .#checks.x86_64-linux; refusing to build nothing" >&2
  exit 1
fi

run_checks() {
  local name kind
  while IFS=' ' read -r name kind; do
    [ -n "$name" ] || continue
    if [ "$kind" = "vm" ] && [ ! -w "$KVM" ]; then
      echo "nightly.sh: SKIPPING VM test ${name}: ${KVM} is not writable; only VM tests are skipped" >&2
      continue
    fi
    log "building check: ${name}"
    nix build --no-link ".#checks.x86_64-linux.${name}" || return 1
  done <<<"$checks"
}

# Writes the names of the inputs nix reports as updated to $UPDATED.
UPDATED="$(mktemp)"
update_and_check() {
  local errs
  errs="$(mktemp)"
  if ! nix flake update "$@" 2>"$errs"; then
    cat "$errs" >&2
    rm -f "$errs"
    return 1
  fi
  cat "$errs" >&2
  sed -n "s/.*Updated input '\([^']*\)'.*/\1/p" "$errs" >"$UPDATED"
  rm -f "$errs"
  run_checks
}

log "bumping all inputs"
if ! update_and_check; then
  git checkout -- flake.lock
  log "full bump failed; retrying with home-player only"
  if ! update_and_check home-player; then
    git checkout -- flake.lock
    echo "nightly.sh: both the full bump and the home-player-only bump failed; publishing nothing" >&2
    exit 1
  fi
fi

if git diff --quiet -- flake.lock; then
  log "flake.lock unchanged; nothing to commit"
else
  inputs="$(paste -sd, "$UPDATED" | sed 's/,/, /g')"
  git add flake.lock
  # Local only until it is published below; the next night resets past it.
  git -c user.name="nightly build" -c user.email="ci@edholm.cc" commit -q \
    -m "chore(nix): nightly bump [skip ci]" -m "Updated inputs: ${inputs}"
fi

"$SHIP" "$MACHINE" --no-push

# What the pointer was built from, so anyone can check it out. Forced: it is
# this job's branch alone, and each night replaces the last.
git push -q --force "$REMOTE" "HEAD:refs/heads/${PUBLISH}"
log "published $(git rev-parse --short HEAD) to ${PUBLISH}"

# After ship.sh, atomically: the box reads a bare epoch integer.
install -d "${CACHE_DIR}/pointers"
date +%s >"${LAST_SUCCESS}.new"
mv "${LAST_SUCCESS}.new" "$LAST_SUCCESS"
rm -f "$BASELINE"
log "recorded success for ${MACHINE}"
