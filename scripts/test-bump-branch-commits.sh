#!/usr/bin/env bash
# Offline tests for bump-branch-commits.sh, with a local git repository and local source archives.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null
fails=0
FISH1=$(printf '1%.0s' {1..40}) FISH2=$(printf '2%.0s' {1..40})

# Upstream: branch "boppos" with meson.build and a gitlink "fisherman"
up="$tmp/upstream"
git init -q -b boppos "$up"
commit() { # commit <meson-version> <fisherman-sha> <message>
  printf "project('x',\n          version: '%s',\n)\n" "$1" > "$up/meson.build"
  git -C "$up" add meson.build
  git -C "$up" update-index --add --cacheinfo "160000,$2,fisherman"
  git -C "$up" commit -q -m "$3"
  git -C "$up" rev-parse HEAD
}
C1=$(commit 3.0.0 "$FISH1" "first")

mkdir -p "$tmp/archives"
archive() { echo "$1" > "$tmp/archives/$2"; }

pkg() { # pkg <name> <commit> <fishcommit> <pkgver> <pkgrel>
  mkdir -p "$tmp/$1"
  printf 'url %s\nbranch boppos\nsubmodule _fishcommit fisherman\n' "$up" > "$tmp/$1/.upstream-branch"
  cat > "$tmp/$1/PKGBUILD" <<EOF
pkgbase=demo
pkgver=$4
pkgrel=$5
_commit=$2
_fishcommit=$3
source=("bootc-installer-\${_commit}.tar.gz::https://github.com/bopp-os/bootc-installer/archive/\${_commit}.tar.gz"
        "fisherman-\${_fishcommit}.tar.gz::https://github.com/bopp-os/fisherman/archive/\${_fishcommit}.tar.gz")
sha256sums=('old1'
            'old2')

build() { :; }
EOF
}
run() { ARCHIVE_DIR="$tmp/archives" bash "$here/bump-branch-commits.sh" "$tmp/$1" > /dev/null 2>&1; }
check() { # check <label> <got-rc> <want-rc> <name> [grep -F patterns...]
  local label=$1 got=$2 want=$3 name=$4 ok=1 p; shift 4
  [[ "$got" == "$want" ]] || ok=0
  for p in "$@"; do grep -qF -- "$p" "$tmp/$name/PKGBUILD" || ok=0; done
  if [[ $ok == 1 ]]; then echo "ok   $label"; else echo "FAIL $label (rc $got, want $want)"; fails=1; fi
}
sha() { sha256sum "$tmp/archives/$1" | cut -d' ' -f1; }

# 1. Already at the head: nothing changes
pkg same "$C1" "$FISH1" 3.0.0 3
cp "$tmp/same/PKGBUILD" "$tmp/same.before"
run same; rc=$?
check "at the head: exit 10" "$rc" 10 same "pkgrel=3"
cmp -s "$tmp/same/PKGBUILD" "$tmp/same.before" || { echo "FAIL at the head: PKGBUILD changed"; fails=1; }

# 2. A new commit, same version: commits from the head and its gitlink, pkgrel + 1, checksums recomputed
C2=$(commit 3.0.0 "$FISH2" "second")
archive a "bootc-installer-$C2.tar.gz"; archive b "fisherman-$FISH2.tar.gz"
pkg rel "$C1" "$FISH1" 3.0.0 3
run rel; rc=$?
check "new commit: repinned, pkgrel+1, sums" "$rc" 0 rel "_commit=$C2" "_fishcommit=$FISH2" "pkgver=3.0.0" "pkgrel=4" \
  "sha256sums=('$(sha "bootc-installer-$C2.tar.gz")'" "            '$(sha "fisherman-$FISH2.tar.gz")')" "build() { :; }"
if grep -q "second" "$tmp/rel/.bump-log" && ! grep -q "first" "$tmp/rel/.bump-log"; then
  echo "ok   new commit: bump log lists only the new commit"
else
  echo "FAIL new commit: bump log"; fails=1
fi
[[ $(grep -c "old" "$tmp/rel/PKGBUILD") -eq 0 ]] || { echo "FAIL new commit: old checksums left"; fails=1; }

# 3. A new meson version: pkgver follows, pkgrel back to 1
C3=$(commit 3.1.0 "$FISH2" "third")
archive c "bootc-installer-$C3.tar.gz"
pkg ver "$C2" "$FISH2" 3.0.0 4
run ver; rc=$?
check "new version: pkgver follows, pkgrel=1" "$rc" 0 ver "_commit=$C3" "pkgver=3.1.0" "pkgrel=1"

# 4. The submodule is gone at the head: error, PKGBUILD untouched
git -C "$up" rm -q --cached fisherman
git -C "$up" commit -q -m "no submodule"
pkg nosub "$C3" "$FISH2" 3.1.0 1
cp "$tmp/nosub/PKGBUILD" "$tmp/nosub.before"
run nosub; rc=$?
check "missing submodule: exit 1" "$rc" 1 nosub
cmp -s "$tmp/nosub/PKGBUILD" "$tmp/nosub.before" || { echo "FAIL missing submodule: PKGBUILD changed"; fails=1; }

exit $fails
