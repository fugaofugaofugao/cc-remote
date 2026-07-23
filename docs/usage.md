# Usage workflow

## 1. Install the operator CLI

For normal install-and-use operation, install a full runtime archive from the
GitHub Release instead of cloning source code or running `go build`:

```text
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.2.0
```

After extracting a runtime archive, run the included installer and verify with
`cc-remote doctor --json`. The installer is user-local and does not create
sessions, keys, relay authorization, services, or `~/.cc-remote` records.

For source development only:

```sh
./scripts/build.sh
```

Use the installed `cc-remote` below, or during development use `./dist/cc-remote`.

## 2. Prepare your public relay

Configure a Linux/OpenSSH relay you administer. Keep reverse forwarding loopback-only and use a dedicated `cc-tunnel` account. See [relay.md](relay.md).

## 3. Create a support session

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

Replace the reserved example hostname with your relay. `--platform` accepts `windows`, `macos`, `linux`, or `all`.

The command creates fresh target and tunnel key pairs and writes operator artifacts under `~/.cc-remote/`. By default it prints a restricted relay authorization instead of changing the relay. Install that public line before the recipient launches the bundle.

Automatic installation is opt-in only:

```sh
./dist/cc-remote create \
  --name support-session \
  --platform windows \
  --relay-host relay.example.test \
  --relay-ssh-host support-relay \
  --install-relay=true
```

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
./dist/cc-remote ready 'CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>'
```

The command rejects a relay host different from the configured record and rejects ports outside `1-65535`. Rejection does not rewrite connection artifacts.

## 6. Inspect and connect

```sh
./dist/cc-remote show support-session
./dist/cc-remote list
./dist/cc-remote ssh support-session
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
./dist/cc-remote close support-session
```

Controlled-side cleanup may remove only the exact `cc-remote:<session-id>` key line, stop the exact verified tunnel process, and remove exact-session state. It must not stop, disable, uninstall, restart, or reconfigure shared `sshd`.

The operator CLI removes relay authorization only if it installed it. A manually installed authorization remains an explicit operator responsibility.

## AI prompt for install-and-use

Copy this prompt when another AI/operator should install cc-remote and generate a
single reusable launcher from the GitHub Release:

```text
Install and use cc-remote v0.2.0 from GitHub Release. Do not clone source code,
do not run go build, and do not rewrite the launcher scripts.

Release:
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.2.0

1. Detect the operator machine OS/architecture and download the matching full
   runtime archive plus its .sha256 file:
   - Windows x86_64: cc-remote_v0.2.0_windows_amd64_full.zip
   - macOS Apple Silicon: cc-remote_v0.2.0_darwin_arm64_full.zip
   - macOS Intel: cc-remote_v0.2.0_darwin_amd64_full.zip
   - Linux x86_64: cc-remote_v0.2.0_linux_amd64_full.tar.gz
   - Linux ARM64: cc-remote_v0.2.0_linux_arm64_full.tar.gz
2. Verify SHA256 before extraction. Stop if verification fails.
3. Extract and run the included installer:
   - macOS/Linux: ./install.sh
   - Windows: .\install.ps1 -AddToPath
4. Verify the installed binary by deterministic path, not by guessing PATH:
   - macOS/Linux: "$HOME/.local/share/cc-remote/cc-remote" doctor --json
   - Windows: & "$env:LOCALAPPDATA\Programs\cc-remote\cc-remote.exe" doctor --json
5. Continue only if doctor JSON has ok=true. If not, stop and report the JSON.
6. Create one single-platform launcher with JSON output:
   cc-remote create --json \
     --name <target-name> \
     --platform <windows|macos|linux> \
     --launcher-format <cmd|command|sh> \
     --handoff-mode embedded \
     --relay-host <relay-host> \
     --relay-port <relay-ssh-port> \
     --relay-user cc-tunnel \
     --target-user auto \
     --idle-timeout 12h \
     --max-lifetime 12h

   Platform launcher formats:
   - Windows: cmd
   - macOS: command
   - Linux: sh
7. Send only files listed in share_with_recipient to the authorized controlled
   machine. Do not send files listed in operator_only.
8. Never print, copy, upload, or paste private-key bodies. Key information means
   operator-side private-key paths and public-key fingerprints only.
9. Accept only the complete READY line emitted by the controlled launcher after
   verification:
   CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>
   Never invent or construct READY.
10. Register READY on the operator machine:
    cc-remote ready 'CC_REMOTE_READY ...'
11. Start with read-only checks only, such as hostname, current user, and OS
    version. Do not modify the controlled machine until that exact work is
    authorized.
```

## Artifact handling

Generated launchers and bundles contain session tunnel credentials. Operator session directories contain private keys. Never include `~/.cc-remote`, generated `.cmd`/`.command`/`.sh` launchers, records, logs, state, known-host files, or connection metadata in a reusable source archive.
