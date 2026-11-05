#!/usr/bin/env bash
# The urgent path, `just deploy <machine>`: get what is committed here onto the
# box now, signed by nixhost, without waiting for the night.
#
#   deploy.sh <machine> [--no-push]
#
# 1. Push the current branch to nixhost. It must be the branch nixhost builds
#    (roles.update-host.branch), and everything must be committed.
# 2. Run nixhost's nightly job for it now -- the same unit, bump, checks,
#    signing and publish as every night -- following its journal until it ends,
#    and fail if it failed. The signing key never leaves nixhost.
# 3. Have the box fetch the published closure from its cache and activate it
#    at once (`ship.sh --stage`, which ends in `htpc-stage --now` over
#    `ssh deploy@<machine>`). The pointer is now this build, so the next night
#    finds the box current instead of taking it back.
#
# --no-push stops after step 2: published, and taken at the box's next night.
#
# Environment (all optional; tests set them): DEPLOY_REMOTE (git remote for
# nixhost's repo, default nixhost), DEPLOY_NIXHOST (ssh target), DEPLOY_SHIP,
# DEPLOY_BRANCH, DEPLOY_BUILDS and DEPLOY_CACHE_URL (otherwise read from the
# flake: what nixhost builds, and where the box reads its cache).
set -euo pipefail

MACHINE="${1:?usage: deploy.sh <machine> [--no-push]}"
shift
PUSH=1
for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=0 ;;
    *) echo "deploy.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

REMOTE="${DEPLOY_REMOTE:-nixhost}"
NIXHOST="${DEPLOY_NIXHOST:-default-user@nixhost.edholm.cc}"
SHIP="${DEPLOY_SHIP:-${REPO_ROOT}/scripts/ship.sh}"
UNIT=nixhost-nightly.service

log() { printf '==> %s\n' "$*"; }
flake_str() { nix eval --raw ".#nixosConfigurations.$1"; }

BUILDS="${DEPLOY_BUILDS:-$(flake_str nixhost.config.roles.update-host.machine)}"
if [ "$MACHINE" != "$BUILDS" ]; then
  echo "deploy.sh: nixhost builds ${BUILDS}, not ${MACHINE}; use \`just deploy-nixos ${MACHINE}\`" >&2
  exit 1
fi
BRANCH="${DEPLOY_BRANCH:-$(flake_str nixhost.config.roles.update-host.branch)}"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "deploy.sh: uncommitted changes; nixhost builds what is pushed, so commit them first" >&2
  exit 1
fi
current="$(git symbolic-ref --short -q HEAD || true)"
if [ "$current" != "$BRANCH" ]; then
  echo "deploy.sh: nixhost builds ${BRANCH}, and this checkout is on '${current:-a detached HEAD}'" >&2
  echo "deploy.sh: check out ${BRANCH}, or change roles.update-host.branch in nix/machines.nix and deploy nixhost" >&2
  exit 1
fi
CACHE_URL="${DEPLOY_CACHE_URL:-$(flake_str "${MACHINE}.config.roles.staged-updates.cacheUrl")}"

"${REPO_ROOT}/scripts/lock-check.sh" "$MACHINE" "$REMOTE"

pushed="$(git rev-parse HEAD)"
log "pushing ${BRANCH} ($(git rev-parse --short HEAD)) to ${REMOTE}"
# Not forced: if someone else pushed, that is theirs to keep.
git push "$REMOTE" "HEAD:refs/heads/${BRANCH}"

log "building on nixhost: ${UNIT}"
# The journal is followed from before the start, so no line is missed; the
# unit may also be running already (the night's), in which case this joins it.
# shellcheck disable=SC2087 # expanded here on purpose: the unit name
ssh -o BatchMode=yes "$NIXHOST" bash -s <<EOF
set -euo pipefail
unit=${UNIT}
sudo journalctl -f -n 0 -o cat -u "\$unit" &
follow=\$!
trap 'kill "\$follow" 2>/dev/null || true' EXIT
sleep 1
sudo systemctl start --no-block "\$unit"
sleep 2
while [ -n "\$(systemctl list-jobs --no-legend "\$unit")" ] ||
      [ "\$(systemctl show -P ActiveState "\$unit")" = activating ]; do
  sleep 5
done
result=\$(systemctl show -P Result "\$unit")
echo "==> \$unit: \$result"
[ "\$result" = success ]
EOF

# The night's run, or another push, can publish in between. Only a result
# built on this push is this deploy's.
published_ref="refs/remotes/${REMOTE}/nightly/${MACHINE}"
git fetch -q "$REMOTE" "+refs/heads/nightly/${MACHINE}:${published_ref}"
if ! git merge-base --is-ancestor "$pushed" "$published_ref"; then
  echo "deploy.sh: nixhost's nightly/${MACHINE} is not built on ${pushed}; someone pushed or a night ran in between. Run it again." >&2
  exit 1
fi
log "published $(git rev-parse --short "$published_ref") (nightly/${MACHINE})"

if [ "$PUSH" -eq 0 ]; then
  log "--no-push: ${MACHINE} takes it at its next night"
  exit 0
fi

pointer="$(curl -fsS --max-time 20 "${CACHE_URL}/pointers/${MACHINE}")"
pointer="${pointer//[[:space:]]/}"
exec "$SHIP" "$MACHINE" --now --stage "$pointer"
