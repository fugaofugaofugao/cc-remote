# Scripts

All scripts operate on the repository or on explicit paths. Generated session material belongs under the operator's private `~/.cc-remote` directory and must not be packaged as source.

## `build.sh`

Build the CLI into `dist/`. Optional environment variables:

```sh
GOOS=windows GOARCH=amd64 VERSION=v0.2.0 ./scripts/build.sh
```

`VERSION`, `COMMIT`, and `DATE` are embedded into `cc-remote version` when provided.

## `test.sh`

Runs formatting verification, `go vet`, all Go tests, shell syntax checks, payload verification when present, and static Windows launcher/setup invariants. PowerShell regression tests are run automatically when a compatible `powershell` executable is available.

## `privacy-scan.sh`

Fail-closed source/archive scanner. It checks forbidden runtime paths, private-key headers, local absolute home paths, provider-specific legacy literals, public IPv4 literals, generated launchers, records, logs, state, and other session artifacts. Pass optional additional forbidden literals through a newline-delimited file:

```sh
CC_REMOTE_PRIVACY_DENYLIST=/path/to/private-denylist.txt ./scripts/privacy-scan.sh .
```

The scanner treats security-test assertions that mention a private-key header as source tests, but rejects an actual PEM/OpenSSH private-key block.

## `install.sh`, `install.command`, `install.ps1`, `install.cmd`

Install an already extracted runtime archive into a user-local app directory. The installers copy the portable tree, create a command shim, and print `cc-remote version` / `cc-remote doctor --json` verification commands. They do not create sessions, keys, relay authorization, services, or `~/.cc-remote` records.

## `package-runtime.sh`

Builds one install-and-use runtime archive for a specific `--goos` / `--goarch` target. Runtime archives include the CLI executable, bootstrap assets, docs, user-local installers, and the pinned Win32-OpenSSH payload for offline Windows launcher generation.

```sh
./scripts/package-runtime.sh --output /path/to/output --version v0.2.0 --goos darwin --goarch arm64
```

## `release.sh`

Runs tests, builds privacy-safe source archives, builds the macOS/Linux/Windows runtime archive matrix, and writes `SHA256SUMS.txt` plus `release-manifest.txt`.

```sh
./scripts/release.sh /path/to/output v0.2.0
```

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
