# Usage workflow

## 1. Install the operator CLI

For normal install-and-use operation, install a full runtime archive from the GitHub Release instead of cloning source code or running `go build`.

Release page:

```text
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.3.0
```

Direct runtime download links:

| Operator OS / arch | Runtime archive | SHA256 file |
| --- | --- | --- |
| Windows x86_64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_windows_amd64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_windows_amd64_full.zip.sha256 |
| macOS Apple Silicon | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_darwin_arm64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_darwin_arm64_full.zip.sha256 |
| macOS Intel | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_darwin_amd64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_darwin_amd64_full.zip.sha256 |
| Linux x86_64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_linux_amd64_full.tar.gz | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_linux_amd64_full.tar.gz.sha256 |
| Linux ARM64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_linux_arm64_full.tar.gz | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_linux_arm64_full.tar.gz.sha256 |

After extracting a runtime archive, run the included installer and verify with `cc-remote doctor --json`. The installer is user-local and does not create sessions, keys, relay authorization, services, or `~/.cc-remote` records.

## 2. Prepare and save your public relay once

Configure a Linux/OpenSSH relay you administer. Keep reverse forwarding loopback-only and use a dedicated `cc-tunnel` account. See [relay.md](relay.md).

If you have administrative SSH access to the relay and explicitly authorize AI/CLI relay mutation, bootstrap it directly:

```sh
cc-remote relay bootstrap \
  --admin-target root@relay.example.test \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel \
  --yes
```

This logs in over SSH, creates or verifies the dedicated relay user, appends a restricted `Match User` policy only when no existing matching block needs manual review, validates with `sshd -t`, reloads sshd, and saves the default relay profile. The command has no `--password` flag. If password login is the only available admin method, let SSH/sudo prompt interactively; never put passwords in command lines, config files, logs, docs, or chat. If admin SSH needs a non-default port or identity file and you want the profile saved for later `--install-relay=true`, first create an SSH alias containing those details and use that alias as `--admin-target`. Direct `--ssh-port` or `--identity-file` bootstrap requires `--no-save`.

Save the default relay profile once on the operator machine:

```sh
cc-remote relay set \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel
```

If you have an operator-side administrative SSH alias and want the option to explicitly install per-session relay authorization later, save it too:

```sh
cc-remote relay set \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel \
  --ssh-host support-relay-admin
```

Verify the saved profile:

```sh
cc-remote relay show --json
cc-remote relay doctor --json
```

The profile is stored at `~/.cc-remote/config.json` with mode `0600`. It stores relay endpoint metadata only, never private-key bodies. Per-session keys and restricted relay authorization lines are still generated fresh every time.

## 3. Create a support session

After `cc-remote relay set`, the relay flags are no longer repeated for normal session creation:

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

`--platform` accepts `windows`, `macos`, `linux`, or `all`. Single-platform launcher formats are `cmd` for Windows, `command` for macOS, and `sh` for Linux.

By default the command does not change the relay. It prints a restricted `relay_authorized_key_line`; install that exact line in the dedicated relay user's `authorized_keys`, preserving unrelated lines, before the recipient launches the bundle.

Automatic per-session relay authorization installation is opt-in only:

```sh
cc-remote create --json \
  --name support-session \
  --platform windows \
  --launcher-format cmd \
  --install-relay=true
```

`--install-relay=true` is not remembered as a default. Each relay mutation must be explicitly requested.

## 4. Run the controlled launcher

### Windows

Send the generated `.cmd` only to the authorized recipient. They double-click it and approve UAC.

The launcher decodes its offline bundle and runs finite setup as:

```powershell
bootstrap.ps1 -NoMonitor
```

Only this finite phase writes `bootstrap.log`. It resolves the signed-in user, enables or installs OpenSSH when needed, reconciles the exact session public key, verifies `127.0.0.1:22`, establishes the reverse tunnel, verifies exact process identity, registers SYSTEM idle cleanup, and emits READY.

After successful setup, it starts the read-only monitor outside the log pipeline:

```powershell
bootstrap.ps1 -MonitorOnly
```

The monitor rereads current state, allows bounded same-session PID replacement, and never opens or locks `bootstrap.log`. Rerunning the launcher while an older monitor remains open is supported. Closing either monitor does not remove access.

Logs:

```text
%ProgramData%\cc-remote\sessions\<session-id>\bootstrap.log
%ProgramData%\cc-remote\sessions\<session-id>\tunnel.log
```

### macOS

Send the generated `.command`. The POSIX entry point hands off to Bash before Bash-only
syntax is parsed, requests `sudo`, installs the **bundled self-contained OpenSSH** under
`/usr/local/cc-remote/openssh`, starts an **isolated standalone sshd** on its own
`local_ssh_port` with session-scoped host keys, and builds the reverse tunnel with the
bundled `ssh` client. It never depends on the machine's own openssh programs and does
not touch the system Remote Login service or system sshd.

Logs:

```text
/var/tmp/cc-remote/<session-id>/bootstrap.log
/var/tmp/cc-remote/<session-id>/tunnel.log
```

### Linux

Send the generated `.sh` and run it with root authorization. The bootstrap installs the
**bundled self-contained OpenSSH** under `/opt/cc-remote/openssh`, starts an isolated
standalone sshd on `local_ssh_port` with session-scoped host keys, and builds the
reverse tunnel with the bundled `ssh` client — no dependency on the machine's own
openssh components and no network package download. The system sshd (port 22) is left
untouched before and after the session.

## 5. Register genuine READY

The controlled machine prints READY only after verification:

```text
CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>
```

Paste the complete exact line:

```sh
cc-remote ready 'CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>'
```

The command rejects a relay host different from the configured record and rejects ports outside `1-65535`. Rejection does not rewrite connection artifacts.

## 6. Inspect and connect

```sh
cc-remote show support-session
cc-remote list
cc-remote ssh support-session
```

Or:

```sh
ssh -F ~/.cc-remote/sessions/<session-id>/ssh_config cc-remote-<session-id>
```

The generated configuration uses a per-session `HostKeyAlias` and `UserKnownHostsFile`, and reaches the loopback listener through the relay with `ProxyCommand`/`ssh -W`.

Start with read-only checks such as hostname, current user, and OS version before making authorized changes.

## 7. Cleanup

Preferred controlled-side cleanup:

1. Let the registered idle watcher clean the exact session after inactivity.
2. Or run the extracted session-specific cleanup script.

Then close the operator record:

```sh
cc-remote close support-session
```

Controlled-side cleanup may remove only the exact `cc-remote:<session-id>` key line, stop the exact verified tunnel process, and remove exact-session state. It must not stop, disable, uninstall, restart, or reconfigure shared `sshd`.

The operator CLI removes relay authorization only if it installed it. A manually installed authorization remains an explicit operator responsibility.

## AI prompt for install-and-use

Copy this prompt when another AI/operator should install cc-remote and generate a single reusable launcher from the GitHub Release:

```text
Install and use cc-remote v0.3.0 from GitHub Release. Do not clone source code, do not run go build, and do not rewrite the launcher scripts.

Release page:
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.3.0

First install the operator CLI from exactly one matching runtime archive. Detect this operator machine's OS/architecture, select the single matching block below, run the commands as-is, and stop if SHA256 verification or doctor fails. Do not use GitHub source archives for normal operation. Detection commands: macOS/Linux run `uname -s` and `uname -m`; Windows PowerShell run `$env:PROCESSOR_ARCHITECTURE`. Mapping: Darwin arm64=macOS Apple Silicon, Darwin x86_64=macOS Intel, Linux x86_64=Linux x86_64, Linux aarch64/arm64=Linux ARM64, Windows AMD64=Windows x86_64.

macOS Apple Silicon (Darwin arm64):
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_darwin_arm64_full.zip
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_darwin_arm64_full.zip.sha256
  shasum -a 256 -c cc-remote_v0.3.0_darwin_arm64_full.zip.sha256
  unzip cc-remote_v0.3.0_darwin_arm64_full.zip
  cd cc-remote_v0.3.0_darwin_arm64_full
  ./install.sh
  "$HOME/.local/share/cc-remote/cc-remote" doctor --json

macOS Intel (Darwin x86_64):
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_darwin_amd64_full.zip
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_darwin_amd64_full.zip.sha256
  shasum -a 256 -c cc-remote_v0.3.0_darwin_amd64_full.zip.sha256
  unzip cc-remote_v0.3.0_darwin_amd64_full.zip
  cd cc-remote_v0.3.0_darwin_amd64_full
  ./install.sh
  "$HOME/.local/share/cc-remote/cc-remote" doctor --json

Linux x86_64:
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_linux_amd64_full.tar.gz
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_linux_amd64_full.tar.gz.sha256
  sha256sum -c cc-remote_v0.3.0_linux_amd64_full.tar.gz.sha256
  tar -xzf cc-remote_v0.3.0_linux_amd64_full.tar.gz
  cd cc-remote_v0.3.0_linux_amd64_full
  ./install.sh
  "$HOME/.local/share/cc-remote/cc-remote" doctor --json

Linux ARM64 (aarch64/arm64):
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_linux_arm64_full.tar.gz
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_linux_arm64_full.tar.gz.sha256
  sha256sum -c cc-remote_v0.3.0_linux_arm64_full.tar.gz.sha256
  tar -xzf cc-remote_v0.3.0_linux_arm64_full.tar.gz
  cd cc-remote_v0.3.0_linux_arm64_full
  ./install.sh
  "$HOME/.local/share/cc-remote/cc-remote" doctor --json

Windows x86_64 PowerShell:
  Invoke-WebRequest -Uri 'https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_windows_amd64_full.zip' -OutFile '.\cc-remote_v0.3.0_windows_amd64_full.zip'
  Invoke-WebRequest -Uri 'https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.3.0/cc-remote_v0.3.0_windows_amd64_full.zip.sha256' -OutFile '.\cc-remote_v0.3.0_windows_amd64_full.zip.sha256'
  $Expected = (Get-Content '.\cc-remote_v0.3.0_windows_amd64_full.zip.sha256').Split(' ')[0].ToLowerInvariant()
  $Actual = (Get-FileHash '.\cc-remote_v0.3.0_windows_amd64_full.zip' -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Actual -ne $Expected) { throw "SHA256 mismatch: $Actual" }
  Expand-Archive '.\cc-remote_v0.3.0_windows_amd64_full.zip'
  cd '.\cc-remote_v0.3.0_windows_amd64_full'
  .\install.ps1 -AddToPath
  & "$env:LOCALAPPDATA\Programs\cc-remote\cc-remote.exe" doctor --json

Continue only if doctor JSON has ok=true. If not, stop and report the JSON.

Before configuring relay or creating any session, ask the operator for relay configuration and wait for an explicit answer. Required: public relay host/IP controlled by the operator, public SSH port, dedicated relay user such as cc-tunnel, whether the relay is already prepared, optional administrative SSH alias/destination, and whether relay bootstrap or per-session --install-relay=true is explicitly authorized. If any required relay endpoint info is missing, stop and ask; do not create a session, do not infer values from SSH config, and do not use example relay values.

If administrative SSH access is available and the operator explicitly authorizes relay mutation, run cc-remote relay bootstrap --admin-target <relay-admin-ssh-alias-or-user@host> --host <relay-host> --port <relay-ssh-port> --user cc-tunnel --yes. Do not pass passwords as command-line flags; let SSH/sudo prompt interactively or first create an approved SSH alias/key. For non-default admin ports or identity files that should be reused later, use an SSH alias rather than saving raw options. If the relay host is not prepared and bootstrap is not authorized, run cc-remote init-relay --user cc-tunnel and apply the printed Match User policy on that relay. Keep GatewayPorts no, validate with sudo sshd -t, and reload sshd; prefer reload, not restart.

Save the relay once on the operator machine:
  cc-remote relay set --host <relay-host> --port <relay-ssh-port> --user cc-tunnel
If the operator explicitly provides an administrative SSH destination, include:
  --ssh-host <relay-admin-ssh-alias>

Verify the saved relay profile:
  cc-remote relay show --json
  cc-remote relay doctor --json

Create one single-platform launcher with JSON output. The saved relay profile is reused automatically:
  cc-remote create --json --name <target-name> --platform <windows|macos|linux> --launcher-format <cmd|command|sh> --handoff-mode embedded --target-user auto --idle-timeout 12h --max-lifetime 12h
Platform launcher formats: Windows=cmd, macOS=command, Linux=sh.

By default create does not modify the relay. Install the exact relay_authorized_key_line from create --json into the relay user's authorized_keys, preserving unrelated keys. Only use --install-relay=true when the operator explicitly authorizes that relay mutation for this session.
Send only files listed in share_with_recipient to the authorized controlled machine. Do not send files listed in operator_only.
Never print, copy, upload, or paste private-key bodies. Key information means operator-side private-key paths and public-key fingerprints only.
Accept only the complete READY line emitted by the controlled launcher after verification: CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>. Never invent or construct READY.
Register READY on the operator machine: cc-remote ready 'CC_REMOTE_READY ...'
Start with read-only checks only, such as hostname, current user, and OS version. Do not modify the controlled machine until that exact work is authorized.
```

## Artifact handling

Generated launchers and bundles contain session tunnel credentials. Operator session directories contain private keys. Never include `~/.cc-remote`, generated `.cmd`/`.command`/`.sh` launchers, records, logs, state, known-host files, or connection metadata in a reusable source archive.
