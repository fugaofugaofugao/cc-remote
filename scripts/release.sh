#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-}"
VERSION_VALUE="${2:-${VERSION:-dev}}"
if [ -z "$OUTPUT" ]; then
  echo "Usage: $0 /path/to/output VERSION" >&2
  exit 2
fi
OUTPUT="$(mkdir -p "$OUTPUT" && cd "$OUTPUT" && pwd)"
case "$OUTPUT/" in "$ROOT"/*) echo 'Output directory must be outside the source tree.' >&2; exit 2 ;; esac

"$ROOT/scripts/test.sh"
"$ROOT/scripts/package.sh" "$OUTPUT"

matrix='darwin amd64
darwin arm64
linux amd64
linux arm64
windows amd64'
printf '%s\n' "$matrix" | while read -r goos goarch; do
  [ -n "$goos" ] || continue
  "$ROOT/scripts/package-runtime.sh" --output "$OUTPUT" --version "$VERSION_VALUE" --goos "$goos" --goarch "$goarch" --payload-mode full
done

(
  cd "$OUTPUT"
  rm -f SHA256SUMS.txt
  for file in cc-remote-* cc-remote_*; do
    [ -f "$file" ] || continue
    case "$file" in *.sha256) continue ;; esac
    shasum -a 256 "$file"
  done | LC_ALL=C sort > SHA256SUMS.txt
)

cat >> "$OUTPUT/release-manifest.txt" <<EOF

Install-and-use runtime archives
  macOS: cc-remote_${VERSION_VALUE}_darwin_amd64_full.zip, cc-remote_${VERSION_VALUE}_darwin_arm64_full.zip
  Linux: cc-remote_${VERSION_VALUE}_linux_amd64_full.tar.gz, cc-remote_${VERSION_VALUE}_linux_arm64_full.tar.gz
  Windows: cc-remote_${VERSION_VALUE}_windows_amd64_full.zip
  Runtime archives include the CLI executable, bootstrap assets, docs, installers, and the pinned bundled OpenSSH payload for that platform (win/unix, built from pinned OSS sources by prepare-*-openssh.sh).
  Installers are user-local and do not create sessions, keys, relay authorization, services, or ~/.cc-remote records.
  Verify downloads with SHA256SUMS.txt or the per-asset .sha256 files before installing.
EOF
"$ROOT/scripts/privacy-scan.sh" "$OUTPUT/release-manifest.txt"
printf 'Release artifacts ready in %s\n' "$OUTPUT"
