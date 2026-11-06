#!/usr/bin/env bash
# Offline tests for upstream-version.sh.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=upstream-version.sh
source "$here/upstream-version.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
mk() { printf 'pkgname=x\n%spkgver=%s\npkgrel=%s\n' "${4:+epoch=$4$'\n'}" "$2" "$3" > "$tmp/$1"; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fails=1; fi; }
changed() { upstream_changed "$@" && echo yes || echo no; }

# pkgver bump: sync, pkgrel taken from AUR
mk local 5.1.9 8; mk aur 5.2.0 1; echo 5.1.9-7 > "$tmp/v"
check "pkgver bump triggers" "$(changed "$tmp/local" "$tmp/aur" "$tmp/v")" yes
check "pkgver bump keeps AUR pkgrel" "$(bump_pkgrel_after_sync "$tmp/local" "$tmp/aur")" 1

# autofs: local -8, recorded -7, AUR goes -8 -> sync, result -9
mk local 5.1.9 8; mk aur 5.1.9 8; echo 5.1.9-7 > "$tmp/v"
check "autofs pkgrel-only triggers" "$(changed "$tmp/local" "$tmp/aur" "$tmp/v")" yes
check "autofs result is -9" "$(bump_pkgrel_after_sync "$tmp/local" "$tmp/aur")" 9
check "autofs file rewritten" "$(pkgbuild_var "$tmp/aur" pkgrel)" 9

# AUR jumps well past ours: take AUR's
mk local 1.0 2; mk aur 1.0 5; check "AUR ahead wins" "$(bump_pkgrel_after_sync "$tmp/local" "$tmp/aur")" 5

# no change
mk aur 5.1.9 7; check "no change" "$(changed "$tmp/local" "$tmp/aur" "$tmp/v")" no

# missing version file: pkgver compare only
rm "$tmp/v"; mk local 5.1.9 8; mk aur 5.1.9 9
check "missing file, same pkgver" "$(changed "$tmp/local" "$tmp/aur" "$tmp/v")" no
mk aur 5.2.0 1
check "missing file, new pkgver" "$(changed "$tmp/local" "$tmp/aur" "$tmp/v")" yes

# epoch change counts as a version change; epoch in full version
mk local 1.0 3; mk aur 1.0 1 1; echo 1.0-1 > "$tmp/v"
check "epoch triggers" "$(changed "$tmp/local" "$tmp/aur" "$tmp/v")" yes
check "epoch change keeps AUR pkgrel" "$(bump_pkgrel_after_sync "$tmp/local" "$tmp/aur")" 1
check "full version with epoch" "$(pkgbuild_full_version "$tmp/aur")" 1:1.0-1

# fractional pkgrel
check "max 1.1 vs 1" "$(pkgrel_max 1 1.1)" 1.1
check "max 10 vs 9" "$(pkgrel_max 10 9)" 10
check "next 1.1" "$(pkgrel_next 1.1)" 1.2
mk local 2.0 1.1; mk aur 2.0 1.1; check "fractional bump" "$(bump_pkgrel_after_sync "$tmp/local" "$tmp/aur")" 1.2
exit $fails
