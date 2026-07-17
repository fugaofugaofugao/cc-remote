#!/usr/bin/env bash
set -euo pipefail

STATE="${1:-}"
if [ -z "$STATE" ] || [ ! -f "$STATE" ]; then
  echo "usage: cleanup.sh /path/to/state.env" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$STATE"

if [ -n "${AUTH_KEYS:-}" ] && [ -f "$AUTH_KEYS" ]; then
  tmp="${AUTH_KEYS}.cc-remote-cleanup"
  grep -v "cc-remote:${SESSION_ID}" "$AUTH_KEYS" > "$tmp" || true
  cat "$tmp" > "$AUTH_KEYS"
  rm -f "$tmp"
  echo "removed temporary authorized_keys marker cc-remote:${SESSION_ID}"
fi

if [ -n "${TUNNEL_PID:-}" ] && kill -0 "$TUNNEL_PID" >/dev/null 2>&1; then
  command_name="$(ps -p "$TUNNEL_PID" -o comm= 2>/dev/null || true)"
  command_line="$(ps -p "$TUNNEL_PID" -o command= 2>/dev/null || true)"
  expected_forward="127.0.0.1:${REMOTE_PORT:-}:127.0.0.1:22"
  expected_port="-p ${RELAY_SSH_PORT:-}"
  expected_target="${RELAY_USER:-}@${RELAY_HOST:-}"
  if [ "$(basename "$command_name")" = "ssh" ] &&
     [ -n "${REMOTE_PORT:-}" ] &&
     [ -n "${RELAY_USER:-}" ] &&
     [ -n "${RELAY_HOST:-}" ] &&
     [ -n "${RELAY_SSH_PORT:-}" ] &&
     [ -n "${TUNNEL_KEY:-}" ] &&
     printf '%s\n' "$command_line" | grep -F -- "$expected_forward" >/dev/null &&
     printf '%s\n' "$command_line" | grep -F -- "$expected_port" >/dev/null &&
     printf '%s\n' "$command_line" | grep -F -- "$expected_target" >/dev/null &&
     printf '%s\n' "$command_line" | grep -F -- "$TUNNEL_KEY" >/dev/null; then
    kill "$TUNNEL_PID" || true
    echo "stopped verified session tunnel process $TUNNEL_PID"
  else
    echo "warning: PID $TUNNEL_PID does not match this session tunnel; it was not stopped" >&2
  fi
fi

# SSH/Remote Login is a shared machine service. Cleanup deliberately leaves its
# running state, startup configuration, installation, and service files intact.
rm -f "$STATE"
echo "cc-remote cleanup complete for ${SESSION_ID}"
