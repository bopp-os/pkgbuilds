#!/usr/bin/env bash
# prune-old-pkgs.sh — Remove all but the newest versions of each package in a pacman repo directory
# Usage: ./scripts/prune-old-pkgs.sh <repo-dir> [<keep>]
#   e.g. on the runner host: ./scripts/prune-old-pkgs.sh /var/www/pacman-repo 5
#
# Does what `paccache -rk<keep> -c <repo-dir>` does, without needing pacman-contrib: packages are grouped by
# name and architecture, ordered with vercmp (from pacman), and every version past the <keep> newest is deleted
# together with its .sig file. The database is not touched; repo-add already points it at the newest version.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <repo-dir> [<keep>]" >&2
  exit 2
fi

repo_dir=$1
keep=${2:-5}
[[ $keep =~ ^[1-9][0-9]*$ ]] || { echo "keep must be a positive integer, got '$keep'" >&2; exit 2; }

# File names are <pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst; pkgname may itself contain dashes.
declare -A versions
shopt -s nullglob
for path in "$repo_dir"/*.pkg.tar.zst; do
  file=${path##*/}
  stem=${file%.pkg.tar.zst}
  arch=${stem##*-}; rest=${stem%-*}
  rel=${rest##*-}; rest=${rest%-*}
  ver=${rest##*-}; name=${rest%-*}
  [[ $name != "$rest" && -n $name ]] || { echo "skipping unrecognised file name: $file" >&2; continue; }
  versions["$name $arch"]+="$ver-$rel"$'\n'
done

removed=0
for key in "${!versions[@]}"; do
  name=${key% *}; arch=${key#* }
  mapfile -t vers < <(printf '%s' "${versions[$key]}")
  # Insertion sort, newest first; vercmp handles epochs and pkgrel the way pacman does.
  sorted=()
  for v in "${vers[@]}"; do
    i=${#sorted[@]}
    while (( i > 0 )) && (( $(vercmp "$v" "${sorted[i-1]}") > 0 )); do
      sorted[i]=${sorted[i-1]}; i=$((i - 1))
    done
    sorted[i]=$v
  done
  for v in "${sorted[@]:keep}"; do
    pkg="$repo_dir/$name-$v-$arch.pkg.tar.zst"
    echo "removing ${pkg##*/}"
    rm -f -- "$pkg" "$pkg.sig"
    removed=$((removed + 1))
  done
done

echo "removed $removed old package file(s), kept up to $keep version(s) of each package"
