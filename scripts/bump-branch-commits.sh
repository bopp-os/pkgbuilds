#!/usr/bin/env bash
# bump-branch-commits.sh — move one of our own packages to the newest commit of the branch it follows
# Usage: ./scripts/bump-branch-commits.sh <package-dir>
#
# For a first-party package built from pinned commits (not from the AUR, so the AUR check does not apply). Its
# <package-dir>/.upstream-branch says what to follow, one "key value" per line:
#   url https://github.com/bopp-os/bootc-installer      the repository
#   branch boppos                                      the branch whose head _commit should be
#   submodule _fishcommit fisherman                    a PKGBUILD variable pinning that submodule (any number)
# A submodule's commit is read from the branch head's gitlink, so the two pins always match.
# pkgver follows meson.build's project version at the new head (when there is one): a new version resets pkgrel to 1,
# otherwise pkgrel goes up by one. sha256sums are recomputed from the downloaded sources.
# The PKGBUILD is read as text and never sourced (this runs with a token).
#
# On a bump it writes <package-dir>/.bump-log (the new commits, for the PR body; not to be committed).
# Exit: 0 bumped   10 already at the branch head   1 error
# ARCHIVE_DIR (tests): take each source from this folder, by its file name, instead of downloading it.
set -euo pipefail

dir=${1:?usage: $0 <package-dir>}
pkgbuild="$dir/PKGBUILD"
conf="$dir/.upstream-branch"
[[ -f "$pkgbuild" && -f "$conf" ]] || { echo "bump-branch-commits: need PKGBUILD and .upstream-branch in $dir" >&2; exit 1; }

url="" branch="" subvars=() subpaths=()
while read -r key a b; do
  case "$key" in
    url) url=$a ;;
    branch) branch=$a ;;
    submodule) subvars+=("$a"); subpaths+=("$b") ;;
    ''|'#'*) ;;
    *) echo "bump-branch-commits: unknown key '$key' in $conf" >&2; exit 1 ;;
  esac
done < "$conf"
[[ "$url" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ || "$url" =~ ^file:// || -d "$url" ]] ||
  { echo "bump-branch-commits: unusable url '$url'" >&2; exit 1; }
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "bump-branch-commits: unusable branch '$branch'" >&2; exit 1; }
for v in "${subvars[@]}"; do [[ "$v" =~ ^_[A-Za-z0-9_]+$ ]] || { echo "bump-branch-commits: bad variable '$v'" >&2; exit 1; }; done

# || true: a missing line must not trip set -e/pipefail
var() { grep -m1 -E "^$1=" "$pkgbuild" | cut -d= -f2 | tr -d "\r\"' " || true; }
current=$(var _commit)
[[ "$current" =~ ^[0-9a-f]{40}$ ]] || { echo "bump-branch-commits: no pinned _commit in $pkgbuild" >&2; exit 1; }

head=$(git ls-remote "$url" "refs/heads/$branch" | cut -f1)
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "bump-branch-commits: branch $branch not found in $url" >&2; exit 1; }
if [[ "$head" == "$current" ]]; then
  echo "  ✓ at the head of $branch (${current:0:12})"
  exit 10
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git clone --quiet --filter=blob:none --no-checkout --branch "$branch" "$url" "$work/repo"

# Submodule pins at the new head
declare -A newval=([_commit]=$head)
for i in "${!subvars[@]}"; do
  entry=$(git -C "$work/repo" ls-tree "$head" -- "${subpaths[$i]}")
  [[ "$entry" =~ ^160000\ commit\ ([0-9a-f]{40}) ]] ||
    { echo "bump-branch-commits: ${subpaths[$i]} is not a submodule at $head" >&2; exit 1; }
  newval[${subvars[$i]}]=${BASH_REMATCH[1]}
done

# Version: meson's project version, else keep pkgver
pkgver=$(var pkgver) pkgrel=$(var pkgrel)
[[ "$pkgrel" =~ ^[0-9]+$ ]] || { echo "bump-branch-commits: unusable pkgrel '$pkgrel'" >&2; exit 1; }
newver=$(git -C "$work/repo" show "$head:meson.build" 2> /dev/null |
  sed -n -E "s/^[[:space:]]*version:[[:space:]]*'([^']+)'.*/\\1/p" | head -n1 || true)
if [[ -n "$newver" && "$newver" != "$pkgver" ]]; then
  [[ "$newver" =~ ^[A-Za-z0-9._+]+$ ]] || { echo "bump-branch-commits: unusable version '$newver'" >&2; exit 1; }
  newrel=1
else
  newver=$pkgver newrel=$((pkgrel + 1))
fi

# The new commits, for the PR body
{
  if git -C "$work/repo" merge-base --is-ancestor "$current" "$head" 2> /dev/null; then
    git -C "$work/repo" log --oneline --no-decorate "$current..$head"
  else
    echo "(${current:0:12} is not an ancestor of the new head: the branch was rewritten)"
  fi
} > "$dir/.bump-log"

# Rewrite the pins and the version
tmp_pkgbuild="$work/PKGBUILD"
cp "$pkgbuild" "$tmp_pkgbuild"
for v in "${!newval[@]}"; do
  grep -qE "^$v=" "$tmp_pkgbuild" || { echo "bump-branch-commits: $v is not set in $pkgbuild" >&2; exit 1; }
  sed -i -E "s/^$v=.*/$v=${newval[$v]}/" "$tmp_pkgbuild"
done
sed -i -E "s/^pkgver=.*/pkgver=$newver/; s/^pkgrel=.*/pkgrel=$newrel/" "$tmp_pkgbuild"

# Sources: the quoted entries of source=( ... ), with the pin and version variables filled in
mapfile -t entries < <(awk '/^source=\(/{f=1} f{print} f&&/\)/{exit}' "$tmp_pkgbuild" | grep -oE '"[^"]+"' | tr -d '"')
[[ ${#entries[@]} -gt 0 ]] || { echo "bump-branch-commits: no source=( ... ) entries" >&2; exit 1; }
sums=()
for e in "${entries[@]}"; do
  for v in "${!newval[@]}" pkgver; do
    val=${newval[$v]:-$newver}
    e=${e//\$\{$v\}/$val}; e=${e//\$$v/$val}
  done
  [[ "$e" != *'$'* ]] || { echo "bump-branch-commits: unresolved variable in source '$e'" >&2; exit 1; }
  name=${e%%::*} src=${e#*::}
  [[ "$e" == *::* ]] || name=$(basename "$src")
  if [[ -n "${ARCHIVE_DIR:-}" ]]; then
    cp "$ARCHIVE_DIR/$name" "$work/$name"
  else
    [[ "$src" =~ ^https:// ]] || { echo "bump-branch-commits: refusing non-https source '$src'" >&2; exit 1; }
    curl -fsSL --retry 3 -o "$work/$name" "$src"
  fi
  sums+=("$(sha256sum "$work/$name" | cut -d' ' -f1)")
done

# Replace sha256sums=( ... ), one entry per line, aligned like the existing file
{
  printf "sha256sums=('%s'" "${sums[0]}"
  for s in "${sums[@]:1}"; do printf "\n            '%s'" "$s"; done
  printf ')\n'
} > "$work/sums"
awk -v sums="$work/sums" '
  /^sha256sums=\(/ { while ((getline line < sums) > 0) print line; skip = !/\)/; next }
  skip { if (/\)/) skip = 0; next }
  { print }' "$tmp_pkgbuild" > "$work/PKGBUILD.new"
[[ $(grep -c '^sha256sums=(' "$work/PKGBUILD.new") -eq 1 ]] || { echo "bump-branch-commits: no sha256sums=( ... )" >&2; exit 1; }
cp "$work/PKGBUILD.new" "$pkgbuild"

echo "  ↑ ${current:0:12} -> ${head:0:12} ($pkgver-$pkgrel -> $newver-$newrel)"
exit 0
