#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$ROOT_DIR/manifest.json"
STATE_ROOT="/var/tmp/cc-remote"
CURRENT_STAGE="initialization"
SESSION_ID="unknown"
LOG_FILE="${CC_REMOTE_LOG:-}"
READY=0

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR [$CURRENT_STAGE]: $*" >&2
  return 1
}

on_error() {
  local rc="$1" line="$2"
  trap - ERR
  log "ERROR: cc-remote stopped during '$CURRENT_STAGE' (line $line, exit $rc)." >&2
  if [ -n "$LOG_FILE" ]; then
    log "Persistent log: $LOG_FILE" >&2
  fi
  if [ "$SESSION_ID" != "unknown" ]; then
    log "Session ID: $SESSION_ID" >&2
  fi
  exit "$rc"
}
trap 'on_error $? $LINENO' ERR

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Administrator privileges are required. Run the one-click launcher; it requests sudo automatically."
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is missing: $1"
}

json_get() {
  python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
cur = data
for part in sys.argv[2].split('.'):
    cur = cur[part]
print(cur)
PY
}

verify_payloads() {
  python3 - "$MANIFEST" "$ROOT_DIR" <<'PY'
import hashlib, json, os, sys
manifest, root = sys.argv[1], sys.argv[2]
with open(manifest, 'r', encoding='utf-8') as f:
    data = json.load(f)
for payload in data.get('payloads', []):
    path = os.path.join(root, payload['path'])
    if not os.path.exists(path):
        raise SystemExit(f"missing payload: {payload['path']}")
    h = hashlib.sha256()
    with open(path, 'rb') as pf:
        for chunk in iter(lambda: pf.read(1024 * 1024), b''):
            h.update(chunk)
    if h.hexdigest() != payload['sha256']:
        raise SystemExit(f"sha256 mismatch: {payload['path']}")
print('payload verification ok')
PY
}

service_active() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$1"
  else
    service "$1" status >/dev/null 2>&1
  fi
}

start_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start "$1"
  else
    service "$1" start
  fi
}

ensure_linux_sshd() {
  if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID_LIKE:-$ID}" in
    *debian*|*ubuntu*)
      if compgen -G "$ROOT_DIR/payloads/linux/debian/*.deb" >/dev/null; then
        dpkg -i "$ROOT_DIR"/payloads/linux/debian/*.deb
      else
        fail "OpenSSH Server is missing and no Debian/Ubuntu offline .deb payloads are bundled."
      fi
      ;;
    *rhel*|*fedora*|*centos*)
      if compgen -G "$ROOT_DIR/payloads/linux/rhel/*.rpm" >/dev/null; then
        rpm -Uvh "$ROOT_DIR"/payloads/linux/rhel/*.rpm
      else
        fail "OpenSSH Server is missing and no RHEL/Rocky/CentOS offline .rpm payloads are bundled."
      fi
      ;;
    *) fail "Unsupported Linux distribution for offline OpenSSH install: ${ID:-unknown}" ;;
  esac
}

port_22_ready() {
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 2 127.0.0.1 22 >/dev/null 2>&1
  else
    python3 - <<'PY'
import socket
s = socket.socket()
s.settimeout(2)
try:
    s.connect(('127.0.0.1', 22))
finally:
    s.close()
PY
  fi
}

remote_login_status() {
  local output rc
  if output="$(systemsetup -getremotelogin 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  log "systemsetup status (exit $rc): $output" >&2
  if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -qi 'on'; then
    printf 'on\n'
  elif [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -qi 'off'; then
    printf 'off\n'
  else
    printf 'unknown\n'
  fi
}

ensure_macos_sshd() {
  local status output rc plist
  require_command systemsetup
  require_command dscl
  plist="/System/Library/LaunchDaemons/ssh.plist"
  status="$(remote_login_status | tail -n 1)"
  PREV_REMOTE_LOGIN="$status"
  REMOTE_LOGIN_METHOD="existing"

  if [ "$status" = "on" ] && port_22_ready; then
    log "Remote Login is already enabled and local SSH port 22 is reachable."
    return
  fi

  log "Enabling macOS Remote Login with systemsetup..."
  if output="$(systemsetup -setremotelogin on 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [ -n "$output" ]; then
    log "systemsetup result (exit $rc): $output"
  else
    log "systemsetup returned no text (exit $rc)."
  fi
  if [ "$rc" -eq 0 ]; then
    REMOTE_LOGIN_METHOD="systemsetup"
  else
    log "systemsetup could not enable Remote Login; trying the macOS launchd compatibility path."
  fi

  if ! port_22_ready; then
    [ -f "$plist" ] || fail "macOS SSH launch daemon plist was not found: $plist"
    output=""
    if output="$(launchctl enable system/com.openssh.sshd 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
    [ -n "$output" ] && log "launchctl enable result (exit $rc): $output"

    if ! port_22_ready; then
      if output="$(launchctl bootstrap system "$plist" 2>&1)"; then
        rc=0
      else
        rc=$?
      fi
      [ -n "$output" ] && log "launchctl bootstrap result (exit $rc): $output"
    fi

    if ! port_22_ready; then
      if output="$(launchctl kickstart -k system/com.openssh.sshd 2>&1)"; then
        rc=0
      else
        rc=$?
      fi
      [ -n "$output" ] && log "launchctl kickstart result (exit $rc): $output"
    fi

    if ! port_22_ready; then
      if output="$(launchctl load -w "$plist" 2>&1)"; then
        rc=0
      else
        rc=$?
      fi
      [ -n "$output" ] && log "launchctl load result (exit $rc): $output"
    fi

    if port_22_ready; then
      REMOTE_LOGIN_METHOD="launchctl"
      log "Remote Login was enabled through launchd compatibility mode."
    else
      fail "Remote Login could not be enabled after systemsetup and launchctl attempts (last exit $rc). Give Terminal Full Disk Access, then rerun this same file: System Settings > Privacy & Security > Full Disk Access > Terminal."
    fi
  fi

  port_22_ready || fail "Remote Login reported enabled, but local SSH port 22 is not reachable."
  log "Local SSH port 22 is reachable."
}

resolve_target_user() {
  local target_user="$1" console_user=""
  if [ -n "$target_user" ] && [ "$target_user" != "auto" ]; then
    printf '%s\n' "$target_user"
    return
  fi
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
    printf '%s\n' "$SUDO_USER"
    return
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    console_user="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
    if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$console_user" != "loginwindow" ]; then
      printf '%s\n' "$console_user"
      return
    fi
  fi
  target_user="$(logname 2>/dev/null || true)"
  if [ -n "$target_user" ] && [ "$target_user" != "root" ]; then
    printf '%s\n' "$target_user"
    return
  fi
  fail "Could not detect the signed-in non-root user."
}

install_key() {
  local target_user="$1" key="$2" home_dir group_name
  case "$(uname -s)" in
    Darwin)
      home_dir="$(dscl . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
      group_name="$(id -gn "$target_user" 2>/dev/null || echo staff)"
      ;;
    Linux)
      home_dir="$(getent passwd "$target_user" | cut -d: -f6 || true)"
      group_name="$(id -gn "$target_user" 2>/dev/null || echo "$target_user")"
      ;;
    *) home_dir=""; group_name="$target_user" ;;
  esac
  [ -n "$home_dir" ] && [ -d "$home_dir" ] || fail "Could not locate home directory for target user: $target_user"
  install -d -m 700 -o "$target_user" -g "$group_name" "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  chown "$target_user:$group_name" "$home_dir/.ssh/authorized_keys" || true
  if ! grep -q "cc-remote:$SESSION_ID" "$home_dir/.ssh/authorized_keys"; then
    printf '\n%s\n' "$key" >> "$home_dir/.ssh/authorized_keys"
  fi
  grep -q "cc-remote:$SESSION_ID" "$home_dir/.ssh/authorized_keys" || fail "Temporary SSH key marker was not written."
  AUTH_KEYS="$home_dir/.ssh/authorized_keys"
  log "Installed the temporary session public key for user $target_user."
}

target_key_fingerprint() {
  python3 - "$MANIFEST" <<'PY'
import base64, hashlib, json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    key = json.load(f)['target_authorized_key'].split()[1]
digest = base64.b64encode(hashlib.sha256(base64.b64decode(key)).digest()).decode().rstrip('=')
print('SHA256:' + digest)
PY
}

write_state() {
  install -d -m 700 "$STATE_ROOT/$SESSION_ID"
  cat > "$STATE_ROOT/$SESSION_ID/state.env" <<EOF
SESSION_ID='$SESSION_ID'
TARGET_USER='$TARGET_USER'
AUTH_KEYS='$AUTH_KEYS'
PREV_REMOTE_LOGIN='${PREV_REMOTE_LOGIN:-unknown}'
REMOTE_LOGIN_METHOD='${REMOTE_LOGIN_METHOD:-unknown}'
TUNNEL_PID='${TUNNEL_PID:-}'
RELAY_USER='$RELAY_USER'
RELAY_HOST='$RELAY_HOST'
RELAY_SSH_PORT='$RELAY_SSH_PORT'
REMOTE_PORT='$REMOTE_PORT'
TUNNEL_KEY='$ROOT_DIR/keys/tunnel_ed25519'
EOF
}

start_tunnel() {
  local rc
  TUNNEL_LOG="$STATE_ROOT/$SESSION_ID/tunnel.log"
  chmod 600 "$ROOT_DIR/keys/tunnel_ed25519"
  : > "$TUNNEL_LOG"
  log "Connecting to restricted relay $RELAY_USER@$RELAY_HOST:$RELAY_SSH_PORT..."
  ssh -N \
    -i "$ROOT_DIR/keys/tunnel_ed25519" \
    -p "$RELAY_SSH_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o ConnectionAttempts=2 \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$STATE_ROOT/$SESSION_ID/known_hosts" \
    -o ControlPath=none \
    -R "127.0.0.1:$REMOTE_PORT:127.0.0.1:22" \
    "$RELAY_USER@$RELAY_HOST" >>"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  sleep 3
  if ! kill -0 "$TUNNEL_PID" >/dev/null 2>&1; then
    set +e
    wait "$TUNNEL_PID"
    rc=$?
    set -e
    log "Relay tunnel output follows:" >&2
    while IFS= read -r line; do log "  $line" >&2; done < "$TUNNEL_LOG"
    fail "Reverse tunnel exited before becoming ready (exit $rc)."
  fi
  log "Reverse tunnel is active (PID $TUNNEL_PID); ExitOnForwardFailure verified relay listener 127.0.0.1:$REMOTE_PORT."
}

install_idle_cleanup() {
  local idle_seconds
  idle_seconds="$(json_get idle_timeout_seconds)"
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --unit "cc-remote-idle-watch-$SESSION_ID" "$ROOT_DIR/idle-watch.sh" "$STATE_ROOT/$SESSION_ID/state.env" "$idle_seconds" >/dev/null || true
  else
    ( "$ROOT_DIR/idle-watch.sh" "$STATE_ROOT/$SESSION_ID/state.env" "$idle_seconds" ) >>"$STATE_ROOT/$SESSION_ID/idle-watch.log" 2>&1 &
    IDLE_WATCH_PID=$!
  fi
  log "Idle cleanup is armed for $idle_seconds seconds after the last SSH connection becomes inactive."
}

write_status() {
  local fingerprint="$1"
  cat > "$STATE_ROOT/$SESSION_ID/status.txt" <<EOF
session_id=$SESSION_ID
status=ready
relay_host=$RELAY_HOST
relay_ssh_port=$RELAY_SSH_PORT
relay_user=$RELAY_USER
reverse_listener=127.0.0.1:$REMOTE_PORT
target_user=$TARGET_USER
target_public_key_fingerprint=$fingerprint
bootstrap_log=$LOG_FILE
tunnel_log=$TUNNEL_LOG
EOF
  chmod 600 "$STATE_ROOT/$SESSION_ID/status.txt"
}

monitor_session() {
  [ "${CC_REMOTE_NO_MONITOR:-0}" = "1" ] && return
  log "Status monitor started. Leave this window open; cleanup stops only this session."
  while kill -0 "$TUNNEL_PID" >/dev/null 2>&1; do
    sleep 30
    if [ ! -f "$STATE_ROOT/$SESSION_ID/state.env" ]; then
      log "Session state was removed; monitoring has finished."
      return
    fi
    log "Status: tunnel active; relay reverse port $REMOTE_PORT; target user $TARGET_USER."
  done
  fail "The relay tunnel stopped unexpectedly. Tunnel log: $TUNNEL_LOG"
}

need_root
require_command python3
require_command ssh
[ -f "$MANIFEST" ] || fail "Manifest is missing: $MANIFEST"

CURRENT_STAGE="reading session manifest"
SESSION_ID="$(json_get session_id)"
RELAY_HOST="$(json_get relay_host)"
RELAY_USER="$(json_get relay_user)"
RELAY_SSH_PORT="$(json_get relay_ssh_port)"
REMOTE_PORT="$(json_get remote_port)"
TARGET_KEY="$(json_get target_authorized_key)"
TARGET_USER="$(resolve_target_user "$(json_get target_user)")"
PREV_REMOTE_LOGIN="unknown"
REMOTE_LOGIN_METHOD="unknown"
AUTH_KEYS=""
TUNNEL_PID=""

install -d -m 700 "$STATE_ROOT/$SESSION_ID"
if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$STATE_ROOT/$SESSION_ID/bootstrap.log"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

log "cc-remote session $SESSION_ID starting on $(uname -s)."
log "Target user: $TARGET_USER"
log "Relay endpoint: $RELAY_HOST:$RELAY_SSH_PORT (restricted user $RELAY_USER)"
log "Reverse listener: relay loopback 127.0.0.1:$REMOTE_PORT"
log "Security: private operator keys are not printed or copied to this Mac."

CURRENT_STAGE="verifying embedded payloads"
verify_payloads

CURRENT_STAGE="enabling local SSH service"
case "$(uname -s)" in
  Darwin) ensure_macos_sshd ;;
  Linux)
    ensure_linux_sshd
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^sshd.service'; then SSH_SERVICE=sshd; else SSH_SERVICE=ssh; fi
    service_active "$SSH_SERVICE" || start_service "$SSH_SERVICE"
    port_22_ready || fail "Local SSH service started, but port 22 is not reachable."
    ;;
  *) fail "Unsupported OS: $(uname -s)" ;;
esac

CURRENT_STAGE="installing temporary target key"
install_key "$TARGET_USER" "$TARGET_KEY"

CURRENT_STAGE="creating restricted reverse tunnel"
write_state
start_tunnel
write_state

CURRENT_STAGE="arming idle cleanup"
install_idle_cleanup
FINGERPRINT="$(target_key_fingerprint)"
write_status "$FINGERPRINT"
READY=1

CURRENT_STAGE="ready"
log ""
log "====== CC-REMOTE CONNECTION INFORMATION ======"
log "Session ID: $SESSION_ID"
log "Relay SSH: $RELAY_HOST:$RELAY_SSH_PORT"
log "Restricted relay user: $RELAY_USER"
log "Relay reverse listener: 127.0.0.1:$REMOTE_PORT"
log "Target Mac user: $TARGET_USER"
log "Target public-key fingerprint: $FINGERPRINT"
log "Operator key paths, SSH config, and full command are in the operator-side connection.md/connection.json for session $SESSION_ID."
log "CC_REMOTE_READY $SESSION_ID $TARGET_USER $RELAY_HOST $REMOTE_PORT"
log "Bootstrap log: $LOG_FILE"
log "Tunnel log: $TUNNEL_LOG"
log "Manual cleanup: sudo /bin/bash $ROOT_DIR/cleanup.sh $STATE_ROOT/$SESSION_ID/state.env"
log "====== END CONNECTION INFORMATION ======"
log ""
monitor_session
