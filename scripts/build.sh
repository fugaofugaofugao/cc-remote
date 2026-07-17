#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GOOS_VALUE="${GOOS:-$(go env GOOS)}"
GOARCH_VALUE="${GOARCH:-$(go env GOARCH)}"
OUT_DIR="$ROOT/dist"
OUT_NAME="cc-remote"
if [ "$GOOS_VALUE" = windows ]; then
  OUT_NAME="$OUT_NAME.exe"
fi

mkdir -p "$OUT_DIR"
GOOS="$GOOS_VALUE" GOARCH="$GOARCH_VALUE" go -C "$ROOT" build -trimpath -ldflags='-s -w' -o "$OUT_DIR/$OUT_NAME" ./cmd/cc-remote
printf 'Built %s/%s: %s\n' "$GOOS_VALUE" "$GOARCH_VALUE" "$OUT_DIR/$OUT_NAME"
