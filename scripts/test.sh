#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_OPENSSH_SHA256="23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5"
EXPECTED_MACOS_ARM64_SHA256="63226db97f12d36fc720b9e5e7304a509907df5ff08b7aa3917c2f96fe7db249"
EXPECTED_LINUX_ARM64_SHA256="529a6f97330490754454383608987c888274602602d70a36ddd2617e7291654a"
EXPECTED_LINUX_X86_64_SHA256="8c322411f4023424a2ba22e06694c3634486c115c964dadd2975bdb34da7b74f"
# macOS x86_64 is built on an Intel CI runner (no pinned digest until first CI build);
# empty pin means verify presence/structure only.
EXPECTED_MACOS_X86_64_SHA256=""
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

# Bundled self-contained unix OpenSSH payloads (built by prepare-unix-openssh.sh).
check_unix_payload() { # $1=os(macos|linux) $2=arch $3=goos-tag(darwin|linux) $4=label $5=expected_sha
  local p="$ROOT/payloads/$1/openssh-$3-$2-9.8p1.tar.gz" actual
  if [ -f "$p" ]; then
    if [ -n "$5" ]; then
      actual="$(shasum -a 256 "$p" | cut -d' ' -f1)"
      if [ "$actual" != "$5" ]; then
        printf '%s payload digest mismatch: expected %s, got %s\n' "$4" "$5" "$actual" >&2
        exit 1
      fi
    fi
    tar -tzf "$p" | grep -Fx 'openssh/LICENSE' >/dev/null || { echo "$4 missing LICENSE" >&2; exit 1; }
    tar -tzf "$p" | grep -Fx 'openssh/bin/sshd' >/dev/null || { echo "$4 missing sshd" >&2; exit 1; }
    tar -tzf "$p" | grep -Fx 'openssh/bin/ssh' >/dev/null || { echo "$4 missing ssh client" >&2; exit 1; }
    tar -tzf "$p" | grep -Fx 'openssh/libexec/sshd-session' >/dev/null || { echo "$4 missing sshd-session" >&2; exit 1; }
  else
    printf 'Source-only tree: pinned %s (%s %s) absent; skipped.\n' "$4" "$1" "$2"
  fi
}
check_unix_payload macos arm64 darwin 'macOS arm64' "$EXPECTED_MACOS_ARM64_SHA256"
check_unix_payload linux arm64 linux 'Linux arm64' "$EXPECTED_LINUX_ARM64_SHA256"
check_unix_payload linux x86_64 linux 'Linux x86_64' "$EXPECTED_LINUX_X86_64_SHA256"
# macOS x86_64 is built on an Intel CI runner; verify when present, else skip in source-only trees.
check_unix_payload macos x86_64 darwin 'macOS x86_64' "$EXPECTED_MACOS_X86_64_SHA256"

grep -F 'bootstrap.ps1 -NoMonitor *>&1 | Tee-Object' "$ROOT/cmd/cc-remote/main.go" >/dev/null
grep -F 'bootstrap.ps1" -MonitorOnly' "$ROOT/cmd/cc-remote/main.go" >/dev/null
if grep -F 'bootstrap.ps1" -MonitorOnly' "$ROOT/cmd/cc-remote/main.go" | grep -F 'Tee-Object' >/dev/null; then
  echo 'MonitorOnly must remain outside the Tee-Object logging pipeline.' >&2
  exit 1
fi
grep -F 'exec /bin/bash "$0" "$@"' "$ROOT/cmd/cc-remote/main.go" >/dev/null

grep -F './install.sh' "$ROOT/scripts/install.command" >/dev/null
grep -F 'install.ps1' "$ROOT/scripts/install.cmd" >/dev/null
go -C "$ROOT" run ./cmd/cc-remote version >/dev/null
# doctor --platform macos validates that a bundled unix payload is present, so it must
# only run in a tree that has one (the main tree / self-contained tree), not the
# source-only tree which intentionally omits payload archives.
if compgen -G "$ROOT/payloads/macos/openssh-*.tar.gz" >/dev/null; then
  go -C "$ROOT" run ./cmd/cc-remote doctor --json --platform macos >/dev/null
fi

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
