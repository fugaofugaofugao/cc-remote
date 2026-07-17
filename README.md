# cc-remote

`cc-remote` creates time-bounded SSH access for authorized remote support. A controlled Windows, macOS, or Linux machine runs a generated one-shot launcher, establishes a restricted reverse SSH tunnel to a public Linux/OpenSSH relay that **you control**, and prints a verified `CC_REMOTE_READY` line. The operator connects with fresh per-session keys.

This project is for consent-based maintenance. It is not a persistence or unattended-access product.

## Security model

- The relay endpoint is mandatory; the project provides no relay service or provider account.
- Reverse listeners bind to relay loopback only: `127.0.0.1:<port>`.
- A dedicated relay account (default `cc-tunnel`) is restricted with `permitopen`, `permitlisten`, `no-pty`, and no X11 forwarding.
- Target and tunnel Ed25519 key pairs are generated for each session.
- Private keys remain on the operator computer. Connection files contain only private-key paths and public fingerprints.
- READY is accepted only after local SSH, the exact reverse-tunnel process, and cleanup registration are verified.
- Cleanup matches the exact session marker and recorded tunnel process. Shared `sshd` is never session-owned.
- Relay mutation is off by default. Automatic authorization installation requires explicit opt-in and a separately supplied administrative SSH destination.

Read [SECURITY.md](SECURITY.md) before use.

## Requirements

- Go 1.22 or newer on the operator computer.
- `ssh`, `ssh-keygen`, and `zip`/`unzip` where required by your workflow.
- A public Linux host running OpenSSH that you administer.
- Administrator/root approval on the controlled machine.
- For offline Windows launcher generation, the pinned Win32-OpenSSH payload at `payloads/windows/openssh-win64.zip`.

## Install and build

Clone the repository or extract one of the release source archives, then work from its root:

```sh
git clone https://github.com/fugaofugaofugao/cc-remote.git
cd cc-remote
./scripts/test.sh
./scripts/build.sh
```

The binary is written to `dist/cc-remote` (`dist/cc-remote.exe` for a Windows target build). You can also run the CLI from the repository root:

```sh
go run ./cmd/cc-remote
```

The self-contained repository and release archive include the checksum-pinned Windows OpenSSH payload. The source-only release archive omits it; prepare the optional payload before generating an offline Windows launcher:

```sh
./scripts/prepare-windows-openssh.sh
./scripts/test.sh
./scripts/build.sh
```

### Supported installation boundary

The CLI uses project-owned files under `bootstrap/`, and Windows launcher generation additionally uses `payloads/`. For `v0.1.0`, run it from a cloned/extracted project tree. A bare copied binary, `go install`, Homebrew package, or curl-pipe-shell installation is **not** a supported deployment model.

## Prepare your relay

Print provider-neutral setup guidance:

```sh
./dist/cc-remote init-relay --user cc-tunnel
```

Review and apply the commands on a public Linux/OpenSSH relay you control. Keep `GatewayPorts no`. See [docs/relay.md](docs/relay.md).

## Create a session

The default workflow does **not** change the relay. It prints the exact restricted `authorized_keys` line for you to install:

```sh
./dist/cc-remote create \
  --name support-session \
  --platform windows \
  --relay-host relay.example.test \
  --relay-port 22 \
  --relay-user cc-tunnel \
  --target-user auto \
  --idle-timeout 2h \
  --max-lifetime 168h
```

Replace `relay.example.test` with the public hostname or address of your own relay. Install the printed line in the dedicated relay user's `authorized_keys`, then send only the generated launcher to the authorized recipient.

> **Secret-bearing output:** generated `.cmd`/`.command` launchers contain a session tunnel private key. Give a launcher only to the operator of the authorized controlled machine. Never commit it, upload it to GitHub, paste it into an AI chat, or distribute it as reusable project source.

To explicitly let the CLI install that single authorization line, provide an administrative SSH destination you configured and opt in:

```sh
./dist/cc-remote create \
  --name support-session \
  --platform windows \
  --relay-host relay.example.test \
  --relay-ssh-host support-relay \
  --install-relay=true
```

`--relay-host` is the endpoint used by the controlled machine. `--relay-ssh-host` is an operator-side administrative SSH destination and is used only for explicit installation/removal. They are intentionally separate.

## Run, register READY, and connect

The controlled user runs the generated launcher and sends back only the genuine line:

```text
CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>
```

Register the exact line:

```sh
./dist/cc-remote ready 'CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>'
```

Inspect the session and begin with read-only checks:

```sh
./dist/cc-remote show <session-name-or-id>
./dist/cc-remote ssh <session-name-or-id>
# On the controlled machine: hostname; whoami; inspect the OS version.
```

You can also connect through the generated per-session SSH config:

```sh
ssh -F ~/.cc-remote/sessions/<session-id>/ssh_config cc-remote-<session-id>
```

Never construct a READY line from expected values, metadata, or an old log.

## Use with Claude Code

This is a command-line workflow that Claude Code can operate with your approval; it is not a Claude Code plugin, slash command, or MCP server.

1. Clone/extract the project and start Claude Code from its root:

   ```sh
   cd /path/to/cc-remote
   claude
   ```

2. Give Claude the authorized target scope, platform, relay you control, session lifetime, and whether relay installation is permitted. Ask it to read this README and [SECURITY.md](SECURITY.md), show each command before running it, and run the repository tests before creating a launcher.
3. Approve only the required actions. Session creation invokes `ssh-keygen` and writes sensitive operator-side state under `~/.cc-remote`; SSH connection and optional relay administration require network access. Treat relay mutation as a separate approval.
4. Give the secret-bearing launcher to the authorized controlled-machine operator outside the model conversation.
5. Provide Claude only the complete, genuine `CC_REMOTE_READY ...` line emitted by that machine. Do not provide the launcher, keys, session files, connection files, logs, or relay diagnostics.
6. Have Claude register READY, connect, and start with read-only inspection. Explicitly authorize any later target modification.
7. When finished, have Claude close only the exact session and verify revocation.

Copyable prompt:

```text
Read README.md and SECURITY.md first. Help me create one authorized,
time-bounded cc-remote session for <platform> through a relay I control at
<relay-host>. Do not install relay authorization unless I explicitly approve
--install-relay=true. Show every command before running it. Never display or
paste private-key contents, generated launchers, ~/.cc-remote records, logs,
or connection metadata. Accept READY only from the exact line emitted by the
controlled machine. Begin with read-only checks after connecting and clean up
only the exact session when finished. Never stop or reconfigure shared sshd.
```

Do not blanket-approve filesystem, subprocess, SSH, or network access. A permission request is not evidence that a command is safe; review the exact command and scope.

## Use with Codex

This is likewise a command-line workflow, not a Codex plugin or MCP integration:

```sh
cd /path/to/cc-remote
codex
```

Use the same prompt and lifecycle described above. Codex sandbox and approval controls vary by installation, but the security boundary does not:

- Approve only the exact build, test, `ssh-keygen`, `~/.cc-remote`, SSH, and optional relay-administration operations required.
- Do not disable the sandbox globally or grant unrestricted access merely for convenience.
- Keep generated launchers and bundles out of the conversation; they contain session secrets.
- The genuine READY line may be provided, but private keys, connection files, known-host files, records, logs, and real relay diagnostics must not be pasted.
- Require read-only inspection first and separate authorization for target changes.
- Cleanup must match the exact session and must not stop or reconfigure shared `sshd`.

## Windows execution model

The Windows `.cmd` launcher requests UAC and runs two distinct phases:

1. `bootstrap.ps1 -NoMonitor` performs finite setup and is the only process allowed to append to `bootstrap.log` through `Tee-Object`.
2. After setup succeeds, `bootstrap.ps1 -MonitorOnly` runs outside that logging pipeline and only observes current state.

The monitor rereads `state.json`, follows a verified same-session tunnel PID replacement, and never owns or locks `bootstrap.log`. This permits rerunning the same launcher while an older monitor window remains open. Closing a monitor window is **not** cleanup.

## Session artifacts are sensitive

Everything under `~/.cc-remote/` is sensitive, including private keys, generated launchers/bundles, records, known-host files, SSH configs, and connection metadata. Do not publish, commit, paste into a chat, or include these files in a reusable archive. Distribute the clean source tree, not a generated session.

## Cleanup

On the controlled machine, use the registered idle cleanup or the extracted exact-session cleanup script. On the operator computer:

```sh
./dist/cc-remote close <session-name-or-id>
```

The CLI removes relay authorization only when that authorization was installed by the CLI. Default/manual sessions close locally without making a remote SSH connection. Closing a monitor window alone does not revoke access.

## Release downloads and verification

The `v0.1.0` prerelease provides five verified attachments:

- `cc-remote-self-contained-source.zip` — includes the pinned Win32-OpenSSH payload.
- `cc-remote-self-contained-source.zip.sha256`
- `cc-remote-source-only.zip` — omits the optional Windows payload.
- `cc-remote-source-only.zip.sha256`
- `release-manifest.txt`

Verify an archive before extraction, for example:

```sh
shasum -a 256 -c cc-remote-self-contained-source.zip.sha256
```

GitHub's automatically generated “Source code” archives are repository snapshots. The attached archives are separately built through the project's explicit allowlist, privacy scans, extraction, and extracted-tree retests. No standalone CLI binary is distributed in `v0.1.0` because the CLI requires project assets.

## Documentation

- [Usage workflow](docs/usage.md)
- [Relay setup](docs/relay.md)
- [Offline payloads](docs/payloads.md)
- [Distribution privacy](docs/distribution-privacy.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## License

Project source is available under the [MIT License](LICENSE). Bundled third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
