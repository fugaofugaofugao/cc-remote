#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_OPENSSH_SHA256="23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5"
PAYLOAD="$ROOT/payloads/windows/openssh-win64.zip"

unformatted="$(gofmt -l "$ROOT/cmd" "$ROOT/internal")"
if [ -n "$unformatted" ]; then
  printf 'Go files require gofmt:\n%s\n' "$unformatted" >&2
  exit 1
fi

go -C "$ROOT" vet ./...
go -C "$ROOT" test ./...

for dir in bootstrap relay scripts; do
  if [ ! -d "$ROOT/$dir" ]; then
    printf 'Required source directory is missing: %s\n' "$dir" >&2
    exit 1
  fi
done

while IFS= read -r script; do
  bash -n "$script"
done < <(find "$ROOT/bootstrap" "$ROOT/relay" "$ROOT/scripts" -type f -name '*.sh' -print | LC_ALL=C sort)

if [ -f "$PAYLOAD" ]; then
  actual="$(shasum -a 256 "$PAYLOAD" | cut -d' ' -f1)"
  if [ "$actual" != "$EXPECTED_OPENSSH_SHA256" ]; then
    printf 'Win32-OpenSSH payload digest mismatch: expected %s, got %s\n' "$EXPECTED_OPENSSH_SHA256" "$actual" >&2
    exit 1
  fi
  unzip -Z1 "$PAYLOAD" | grep -Fx 'OpenSSH-Win64/LICENSE.txt' >/dev/null
  unzip -Z1 "$PAYLOAD" | grep -Fx 'OpenSSH-Win64/NOTICE.txt' >/dev/null
else
  printf 'Source-only tree: pinned Win32-OpenSSH payload is absent; payload-dependent Go test is expected to skip.\n'
fi

grep -F 'bootstrap.ps1 -NoMonitor *>&1 | Tee-Object' "$ROOT/cmd/cc-remote/main.go" >/dev/null
grep -F 'bootstrap.ps1" -MonitorOnly' "$ROOT/cmd/cc-remote/main.go" >/dev/null
if grep -F 'bootstrap.ps1" -MonitorOnly' "$ROOT/cmd/cc-remote/main.go" | grep -F 'Tee-Object' >/dev/null; then
  echo 'MonitorOnly must remain outside the Tee-Object logging pipeline.' >&2
  exit 1
fi
grep -F 'exec /bin/bash "$0" "$@"' "$ROOT/cmd/cc-remote/main.go" >/dev/null

powershell_bin=""
if command -v powershell >/dev/null 2>&1; then
  powershell_bin="$(command -v powershell)"
elif command -v pwsh >/dev/null 2>&1; then
  powershell_bin="$(command -v pwsh)"
fi
if [ -n "$powershell_bin" ]; then
  while IFS= read -r script; do
    CC_REMOTE_PARSE_FILE="$script" "$powershell_bin" -NoProfile -Command '$errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:CC_REMOTE_PARSE_FILE,[ref]$null,[ref]$errors); if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }'
  done < <(find "$ROOT/bootstrap" "$ROOT/scripts" -type f -name '*.ps1' -print | LC_ALL=C sort)
  if [ "$(uname -s)" = MINGW* ] || [ "$(uname -s)" = MSYS* ] || [ "$(uname -s)" = CYGWIN* ] || [ "${OS:-}" = Windows_NT ]; then
    while IFS= read -r script; do
      "$powershell_bin" -NoProfile -ExecutionPolicy Bypass -File "$script"
    done < <(find "$ROOT/scripts" -type f -name 'test-windows-*.ps1' -print | LC_ALL=C sort)
  fi
else
  echo 'PowerShell unavailable; parser and Windows-only regression scripts were skipped.'
fi

echo 'All available tests passed.'
