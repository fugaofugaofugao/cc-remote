# cc-remote 中文说明

`cc-remote` 用于授权远程支持：在受控 Windows、macOS 或 Linux 电脑上运行一次性启动器，临时启用/复用本机 SSH，通过你自己控制的公网 Linux/OpenSSH 中继建立受限反向 SSH 隧道，然后输出经过验证的 `CC_REMOTE_READY` 行。操作端使用每次会话新生成的密钥连接。

这个项目只用于经过同意的维护/运维，不是持久化或无人值守访问工具。

## 安全模型

- 你必须自己提供并控制公网 Linux/OpenSSH 中继；cc-remote 不提供云中继服务。
- 反向监听只绑定在中继回环地址：`127.0.0.1:<port>`。
- 中继使用专用账号，通常是 `cc-tunnel`，并用 `permitopen`、`permitlisten`、`no-pty`、禁用 X11 等方式限制。
- 每次会话都会新生成 target/tunnel Ed25519 密钥。
- 私钥只保留在操作端电脑。连接文件只包含私钥路径和公钥指纹，不包含私钥正文。
- 只有在本机 SSH、精确反向隧道进程和清理任务都验证成功后，受控端才会输出 READY。
- 清理只匹配本次会话 marker 和记录的隧道进程。共享 `sshd` 不属于会话，不能随意停止/卸载/重配。
- 默认不会修改中继。自动安装中继授权必须每次显式传入 `--install-relay=true`，并提供单独的中继管理 SSH 入口。

使用前建议阅读 [SECURITY.md](SECURITY.md)。

## 1. 从 Release 安装操作端 CLI

正常使用请安装完整 runtime archive，不要 clone 源码、不要 `go build`、不要用 GitHub 自动生成的 Source code 压缩包。

Release 页面：

```text
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.2.4
```

按操作端系统/架构下载对应 runtime archive 和 `.sha256`：

| 操作端系统/架构 | Runtime archive | SHA256 文件 |
| --- | --- | --- |
| Windows x86_64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_windows_amd64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_windows_amd64_full.zip.sha256 |
| macOS Apple Silicon | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_arm64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_arm64_full.zip.sha256 |
| macOS Intel | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_amd64_full.zip | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_amd64_full.zip.sha256 |
| Linux x86_64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_amd64_full.tar.gz | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_amd64_full.tar.gz.sha256 |
| Linux ARM64 | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_arm64_full.tar.gz | https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_arm64_full.tar.gz.sha256 |

macOS Apple Silicon 示例：

```sh
curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_arm64_full.zip
curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_arm64_full.zip.sha256
shasum -a 256 -c cc-remote_v0.2.4_darwin_arm64_full.zip.sha256
unzip cc-remote_v0.2.4_darwin_arm64_full.zip
cd cc-remote_v0.2.4_darwin_arm64_full
./install.sh
"$HOME/.local/share/cc-remote/cc-remote" doctor --json
```

Linux x86_64 示例：

```sh
curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_amd64_full.tar.gz
curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_amd64_full.tar.gz.sha256
sha256sum -c cc-remote_v0.2.4_linux_amd64_full.tar.gz.sha256
tar -xzf cc-remote_v0.2.4_linux_amd64_full.tar.gz
cd cc-remote_v0.2.4_linux_amd64_full
./install.sh
"$HOME/.local/share/cc-remote/cc-remote" doctor --json
```

Windows PowerShell 示例：

```powershell
Invoke-WebRequest -Uri 'https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_windows_amd64_full.zip' -OutFile '.\cc-remote_v0.2.4_windows_amd64_full.zip'
Invoke-WebRequest -Uri 'https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_windows_amd64_full.zip.sha256' -OutFile '.\cc-remote_v0.2.4_windows_amd64_full.zip.sha256'
$Expected = (Get-Content '.\cc-remote_v0.2.4_windows_amd64_full.zip.sha256').Split(' ')[0].ToLowerInvariant()
$Actual = (Get-FileHash '.\cc-remote_v0.2.4_windows_amd64_full.zip' -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Actual -ne $Expected) { throw "SHA256 mismatch: $Actual" }
Expand-Archive '.\cc-remote_v0.2.4_windows_amd64_full.zip'
cd '.\cc-remote_v0.2.4_windows_amd64_full'
.\install.ps1 -AddToPath
& "$env:LOCALAPPDATA\Programs\cc-remote\cc-remote.exe" doctor --json
```

安装器只把 CLI、`bootstrap/`、`payloads/` 和文档复制到用户本地目录。不会创建会话、密钥、中继授权、系统服务或 `~/.cc-remote` 会话记录。

## 2. 一次性配置中继

你需要一台自己控制的公网 Linux/OpenSSH 服务器作为中继。中继必须保持反向监听只在 loopback，不要开放公网监听。建议使用专用账号 `cc-tunnel`。

在中继上准备账号和 sshd 策略前，可以先打印参考配置：

```sh
cc-remote init-relay --user cc-tunnel
```

典型 sshd 配置块：

```sshconfig
Match User cc-tunnel
  PasswordAuthentication no
  PermitTTY no
  X11Forwarding no
  AllowTcpForwarding yes
  GatewayPorts no
```

修改后验证并 reload：

```sh
sudo sshd -t
sudo systemctl reload sshd
```

如果系统服务名不同，用系统支持的 reload 命令。优先 reload，不要随意 restart 共享 sshd。

如果操作端已经有中继的管理 SSH 权限，并且用户明确授权 AI 修改这台中继，可以让 CLI 自动 bootstrap：

```sh
cc-remote relay bootstrap \
  --admin-target root@relay.example.test \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel \
  --yes
```

如果管理 SSH 使用非默认端口或密钥，先创建 SSH alias，再把 alias 作为 `--admin-target`，这样保存的默认配置以后也能用于 `--install-relay=true`：

```sshconfig
Host support-relay-admin
  HostName relay.example.test
  Port 39022
  User root
  IdentityFile ~/.ssh/relay_admin_ed25519
```

```sh
cc-remote relay bootstrap \
  --admin-target support-relay-admin \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel \
  --yes
```

直接用 `--ssh-port` 或 `--identity-file` bootstrap 时只能加 `--no-save`，否则后续 `--install-relay=true` 不知道这些原始 SSH 选项。这个命令会通过 SSH 登录中继，创建/校验 `cc-tunnel`，追加安全的 `Match User` 策略，执行 `sshd -t`，reload sshd，并保存默认中继配置。不要把密码作为命令行参数传入；如果只能密码登录，让 SSH/sudo 交互式提示，或先按用户批准的方式创建 SSH alias/key。密码不能写入 `~/.cc-remote/config.json`、shell history、日志或文档。

也可以手动在操作端电脑上保存默认中继配置一次：

```sh
cc-remote relay set \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel
```

如果你有中继管理 SSH alias，并希望以后可以显式自动安装每次会话的授权行，也可以保存：

```sh
cc-remote relay set \
  --host relay.example.test \
  --port 22 \
  --user cc-tunnel \
  --ssh-host support-relay-admin
```

检查保存结果：

```sh
cc-remote relay show --json
cc-remote relay doctor --json
```

配置保存在：

```text
~/.cc-remote/config.json
```

权限为 `0600`。这里只保存中继地址、端口、用户和可选管理 alias，不保存任何私钥正文。每次创建会话仍然会生成全新的密钥和全新的受限 `authorized_keys` 行。

## 3. 创建一次性远控启动器

完成 `cc-remote relay set` 后，后续创建会话不需要重复写中继参数：

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

平台和启动器格式：

- Windows：`--platform windows --launcher-format cmd`
- macOS：`--platform macos --launcher-format command`
- Linux：`--platform linux --launcher-format sh`

默认情况下，`create` 不会修改中继。它会在 JSON 输出中给出一个 `relay_authorized_key_line`，你需要把这一整行追加到中继专用用户的 `authorized_keys`，并保留其他无关 key。

如果你明确授权 CLI 自动给中继安装本次会话授权行，可以每次显式加：

```sh
cc-remote create --json \
  --name support-session \
  --platform windows \
  --launcher-format cmd \
  --install-relay=true
```

`--install-relay=true` 不会被记住为默认值，每次修改中继都必须显式指定。

只把 JSON 里 `share_with_recipient` 列出的文件发给受控端。不要发送 `operator_only` 里的文件。

> 注意：生成的 `.cmd`、`.command`、`.sh` 启动器包含本次会话的隧道私钥。只能发给被授权的受控端操作者，不能提交到 GitHub、不能上传、不能粘贴到 AI 聊天里，也不能作为可复用源码分发。

## 4. 受控端运行启动器

### Windows

把生成的 `.cmd` 发给授权的受控端用户。对方双击运行并同意 UAC。

Windows 启动器会运行两个阶段：

1. `bootstrap.ps1 -NoMonitor`：有限安装/配置阶段，负责启用或安装 OpenSSH、写入本次会话公钥、验证本机 SSH、建立反向隧道、注册空闲清理、输出 READY。
2. `bootstrap.ps1 -MonitorOnly`：只读监控阶段，不占用 `bootstrap.log`，可以支持重复运行启动器。

日志位置：

```text
%ProgramData%\cc-remote\sessions\<session-id>\bootstrap.log
%ProgramData%\cc-remote\sessions\<session-id>\tunnel.log
```

### macOS

发送生成的 `.command`。对方双击运行，输入一次 Mac 登录密码。启动器会启用并验证 Remote Login，写入本次会话公钥，然后启动受限反向隧道。

日志位置：

```text
/var/tmp/cc-remote/<session-id>/bootstrap.log
/var/tmp/cc-remote/<session-id>/tunnel.log
```

### Linux

发送生成的 `.sh`，受控端需要 root 授权运行。如果没有 `sshd`，只允许使用准备好的兼容离线包；脚本不会静默联网下载。

## 5. 注册 READY 并连接

受控端只有在验证完成后才会输出：

```text
CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>
```

操作端只接受完整原样 READY 行，不要自己拼：

```sh
cc-remote ready 'CC_REMOTE_READY <session-id> <target-user> <relay-host> <remote-port>'
```

查看并连接：

```sh
cc-remote show support-session
cc-remote list
cc-remote ssh support-session
```

也可以用生成的 SSH config：

```sh
ssh -F ~/.cc-remote/sessions/<session-id>/ssh_config cc-remote-<session-id>
```

连接后先做只读检查，例如：

```sh
hostname
whoami
uname -a
```

未经明确授权，不要修改受控端。

## 6. 清理

优先让已注册的 idle watcher 在空闲后自动清理。也可以在受控端运行解包出来的本次会话专用 cleanup 脚本。

操作端关闭记录：

```sh
cc-remote close support-session
```

受控端清理只能删除本次会话精确 marker `cc-remote:<session-id>` 的 key 行、停止经过验证的本次会话隧道进程、删除本次会话状态。不能停止、禁用、卸载、重启或重配共享 `sshd`。

如果本次中继授权是手动安装的，手动清理时也只删除那一条精确 marker。不要删除无关 key。

## 给朋友/AI 的安装提示词

如果朋友是在他的电脑上作为“操作端”安装 cc-remote，可以把下面提示词发给他的 AI：

```text
Install and use cc-remote v0.2.4 from GitHub Release. Do not clone source code, do not run go build, and do not rewrite the launcher scripts.

Release page:
https://github.com/fugaofugaofugao/cc-remote/releases/tag/v0.2.4

First install the operator CLI from exactly one matching runtime archive. Detect this operator machine's OS/architecture, select the single matching block below, run the commands as-is, and stop if SHA256 verification or doctor fails. Do not use GitHub source archives for normal operation. Detection commands: macOS/Linux run `uname -s` and `uname -m`; Windows PowerShell run `$env:PROCESSOR_ARCHITECTURE`. Mapping: Darwin arm64=macOS Apple Silicon, Darwin x86_64=macOS Intel, Linux x86_64=Linux x86_64, Linux aarch64/arm64=Linux ARM64, Windows AMD64=Windows x86_64.

macOS Apple Silicon (Darwin arm64):
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_arm64_full.zip
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_arm64_full.zip.sha256
  shasum -a 256 -c cc-remote_v0.2.4_darwin_arm64_full.zip.sha256
  unzip cc-remote_v0.2.4_darwin_arm64_full.zip
  cd cc-remote_v0.2.4_darwin_arm64_full
  ./install.sh
  "$HOME/.local/share/cc-remote/cc-remote" doctor --json

macOS Intel (Darwin x86_64):
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_amd64_full.zip
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_darwin_amd64_full.zip.sha256
  shasum -a 256 -c cc-remote_v0.2.4_darwin_amd64_full.zip.sha256
  unzip cc-remote_v0.2.4_darwin_amd64_full.zip
  cd cc-remote_v0.2.4_darwin_amd64_full
  ./install.sh
  "$HOME/.local/share/cc-remote/cc-remote" doctor --json

Linux x86_64:
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_amd64_full.tar.gz
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_amd64_full.tar.gz.sha256
  sha256sum -c cc-remote_v0.2.4_linux_amd64_full.tar.gz.sha256
  tar -xzf cc-remote_v0.2.4_linux_amd64_full.tar.gz
  cd cc-remote_v0.2.4_linux_amd64_full
  ./install.sh
  "$HOME/.local/share/cc-remote/cc-remote" doctor --json

Linux ARM64 (aarch64/arm64):
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_arm64_full.tar.gz
  curl -L -O https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_linux_arm64_full.tar.gz.sha256
  sha256sum -c cc-remote_v0.2.4_linux_arm64_full.tar.gz.sha256
  tar -xzf cc-remote_v0.2.4_linux_arm64_full.tar.gz
  cd cc-remote_v0.2.4_linux_arm64_full
  ./install.sh
  "$HOME/.local/share/cc-remote/cc-remote" doctor --json

Windows x86_64 PowerShell:
  Invoke-WebRequest -Uri 'https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_windows_amd64_full.zip' -OutFile '.\cc-remote_v0.2.4_windows_amd64_full.zip'
  Invoke-WebRequest -Uri 'https://github.com/fugaofugaofugao/cc-remote/releases/download/v0.2.4/cc-remote_v0.2.4_windows_amd64_full.zip.sha256' -OutFile '.\cc-remote_v0.2.4_windows_amd64_full.zip.sha256'
  $Expected = (Get-Content '.\cc-remote_v0.2.4_windows_amd64_full.zip.sha256').Split(' ')[0].ToLowerInvariant()
  $Actual = (Get-FileHash '.\cc-remote_v0.2.4_windows_amd64_full.zip' -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Actual -ne $Expected) { throw "SHA256 mismatch: $Actual" }
  Expand-Archive '.\cc-remote_v0.2.4_windows_amd64_full.zip'
  cd '.\cc-remote_v0.2.4_windows_amd64_full'
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

如果朋友只是“受控端”，他不需要安装 CLI。操作端生成 `.cmd`、`.command` 或 `.sh` 后，只把启动器发给他运行即可。
