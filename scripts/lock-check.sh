#!/usr/bin/env bash
# Warn when this checkout's flake.lock is older than the one nixhost last
# published for a machine, on its nightly/<machine> branch.
#
#   lock-check.sh <machine> [<remote>]
#
# Each night nixhost starts from the tracked branch's lock and bumps every
# input. If that full bump fails it retries with only home-player bumped, and
# then every other input comes from the lock the laptop pushed. A lock older
# than what the box already runs would then take the box backwards. The same
# goes for `just deploy-nixos`, which builds this lock as it is.
#
# Only ever warns, on stderr, and always exits 0: an unreachable nixhost or a
# branch that does not exist yet is not a reason to stop a deploy.
set -uo pipefail

MACHINE="${1:?usage: lock-check.sh <machine> [<remote>]}"
REMOTE="${2:-nixhost}"
BRANCH="nightly/${MACHINE}"
REF="refs/remotes/${REMOTE}/${BRANCH}"

cd "$(git rev-parse --show-toplevel)" || exit 0

if ! git fetch -q "$REMOTE" "+refs/heads/${BRANCH}:${REF}" 2>/dev/null; then
  exit 0
fi
published="$(git show "${REF}:flake.lock" 2>/dev/null)" || exit 0

# Inputs whose locked revision here is older than the published one.
older="$(jq -rn --slurpfile here flake.lock --argjson there "$published" '
  [ $there.nodes | to_entries[]
    | select(.value.locked.lastModified != null)
    | select(($here[0].nodes[.key].locked.lastModified // 0) < .value.locked.lastModified)
    | .key ] | join(", ")' 2>/dev/null)" || exit 0

if [ -n "$older" ]; then
  echo "WARNING: this flake.lock is older than nixhost's ${BRANCH} for: ${older}." >&2
  echo "WARNING: if a night's full bump fails, nixhost builds on these older inputs, and deploy-nixos uses them as they are." >&2
  echo "WARNING: to catch up, \`git merge ${REMOTE}/${BRANCH}\` or \`nix flake update\`, and commit." >&2
fi
exit 0
