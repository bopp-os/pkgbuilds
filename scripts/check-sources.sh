#!/usr/bin/env bash
# check-sources.sh — Lint the sources of PKGBUILDs for supply-chain problems
# Usage: ./scripts/check-sources.sh <package-dir> [<package-dir> ...]
#
# Errors (exit 1):
#   - a remote (non-VCS) source with a SKIP checksum, unless it is a signature file
#   - a source array with no checksum array, or only md5/sha1/cksum ones
#   - a VCS source (git+...) not pinned with #tag= or #commit=
#   - a signature file in source while validpgpkeys is empty, or a validpgpkeys entry that is not a full fingerprint
# Warnings: a download over http:// or ftp:// that is protected by a real checksum.

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <package-dir> [...]" >&2
  exit 2
fi

check_one() (
  # Runs in a subshell: sourcing the PKGBUILD must not leak variables between packages.
  local dir=$1 pkg errors=0
  pkg=$(basename "$dir")
  err() { echo "::error::$pkg: $*"; errors=$((errors + 1)); }
  warn() { echo "::warning::$pkg: $*"; }

  if [[ ! -f "$dir/PKGBUILD" ]]; then
    err "no PKGBUILD in $dir"
    return 1
  fi
  cd "$dir"
  validpgpkeys=()
  # shellcheck disable=SC1091
  source ./PKGBUILD

  local has_sig=0 name suffix algo strong_name weak
  while IFS= read -r name; do
    suffix=${name#source}
    local -n srcs=$name
    strong_name=""
    for algo in b2 sha512 sha384 sha256 sha224; do
      if declare -p "${algo}sums$suffix" &>/dev/null; then strong_name="${algo}sums$suffix"; break; fi
    done
    if [[ -z "$strong_name" ]]; then
      weak=""
      for algo in md5 sha1 ck; do
        if declare -p "${algo}sums$suffix" &>/dev/null; then weak="${algo}sums$suffix"; fi
      done
      if [[ -n "$weak" ]]; then err "$name is only protected by weak checksums ($weak)"; else err "$name has no checksum array"; fi
      continue
    fi
    local -n sums=$strong_name
    local i entry url hash
    for i in "${!srcs[@]}"; do
      entry=${srcs[$i]}
      url=${entry#*::}
      hash=${sums[$i]:-}
      if [[ -z "$hash" ]]; then err "${name}[$i] ($entry) has no entry in $strong_name"; continue; fi
      if [[ "$url" =~ ^(git|svn|hg|bzr|fossil)(\+|://) ]]; then
        if [[ ! "$url" =~ \#(tag|commit)= ]]; then err "VCS source $entry is not pinned with #tag= or #commit="; fi
        continue
      fi
      if [[ "$url" != *://* ]]; then continue; fi  # a file shipped in this repo
      if [[ "${url%%[?#]*}" =~ \.(sig|asc|sign)$ ]]; then has_sig=1; continue; fi
      if [[ "$hash" == SKIP ]]; then err "$entry has a SKIP checksum"; fi
      if [[ "$url" =~ ^(http|ftp):// ]]; then
        if [[ "$hash" == SKIP ]]; then err "$entry is downloaded without TLS and without a checksum"; else warn "$entry is downloaded over ${url%%:*}:// (protected only by $strong_name)"; fi
      fi
    done
    unset -n srcs sums
  done < <(compgen -A variable | grep -E '^source(_[a-z0-9_]+)?$' || true)

  local key
  if [[ "$has_sig" == 1 && ${#validpgpkeys[@]} -eq 0 ]]; then err "a signature file is in source but validpgpkeys is empty"; fi
  for key in "${validpgpkeys[@]}"; do
    if [[ ! "$key" =~ ^[0-9A-F]{40}$ ]]; then err "validpgpkeys entry '$key' is not a full 40-digit uppercase fingerprint"; fi
  done

  if [[ $errors -eq 0 ]]; then echo "$pkg: sources OK"; fi
  [[ $errors -eq 0 ]]
)

rc=0
for d in "$@"; do
  check_one "$d" || rc=1
done
exit $rc
