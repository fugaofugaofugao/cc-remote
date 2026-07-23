#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_OPENSSH_SHA256="23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5"
OUTPUT=""
VERSION_VALUE="${VERSION:-dev}"
GOOS_VALUE=""
GOARCH_VALUE=""
PAYLOAD_MODE="full"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    --version) VERSION_VALUE="$2"; shift 2 ;;
    --goos) GOOS_VALUE="$2"; shift 2 ;;
    --goarch) GOARCH_VALUE="$2"; shift 2 ;;
    --payload-mode) PAYLOAD_MODE="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 --output DIR --version VERSION --goos OS --goarch ARCH [--payload-mode full]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$OUTPUT" ] || { echo '--output is required' >&2; exit 2; }
[ -n "$GOOS_VALUE" ] || { echo '--goos is required' >&2; exit 2; }
[ -n "$GOARCH_VALUE" ] || { echo '--goarch is required' >&2; exit 2; }
[ "$PAYLOAD_MODE" = full ] || { echo 'Only --payload-mode full is supported for install-and-use runtime archives.' >&2; exit 2; }
OUTPUT="$(mkdir -p "$OUTPUT" && cd "$OUTPUT" && pwd)"
case "$OUTPUT/" in "$ROOT"/*) echo 'Output directory must be outside the source tree.' >&2; exit 2 ;; esac

payload="$ROOT/payloads/windows/openssh-win64.zip"
[ -f "$payload" ] || { echo "Missing full runtime payload: $payload" >&2; exit 1; }
payload_sha="$(shasum -a 256 "$payload" | cut -d' ' -f1)"
[ "$payload_sha" = "$EXPECTED_OPENSSH_SHA256" ] || { echo "Pinned payload mismatch: $payload_sha" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-remote-runtime.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
name="cc-remote_${VERSION_VALUE}_${GOOS_VALUE}_${GOARCH_VALUE}_${PAYLOAD_MODE}"
stage="$WORK/$name"
mkdir -p "$stage"

COMMIT_VALUE="${COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf unknown)}"
DATE_VALUE="${DATE:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
GOOS="$GOOS_VALUE" GOARCH="$GOARCH_VALUE" VERSION="$VERSION_VALUE" COMMIT="$COMMIT_VALUE" DATE="$DATE_VALUE" "$ROOT/scripts/build.sh"
exe="cc-remote"
[ "$GOOS_VALUE" = windows ] && exe="cc-remote.exe"
cp -p "$ROOT/dist/$exe" "$stage/$exe"

for rel in README.md SECURITY.md LICENSE NOTICE THIRD_PARTY_NOTICES.md; do cp -p "$ROOT/$rel" "$stage/$rel"; done
mkdir -p "$stage/bootstrap" "$stage/payloads" "$stage/docs"
cp -p "$ROOT/bootstrap/"* "$stage/bootstrap/"
cp -pR "$ROOT/payloads/"* "$stage/payloads/"
for rel in docs/relay.md docs/usage.md docs/payloads.md docs/distribution-privacy.md; do mkdir -p "$stage/$(dirname "$rel")"; cp -p "$ROOT/$rel" "$stage/$rel"; done
case "$GOOS_VALUE" in
  windows) cp -p "$ROOT/scripts/install.ps1" "$ROOT/scripts/install.cmd" "$stage/" ;;
  darwin) cp -p "$ROOT/scripts/install.sh" "$ROOT/scripts/install.command" "$stage/"; chmod 755 "$stage/install.sh" "$stage/install.command" ;;
  linux) cp -p "$ROOT/scripts/install.sh" "$stage/"; chmod 755 "$stage/install.sh" ;;
  *) echo "Unsupported GOOS: $GOOS_VALUE" >&2; exit 2 ;;
esac

"$ROOT/scripts/privacy-scan.sh" "$stage"
find "$stage" -exec touch -t 202601010000 {} +
if [ "$GOOS_VALUE" = linux ]; then
  archive="$OUTPUT/$name.tar.gz"
  rm -f "$archive" "$archive.sha256"
  (cd "$WORK" && find "$name" -type f -print | LC_ALL=C sort | tar -czf "$archive" -T -)
else
  archive="$OUTPUT/$name.zip"
  rm -f "$archive" "$archive.sha256"
  (cd "$WORK" && find "$name" -type f -print | LC_ALL=C sort | zip -X -q "$archive" -@)
fi
"$ROOT/scripts/privacy-scan.sh" "$archive"

verify="$WORK/verify"
mkdir -p "$verify"
case "$archive" in
  *.zip) unzip -q "$archive" -d "$verify" ;;
  *.tar.gz) tar -xzf "$archive" -C "$verify" ;;
esac
extracted="$verify/$name"
[ -f "$extracted/$exe" ] || { echo 'Extracted runtime executable missing.' >&2; exit 1; }
[ -f "$extracted/bootstrap/bootstrap.sh" ] || { echo 'Extracted bootstrap asset missing.' >&2; exit 1; }
[ -f "$extracted/payloads/windows/openssh-win64.zip" ] || { echo 'Extracted Windows payload missing.' >&2; exit 1; }
if [ "$GOOS_VALUE" = "$(go env GOOS)" ] && [ "$GOARCH_VALUE" = "$(go env GOARCH)" ]; then
  "$extracted/$exe" version >/dev/null
fi
sha="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
printf '%s  %s\n' "$sha" "$(basename "$archive")" > "$archive.sha256"
printf '%s\n%s\n' "$archive" "$archive.sha256"
