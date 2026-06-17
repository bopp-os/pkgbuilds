#!/usr/bin/env bash
# check-updates.sh — Compare local PKGBUILDs against upstream AUR
# Usage: ./scripts/check-updates.sh [package-name ...]
#   No args = check all packages

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="$SCRIPT_DIR/../packages"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Filter to specific packages if args given
if [[ $# -gt 0 ]]; then
  targets=("$@")
else
  targets=()
  for d in "$PACKAGES_DIR"/*/; do
    targets+=("$(basename "$d")")
  done
fi

any_diff=0

for pkg_name in "${targets[@]}"; do
  pkg_dir="$PACKAGES_DIR/$pkg_name"

  if [[ ! -d "$pkg_dir" ]]; then
    echo -e "${RED}✗ Package directory not found: $pkg_dir${RESET}"
    continue
  fi

  upstream_name="$pkg_name"
  if [[ -f "$pkg_dir/.upstream-name" ]]; then
    upstream_name=$(cat "$pkg_dir/.upstream-name" | tr -d '[:space:]')
  fi

  local_pkgbuild="$pkg_dir/PKGBUILD"
  if [[ ! -f "$local_pkgbuild" ]]; then
    echo -e "${YELLOW}⚠ No PKGBUILD for $pkg_name${RESET}"
    continue
  fi

  upstream_url="https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=${upstream_name}"
  source_type="AUR"
  if [[ -f "$pkg_dir/.upstream-url" ]]; then
    upstream_url=$(cat "$pkg_dir/.upstream-url" | tr -d '[:space:]')
    source_type="Custom URL"
  fi

  echo -ne "${CYAN}Checking $pkg_name ($source_type: $upstream_name)...${RESET} "

  upstream_pkgbuild=$(curl -fsSL "$upstream_url" 2>/dev/null || true)

  if [[ -z "$upstream_pkgbuild" ]]; then
    echo -e "${YELLOW}⚠ Could not fetch (package gone from upstream?)${RESET}"
    continue
  fi

  if ! echo "$upstream_pkgbuild" | grep -q 'pkgver='; then
    echo -e "${YELLOW}⚠ Fetched content does not look like a valid PKGBUILD (missing pkgver=). Check .upstream-url.${RESET}"
    continue
  fi

  if diff <(echo "$upstream_pkgbuild") "$local_pkgbuild" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ up to date${RESET}"
  else
    echo -e "${RED}↑ DIFFERS from upstream${RESET}"
    any_diff=1
    echo ""
    echo -e "${YELLOW}--- upstream ($source_type)  /  +++ local $pkg_name${RESET}"
    diff --color=always \
      <(echo "$upstream_pkgbuild") \
      "$local_pkgbuild" || true
    echo ""
  fi
done

if [[ $any_diff -eq 1 ]]; then
  echo -e "${YELLOW}Review diffs above. To accept an upstream update:${RESET}"
  echo "  # For AUR packages:"
  echo "  curl -fsSL 'https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=<pkg>' > packages/<pkg>/PKGBUILD"
  echo "  # For custom URLs, use your configured .upstream-url"
  echo "  git diff packages/<pkg>/PKGBUILD   # final review"
  echo "  git commit -m 'upstream(<pkg>): update to <ver>'"
fi