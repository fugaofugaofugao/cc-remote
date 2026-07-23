# cc-remote

**Languages:** English | [简体中文](README.zh-CN.md)

`cc-remote` creates time-bounded SSH access for authorized remote support. A controlled Windows, macOS, or Linux machine runs a generated one-shot launcher, establishes a restricted reverse SSH tunnel to a public Linux/OpenSSH relay that **you control**, and prints a verified `CC_REMOTE_READY` line. The operator connects with fresh per-session keys.

This project is for consent-based maintenance. It is not a persistence or unattended-access product.

## Security model

- You must provide and control the public Linux/OpenSSH relay. cc-remote does not provide a relay service.
- Reverse listeners bind to relay loopback only: `127.0.0.1:<port>`.
- A dedicated relay account, normally `cc-tunnel`, is restricted with `permitopen`, `permitlisten`, `no-pty`, and no X11 forwarding.
- Target and tunnel Ed25519 key pairs are generated fresh for each session.
- Private keys remain on the operator computer. Connection files contain only private-key paths and public fingerprints.
- READY is accepted only after local SSH, the exact reverse-tunnel process, and cleanup registration are verified.
- Cleanup matches the exact session marker and recorded tunnel process. Shared `sshd` is never session-owned.
- Relay mutation is off by default. Automatic per-session authorization installation requires explicit `--install-relay=true` and a separately supplied administrative SSH destination.

Read [SECURITY.md](SECURITY.md) before use.

## Install from a release

Install a full runtime archive. Do not use GitHub's automatic source archives for normal operation.

Release page:

```text
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.2.1
```

Direct `v0.2.1` runtime downloads:

| Operator OS / arch | Runtime archive | SHA256 file |
| --- | --- | --- |
| Windows x86_64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_windows_amd64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_windows_amd64_full.zip.sha256 |
| macOS Apple Silicon | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_arm64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_arm64_full.zip.sha256 |
| macOS Intel | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_amd64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_amd64_full.zip.sha256 |
| Linux x86_64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_amd64_full.tar.gz | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_amd64_full.tar.gz.sha256 |
| Linux ARM64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_arm64_full.tar.gz | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_arm64_full.tar.gz.sha256 |

macOS Apple Silicon example:

```sh
curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_arm64_full.zip
curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_arm64_full.zip.sha256
shasum -a 256 -c cc-remote_v0.2.1_darwin_arm64_full.zip.sha256
unzip cc-remote_v0.2.1_darwin_arm64_full.zip
cd cc-remote_v0.2.1_darwin_arm64_full
./install.sh
"$HOME/.local/share/cc-remote/cc-remote" doctor --json
```

Linux x86_64 example:

```sh
curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_amd64_full.tar.gz
curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_amd64_full.tar.gz.sha256
sha256sum -c cc-remote_v0.2.1_linux_amd64_full.tar.gz.sha256
tar -xzf cc-remote_v0.2.1_linux_amd64_full.tar.gz
cd cc-remote_v0.2.1_linux_amd64_full
./install.sh
"$HOME/.local/share/cc-remote/cc-remote" doctor --json
```

Windows PowerShell example:

```powershell
Invoke-WebRequest -Uri 'https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_windows_amd64_full.zip' -OutFile '.\cc-remote_v0.2.1_windows_amd64_full.zip'
Invoke-WebRequest -Uri 'https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_windows_amd64_full.zip.sha256' -OutFile '.\cc-remote_v0.2.1_windows_amd64_full.zip.sha256'
$Expected = (Get-Content '.\cc-remote_v0.2.1_windows_amd64_full.zip.sha256').Split(' ')[0].ToLowerInvariant()
$Actual = (Get-FileHash '.\cc-remote_v0.2.1_windows_amd64_full.zip' -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Actual -ne $Expected) { throw "SHA256 mismatch: $Actual" }
Expand-Archive '.\cc-remote_v0.2.1_windows_amd64_full.zip'
cd '.\cc-remote_v0.2.1_windows_amd64_full'
.\install.ps1 -AddToPath
& "$env:LOCALAPPDATA\Programs\cc-remote\cc-remote.exe" doctor --json
```

The installers copy the CLI plus `bootstrap/`, `payloads/`, and docs into a user-local app directory. They do not create sessions, keys, relay authorization, services, or `~/.cc-remote` records.

## Configure your relay once

First prepare a public Linux/OpenSSH relay that you administer. Keep `GatewayPorts no` and use a dedicated account such as `cc-tunnel`. See [docs/relay.md](docs/relay.md).

Then save the operator-side default relay profile once:

```sh
cc-remote relay set \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel
```

If you also have an operator-side administrative SSH alias for explicit relay authorization installation, save it too:

```sh
cc-remote relay set \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel \
  --ssh-host support-relay-admin
```

The profile is stored at `~/.cc-remote/config.json` with mode `0600`. It stores relay endpoint metadata only, never private-key bodies. It is reused by later `cc-remote create` commands. Per-session keys and restricted relay `authorized_keys` lines are still generated fresh every time.

Verify the saved profile:

```sh
cc-remote relay show --json
cc-remote relay doctor --json
```

`relay doctor` validates the saved local profile. You must still verify the actual relay host configuration with `cc-remote init-relay --user cc-tunnel` and the checklist in [docs/relay.md](docs/relay.md).

## Create a session

After `cc-remote relay set`, a normal AI/operator command no longer needs repeated relay flags:

```sh
cc-remote create --json \
  --name support-session \
  --platform windows \
  --launcher-format cmd \
  --handoff-mode embedded \
  --target-user auto \
  --idle-timeout 12h \
  --max-lifetime 12h
```

By default this does not change the relay. The JSON result includes one restricted `relay_authorized_key_line`; append that exact line to the dedicated relay user's `authorized_keys`, preserving unrelated lines, before the recipient runs the launcher.

To explicitly let the CLI install that single line, save or pass `--relay-ssh-host` and opt in on the create command:

```sh
cc-remote create --json \
  --name support-session \
  --platform windows \
  --launcher-format cmd \
  --install-relay=true
```

`--install-relay=true` is intentionally not remembered as a default. Each automatic relay mutation must be explicit.

Send only files listed in `share_with_recipient` to the authorized controlled machine. Do not send files listed in `operator_only`.

> **Secret-bearing output:** generated `.cmd`/`.command`/`.sh` launchers contain a session tunnel private key. Give a launcher only to the operator of the authorized controlled machine. Never commit it, upload it to GitHub, paste it into an AI chat, or distribute it as reusable project source.

## Run, register READY, and connect

The controlled user runs the generated launcher and sends back only the genuine line:

```text
CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>
```

Register the exact line:

```sh
cc-remote ready 'CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>'
```

Inspect the session and begin with read-only checks:

```sh
cc-remote show <session-name-or-id>
cc-remote ssh <session-name-or-id>
# On the controlled machine: hostname; whoami; inspect the OS version.
```

You can also connect through the generated per-session SSH config:

```sh
ssh -F ~/.cc-remote/sessions/<session-id>/ssh_config cc-remote-<session-id>
```

Never construct a READY line from expected values, metadata, or an old log.

## AI install-and-use prompt

Copy this prompt when another AI/operator should install cc-remote and generate a reusable one-click launcher from the GitHub Release:

```text
Install and use cc-remote v0.2.1 from GitHub Release. Do not clone source code, do not run go build, and do not rewrite the launcher scripts.

Release page:
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.2.1

Download exactly one matching runtime archive plus its .sha256 file:
- Windows x86_64:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_windows_amd64_full.zip
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_windows_amd64_full.zip.sha256
- macOS Apple Silicon:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_arm64_full.zip
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_arm64_full.zip.sha256
- macOS Intel:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_amd64_full.zip
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_darwin_amd64_full.zip.sha256
- Linux x86_64:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_amd64_full.tar.gz
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_amd64_full.tar.gz.sha256
- Linux ARM64:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_arm64_full.tar.gz
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.1/cc-remote_v0.2.1_linux_arm64_full.tar.gz.sha256

Steps:
1. Verify SHA256 before extraction. Stop if verification fails.
2. Extract and run the included installer:
   - macOS/Linux: ./install.sh
   - Windows: .\install.ps1 -AddToPath
3. Verify the installed binary by deterministic path, not by guessing PATH:
   - macOS/Linux: "$HOME/.local/share/cc-remote/cc-remote" doctor --json
   - Windows: & "$env:LOCALAPPDATA\Programs\cc-remote\cc-remote.exe" doctor --json
4. Continue only if doctor JSON has ok=true. If not, stop and report the JSON.
5. Confirm there is a public Linux/OpenSSH relay server controlled by the operator. You need the relay public host/IP, SSH port, dedicated relay user such as cc-tunnel, and optionally an administrative SSH alias. If the relay host is not prepared yet, run cc-remote init-relay --user cc-tunnel and apply the printed Match User policy on that relay. Keep GatewayPorts no, validate with sudo sshd -t, and reload sshd; prefer reload, not restart.
6. Save the relay once on the operator machine:
   cc-remote relay set --host <relay-host> --port <relay-ssh-port> --user cc-tunnel
   If the operator explicitly provides an administrative SSH destination, include:
   --ssh-host <relay-admin-ssh-alias>
7. Verify the saved relay profile:
   cc-remote relay show --json
   cc-remote relay doctor --json
8. Create one single-platform launcher with JSON output. The saved relay profile is reused automatically:
   cc-remote create --json \
     --name <target-name> \
     --platform <windows|macos|linux> \
     --launcher-format <cmd|command|sh> \
     --handoff-mode embedded \
     --target-user auto \
     --idle-timeout 12h \
     --max-lifetime 12h
   Platform launcher formats: Windows=cmd, macOS=command, Linux=sh.
9. By default create does not modify the relay. Install the exact relay_authorized_key_line from create --json into the relay user's authorized_keys, preserving unrelated keys. Only use --install-relay=true when the operator explicitly authorizes that relay mutation for this session.
10. Send only files listed in share_with_recipient to the authorized controlled machine. Do not send files listed in operator_only.
11. Never print, copy, upload, or paste private-key bodies. Key information means operator-side private-key paths and public-key fingerprints only.
12. Accept only the complete READY line emitted by the controlled launcher after verification: CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>. Never invent or construct READY.
13. Register READY on the operator machine: cc-remote ready 'CC_REMOTE_READY ...'
14. Start with read-only checks only, such as hostname, current user, and OS version. Do not modify the controlled machine until that exact work is authorized.
```

## Use with Claude Code or Codex

This is a command-line workflow that AI coding agents can operate with your approval; it is not a Claude Code plugin, slash command, or MCP server.

Give the agent the authorized target scope, platform, relay you control, session lifetime, and whether relay installation is permitted. Ask it to read this README and [SECURITY.md](SECURITY.md), show each command before running it, and never display or paste private-key contents, generated launchers, `~/.cc-remote` records, logs, or connection metadata. Provide the agent only the complete, genuine `CC_REMOTE_READY ...` line emitted by the controlled machine. Begin with read-only inspection and require separate authorization for target changes.

Do not blanket-approve filesystem, subprocess, SSH, or network access. A permission request is not evidence that a command is safe; review the exact command and scope.

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
cc-remote close <session-name-or-id>
```

The CLI removes relay authorization only when that authorization was installed by the CLI. Default/manual sessions close locally without making a remote SSH connection. Closing a monitor window alone does not revoke access.

## Source development

Source development requires Go 1.22 or newer plus `ssh`, `ssh-keygen`, and `zip`/`unzip` where required by your workflow.

```sh
git clone https://github.com/fugaofugaofugao/cc-remote.git
cd cc-remote
./scripts/test.sh
./scripts/build.sh
```

The binary is written to `dist/cc-remote` (`dist/cc-remote.exe` for a Windows target build). During development you can also run:

```sh
go run ./cmd/cc-remote --help
```

For Windows launcher generation from source-only checkouts, prepare the optional pinned Win32-OpenSSH payload first:

```sh
./scripts/prepare-windows-openssh.sh
./scripts/test.sh
./scripts/build.sh
```

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
