#!/bin/sh
# Scan built packages with ClamAV. Runs inside the clamav/clamav image (Alpine, no bash) from build-repo.yml.
#
# Usage: clamscan-pkgs.sh <dir>
#   <dir> holds the downloaded .pkg.tar.zst files, each next to a <name>.unpacked/ folder with its contents.
#
# Writes to $GITHUB_OUTPUT:
#   clean=<space-separated package file names with no findings>
#   flagged=<number of packages with findings or scan errors>
# Exits 0 once it got as far as writing those outputs; the workflow decides what a finding means.

set -u

dir=${1:?usage: clamscan-pkgs.sh <dir>}
clean=""
flagged=0
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

clamscan --version
# shellcheck disable=SC2016 # the backticks are Markdown
printf '## ClamAV scan\n\n`%s`\n\n| Package | Result |\n|---|---|\n' "$(clamscan --version)" >> "$summary"

for pkg in "$dir"/*.pkg.tar.zst; do
  [ -f "$pkg" ] || continue
  name=$(basename "$pkg")
  # Oversized files count as findings (--alert-exceeds-max), so nothing slips through unscanned.
  out=$(clamscan --no-summary --infected --recursive --scan-archive=yes \
    --max-filesize=2000M --max-scansize=4000M --alert-exceeds-max=yes \
    "$pkg" "${pkg%.pkg.tar.zst}.unpacked" 2>&1)
  rc=$?
  case $rc in
    0)
      echo "$name: clean"
      clean="$clean $name"
      printf '| %s | clean |\n' "$name" >> "$summary"
      ;;
    1)
      flagged=$((flagged + 1))
      echo "::error::$name: ClamAV found malware; this package will not be published"
      echo "$out"
      printf '| %s | **FOUND**: %s |\n' "$name" "$(echo "$out" | grep 'FOUND$' | sed "s|^$dir/||" | tr '\n' ' ')" >> "$summary"
      ;;
    *)
      flagged=$((flagged + 1))
      echo "::error::$name: ClamAV scan failed (exit $rc); this package will not be published"
      echo "$out"
      printf '| %s | **scan error** (exit %s) |\n' "$name" "$rc" >> "$summary"
      ;;
  esac
done

echo "clean=${clean# }" >> "$GITHUB_OUTPUT"
echo "flagged=$flagged" >> "$GITHUB_OUTPUT"
