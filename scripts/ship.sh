#!/usr/bin/env bash
# Build, sign, publish and -- if the box answers -- push one machine's system
# closure.
#
# Two callers: scripts/nightly.sh on nixhost, which builds, signs and
# publishes with --no-push, and scripts/deploy.sh (`just deploy`), which has
# nixhost run that same nightly job and then hands the box the result with
# --stage. The builder ships bytes and writes a pointer; it never activates.
# The box verifies signatures and decides when to switch, so a stolen deploy
# key uploads something the box refuses rather than granting root.
#
# A sleeping television must never turn a pipeline red: everything after the
# pointer is written is best-effort, and the cache plus the pointer are the
# durable artifact.
#
# By default the box is woken, handed the closure and told to stage it; it
# then activates inside its own activation window. Three flags change that:
#   --now          stage with `htpc-stage --now`, which activates immediately
#                  and ignores the window (the urgent path)
#   --no-push      stop once the pointer is written: no wake, no SSH. The box
#                  picks the pointer up at its next fetch. Wins over --now.
#   --stage <out>  build and publish nothing: <out> is already in the cache.
#                  The box fetches it from there itself (its substituter), so
#                  this machine needs neither the closure nor a cache.
set -euo pipefail

MACHINE="${1:?usage: ship.sh <machine> [--bump] [--now] [--no-push] [--stage <store-path>]}"
shift

BUMP=0
NOW=0
PUSH=1
STAGE=0
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bump) BUMP=1 ;;
    --now) NOW=1 ;;
    --no-push) PUSH=0 ;;
    --stage)
      STAGE=1
      OUT="${2-}"
      shift || true
      ;;
    *) echo "ship.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift || true
done

# One literal store path and nothing a remote shell or Nix could read as more:
# Nix's base32 hash and the characters Nix allows in a name. It reaches the
# box inside a command string, so this is what keeps `;`, `$` and backticks
# out of a shell there; the value is also quoted on the way.
is_store_path() {
  [[ $1 =~ ^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+$ ]]
}

if [ "$STAGE" -eq 1 ]; then
  if [ "$PUSH" -eq 0 ] || [ "$BUMP" -eq 1 ]; then
    echo "ship.sh: --stage only hands the box a published closure; it takes neither --no-push nor --bump" >&2
    exit 2
  fi
  if ! is_store_path "$OUT"; then
    echo "ship.sh: --stage needs one literal store path, got '${OUT}'" >&2
    exit 2
  fi
fi

# Anchored to the script, not to the caller's cwd. Every default below that
# names a file in the repo has to be, or running ship.sh from anywhere else
# degrades silently rather than failing: a relative TFVARS that does not
# resolve makes the awk MAC lookup return nothing, which this script reports
# as the entirely ordinary "no MAC ... not waking" -- so a sleeping box is
# never woken and nothing says why.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# /srv/nix-cache is nixhost's cache directory (roles/update-host.nix) and
# exists nowhere else. Anywhere else, the existence check below turns it into
# a one-second, comprehensible failure instead of a df error after a
# multi-minute build. --stage needs no cache here at all.
CACHE_DIR="${NIX_CACHE_DIR:-/srv/nix-cache}"
SIGNING_KEY_FILE="${SIGNING_KEY_FILE:-}"
DEPLOY_HOST="${DEPLOY_HOST:-deploy@${MACHINE}.edholm.cc}"
WOL_BROADCAST="${WOL_BROADCAST:-192.168.1.255}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-90}"
MIN_FREE_MB="${MIN_FREE_MB:-20480}"
TFVARS="${TFVARS:-${REPO_ROOT}/tofu/deployments/edholm/configurations.tfvars}"

log() { printf '==> %s\n' "$*"; }

# Both cache checks run BEFORE the build, not after it. `df` on a directory
# that does not exist fails, and under `set -o pipefail` that took the whole
# script down with a raw "No such file or directory" *after* a full closure
# build had already been thrown away -- pre-empting the useful message a few
# lines further down. Checking first costs a second and says the right thing.
# (A `nix copy` into a full dataset also leaves a half-written cache that
# later fetches trip over, which is why the free-space check is a refusal
# rather than a warning.)
#
# publish: check the cache, bump, build, sign, publish and move the pointer.
# Everything --stage skips. Left unindented so the history stays readable.
publish() {
if [ ! -d "$CACHE_DIR" ]; then
  echo "ship.sh: cache directory ${CACHE_DIR} does not exist" >&2
  echo "ship.sh: on nixhost it is the cache the box reads; elsewhere set NIX_CACHE_DIR to a local path, or use \`just deploy\`, which builds on nixhost" >&2
  exit 1
fi
avail=$(df -Pm "$CACHE_DIR" | awk 'NR==2 {print $4}')
if [ "$avail" -lt "$MIN_FREE_MB" ]; then
  echo "ship.sh: only ${avail}MB free on ${CACHE_DIR}, need ${MIN_FREE_MB}MB" >&2
  exit 1
fi

if [ "$BUMP" -eq 1 ]; then
  # `nix flake update <input>` warns and exits 0 when no such input exists --
  # renamed, removed, or misspelt -- so the --bump gate would silently stop
  # holding while the pipeline stayed green, and a deployed system would no
  # longer correspond to any particular home-player revision. Assert the input
  # is really there first. Done in nix itself rather than with jq: the
  # nixos/nix image ships neither jq nor a guaranteed grep, and the deploy job
  # only adds bash, git, openssh, wakeonlan, gawk and gnused on top of it.
  if ! nix eval --impure --raw --expr \
       "let lock = builtins.fromJSON (builtins.readFile \"${REPO_ROOT}/flake.lock\");
        in if lock.nodes.\${lock.root}.inputs ? home-player
           then \"ok\" else throw \"absent\"" >/dev/null 2>&1; then
    echo "ship.sh: --bump was requested but the flake has no input named 'home-player'" >&2
    echo "ship.sh: refusing to report a bump that did not happen; fix flake.nix or drop --bump" >&2
    exit 1
  fi

  log "bumping the home-player input"
  nix flake update home-player
  # The commit below is the gate made concrete: every system that ever ran
  # corresponds to a terranse commit that can be checked out and rebuilt.
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
if ! is_store_path "$OUT"; then
  echo "ship.sh: the build printed '${OUT}', which is not one store path" >&2
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

"${REPO_ROOT}/scripts/prune-cache.sh" || log "cache prune failed (non-fatal)"
}

if [ "$STAGE" -eq 0 ]; then
  publish
else
  log "${OUT} is already published; handing it to ${MACHINE}"
fi

if [ "$PUSH" -eq 0 ]; then
  log "--no-push: stopping after the pointer; ${MACHINE} will fetch it itself"
  exit 0
fi

# ---- best-effort from here on --------------------------------------------

# The MAC is declared once, in tfvars, and read by both the DHCP reservation
# and this step.
#
# `inblock` must be cleared when the machine's own block closes, or a
# machine with no `mac` field falls through into whatever block comes next
# and silently returns a different host's MAC. Brace depth is tracked from
# the line the block opens on (its own `{` included) back down to the line
# where it closes, and scanning stops there whether or not `mac` was found.
WOL_MAC="${WOL_MAC:-$(awk -v m="$MACHINE" '
  $1 == m && $2 == "=" { inblock = 1; depth = 0 }
  inblock {
    depth += gsub(/{/, "{")
    depth -= gsub(/}/, "}")
    if ($1 == "mac") { gsub(/"/, "", $3); print $3; exit }
    if (depth <= 0) { inblock = 0 }
  }
' "$TFVARS" 2>/dev/null || true)}"

# The deploy job brings wakeonlan along; a laptop running `just deploy` may
# not, and skipping the wake then left a sleeping box unreached while the log
# blamed a missing MAC. Take it from nixpkgs for the one call.
wol() {
  if command -v wakeonlan >/dev/null 2>&1; then
    wakeonlan "$@"
  elif command -v nix >/dev/null 2>&1; then
    nix shell nixpkgs#wakeonlan -c wakeonlan "$@"
  else
    return 127
  fi
}

if [ -z "$WOL_MAC" ]; then
  log "no MAC for ${MACHINE} in ${TFVARS}; not waking"
elif log "waking ${WOL_MAC}" && wol -i "$WOL_BROADCAST" "$WOL_MAC" >/dev/null; then
  :
else
  log "could not send a wake to ${WOL_MAC} (no wakeonlan, and no nix to fetch it)"
fi

# The cache and pointer stand either way. What differs is the promise: the
# boot fetch honours the activation window, so a box that was not reached
# activates in its next window, not now. An urgent (--now) run must not report
# success for that.
not_activated() {
  if [ "$NOW" -eq 1 ]; then
    echo "ship.sh: $1" >&2
    echo "ship.sh: NOT activated; it will wait for the next night window" >&2
    exit 1
  fi
  log "$1; the box picks it up in its next activation window"
  exit 0
}

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
  not_activated "${DEPLOY_HOST} did not answer"
fi

# `if`, not a bare command: the box answered the reachability probe a moment
# ago, but it can still sleep, drop the network, or refuse the push before
# this finishes. The cache and pointer already stand, so a failure here must
# not turn the pipeline red -- not_activated exits 0 unless --now was asked
# for, and it does so instead of letting `set -e` take the script down.
if [ "$STAGE" -eq 1 ]; then
  # From the box's own substituter, signature-checked by its own daemon: the
  # deploy account is not trusted, so nothing unsigned gets in this way.
  log "${MACHINE} fetches the closure from its cache"
  if ! ssh -o BatchMode=yes "$DEPLOY_HOST" "nix-store --realise $(printf '%q' "$OUT")"; then
    not_activated "${MACHINE} could not fetch ${OUT}"
  fi
else
  log "pushing the closure"
  if ! nix copy --to "ssh-ng://${DEPLOY_HOST}" "$OUT"; then
    not_activated "push to ${DEPLOY_HOST} failed"
  fi
fi

if ssh -o BatchMode=yes "$DEPLOY_HOST" 'test -x /run/current-system/sw/bin/htpc-stage'; then
  STAGE_FLAG=""
  if [ "$NOW" -eq 1 ]; then
    STAGE_FLAG="--now "
    log "staging, activating now"
  else
    log "staging"
  fi
  # Same reasoning as the push above: staging is the box's business once the
  # bytes are on it, so a remote failure here is logged, not fatal.
  if ! ssh -o BatchMode=yes "$DEPLOY_HOST" \
       "sudo /run/current-system/sw/bin/htpc-stage ${STAGE_FLAG}$(printf '%q' "$OUT")"; then
    not_activated "staging on ${MACHINE} failed; the closure is on the box"
  fi
else
  not_activated "htpc-stage is not installed on ${MACHINE} yet; closure pushed"
fi

log "done"
