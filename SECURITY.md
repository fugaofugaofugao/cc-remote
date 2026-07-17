# Security policy

## Supported versions

Until a broader support policy is established, only the latest tagged release receives security fixes.

## Authorized use only

Use cc-remote only on systems whose owner has authorized the specific support session. State what the launcher changes before execution and keep access time-bounded.

## Non-negotiable boundaries

- Private keys stay on the operator computer. Never print, paste, log, publish, or send their bodies to the controlled machine.
- Use fresh target and tunnel Ed25519 key pairs for every session.
- Install only the target public key marked exactly `cc-remote:<session-id>`.
- Keep relay reverse listeners on `127.0.0.1:<port>`. Do not enable public `GatewayPorts` without designing and approving a different threat model.
- Use per-key `permitopen`, `permitlisten`, `no-pty`, and no-X11-forwarding restrictions.
- Accept READY only when the controlled bootstrap emits the complete line after local SSH, tunnel, and cleanup verification.
- Never infer READY from expected values, metadata, or historical logs.
- Stop only a stored tunnel PID whose executable and full session identity match. Never broadly kill SSH processes.
- Treat `sshd` and all pre-existing/shared services as outside session ownership. Cleanup must not stop, disable, uninstall, restart, replace, or reconfigure them.
- Missing, malformed, or ambiguous state fails closed and preserves unrelated resources.

## Relay administration

The default create workflow makes no remote relay change. Automatic installation is allowed only with explicit `--install-relay=true` and a separate `--relay-ssh-host` administrative destination. The public relay endpoint is never inferred from an SSH alias.

Review all relay setup commands. Validate `sshd_config` before a reload. Preserve unrelated authorized keys and remove only the exact session marker.

## Windows launcher ownership

Finite setup (`-NoMonitor`) alone may mutate state and append to `bootstrap.log`. Monitor-only mode is read-only, rereads `state.json`, and runs outside the logging pipeline. A monitor window is not a cleanup owner; closing it neither revokes nor deletes access.

## Sensitive artifacts

Everything under `~/.cc-remote` should be treated as sensitive. Generated launchers/bundles contain a session tunnel private key; session directories contain operator private keys, records, known hosts, and connection metadata. Never include these in reusable source releases or AI conversations.

Before distribution, run `scripts/privacy-scan.sh` and package through the explicit-allowlist `scripts/package.sh`. Add deployment-specific private literals to `CC_REMOTE_PRIVACY_DENYLIST` stored outside the repository.

## Reporting a vulnerability

Use GitHub Private Vulnerability Reporting:

`https://github.com/fugaofugaofugao/cc-remote/security/advisories/new`

Do not open a public issue containing keys, relay endpoints, SSH aliases, session identifiers, ports, fingerprints, launchers, connection metadata, logs, or controlled-machine details. Reproduce with reserved domains and synthetic fixtures. Include the affected version, minimal reproduction steps, impact, and a proposed mitigation when available.

Revoke affected exact-session authorizations and keys before sharing diagnostics. Do not attach generated launchers, private session directories, or real deployment data even to a private report unless the maintainer explicitly requests a minimal sanitized excerpt.
