# Offline payloads

cc-remote embeds a **self-contained OpenSSH** for every supported OS so a controlled
machine can run a local sshd and build the reverse tunnel **without depending on its
own system openssh components** — whether the CPU is ARM or x86.

Each payload is built from pinned OSS sources by a `prepare-*-openssh.sh` script and
shipped inside the launcher bundle. The bootstrap verifies the exact embedded bytes via
the manifest before use.

| Platform | Payload archive | Built by | Status |
|---|---|---|---|
| Windows (x86_64) | `payloads/windows/openssh-win64.zip` | `prepare-windows-openssh.sh` (download, pinned) | included |
| macOS arm64 | `payloads/macos/openssh-darwin-arm64-9.8p1.tar.gz` | `prepare-unix-openssh.sh --os darwin --arch arm64` | included |
| macOS x86_64 | `payloads/macos/openssh-darwin-x86_64-9.8p1.tar.gz` | `prepare-unix-openssh.sh --os darwin --arch x86_64` (Intel CI runner) | CI-built |
| Linux arm64 | `payloads/linux/openssh-linux-arm64-9.8p1.tar.gz` | `prepare-unix-openssh.sh --os linux --arch arm64` | included |
| Linux x86_64 | `payloads/linux/openssh-linux-x86_64-9.8p1.tar.gz` | `prepare-unix-openssh.sh --os linux --arch x86_64` | included |

Pinned digests (compiled once, then pinned):

```text
windows/openssh-win64.zip                   23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5
macos/openssh-darwin-arm64-9.8p1.tar.gz     63226db97f12d36fc720b9e5e7304a509907df5ff08b7aa3917c2f96fe7db249
macos/openssh-darwin-x86_64-9.8p1.tar.gz    509542271d56c033f33816306c9fe74e037595a8177e7a8b12ac33f5544d2a9d
linux/openssh-linux-arm64-9.8p1.tar.gz      529a6f97330490754454383608987c888274602602d70a36ddd2617e7291654a
linux/openssh-linux-x86_64-9.8p1.tar.gz     8c322411f4023424a2ba22e06694c3634486c115c964dadd2975bdb34da7b74f
```

All payloads skip the source-only tree (so `test.sh` skips their digest checks there);
the digests are pinned and verified once the payload archives are built.

## Windows (Win32-OpenSSH)

Windows and `all` launcher generation require:

```text
payloads/windows/openssh-win64.zip
```

Pinned upstream artifact:

- Project: PowerShell/Win32-OpenSSH
- Version: `10.0.0.0p2-Preview`
- Source: `https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip`
- SHA-256: `23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5`

Verify locally: `shasum -a 256 payloads/windows/openssh-win64.zip`. Refresh only with
`./scripts/prepare-windows-openssh.sh`, which downloads, verifies the pinned digest, and
replaces the payload only on success. Generation validates the digest and fails closed
when absent or different. The upstream archive is included unmodified; its
`OpenSSH-Win64/LICENSE.txt` / `NOTICE.txt` remain inside. When Windows lacks `sshd`, the
bootstrap extracts the verified archive under the session's controlled ProgramData area,
installs the bundled server, and uses the bundled `ssh.exe` for the reverse tunnel.

## macOS (bundled standalone sshd)

macOS and Linux use `prepare-unix-openssh.sh`, which downloads pinned OpenSSH 9.8p1 +
OpenSSL 3.0.15 + zlib 1.3.1 sources and builds a self-contained
`openssh-<os>-<arch>-9.8p1.tar.gz` in-tree (no `make install`).

```sh
./scripts/prepare-unix-openssh.sh --os darwin --arch arm64
./scripts/prepare-unix-openssh.sh --os darwin --arch x86_64   # on an Intel runner
```

The macOS archive is built against Homebrew OpenSSL `@3` and links only macOS's base
system runtime (libSystem) — it never depends on the OS's own sshd/ssh programs.

**macOS behavior boundary:** the bundled `sshd` runs as an isolated standalone daemon on
its own port (`local_ssh_port`) and its own session-scoped host keys, writes to its own
isolated `authorized_keys` / `sshd_config` / logs under `/var/tmp/cc-remote/<session>/`,
and does **not** touch the system sshd, launchd Remote Login service, system OpenSSH
binaries, or system configuration. Cleanup stops only the session's standalone sshd and
tunnel. See `payloads/macos/README-builtin-sshd.txt`.

## Linux (bundled standalone sshd)

```sh
./scripts/prepare-unix-openssh.sh --os linux --arch arm64
./scripts/prepare-unix-openssh.sh --os linux --arch x86_64
```

The Linux archive statically links OpenSSL/zlib and depends only on the base C runtime
(glibc), never on the machine's own sshd/ssh. The bundled `sshd` runs standalone on
`local_ssh_port` with session-scoped host keys and isolated authorized_keys under
`/var/tmp/cc-remote/<session>/`; the system sshd (port 22) and its service are left
untouched before and after a session.

For Linux and macOS the bootstrap:
1. installs the verified payload under a fixed prefix (`/opt/cc-remote/openssh` on
   Linux, `/usr/local/cc-remote/openssh` on macOS) only when its digest matches,
2. generates session host keys and starts the bundled standalone `sshd` on
   `local_ssh_port`,
3. builds the reverse tunnel with the bundled `bin/ssh`.

## Source-only distribution

The source-only release intentionally omits **all** payload archives
(`payloads/windows/openssh-win64.zip` and every `payloads/{macos,linux}/openssh-*.tar.gz`).
Recipients must run the matching `prepare-*-openssh.sh` script and verify the expected
digest before generating launchers.
