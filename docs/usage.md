# Usage workflow

## 1. Build the operator CLI

```sh
./scripts/build.sh
```

Use `./dist/cc-remote` below, or substitute `go run ./cmd/cc-remote`.

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

## Artifact handling

Generated launchers and bundles contain session tunnel credentials. Operator session directories contain private keys. Never include `~/.cc-remote`, generated `.cmd`/`.command`/`.sh` launchers, records, logs, state, known-host files, or connection metadata in a reusable source archive.
