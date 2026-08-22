macOS built-in/standalone OpenSSH

cc-remote ships a self-contained OpenSSH payload for macOS:
  payloads/macos/openssh-<arch>-9.8p1.tar.gz

It is built (not installed from the system) by:
  scripts/prepare-unix-openssh.sh --os darwin --arch arm64|x86_64

Behavior boundary (macOS):
  - The bundled sshd runs as an isolated standalone daemon on its own port and its
    own session-scoped host keys, under /var/tmp/cc-remote/<session>/sshd.
  - It writes to its own isolated authorized_keys (targeting the session's key),
    isolated sshd_config, and logs.
  - It does NOT touch the system sshd, the launchd Remote Login service, the system
    OpenSSH binaries, or the system configuration. System "Remote Login" state is
    left untouched before and after a session.
  - The bundled ssh client (bin/ssh) builds the reverse tunnel to the relay.
  - Cleanup stops only the session's standalone sshd and tunnel process.

The archive is a self-contained OpenSSH 9.8p1 + OpenSSL 3 build that depends only on
macOS's base system runtime (libSystem), never on the OS's own openssh programs.
