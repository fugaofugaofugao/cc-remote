# Offline payloads

cc-remote can embed verified installers so a controlled machine does not need an uncontrolled network download during support.

## Windows Win32-OpenSSH

Windows and `all` launcher generation require:

```text
payloads/windows/openssh-win64.zip
```

Pinned upstream artifact:

- Project: PowerShell/Win32-OpenSSH
- Version: `10.0.0.0p2-Preview`
- Source: `https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip`
- SHA-256: `23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5`

Verify locally:

```sh
shasum -a 256 payloads/windows/openssh-win64.zip
```

Refresh only with:

```sh
./scripts/prepare-windows-openssh.sh
```

The script downloads to a temporary file, verifies the pinned digest, and replaces the payload only on success. Launcher generation also validates the digest and fails closed when the payload is absent or different.

The upstream archive is included unmodified. Its `OpenSSH-Win64/LICENSE.txt` and `OpenSSH-Win64/NOTICE.txt` remain inside the ZIP. See the repository's [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

When Windows lacks `sshd`, the bootstrap extracts the verified archive under the session's controlled ProgramData area, installs the bundled server, and uses the bundled `ssh.exe` for the reverse tunnel. No Windows Update or recipient-side download is required.

## Source-only distribution

The source-only release intentionally omits `payloads/windows/openssh-win64.zip`. Recipients who need Windows launcher generation must run the preparation script and verify the expected digest before use. macOS and Linux source workflows do not require this ZIP.

## Linux

Linux packages are distribution and release specific. Prepare them in a matching environment and place complete sets under:

```text
payloads/linux/debian/*.deb
payloads/linux/rhel/*.rpm
```

Do not mix versions or distributions. Preserve package signatures, licenses, notices, and provenance. If installed `sshd` is absent and no compatible offline package set exists, the bootstrap exits rather than silently using a network repository.

## macOS

macOS includes OpenSSH Server. No third-party OpenSSH payload is required.
