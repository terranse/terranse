#!/usr/bin/env bash
# Build, sign, publish and -- if the box answers -- push one machine's system
# closure.
#
# One implementation with two entry points: `just deploy <machine>` from the
# laptop and the deploy job in .gitlab-ci.yml. CI ships bytes and writes a
# pointer; it never activates. The box verifies signatures and decides when to
# switch, so a stolen deploy key uploads something the box refuses rather than
# granting root.
#
# A sleeping television must never turn a pipeline red: everything after the
# pointer is written is best-effort, and the cache plus the pointer are the
# durable artifact.
set -euo pipefail

MACHINE="${1:?usage: ship.sh <machine> [--bump]}"
shift

BUMP=0
for arg in "$@"; do
  case "$arg" in
    --bump) BUMP=1 ;;
    *) echo "ship.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

CACHE_DIR="${NIX_CACHE_DIR:-/srv/nix-cache}"
SIGNING_KEY_FILE="${SIGNING_KEY_FILE:-}"
DEPLOY_HOST="${DEPLOY_HOST:-deploy@${MACHINE}.edholm.cc}"
WOL_BROADCAST="${WOL_BROADCAST:-192.168.1.255}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-90}"
MIN_FREE_MB="${MIN_FREE_MB:-20480}"
TFVARS="${TFVARS:-tofu/deployments/edholm/configurations.tfvars}"

log() { printf '==> %s\n' "$*"; }

if [ "$BUMP" -eq 1 ]; then
  # This commit is the gate made concrete: every system that ever ran
  # corresponds to a terranse commit that can be checked out and rebuilt.
  log "bumping the home-player input"
  nix flake update home-player
  if git diff --quiet -- flake.lock; then
    log "flake.lock unchanged"
  else
    git add flake.lock
    # [skip ci] because the lock bump and the deploy are one job; without it
    # the push would re-trigger the pipeline that made it.
    git -c user.name="terranse CI" -c user.email="ci@edholm.cc" \
      commit -m "chore(nix): bump home-player [skip ci]"
    if [ -n "${PUSH_REMOTE:-}" ]; then
      git push "$PUSH_REMOTE" "HEAD:${PUSH_BRANCH:-main}"
    else
      log "no PUSH_REMOTE set; leaving the bump commit local"
    fi
  fi
fi

log "building ${MACHINE}"
OUT=$(nix build --no-link --print-out-paths \
  ".#nixosConfigurations.${MACHINE}.config.system.build.toplevel")
log "built ${OUT}"

# A `nix copy` into a full dataset leaves a half-written cache that later
# fetches trip over, so refuse before rather than after.
avail=$(df -Pm "$CACHE_DIR" | awk 'NR==2 {print $4}')
if [ "$avail" -lt "$MIN_FREE_MB" ]; then
  echo "ship.sh: only ${avail}MB free on ${CACHE_DIR}, need ${MIN_FREE_MB}MB" >&2
  exit 1
fi

if [ -n "$SIGNING_KEY_FILE" ]; then
  log "signing with ${SIGNING_KEY_FILE}"
  nix store sign --recursive --key-file "$SIGNING_KEY_FILE" "$OUT"
else
  log "no SIGNING_KEY_FILE; publishing unsigned (the box will refuse this)"
fi

log "publishing to ${CACHE_DIR}"
nix copy --to "file://${CACHE_DIR}" "$OUT"

install -d "${CACHE_DIR}/pointers"
# Written last and atomically: a pointer must never name a closure the cache
# does not fully hold.
printf '%s\n' "$OUT" > "${CACHE_DIR}/pointers/${MACHINE}.new"
mv "${CACHE_DIR}/pointers/${MACHINE}.new" "${CACHE_DIR}/pointers/${MACHINE}"
printf '%s\n' "$OUT" >> "${CACHE_DIR}/pointers/${MACHINE}.history"
log "pointer written"

"$(dirname "$0")/prune-cache.sh" || log "cache prune failed (non-fatal)"

# ---- best-effort from here on --------------------------------------------

# The MAC is declared once, in tfvars, and read by both the DHCP reservation
# and this step.
WOL_MAC="${WOL_MAC:-$(awk -v m="$MACHINE" '
  $1 == m && $2 == "=" { inblock = 1 }
  inblock && $1 == "mac" { gsub(/"/, "", $3); print $3; exit }
' "$TFVARS" 2>/dev/null || true)}"

if [ -n "$WOL_MAC" ] && command -v wakeonlan >/dev/null 2>&1; then
  log "waking ${WOL_MAC}"
  wakeonlan -i "$WOL_BROADCAST" "$WOL_MAC" || true
else
  log "no MAC for ${MACHINE} (or no wakeonlan); not waking"
fi

log "waiting up to ${SSH_WAIT_SECONDS}s for ${DEPLOY_HOST}"
deadline=$(( $(date +%s) + SSH_WAIT_SECONDS ))
reachable=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "$DEPLOY_HOST" true 2>/dev/null; then
    reachable=1
    break
  fi
  sleep 5
done

if [ "$reachable" -ne 1 ]; then
  log "${DEPLOY_HOST} did not answer; it will pull from the cache on next boot"
  exit 0
fi

log "pushing the closure"
nix copy --to "ssh-ng://${DEPLOY_HOST}" "$OUT"

if ssh -o BatchMode=yes "$DEPLOY_HOST" 'test -x /run/current-system/sw/bin/htpc-stage'; then
  log "staging"
  ssh -o BatchMode=yes "$DEPLOY_HOST" \
    "sudo /run/current-system/sw/bin/htpc-stage $OUT"
else
  log "htpc-stage is not installed on ${MACHINE} yet; closure pushed, activate by hand"
fi

log "done"
