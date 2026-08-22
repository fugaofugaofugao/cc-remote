#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# --- bundled self-contained OpenSSH payload per target platform ---------------------------------
# Pinned (compile-once, verified) digests:
#   Win32-OpenSSH: crafted by prepare-windows-openssh.sh
#   unix (darwin/linux): crafted by prepare-unix-openssh.sh on native/CI runners
# amd64 unix payloads are built on native x86_64 runners/CI; their digests are pinned
# here once built. If a target's digest is not yet pinned we still require the payload
# to exist so install-and-use does not silently ship without it.
payload_win="payloads/windows/openssh-win64.zip"
payload_win_sha="23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5"
payload_macos_arm64="payloads/macos/openssh-darwin-arm64-9.8p1.tar.gz"
payload_macos_arm64_sha="63226db97f12d36fc720b9e5e7304a509907df5ff08b7aa3917c2f96fe7db249"
payload_macos_x86_64="payloads/macos/openssh-darwin-x86_64-9.8p1.tar.gz"
payload_macos_x86_64_sha="509542271d56c033f33816306c9fe74e037595a8177e7a8b12ac33f5544d2a9d"
payload_linux_arm64="payloads/linux/openssh-linux-arm64-9.8p1.tar.gz"
payload_linux_arm64_sha="529a6f97330490754454383608987c888274602602d70a36ddd2617e7291654a"
payload_linux_x86_64="payloads/linux/openssh-linux-x86_64-9.8p1.tar.gz"
payload_linux_x86_64_sha="8c322411f4023424a2ba22e06694c3634486c115c964dadd2975bdb34da7b74f"

ensure_payload() { # $1=relpath  $2=expected_sha(optional)
  local p="$ROOT/$1" sha
  [ -f "$p" ] || { echo "Missing full runtime payload for $GOOS_VALUE/$GOARCH_VALUE: $p (run scripts/prepare-unix-openssh.sh or prepare-windows-openssh.sh)" >&2; exit 1; }
  # In a release build the payload is freshly compiled on CI, so its digest need not
  # match our locally-generated pin; verify existence only. Dev/source builds enforce it.
  if [ "${CC_REMOTE_RELEASE_BUILD:-0}" != 1 ] && [ -n "$2" ]; then
    sha="$(shasum -a 256 "$p" | cut -d' ' -f1)"
    [ "$sha" = "$2" ] || { echo "Pinned payload mismatch for $GOOS_VALUE/$GOARCH_VALUE: got $sha want $2" >&2; exit 1; }
  fi
}

payload=""
case "$GOOS_VALUE" in
  windows)
    ensure_payload "$payload_win" "$payload_win_sha"; payload="$ROOT/$payload_win" ;;
  darwin)
    if [ "$GOARCH_VALUE" = arm64 ]; then
      ensure_payload "$payload_macos_arm64" "$payload_macos_arm64_sha"; payload="$ROOT/$payload_macos_arm64"
    elif [ "$GOARCH_VALUE" = amd64 ]; then
      ensure_payload "$payload_macos_x86_64" "$payload_macos_x86_64_sha"; payload="$ROOT/$payload_macos_x86_64"
    else
      echo "Unsupported goarch for darwin payload: $GOARCH_VALUE" >&2; exit 2
    fi ;;
  linux)
    if [ "$GOARCH_VALUE" = arm64 ]; then
      ensure_payload "$payload_linux_arm64" "$payload_linux_arm64_sha"; payload="$ROOT/$payload_linux_arm64"
    elif [ "$GOARCH_VALUE" = amd64 ]; then
      ensure_payload "$payload_linux_x86_64" "$payload_linux_x86_64_sha"; payload="$ROOT/$payload_linux_x86_64"
    else
      echo "Unsupported goarch for linux payload: $GOARCH_VALUE" >&2; exit 2
    fi ;;
  *) echo "Unsupported platform for payload: $GOOS_VALUE" >&2; exit 2 ;;
esac

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
rel_payload="${payload#"$ROOT/"}"
[ -f "$extracted/$rel_payload" ] || { echo "Extracted payload missing for $GOOS_VALUE/$GOARCH_VALUE: $rel_payload" >&2; exit 1; }
if [ "$GOOS_VALUE" = "$(go env GOOS)" ] && [ "$GOARCH_VALUE" = "$(go env GOARCH)" ]; then
  "$extracted/$exe" version >/dev/null
fi
sha="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
printf '%s  %s\n' "$sha" "$(basename "$archive")" > "$archive.sha256"
printf '%s\n%s\n' "$archive" "$archive.sha256"
