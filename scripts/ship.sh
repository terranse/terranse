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

# Anchored to the script, not to the caller's cwd. Every default below that
# names a file in the repo has to be, or running ship.sh from anywhere else
# degrades silently rather than failing: a relative TFVARS that does not
# resolve makes the awk MAC lookup return nothing, which this script reports
# as the entirely ordinary "no MAC ... not waking" -- so a sleeping box is
# never woken and nothing says why.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# /srv/nix-cache is the RUNNER's dataset and exists nowhere else. `just deploy`
# passes a laptop-local NIX_CACHE_DIR (see the recipe in the justfile); this
# default is what CI uses, and it is also what the existence check below turns
# into a one-second, comprehensible failure instead of a df error after a
# multi-minute build.
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
if [ ! -d "$CACHE_DIR" ]; then
  echo "ship.sh: cache directory ${CACHE_DIR} does not exist" >&2
  echo "ship.sh: on the runner it is the nix-cache dataset; elsewhere set NIX_CACHE_DIR to a local path (\`just deploy\` does this for you)" >&2
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
# `if`, not a bare command: the box answered the reachability probe a moment
# ago, but it can still sleep, drop the network, or refuse the push before
# this finishes. The cache and pointer already stand, so a failure here must
# not turn the pipeline red -- log it and exit 0 rather than let `set -e`
# take the script down.
if ! nix copy --to "ssh-ng://${DEPLOY_HOST}" "$OUT"; then
  log "push to ${DEPLOY_HOST} failed; the cache and pointer stand, it will pull on next boot"
  exit 0
fi

if ssh -o BatchMode=yes "$DEPLOY_HOST" 'test -x /run/current-system/sw/bin/htpc-stage'; then
  log "staging"
  # Same reasoning as the push above: staging is the box's business once the
  # bytes are on it, so a remote failure here is logged, not fatal.
  if ! ssh -o BatchMode=yes "$DEPLOY_HOST" \
       "sudo /run/current-system/sw/bin/htpc-stage $OUT"; then
    log "staging on ${MACHINE} failed; the closure is on the box, activate by hand"
    exit 0
  fi
else
  log "htpc-stage is not installed on ${MACHINE} yet; closure pushed, activate by hand"
fi

log "done"
