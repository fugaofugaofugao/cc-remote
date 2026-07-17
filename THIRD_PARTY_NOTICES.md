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
