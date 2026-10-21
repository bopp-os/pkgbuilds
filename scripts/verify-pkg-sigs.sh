#!/usr/bin/env bash
# verify-pkg-sigs.sh — Verify the detached signatures of packages and repo databases
# Usage: ./scripts/verify-pkg-sigs.sh <public-keyring> <file> [<file> ...]
#   e.g. on the runner host, to find unsigned or badly signed packages in the live repo:
#   ./scripts/verify-pkg-sigs.sh keys/boppos.gpg /var/www/pacman-repo/*.pkg.tar.zst /var/www/pacman-repo/bopp-os.{db,files}.tar.gz
#
# Each <file> needs <file>.sig made by the BoppOS repository key. Prints OK, MISSING or BAD per file and exits 1
# if any file is not OK. Uses a temporary GNUPGHOME; the caller's keyring is not touched.

set -euo pipefail

WANT=3806768589376830FEA123D6CF30985CE903D47C

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <public-keyring> <file> [...]" >&2
  exit 2
fi

keyring=$1
shift

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf "$GNUPGHOME"' EXIT

gpg --batch --quiet --import "$keyring" 2>/dev/null
have=$(gpg --with-colons --list-keys | awk -F: '/^fpr/ {print $10; exit}')
if [[ "$have" != "$WANT" ]]; then
  echo "::error::$keyring holds key $have, expected $WANT" >&2
  exit 1
fi

bad=0
for f in "$@"; do
  if [[ ! -f "$f.sig" ]]; then
    echo "MISSING  $f"
    bad=$((bad + 1))
    continue
  fi
  status=$(gpg --batch --status-fd 1 --verify "$f.sig" "$f" 2>/dev/null || true)
  # VALIDSIG's last field is the fingerprint of the primary key
  primary=$(awk '$2 == "VALIDSIG" {print $NF}' <<< "$status")
  if grep -q '^\[GNUPG:\] GOODSIG ' <<< "$status" && [[ "$primary" == "$WANT" ]]; then
    echo "OK       $f"
  else
    echo "BAD      $f"
    bad=$((bad + 1))
  fi
done

if [[ $bad -gt 0 ]]; then
  echo "$bad file(s) missing or with a bad signature" >&2
  exit 1
fi
