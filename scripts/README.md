# Scripts

All scripts operate on the repository or on explicit paths. Generated session material belongs under the operator's private `~/.cc-remote` directory and must not be packaged as source.

## `build.sh`

Build the CLI into `dist/`. Optional environment variables:

```sh
GOOS=windows GOARCH=amd64 ./scripts/build.sh
```

## `test.sh`

Runs formatting verification, `go vet`, all Go tests, shell syntax checks, payload verification when present, and static Windows launcher/setup invariants. PowerShell regression tests are run automatically when a compatible `powershell` executable is available.

## `privacy-scan.sh`

Fail-closed source/archive scanner. It checks forbidden runtime paths, private-key headers, local absolute home paths, provider-specific legacy literals, public IPv4 literals, generated launchers, records, logs, state, and other session artifacts. Pass optional additional forbidden literals through a newline-delimited file:

```sh
CC_REMOTE_PRIVACY_DENYLIST=/path/to/private-denylist.txt ./scripts/privacy-scan.sh .
```

The scanner treats security-test assertions that mention a private-key header as source tests, but rejects an actual PEM/OpenSSH private-key block.

## `package.sh`

Creates two reproducible source ZIPs in a temporary release directory:

- Self-contained source, including the pinned Windows payload.
- Source-only, excluding that payload.

It builds from an explicit allowlist, runs tests/scans, extracts both archives, and scans/tests the extracted trees. It never archives `~/.cc-remote` or the working tree wholesale.

Use an output directory outside the source tree:

```sh
./scripts/package.sh /path/to/output
```

## `prepare-windows-openssh.sh`

Downloads the pinned upstream Win32-OpenSSH ZIP and verifies its SHA-256 before replacing the local payload.

## Windows PowerShell regression scripts

The `test-windows-*.ps1` scripts validate reusable PowerShell 5.1 behavior including target-user resolution, structured tunnel startup, exact-process replacement, SYSTEM idle cleanup, authorization handoff, and monitor relaunch. Tests requiring Windows should run on an isolated authorized Windows test machine.
