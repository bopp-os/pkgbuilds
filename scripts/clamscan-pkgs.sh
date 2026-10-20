#!/bin/sh
# Scan built packages with ClamAV. Runs inside the clamav/clamav image (Alpine, no bash) from build-repo.yml.
#
# Usage: clamscan-pkgs.sh <dir>
#   <dir> holds one folder per artifact (pkg-<name>/), each with its .pkg.tar.zst files and their unpacked contents.
#
# Writes to $GITHUB_OUTPUT:
#   clean=<space-separated artifact folders with no findings>
#   flagged=<number of folders with findings or scan errors>
# Always exits 0 when it got as far as writing those outputs; the workflow decides what a finding means.

set -u

dir=${1:?usage: clamscan-pkgs.sh <dir>}
clean=""
flagged=0
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

clamscan --version
# shellcheck disable=SC2016 # the backticks are Markdown
printf '## ClamAV scan\n\n`%s`\n\n| Artifact | Result |\n|---|---|\n' "$(clamscan --version)" >> "$summary"

for pkgdir in "$dir"/pkg-*/; do
  [ -d "$pkgdir" ] || continue
  name=$(basename "$pkgdir")
  # Oversized files count as findings (--alert-exceeds-max), so nothing slips through unscanned.
  out=$(clamscan --no-summary --infected --recursive --scan-archive=yes \
    --max-filesize=2000M --max-scansize=4000M --alert-exceeds-max=yes "$pkgdir" 2>&1)
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
