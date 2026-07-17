## Summary

Describe the change using synthetic fixtures only.

## Verification

- [ ] `./scripts/test.sh`
- [ ] `./scripts/privacy-scan.sh .`
- [ ] Windows PowerShell 5.1 regression suites run on an isolated authorized machine, or not applicable
- [ ] Packaging allowlist updated for every new release file, or not applicable

## Security and privacy

- [ ] No generated launcher, key, `~/.cc-remote` file, connection metadata, known-host file, state, log, real endpoint, session identifier, port, fingerprint, or controlled-machine identity is included.
- [ ] READY remains derived only from live verification.
- [ ] Reverse listeners remain relay-loopback-only.
- [ ] Cleanup remains exact-session-scoped and does not stop or reconfigure shared `sshd`.
- [ ] Relay mutation remains disabled by default.

Use [SECURITY.md](../SECURITY.md) instead of this pull request for undisclosed vulnerabilities or operational details.
