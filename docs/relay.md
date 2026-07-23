# Configure a relay you control

cc-remote does not include or depend on a cloud provider. You must supply a public Linux host running OpenSSH that is reachable by both the operator and the controlled machine.

## Threat boundary

The relay carries SSH traffic but must not expose a target listener publicly. Keep:

```sshconfig
GatewayPorts no
```

Each reverse listener is requested as `127.0.0.1:<port>` and is reachable by the operator only through the relay account and `ssh -W` proxy path.

Use a dedicated account, normally `cc-tunnel`. Do not reuse a personal administrator account.

## AI prompt for relay setup

Copy this prompt when an AI/operator needs to prepare the relay before creating a
cc-remote launcher:

```text
Prepare a cc-remote relay on a public Linux/OpenSSH server that the operator
controls. Do not use a third-party or production server unless the operator has
explicitly authorized this exact relay host.

Required inputs:
- Relay administrative SSH destination, for example root@relay.example.test or a
  configured SSH alias.
- Public relay endpoint that controlled machines will dial, for example
  relay.example.test.
- Public relay SSH port, for example 22 or 39022.
- Dedicated relay user, normally cc-tunnel.

Steps:
1. Run locally: cc-remote init-relay --user cc-tunnel
2. Review the printed commands before applying them.
3. On the relay, create/verify the dedicated cc-tunnel account with no password
   login and no interactive shell.
4. Add an sshd_config Match block for that user:
   Match User cc-tunnel
     PasswordAuthentication no
     PermitTTY no
     X11Forwarding no
     AllowTcpForwarding yes
     GatewayPorts no
5. Validate with sudo sshd -t.
6. Reload sshd with the platform-supported reload command. Prefer reload; do not
   restart shared sshd unless the operator explicitly approves the risk.
7. Do not add broad GatewayPorts/public listeners. cc-remote sessions must use
   loopback-only reverse listeners: 127.0.0.1:<port>.
8. After cc-remote create --json prints relay_authorized_key_line, append that
   exact line to ~cc-tunnel/.ssh/authorized_keys, preserving unrelated lines.
9. Never remove unrelated authorized_keys entries. Cleanup may remove only the
   exact cc-remote:<session-id> marker for that session.
```

## Create the dedicated account

Print a starting configuration:

```sh
cc-remote init-relay --user cc-tunnel
```

Review it before running anything. A typical policy is:

```sshconfig
Match User cc-tunnel
  PasswordAuthentication no
  PermitTTY no
  X11Forwarding no
  AllowTcpForwarding yes
  GatewayPorts no
```

`AllowTcpForwarding yes` is needed for both remote forwarding and the operator's direct-stream `ssh -W` connection. Per-key `permitopen` and `permitlisten` restrictions narrow each session to one loopback port.

Validate before reloading:

```sh
sudo sshd -t
sudo systemctl reload sshd
```

On distributions with a differently named service, use the platform's supported reload command. Do not restart a shared SSH service when a validated reload is available.

## Install a session authorization manually (default)

`cc-remote create` prints one restricted public-key line resembling:

```text
permitopen="127.0.0.1:<port>",permitlisten="127.0.0.1:<port>",no-pty,no-X11-forwarding ssh-ed25519 <public-key> cc-remote:<session-id>
```

Append that exact line to the dedicated relay user's `authorized_keys`. Preserve unrelated lines. The marker is used for exact-session cleanup.

The default create flow does not contact or modify the relay.

## Explicit automatic installation

If you want the CLI to install the line, first configure an operator-side SSH destination with the required administrative rights. Then provide both flags:

```sh
cc-remote create \
  --relay-host relay.example.test \
  --relay-ssh-host support-relay \
  --install-relay=true \
  --name support-session
```

- `--relay-host` is the public endpoint embedded in the controlled-machine bundle.
- `--relay-ssh-host` is the operator's administrative destination used only to edit relay authorization.

The CLI never infers the public endpoint from SSH configuration. This prevents an administrative alias from silently changing what recipients connect to.

## Verification

On the relay, run:

```sh
sudo ./relay/cc-remote-relay-check.sh cc-tunnel
```

Also verify:

- The account has no password login and no interactive shell.
- `.ssh` and `authorized_keys` ownership and modes are correct.
- `sshd -t` succeeds.
- `GatewayPorts no` is effective.
- Only the expected exact-session marker was added.
- The reverse listener is on `127.0.0.1`, never `0.0.0.0` or `::`.

## Cleanup

Manual installation requires manual exact-marker removal. Automatic installation can be removed by `cc-remote close`, but only when the record proves the CLI installed it and contains the administrative SSH destination. Missing or malformed ownership metadata fails closed and makes no remote change.

Never delete unrelated keys, broadly terminate SSH processes, or restart relay `sshd` to close one session.
