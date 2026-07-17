#!/usr/bin/env bash
set -euo pipefail

STATE="${1:-}"
IDLE_SECONDS="${2:-7200}"
CHECK_SECONDS="${3:-60}"
if [ -z "$STATE" ] || [ ! -f "$STATE" ]; then
  echo "usage: idle-watch.sh /path/to/state.env [idle-seconds]" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$STATE"

last_active="$(date +%s)"
ssh_port_active() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:22 -sTCP:ESTABLISHED >/dev/null 2>&1
    return
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -tn state established '( sport = :22 )' | grep -q ':22'
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tn 2>/dev/null | grep -E '[.:]22[[:space:]].*ESTABLISHED' >/dev/null
    return
  fi
  return 1
}

while :; do
  now="$(date +%s)"
  if ssh_port_active; then
    last_active="$now"
  fi
  if [ $(( now - last_active )) -ge "$IDLE_SECONDS" ]; then
    "$(dirname "$0")/cleanup.sh" "$STATE"
    exit 0
  fi
  sleep "$CHECK_SECONDS"
done
