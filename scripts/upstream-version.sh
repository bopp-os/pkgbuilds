#!/usr/bin/env bash
# upstream-version.sh — helpers (sourced) for tracking the AUR version last synced into packages/<pkg>.
# packages/<pkg>/.upstream-version holds "[epoch:]pkgver-pkgrel" of the upstream PKGBUILD we last copied, so an
# upstream pkgrel-only bump is noticed even though our own pkgrel may differ (local rebuild bumps).

# pkgbuild_var <file> <name>: first top-level NAME= value, quotes stripped
pkgbuild_var() {
  grep -m1 "^$2=" "$1" | cut -d= -f2- | tr -d '\r"'\'' ' || true
}

# pkgbuild_full_version <file>: [epoch:]pkgver-pkgrel (pkgrel defaults to 1)
pkgbuild_full_version() {
  local e v r
  e=$(pkgbuild_var "$1" epoch)
  v=$(pkgbuild_var "$1" pkgver)
  r=$(pkgbuild_var "$1" pkgrel)
  echo "${e:+$e:}${v}-${r:-1}"
}

# pkgrel_max <a> <b>: the larger pkgrel, compared numerically per dot-separated field (1.1 > 1 > 0.9)
pkgrel_max() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) {
      p = (i <= na ? x[i] + 0 : 0); q = (i <= nb ? y[i] + 0 : 0)
      if (p > q) { print a; exit }
      if (q > p) { print b; exit }
    }
    print a
  }'
}

# pkgrel_next <r>: r with its last field incremented (8 -> 9, 1.1 -> 1.2)
pkgrel_next() {
  awk -v r="$1" 'BEGIN { n = split(r, f, "."); f[n] = f[n] + 1; s = f[1]; for (i = 2; i <= n; i++) s = s "." f[i]; print s }'
}

# upstream_changed <local-pkgbuild> <upstream-pkgbuild> <version-file>
# Exit 0 when a sync is needed. With a version file: upstream full version != recorded one.
# Without: falls back to comparing pkgver only.
upstream_changed() {
  local up
  if [[ -f "$3" ]]; then
    up=$(pkgbuild_full_version "$2")
    [[ "$up" != "$(tr -d '[:space:]' < "$3")" ]]
  else
    [[ "$(pkgbuild_var "$1" pkgver)" != "$(pkgbuild_var "$2" pkgver)" ]]
  fi
}

# bump_pkgrel_after_sync <old-local-pkgbuild> <new-pkgbuild>
# Call after the upstream PKGBUILD replaced ours (old copy saved by the caller). If epoch and pkgver are unchanged,
# set pkgrel to max(upstream pkgrel, old local pkgrel + 1) so pacman sees an upgrade. Prints the resulting pkgrel.
bump_pkgrel_after_sync() {
  local old="$1" new="$2" up_r old_r want
  up_r=$(pkgbuild_var "$new" pkgrel); up_r=${up_r:-1}
  if [[ "$(pkgbuild_var "$old" epoch)" == "$(pkgbuild_var "$new" epoch)" && "$(pkgbuild_var "$old" pkgver)" == "$(pkgbuild_var "$new" pkgver)" ]]; then
    old_r=$(pkgbuild_var "$old" pkgrel); old_r=${old_r:-1}
    want=$(pkgrel_max "$up_r" "$(pkgrel_next "$old_r")")
    if [[ "$want" != "$up_r" ]]; then
      sed -i "0,/^pkgrel=.*/s//pkgrel=$want/" "$new"
    fi
    echo "$want"
  else
    echo "$up_r"
  fi
}
