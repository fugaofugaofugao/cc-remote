# Contributing

## Development rules

- Work only with synthetic fixtures such as `relay.example.test`, `TESTHOST`, and temporary users/paths.
- Never commit generated launchers, private keys, `~/.cc-remote`, records, logs, state, backups, known-host files, or real connection metadata.
- Keep the public relay endpoint explicit and provider-neutral.
- Keep relay mutation disabled by default.
- Preserve loopback-only reverse forwarding and exact-session cleanup.
- Keep shared `sshd` outside session ownership.
- Preserve Windows finite setup/read-only monitor separation.
- Preserve third-party licenses, notices, and pinned payload provenance.

## Issues and security reports

Ordinary bugs and feature requests may use public GitHub issues only when the report contains synthetic examples. Do not publish a real relay endpoint, SSH alias, session identifier, port, fingerprint, launcher, key, connection file, log, state file, controlled-machine identity, or other operational data.

Suspected vulnerabilities and any report that may require deployment details must use the private path in [SECURITY.md](SECURITY.md). Revoke affected exact-session access before collecting diagnostics.

## Before submitting changes

```sh
./scripts/test.sh
./scripts/privacy-scan.sh .
```

Format Go code with `gofmt`. Match the existing PowerShell 5.1 and POSIX/Bash compatibility boundaries. Add regression tests for security-sensitive changes.

Run the Windows PowerShell 5.1 regression suites on an isolated, authorized Windows machine when changing Windows bootstrap or launcher behavior. A successful non-Windows CI job does **not** certify Windows runtime behavior; state which Windows suites were run in the pull request.

## Review checklist

- Does validation occur before creating session artifacts?
- Can malformed state cause an unrelated process or key to be changed?
- Is READY still derived only from live verification?
- Is the listener still `127.0.0.1` on the relay?
- Does any new output expose a private-key body or deployment identity?
- Can a monitor hold `bootstrap.log` or mutate setup state?
- Are manual and automatically installed relay authorizations distinguished?
- Are tests isolated from real SSH configuration and real network hosts?
- Do packaging and privacy scanning cover every newly tracked release file?
