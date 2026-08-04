#!/usr/bin/env bash
# export-gpg-key.sh — Export BoppOS repository public GPG key
# Usage: ./scripts/export-gpg-key.sh [KEY_ID_OR_EMAIL] [OUTPUT_DIR]

set -euo pipefail

KEY_ID="${1:-repo@ripps.me}"
OUTPUT_DIR="${2:-keys}"

mkdir -p "$OUTPUT_DIR"

echo "Exporting public GPG key for: $KEY_ID"

# Export ASCII armored public key (.asc)
gpg --armor --export "$KEY_ID" > "$OUTPUT_DIR/boppos.asc"
echo "  ✓ Exported $OUTPUT_DIR/boppos.asc"

# Export binary GPG keyring (.gpg)
gpg --export "$KEY_ID" > "$OUTPUT_DIR/boppos.gpg"
echo "  ✓ Exported $OUTPUT_DIR/boppos.gpg"

echo ""
echo "Downstream pacman integration usage:"
echo "  # Add public key to pacman keyring:"
echo "  curl -fsSL https://repo.ripps.me/boppos.gpg -o /tmp/boppos.gpg"
echo "  pacman-key --add /tmp/boppos.gpg"
echo "  pacman-key --lsign-key \$(gpg --with-colons --show-keys /tmp/boppos.gpg | grep '^pub' | cut -d: -f5)"
