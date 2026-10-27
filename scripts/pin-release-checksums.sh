#!/usr/bin/env bash
# pin-release-checksums.sh — fill in the checksum of a first-party release asset
# Usage: ./scripts/pin-release-checksums.sh <package-dir>
#
# A package built from our own GitHub release (source=...github.com/bopp-os/<repo>/releases/download/<tag>/<file>)
# cannot carry its own hash upstream: the asset is built after the PKGBUILD is committed. GitHub records a sha256
# digest for every uploaded release asset, so this reads that digest and writes it into sha256sums.
#
# It touches nothing unless the PKGBUILD has exactly one source, that source is such an asset, and sha256sums is
# SKIP. The PKGBUILD is read as text and never sourced (it comes from another repo and this runs with a token).
#
# Exit: 0 pinned, or nothing to do   3 the asset is not published yet (try again later)   1 error
# GH overrides the gh command (used by the tests).
set -euo pipefail

dir=${1:?usage: $0 <package-dir>}
pkgbuild="$dir/PKGBUILD"
[[ -f "$pkgbuild" ]] || { echo "pin-release-checksums: no PKGBUILD in $dir" >&2; exit 1; }
gh_cmd=${GH:-gh}

pkgver=$(grep -m1 -E '^pkgver=' "$pkgbuild" | cut -d= -f2 | tr -d "\r\"' ")
pkgbase=$(grep -m1 -E '^pkgbase=' "$pkgbuild" | cut -d= -f2 | tr -d "\r\"' ")

source_line=$(grep -E '^source=\(' "$pkgbuild" || true)
[[ $(printf '%s\n' "$source_line" | grep -c .) -eq 1 ]] || exit 0                # none, or defined more than once
[[ "$source_line" =~ ^source=\([[:space:]]*[\"\']?([^\"\'[:space:]\)]+)[\"\']?[[:space:]]*\)[[:space:]]*$ ]] || exit 0
entry=${BASH_REMATCH[1]}                                                          # exactly one source, on one line
url=${entry#*::}
url=${url//\$\{pkgver\}/$pkgver}; url=${url//\$pkgver/$pkgver}
url=${url//\$\{pkgbase\}/$pkgbase}; url=${url//\$pkgbase/$pkgbase}

re='^https://github\.com/bopp-os/([A-Za-z0-9._-]+)/releases/download/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$'
[[ "$url" =~ $re ]] || exit 0                                                     # not a first-party release asset
repo=${BASH_REMATCH[1]} tag=${BASH_REMATCH[2]} file=${BASH_REMATCH[3]}

sums_re="^sha256sums=\\([[:space:]]*[\"']SKIP[\"'][[:space:]]*\\)[[:space:]]*\$"
grep -qE "$sums_re" "$pkgbuild" || exit 0                                         # already pinned (or another scheme)

digest=$("$gh_cmd" api "repos/bopp-os/$repo/releases/tags/$tag" \
  --jq ".assets[] | select(.name == \"$file\") | .digest" 2>/dev/null || true)
if [[ -z "$digest" || "$digest" == null ]]; then
  echo "pin-release-checksums: $repo $tag has no asset $file yet" >&2
  exit 3
fi
if [[ ! "$digest" =~ ^sha256:([0-9a-f]{64})$ ]]; then
  echo "pin-release-checksums: unexpected digest '$digest' for $file" >&2
  exit 1
fi
hash=${BASH_REMATCH[1]}

sed -E -i "s/$sums_re/sha256sums=('$hash')/" "$pkgbuild"
echo "pin-release-checksums: $file -> sha256:$hash"
