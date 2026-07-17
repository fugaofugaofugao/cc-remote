#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${1:-cc-tunnel}"

echo "Checking relay user: $USER_NAME"
if ! id "$USER_NAME" >/dev/null 2>&1; then
  echo "missing user: $USER_NAME" >&2
  exit 1
fi

HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"

if [ ! -d "$HOME_DIR/.ssh" ]; then
  echo "missing .ssh directory: $HOME_DIR/.ssh" >&2
  exit 1
fi
if [ ! -f "$AUTH_KEYS" ]; then
  echo "missing authorized_keys: $AUTH_KEYS" >&2
  exit 1
fi

stat -c '%U %G %a %n' "$HOME_DIR/.ssh" "$AUTH_KEYS"

if ! sshd -t; then
  echo "sshd_config validation failed" >&2
  exit 1
fi

echo "Relay basic checks passed. Confirm sshd_config has a Match User block limiting $USER_NAME with AllowTcpForwarding yes and GatewayPorts no."
