#!/usr/bin/env bash
# Set the HTPC's two login passwords from 1Password. Usage: htpc-passwords.sh <ssh-target>
#
# Every password is read and hashed before the first byte goes to ssh, so a
# failure anywhere sends nothing. A password is only ever on a pipe or in a
# shell variable, never on a command line, and only its hash crosses ssh.
set -euo pipefail

target="${1:?usage: htpc-passwords.sh <ssh-target>}"

# mkpasswd is not on every machine; HTPC_MKPASSWD overrides this (tests do).
if [[ -n "${HTPC_MKPASSWD:-}" ]]; then
  hasher=("$HTPC_MKPASSWD" -s)
else
  hasher=(nix shell nixpkgs#mkpasswd -c mkpasswd -s)
fi

lines=""
for pair in "vuxna:HTPC Vuxna" "barn:HTPC Barn"; do
  user="${pair%%:*}"
  item="${pair#*:}"
  # Assignment, so a failing op aborts under set -e. $(...) only strips
  # newlines, so an empty secret is empty here.
  secret="$(op read "op://HomeNetwork/$item/password")"
  if [[ -z "$secret" ]]; then
    echo "htpc-passwords: the password in '$item' is empty; nothing was changed" >&2
    exit 1
  fi
  hash="$(printf '%s' "$secret" | "${hasher[@]}")"
  unset secret
  if [[ -z "$hash" ]]; then
    echo "htpc-passwords: hashing '$item' produced nothing; nothing was changed" >&2
    exit 1
  fi
  lines+="$user:$hash"$'\n'
done

printf '%s' "$lines" | ssh "$target" "sudo chpasswd -e"
echo "passwords set on $target"
