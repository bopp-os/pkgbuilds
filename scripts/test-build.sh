#!/usr/bin/env bash
# test-build.sh — build one package locally the way CI does (makepkg -s in the CachyOS x86-64-v3 container), without
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
image="${BUILD_IMAGE:-docker.io/cachyos/cachyos-v3:latest}"

bash "$repo/scripts/check-sources.sh" "$dir"
mkdir -p "$out"
podman run --rm -v "$dir:/src:ro" -v "$out:/out" "$image" bash -euo pipefail -c '
  pacman -Syu --noconfirm --needed base-devel git >/dev/null
  useradd -m builder
  echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
  cp -r /src /home/builder/pkg
  chown -R builder:builder /home/builder/pkg
  cd /home/builder/pkg
  sudo -u builder makepkg -s --noconfirm
  cp ./*.pkg.tar.zst /out/'
echo "built into $out:"
ls "$out"
