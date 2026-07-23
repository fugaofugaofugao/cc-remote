#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GOOS_VALUE="${GOOS:-$(go env GOOS)}"
GOARCH_VALUE="${GOARCH:-$(go env GOARCH)}"
VERSION_VALUE="${VERSION:-dev}"
COMMIT_VALUE="${COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf unknown)}"
DATE_VALUE="${DATE:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
OUT_DIR="$ROOT/dist"
OUT_NAME="cc-remote"
if [ "$GOOS_VALUE" = windows ]; then
  OUT_NAME="$OUT_NAME.exe"
fi

mkdir -p "$OUT_DIR"
ldflags="-s -w -X main.version=$VERSION_VALUE -X main.commit=$COMMIT_VALUE -X main.date=$DATE_VALUE"
GOOS="$GOOS_VALUE" GOARCH="$GOARCH_VALUE" go -C "$ROOT" build -trimpath -ldflags="$ldflags" -o "$OUT_DIR/$OUT_NAME" ./cmd/cc-remote
printf 'Built %s/%s: %s\n' "$GOOS_VALUE" "$GOARCH_VALUE" "$OUT_DIR/$OUT_NAME"
