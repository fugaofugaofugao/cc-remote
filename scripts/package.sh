#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-}"
if [ -z "$OUTPUT" ]; then
  echo "Usage: $0 /path/to/output" >&2
  exit 2
fi
OUTPUT="$(mkdir -p "$OUTPUT" && cd "$OUTPUT" && pwd)"
case "$OUTPUT/" in
  "$ROOT"/*) echo 'Output directory must be outside the source tree.' >&2; exit 2 ;;
esac

EXPECTED_OPENSSH_SHA256="23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-remote-release.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

ALLOWLIST=(
  .gitignore CONTRIBUTING.md LICENSE NOTICE README.md SECURITY.md THIRD_PARTY_NOTICES.md go.mod
  .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml .github/pull_request_template.md .github/workflows/ci.yml
  bootstrap/bootstrap.ps1 bootstrap/bootstrap.sh bootstrap/cleanup.ps1 bootstrap/cleanup.sh bootstrap/idle-watch.ps1 bootstrap/idle-watch.sh
  cmd/cc-remote/main.go cmd/cc-remote/main_test.go
  docs/distribution-privacy.md docs/payloads.md docs/relay.md docs/usage.md examples/ssh_config.example
  internal/bundle/bundle.go internal/bundle/bundle_test.go internal/manifest/manifest.go internal/session/session.go internal/session/session_test.go
  payloads/macos/README-builtin-sshd.txt payloads/windows/openssh-win64.zip relay/cc-remote-relay-check.sh
  scripts/README.md scripts/build.sh scripts/package.sh scripts/prepare-windows-openssh.sh scripts/privacy-scan.sh scripts/test.sh
  scripts/test-windows-authorization-handoff.ps1 scripts/test-windows-existing-tunnel-replacement.ps1 scripts/test-windows-idle-cleanup-task.ps1
  scripts/test-windows-monitor-relaunch.ps1 scripts/test-windows-target-user-resolution.ps1 scripts/test-windows-tunnel-handshake.ps1
)

for rel in "${ALLOWLIST[@]}"; do
  if [ ! -f "$ROOT/$rel" ]; then
    echo "Allowlisted source file is missing: $rel" >&2
    exit 1
  fi
done

"$ROOT/scripts/test.sh"
"$ROOT/scripts/privacy-scan.sh" "$ROOT"

SELF_ROOT="$WORK/cc-remote-self-contained-source"
SOURCE_ROOT="$WORK/cc-remote-source-only"
mkdir -p "$SELF_ROOT" "$SOURCE_ROOT"
for rel in "${ALLOWLIST[@]}"; do
  mkdir -p "$SELF_ROOT/$(dirname "$rel")"
  cp -p "$ROOT/$rel" "$SELF_ROOT/$rel"
  if [ "$rel" != payloads/windows/openssh-win64.zip ]; then
    mkdir -p "$SOURCE_ROOT/$(dirname "$rel")"
    cp -p "$ROOT/$rel" "$SOURCE_ROOT/$rel"
  fi
done

payload_sha="$(shasum -a 256 "$SELF_ROOT/payloads/windows/openssh-win64.zip" | cut -d' ' -f1)"
if [ "$payload_sha" != "$EXPECTED_OPENSSH_SHA256" ]; then
  echo "Pinned payload mismatch in staging: $payload_sha" >&2
  exit 1
fi

"$SELF_ROOT/scripts/test.sh"
"$SELF_ROOT/scripts/privacy-scan.sh" "$SELF_ROOT"
"$SOURCE_ROOT/scripts/test.sh"
"$SOURCE_ROOT/scripts/privacy-scan.sh" "$SOURCE_ROOT"

find "$SELF_ROOT" "$SOURCE_ROOT" -exec touch -t 202601010000 {} +
SELF_ZIP="$OUTPUT/cc-remote-self-contained-source.zip"
SOURCE_ZIP="$OUTPUT/cc-remote-source-only.zip"
rm -f "$SELF_ZIP" "$SOURCE_ZIP" "$SELF_ZIP.sha256" "$SOURCE_ZIP.sha256" "$OUTPUT/release-manifest.txt"
(
  cd "$WORK"
  find "$(basename "$SELF_ROOT")" -type f -print | LC_ALL=C sort | zip -X -q "$SELF_ZIP" -@
  find "$(basename "$SOURCE_ROOT")" -type f -print | LC_ALL=C sort | zip -X -q "$SOURCE_ZIP" -@
)

"$ROOT/scripts/privacy-scan.sh" "$SELF_ZIP"
"$ROOT/scripts/privacy-scan.sh" "$SOURCE_ZIP"

VERIFY="$WORK/verify"
mkdir -p "$VERIFY"
unzip -q "$SELF_ZIP" -d "$VERIFY/self"
unzip -q "$SOURCE_ZIP" -d "$VERIFY/source"
EXTRACTED_SELF="$VERIFY/self/$(basename "$SELF_ROOT")"
EXTRACTED_SOURCE="$VERIFY/source/$(basename "$SOURCE_ROOT")"
"$EXTRACTED_SELF/scripts/test.sh"
"$EXTRACTED_SELF/scripts/privacy-scan.sh" "$EXTRACTED_SELF"
"$EXTRACTED_SOURCE/scripts/test.sh"
"$EXTRACTED_SOURCE/scripts/privacy-scan.sh" "$EXTRACTED_SOURCE"

self_sha="$(shasum -a 256 "$SELF_ZIP" | cut -d' ' -f1)"
source_sha="$(shasum -a 256 "$SOURCE_ZIP" | cut -d' ' -f1)"
printf '%s  %s\n' "$self_sha" "$(basename "$SELF_ZIP")" > "$SELF_ZIP.sha256"
printf '%s  %s\n' "$source_sha" "$(basename "$SOURCE_ZIP")" > "$SOURCE_ZIP.sha256"
self_count="$(unzip -Z1 "$SELF_ZIP" | grep -v '/$' | wc -l | tr -d ' ')"
source_count="$(unzip -Z1 "$SOURCE_ZIP" | grep -v '/$' | wc -l | tr -d ' ')"
cat > "$OUTPUT/release-manifest.txt" <<EOF
cc-remote privacy-safe source release

cc-remote-self-contained-source.zip
  sha256: $self_sha
  files: $self_count
  includes pinned Win32-OpenSSH payload: yes

cc-remote-source-only.zip
  sha256: $source_sha
  files: $source_count
  includes pinned Win32-OpenSSH payload: no

Win32-OpenSSH payload sha256: $payload_sha
Relay configuration: not included; recipients must configure a public Linux/OpenSSH relay they control.
Generated sessions, launchers, keys, records, logs, state, known-host files, and connection metadata: not included.
Verification: formatting, Go vet/tests, shell checks, available PowerShell checks, privacy scans, archive extraction, and extracted-tree retests completed successfully.
EOF

"$ROOT/scripts/privacy-scan.sh" "$OUTPUT/release-manifest.txt"
printf 'Created:\n%s\n%s\n%s\n%s\n%s\n' "$SELF_ZIP" "$SELF_ZIP.sha256" "$SOURCE_ZIP" "$SOURCE_ZIP.sha256" "$OUTPUT/release-manifest.txt"
