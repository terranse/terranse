#!/usr/bin/env bash
# Prune the file:// binary cache. `nix store gc` does not apply to it, so
# without this it grows by a full system closure on every deploy.
#
# Reachability is computed from the cache's own narinfo files rather than from
# the local Nix store: an older pointer's closure may well have been collected
# locally, and it must still survive here as long as it is one of the last N.
set -euo pipefail

CACHE_DIR="${NIX_CACHE_DIR:-/srv/nix-cache}"
KEEP="${CACHE_KEEP:-5}"

cd "$CACHE_DIR"
shopt -s nullglob

queue=$(mktemp)
seen=$(mktemp)
kept_nars=$(mktemp)
trap 'rm -f "$queue" "$seen" "$kept_nars"' EXIT

# Seed: the store-path hashes named by the last N pointers of every machine.
for history in pointers/*.history; do
  tail -n "$KEEP" "$history" | sed 's|^/nix/store/||; s|-.*$||'
done | sort -u > "$queue"

if [ ! -s "$queue" ]; then
  echo "prune-cache: no pointer history; nothing to do"
  exit 0
fi

# Breadth-first over References:, straight out of the narinfos.
while [ -s "$queue" ]; do
  h=$(head -n1 "$queue")
  sed -i 1d "$queue"
  # An `if`, not `grep ... && continue`: under `set -e` a failing grep at the
  # head of an && chain takes the whole script down.
  if grep -qxF "$h" "$seen" 2>/dev/null; then
    continue
  fi
  printf '%s\n' "$h" >> "$seen"
  [ -f "$h.narinfo" ] || continue
  awk '/^References: /{ for (i = 2; i <= NF; i++) print $i }' "$h.narinfo" \
    | sed 's|-.*$||' >> "$queue"
done
sort -u "$seen" -o "$seen"

removed=0
for f in *.narinfo; do
  h="${f%.narinfo}"
  if grep -qxF "$h" "$seen"; then
    awk '/^URL: /{ print $2 }' "$f" >> "$kept_nars"
  else
    rm -f "$f"
    removed=$((removed + 1))
  fi
done
sort -u "$kept_nars" -o "$kept_nars"

nars_removed=0
while IFS= read -r n; do
  grep -qxF "$n" "$kept_nars" || { rm -f "$n"; nars_removed=$((nars_removed + 1)); }
done < <(find nar -type f 2>/dev/null)

# Keep the history files themselves from growing without bound.
for history in pointers/*.history; do
  tail -n $((KEEP * 4)) "$history" > "$history.tmp" && mv "$history.tmp" "$history"
done

echo "prune-cache: kept $(wc -l < "$seen") paths, removed ${removed} narinfo and ${nars_removed} nar files"
