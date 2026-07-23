# Distribution privacy and release process

A reusable release must be built from project source, never from a live operator session or by zipping an existing development/runtime directory wholesale.

## Never distribute

- `~/.cc-remote` or any copied portion of it.
- Generated `.cmd`, `.command`, `.ps1`, or `.sh` session launchers.
- Generated session ZIP bundles.
- Target or tunnel private/public key files from a real session.
- `record.json`, `connection.json`, `connection.md`, `ssh_config`, or known-host files.
- Controlled-machine state, logs, startup handshakes, scheduled-task exports, or backups.
- Personal paths, usernames, hostnames, relay addresses, provider aliases, administrative SSH aliases, real ports, session IDs, timestamps, or fingerprints.
- Locally compiled binaries containing source/debug paths.

Generated launchers are secret-bearing because a controlled machine needs the tunnel private key to authenticate to the relay. They are handoff artifacts for one exact authorized session, not generic application binaries.

## Clean release model

`scripts/package.sh` copies an explicit source allowlist into a fresh mode-0700 staging directory. It creates:

1. A self-contained source archive that includes the unmodified, SHA-256-pinned Win32-OpenSSH ZIP.
2. A source-only archive that excludes the binary payload.

The package script does not read or archive the operator's runtime directory.

## Privacy scan

Run:

```sh
./scripts/privacy-scan.sh .
```

For deployment-specific secrets, prepare a private newline-delimited denylist outside the source tree:

```text
real-user-name
real-relay-hostname
real-ssh-alias
real-session-id
```

Then run:

```sh
CC_REMOTE_PRIVACY_DENYLIST=/private/path/denylist.txt ./scripts/privacy-scan.sh .
```

Do not add real private values to repository scripts or examples just to scan for them.

The release process scans source, archive manifests, extracted files, and the nested Windows payload. Both extracted releases are retested. Public IP literals and absolute personal home paths are rejected; reserved documentation domains and required security constants such as `127.0.0.1` and SSH port 22 remain allowed.

## Third-party payload

The self-contained archive includes the exact upstream Win32-OpenSSH ZIP recorded in `THIRD_PARTY_NOTICES.md`. Its SHA-256 and nested LICENSE/NOTICE paths are verified. The payload is never rebuilt or edited.

## Recipient responsibilities

A recipient must configure a public Linux/OpenSSH relay they control and explicitly supply its endpoint. The release contains no server, account, DNS record, or provider configuration. Relay authorization installation is manual by default; automatic installation requires explicit opt-in and a recipient-owned administrative SSH destination.

## Install-and-use runtime archives

Runtime archives are built from an explicit allowlist, not by zipping a working
tree. They may contain the public CLI binary, bootstrap scripts, docs, installers,
and the pinned Win32-OpenSSH payload for offline Windows support.

Runtime archives and installers must never contain generated sessions, launchers,
private or public session keys, records, logs, SSH configs, known-host files,
connection metadata, relay-specific hostnames, fixed ports, or deployment
fixtures. Installers are user-local only: they copy reusable code/assets and may
create a command shim or update the user PATH, but they do not create sessions,
keys, relay authorization, services, or `~/.cc-remote` records.
