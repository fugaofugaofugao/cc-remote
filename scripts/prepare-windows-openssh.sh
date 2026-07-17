#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-10.0.0.0p2-Preview}"
EXPECTED_SHA256="23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/payloads/windows/openssh-win64.zip"
TMP="$OUT.download"
URL="https://github.com/PowerShell/Win32-OpenSSH/releases/download/$VERSION/OpenSSH-Win64.zip"

mkdir -p "$(dirname "$OUT")"
rm -f "$TMP"
echo "Downloading $URL"
curl --connect-timeout 20 --retry 3 --retry-all-errors -fL "$URL" -o "$TMP"
ACTUAL_SHA256="$(shasum -a 256 "$TMP" | cut -d' ' -f1)"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  rm -f "$TMP"
  echo "SHA256 mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256" >&2
  exit 1
fi
mv "$TMP" "$OUT"
echo "$ACTUAL_SHA256  $OUT"
echo "Saved verified Win32-OpenSSH $VERSION payload to $OUT"
