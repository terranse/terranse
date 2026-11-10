#!/usr/bin/env bash
# `just deploy-all`: ship Home Player to the TV and game-sync to the gaming VM in
# one go, without waiting for a full nightly bump.
#
#   deploy-all.sh [--full]
#
# 1. game-sync: when its version (pyproject.toml) is not the one vendored in
#    the gaming role, build the wheel, swap it into the role and commit that,
#    so the role and a later full run agree with what is installed. A changed
#    game-sync with an unchanged version is NOT shipped: pip would keep the old
#    code under the same version and look successful, so bump the version.
# 2. TV: `deploy.sh htpc --quick` (home-player bumped alone; --full for the
#    whole night's bump), in the background.
# 3. Meanwhile game-sync's own tasks of the gaming role (`--tags game-sync`),
#    when the gaming VM is up. It is not woken: that takes the GPU from the AI
#    VM, so it says so and leaves it to `gpu gaming`.
#
# Environment (optional): GAME_SYNC_REPO (default ~/Repos/game-sync-service),
# DEPLOY_ALL_GAMING_HOST (default gaming.edholm.cc), DEPLOY_ALL_GAMING_USER
# (default ubuntu).
set -euo pipefail

FULL=0
for arg in "$@"; do
  case "$arg" in
    --full) FULL=1 ;;
    *) echo "deploy-all.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
GAME_SYNC_REPO="${GAME_SYNC_REPO:-$HOME/Repos/game-sync-service}"
GAMING_HOST="${DEPLOY_ALL_GAMING_HOST:-gaming.edholm.cc}"
GAMING_USER="${DEPLOY_ALL_GAMING_USER:-ubuntu}"
ROLE="ansible/roles/gaming"
# The generated playbook and the vault file live only in the main checkout,
# not in worktrees; the roles come from this checkout.
MAIN_CHECKOUT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"

log() { printf '==> %s\n' "$*"; }

# ---- 1. vendor game-sync ---------------------------------------------------------
version="$(sed -n 's/^version = "\(.*\)"/\1/p' "${GAME_SYNC_REPO}/pyproject.toml" | head -1)"
[ -n "$version" ] || { echo "deploy-all.sh: no version in ${GAME_SYNC_REPO}/pyproject.toml" >&2; exit 1; }
wheel="game_sync_service-${version}-py3-none-any.whl"
vendored="$(sed -n 's/^game_sync_wheel: //p' "${ROLE}/defaults/main.yaml")"
if [ "$vendored" != "$wheel" ]; then
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "deploy-all.sh: uncommitted changes; commit them before vendoring game-sync ${version}" >&2
    exit 1
  fi
  log "vendoring game-sync ${version} (role had ${vendored})"
  build="$(mktemp -d)"
  trap 'rm -rf "$build"' EXIT
  (cd "$GAME_SYNC_REPO" && uv build --wheel -o "$build" >/dev/null)
  git rm -q "${ROLE}/files/${vendored}"
  cp "${build}/${wheel}" "${ROLE}/files/${wheel}"
  sed -i "s/^game_sync_wheel: .*/game_sync_wheel: ${wheel}/" "${ROLE}/defaults/main.yaml"
  git add "${ROLE}/files/${wheel}" "${ROLE}/defaults/main.yaml"
  git commit -q -m "chore(gaming): ship game-sync ${version}"
else
  log "game-sync ${version} is already vendored; bump its version to ship changes"
fi

# ---- 2. the TV, in the background ---------------------------------------------------
tv_log="$(mktemp)"
flags=(--quick)
[ "$FULL" = 0 ] || flags=()
log "deploying htpc ${flags[*]:-(full bump)}; its log: ${tv_log}"
"${REPO_ROOT}/scripts/deploy.sh" htpc "${flags[@]}" >"$tv_log" 2>&1 &
tv=$!

# ---- 3. game-sync on the gaming VM ---------------------------------------------------
gs=skipped
if ! getent hosts "$GAMING_HOST" >/dev/null; then
  log "${GAMING_HOST} is off; run \`gpu gaming\` and this again to install game-sync (\`gpu ai\` after)"
else
  for f in ansible/playbooks/edholm.yaml ansible/secrets.yaml; do
    [ -e "${MAIN_CHECKOUT}/${f}" ] || { echo "deploy-all.sh: ${MAIN_CHECKOUT}/${f} is missing" >&2; gs=failed; }
  done
  if [ "$gs" != failed ]; then
    log "installing game-sync on ${GAMING_HOST}"
    # A one-host inventory: the tofu-backed one is not needed for this.
    if (cd "${MAIN_CHECKOUT}/ansible" &&
        ANSIBLE_ROLES_PATH="${REPO_ROOT}/${ROLE%/gaming}" ansible-playbook \
          -i "${GAMING_HOST}," --limit "$GAMING_HOST" -u "$GAMING_USER" \
          --tags game-sync playbooks/edholm.yaml --extra-vars @./secrets.yaml); then
      # The role restarts game-sync only when the package changed in this run.
      ssh -o BatchMode=yes "${GAMING_USER}@${GAMING_HOST}" \
        'sudo -n systemctl restart game-sync && /opt/game-sync/bin/pip show game-sync-service | sed -n "s/^Version: //p"' |
        sed 's/^/==> game-sync now runs /'
      gs=ok
    else
      gs=failed
    fi
  fi
fi

tv_rc=0
wait "$tv" || tv_rc=$?
tail -n 15 "$tv_log"
log "htpc: $([ "$tv_rc" = 0 ] && echo ok || echo "FAILED (${tv_log})"); game-sync: ${gs}"
[ "$tv_rc" = 0 ] && [ "$gs" != failed ]
