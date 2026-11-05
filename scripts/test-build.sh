#!/usr/bin/env bash
# test-build.sh — build one package locally the way CI does (the CachyOS x86-64-v3 container, scripts/build-in-container.sh), without
# signing or publishing anything. Needs podman (rootless is fine). The packages land in built-pkgs/test/<package>/.
# Usage: scripts/test-build.sh <package-dir>
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1/PKGBUILD" ]]; then
  echo "usage: $0 <package-dir>" >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
dir=$(cd "$1" && pwd)
pkg=$(basename "$dir")
out="$repo/built-pkgs/test/$pkg"
image="${BUILD_IMAGE:-docker.io/cachyos/cachyos-v3@sha256:a4f97f17f19e2ae5b3ecaa92bfad19995d5154776ef490e1e30dbd340a16a4df}"

mkdir -p "$out"
rm -f "$out"/*.pkg.tar.zst  # results of an earlier run would look like this run's output
# The same container and mounts as the build job: the build user (uid 1000) is mapped to you, so the results are yours.
# The package folder is copied first: the build writes src/ and pkg/ into it.
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/$pkg"
cp -r "$dir/." "$work/$pkg/"
podman run --rm --userns=keep-id:uid=1000,gid=1000 --user 0:0 \
  -v "$work/$pkg:/build/$pkg:z" -v "$repo/keys:/keys:ro,z" -v "$repo/scripts:/scripts:ro,z" -v "$out:/out:z" \
  "$image" bash /scripts/build-in-container.sh "/build/$pkg" /out
echo "built into $out:"
ls "$out"
