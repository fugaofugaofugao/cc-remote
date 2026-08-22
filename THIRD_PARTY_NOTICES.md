# Third-party notices

## PowerShell/Win32-OpenSSH

The self-contained release includes the following unmodified upstream artifact:

| Field | Value |
| --- | --- |
| Project | PowerShell/Win32-OpenSSH |
| Upstream | https://github.com/PowerShell/Win32-OpenSSH |
| Version | `10.0.0.0p2-Preview` |
| Artifact | `OpenSSH-Win64.zip` |
| Repository path | `payloads/windows/openssh-win64.zip` |
| Source URL | https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip |
| SHA-256 | `23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5` |

The nested archive contains its upstream licensing material at:

```text
OpenSSH-Win64/LICENSE.txt
OpenSSH-Win64/NOTICE.txt
```

Those files and all upstream SPDX/license metadata must remain intact. The cc-remote MIT License applies only to cc-remote project source and does not replace third-party terms.

The source-only release omits this binary archive. Use `scripts/prepare-windows-openssh.sh` to retrieve and verify the pinned artifact when Windows launcher generation is required.

## OpenSSH (portable) / OpenSSL / zlib (macOS + Linux)

The macOS and Linux self-contained payloads (`payloads/{macos,linux}/openssh-*.tar.gz`)
are built from pinned upstream sources by `scripts/prepare-unix-openssh.sh`:

| Component | Version | Source | SHA-256 |
| --- | --- | --- | --- |
| OpenSSH (portable) | `9.8p1` | https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.8p1.tar.gz | `dd8bd002a379b5d499dfb050dd1fa9af8029e80461f4bb6c523c49973f5a39f3` |
| OpenSSL | `3.0.15` | https://www.openssl.org/source/openssl-3.0.15.tar.gz | `23c666d0edf20f14249b3d8f0368acaee9ab585b09e1de82107c66e1f3ec9533` |
| zlib (Linux only) | `1.3.1` | https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz | `9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23` |

Each archive carries its upstream `LICENSE` (and, where applicable, copyright/permission
notices) unchanged at `openssh/LICENSE`. OpenSSH portable is dual-licensed BSD-2-Clause /
GPL-2.0; OpenSSL is Apache-2.0; zlib is zlib license. These terms are preserved inside the
payload and are not replaced by the cc-remote MIT License. The macOS build links Homebrew's
OpenSSL `@3` (its license applies to the linked build as well).

The source-only release omits these archives. Use `scripts/prepare-unix-openssh.sh` to build
and verify the pinned payloads when macOS/Linux launcher generation is required.
