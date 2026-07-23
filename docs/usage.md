# Usage workflow

## 1. Install the operator CLI

For normal install-and-use operation, install a full runtime archive from the GitHub Release instead of cloning source code or running `go build`.

Release page:

```text
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.2.2
```

Direct runtime download links:

| Operator OS / arch | Runtime archive | SHA256 file |
| --- | --- | --- |
| Windows x86_64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_windows_amd64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_windows_amd64_full.zip.sha256 |
| macOS Apple Silicon | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_darwin_arm64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_darwin_arm64_full.zip.sha256 |
| macOS Intel | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_darwin_amd64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_darwin_amd64_full.zip.sha256 |
| Linux x86_64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_linux_amd64_full.tar.gz | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_linux_amd64_full.tar.gz.sha256 |
| Linux ARM64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_linux_arm64_full.tar.gz | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_linux_arm64_full.tar.gz.sha256 |

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

Send the generated `.command`. The POSIX entry point hands off to Bash before Bash-only syntax is parsed, requests `sudo`, enables and verifies Remote Login, installs the exact session public key, and starts the restricted tunnel.

Logs:

```text
/var/tmp/cc-remote/<session-id>/bootstrap.log
/var/tmp/cc-remote/<session-id>/tunnel.log
```

### Linux

Send the generated `.sh` and run it with root authorization. If `sshd` is absent, only a compatible prepared offline package set may be used; the bootstrap fails rather than silently downloading packages.

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
Install and use cc-remote v0.2.2 from GitHub Release. Do not clone source code, do not run go build, and do not rewrite the launcher scripts.

Release page:
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.2.2

Download exactly one matching runtime archive plus its .sha256 file:
- Windows x86_64:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_windows_amd64_full.zip
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_windows_amd64_full.zip.sha256
- macOS Apple Silicon:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_darwin_arm64_full.zip
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_darwin_arm64_full.zip.sha256
- macOS Intel:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_darwin_amd64_full.zip
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_darwin_amd64_full.zip.sha256
- Linux x86_64:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_linux_amd64_full.tar.gz
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_linux_amd64_full.tar.gz.sha256
- Linux ARM64:
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_linux_arm64_full.tar.gz
  https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.2/cc-remote_v0.2.2_linux_arm64_full.tar.gz.sha256

Steps:
1. Verify SHA256 before extraction. Stop if verification fails.
2. Extract and run the included installer: macOS/Linux ./install.sh; Windows .\install.ps1 -AddToPath.
3. Verify the installed binary by deterministic path: macOS/Linux "$HOME/.local/share/cc-remote/cc-remote" doctor --json; Windows & "$env:LOCALAPPDATA\Programs\cc-remote\cc-remote.exe" doctor --json.
4. Continue only if doctor JSON has ok=true. If not, stop and report the JSON.
5. Confirm there is a public Linux/OpenSSH relay server controlled by the operator. If administrative SSH access is available and the operator explicitly authorizes relay mutation, run cc-remote relay bootstrap --admin-target <relay-admin-ssh-alias-or-user@host> --host <relay-host> --port <relay-ssh-port> --user cc-tunnel --yes. Do not pass passwords as command-line flags; let SSH/sudo prompt interactively or first create an approved SSH alias/key. For non-default admin ports or identity files that should be reused later, use an SSH alias rather than saving raw options.
6. If automatic bootstrap is not used, run cc-remote init-relay --user cc-tunnel and apply the printed Match User policy on that relay. Keep GatewayPorts no, validate with sudo sshd -t, and reload sshd; prefer reload, not restart.
7. Save the relay once unless bootstrap already saved it: cc-remote relay set --host <relay-host> --port <relay-ssh-port> --user cc-tunnel. If the operator explicitly provides an administrative SSH alias, include --ssh-host <relay-admin-ssh-alias>.
8. Verify: cc-remote relay show --json and cc-remote relay doctor --json.
9. Create one single-platform launcher with JSON output. The saved relay profile is reused automatically:
   cc-remote create --json --name <target-name> --platform <windows|macos|linux> --launcher-format <cmd|command|sh> --handoff-mode embedded --target-user auto --idle-timeout 12h --max-lifetime 12h
10. By default create does not modify the relay. Install the exact relay_authorized_key_line from create --json into the relay user's authorized_keys, preserving unrelated keys. Only use --install-relay=true when the operator explicitly authorizes that relay mutation for this session.
11. Send only files listed in share_with_recipient to the authorized controlled machine. Do not send files listed in operator_only.
12. Never print, copy, upload, or paste private-key bodies. Key information means operator-side private-key paths and public-key fingerprints only.
13. Accept only the complete READY line emitted by the controlled launcher after verification: CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>. Never invent or construct READY.
14. Register READY on the operator machine: cc-remote ready 'CC_REMOTE_READY ...'
15. Start with read-only checks only, such as hostname, current user, and OS version. Do not modify the controlled machine until that exact work is authorized.
```

## Artifact handling

Generated launchers and bundles contain session tunnel credentials. Operator session directories contain private keys. Never include `~/.cc-remote`, generated `.cmd`/`.command`/`.sh` launchers, records, logs, state, known-host files, or connection metadata in a reusable source archive.
