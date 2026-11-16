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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
queue="$work/queue"
seen="$work/seen"

# Seed: the store-path hashes named by the last N pointers of every machine.
for history in pointers/*.history; do
  tail -n "$KEEP" "$history" | sed 's|^/nix/store/||; s|-.*$||'
done | sort -u > "$queue"

if [ ! -s "$queue" ]; then
  echo "prune-cache: no pointer history; nothing to do"
  exit 0
fi

# One pass over every narinfo, then the walk and both sweeps in memory. The
# old line-by-line walk (`sed -i 1d` on the queue, `grep` on what was seen)
# was quadratic: 3.5 minutes on nixhost's ~4000 paths, inside every deploy.
#
# awk prints the reachable hashes to "$seen", then the narinfo files and the
# nar files that nothing kept refers to, each line tagged with what it is.
find . -maxdepth 1 -name '*.narinfo' -printf '%f\n' > "$work/narinfos"
find nar -type f 2>/dev/null > "$work/nars" || true
awk -v seen_out="$seen" -v queue_in="$queue" \
    -v narinfos_in="$work/narinfos" -v nars_in="$work/nars" '
  BEGIN {
    while ((getline f < narinfos_in) > 0) {
      hash = f; sub(/\.narinfo$/, "", hash)
      have[hash] = 1
      while ((getline line < f) > 0) {
        if (line ~ /^References: /) refs[hash] = substr(line, 13)
        else if (line ~ /^URL: /) url[hash] = substr(line, 6)
      }
      close(f)
    }
    n = 0
    while ((getline hash < queue_in) > 0) if (!(hash in seen)) { seen[hash] = 1; todo[n++] = hash }
    for (i = 0; i < n; i++) {
      if (!(todo[i] in have)) continue
      m = split(refs[todo[i]], r, " ")
      for (j = 1; j <= m; j++) {
        ref = r[j]; sub(/-.*$/, "", ref)
        if (ref != "" && !(ref in seen)) { seen[ref] = 1; todo[n++] = ref }
      }
    }
    for (hash in seen) print hash > seen_out
    for (hash in have) {
      if (hash in seen) kept[url[hash]] = 1
      else print "narinfo " hash ".narinfo"
    }
    while ((getline f < nars_in) > 0) if (!(f in kept)) print "nar " f
  }' > "$work/doomed"
removed=0
nars_removed=0
while read -r kind f; do
  rm -f -- "$f"
  if [ "$kind" = narinfo ]; then removed=$((removed + 1)); else nars_removed=$((nars_removed + 1)); fi
done < "$work/doomed"
# Keep the history files themselves from growing without bound.
for history in pointers/*.history; do
  tail -n $((KEEP * 4)) "$history" > "$history.tmp" && mv "$history.tmp" "$history"
done

echo "prune-cache: kept $(wc -l < "$seen") paths, removed ${removed} narinfo and ${nars_removed} nar files"
