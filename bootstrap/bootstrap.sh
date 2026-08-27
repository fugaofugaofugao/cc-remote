#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$ROOT_DIR/manifest.json"
STATE_ROOT="/var/tmp/cc-remote"
CURRENT_STAGE="initialization"
SESSION_ID="unknown"
LOG_FILE="${CC_REMOTE_LOG:-}"
READY=0

# Standalone bundled OpenSSH: the controlled machine must not depend on its own system
# openssh. Built binaries are installed to this fixed prefix (see .install-prefix baked
# at build time) so bundled sshd can find sshd-session. By default a user-writable
# location is used and promoted below when running as root.
#
# Linux hosts are typically headless and run the launcher as root; macOS launchd sshd
# is left untouched. When root, the payload is installed under the fixed system prefix:
#   linux:  /opt/cc-remote/openssh
#   darwin: /usr/local/cc-remote/openssh
# When not root, fall back to a per-user prefix so bundled sshd still locates sshd-session
# (which is tracked relative to that same prefix).
OPENSSH_BIN=""
LOCAL_SSH_PORT=""
LOCAL_SSHD_PID=""
LOCAL_SSHD_MODE="none"

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




# ---------------------------------------------------------------------------
# Standalone bundled OpenSSH.
#
# The controlled machine must not depend on its own system openssh. The session
# bundle carries a self-contained OpenSSH payload (see payloads/<os>/*.tar.gz)
# built with a fixed install prefix so bundled sshd reliably finds sshd-session.
# As root we install it under the fixed system prefix; whoever runs this bootstrap
# needs the privilege to write there.
# ---------------------------------------------------------------------------

bundled_openssh_prefix() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ "$(uname -s)" = "Linux" ]; then
      printf '%s\n' /opt/cc-remote/openssh
    else
      printf '%s\n' /usr/local/cc-remote/openssh
    fi
  elif [ "$(uname -s)" = "Linux" ]; then
    printf '%s\n' "$HOME/.cc-remote/openssh"
  else
    printf '%s\n' "$HOME/cc-remote/openssh"
  fi
}

# Install the bundled self-contained OpenSSH payload into the fixed prefix and
# export OPENSSH_BIN (bin dir of built ssh/sshd). Idempotent and cheap.
ensure_bundled_openssh() {
  local payload prefix tmp
  OPENSSH_PREFIX="$(bundled_openssh_prefix)"
  payload=""
  # find the payload matching this OS (prefer arch of this machine)
  local want_arch="" m
  case "$(uname -m)" in aarch64|arm64) want_arch=arm64;; x86_64|amd64) want_arch=x86_64;; esac
  for m in "$ROOT_DIR"/payloads/*/openssh-*-"$want_arch"-*.tar.gz; do
    if [ -f "$m" ]; then payload="$m"; break; fi
  done
  if [ -z "$payload" ] || [ ! -f "$payload" ]; then
    # fall back to any bundled unix payload
    for m in "$ROOT_DIR"/payloads/linux/*.tar.gz "$ROOT_DIR"/payloads/macos/*.tar.gz; do
      [ -f "$m" ] && payload="$m" && break
    done
  fi
  [ -n "$payload" ] && [ -f "$payload" ] || fail "no bundled OpenSSH tarball found under $ROOT_DIR/payloads"

  if [ ! -x "$OPENSSH_PREFIX/bin/sshd" ]; then
    install -d -m 755 "$OPENSSH_PREFIX" 2>/dev/null || fail "cannot create $OPENSSH_PREFIX (run launcher as root or use a writable prefix)"
    prefix="$(dirname "$OPENSSH_PREFIX")"
    tmp="$OPENSSH_PREFIX.tmp-$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    tar xzf "$payload" -C "$tmp" || fail "failed to extract bundled OpenSSH payload"
    ( cd "$tmp"/openssh && cp -R . "$OPENSSH_PREFIX"/ ) || fail "failed to install bundled OpenSSH to $OPENSSH_PREFIX"
    rm -rf "$tmp"
    # chmod binaries
    chmod 755 "$OPENSSH_PREFIX"/bin/* "$OPENSSH_PREFIX"/libexec/* 2>/dev/null || true
  fi
  OPENSSH_BIN="$OPENSSH_PREFIX/bin"
  if [ ! -x "$OPENSSH_BIN/sshd" ] || [ ! -x "$OPENSSH_BIN/ssh" ] || [ ! -x "$OPENSSH_PREFIX/libexec/sshd-session" ]; then
    fail "bundled OpenSSH install is incomplete under $OPENSSH_PREFIX (need bin/sshd, bin/ssh, libexec/sshd-session)"
  fi
  log "Bundled standalone OpenSSH ready at $OPENSSH_PREFIX (client $OPENSSH_BIN/ssh)"
}

# Select an unused local port for the standalone sshd, preferring the manifest value.
select_local_ssh_port() {
  local mport="$1" p
  if [ -n "$mport" ] && [ "$mport" -gt 0 ] 2>/dev/null && ! port_in_use "$mport"; then
    printf '%s\n' "$mport"; return
  fi
  p="$mport"
  [ -n "$p" ] || p=22200
  while port_in_use "$p"; do p=$((p+1)); done
  printf '%s\n' "$p"
}

port_in_use() {
  local port="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1
  else
    python3 - "$port" <<'PY'
import socket, sys
p = int(sys.argv[1])
s = socket.socket()
s.settimeout(1)
try:
    s.connect(('127.0.0.1', p))
    ok = True
except Exception:
    ok = False
finally:
    s.close()
sys.exit(0 if ok else 1)  # 0 => in use
PY
    true
  fi
}

# Run the bundled standalone sshd on LOCAL_SSH_PORT with session-scoped host keys
# and an isolated authorized_keys. Never touches the system sshd / service / config.
ensure_standalone_sshd() {
  local keydir cfg
  ensure_bundled_openssh
  # OpenSSH privilege-separation directory. Minimal/container images and fresh
  # Ubuntu installs do not ship /var/empty and sshd refuses to start without it
  # ("Missing privilege separation directory"). Safe when it already exists.
  install -d -m 0755 /var/empty
  LOCAL_SSH_PORT="$(select_local_ssh_port "$LOCAL_SSH_PORT")"
  keydir="$STATE_ROOT/$SESSION_ID/sshd"
  # 711: traversable by the (non-root) target user so the isolated sshd, after it
  # drops privileges, can open AuthorizedKeysFile below. Not enumerable.
  install -d -m 711 "$keydir"
  if [ ! -f "$keydir/host_ed25519" ]; then
    "$OPENSSH_BIN/ssh-keygen" -q -t ed25519 -f "$keydir/host_ed25519" -N "" || fail "failed to generate standalone sshd host key"
  fi
  cfg="$keydir/sshd_config"
  AUTH_KEYS="$keydir/authorized_keys"
  : > "$AUTH_KEYS"
  # 644: the post-privsep sshd runs as the target user and must be able to read
  # this public-key store. The session host private key stays 600 (owner=root).
  chmod 644 "$AUTH_KEYS"
  printf '\n%s\n' "$TARGET_KEY" >> "$AUTH_KEYS" 2>/dev/null
  cat > "$cfg" <<CONF
Port $LOCAL_SSH_PORT
ListenAddress 127.0.0.1
HostKey $keydir/host_ed25519
PidFile $keydir/sshd.pid
AuthorizedKeysFile $AUTH_KEYS
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin yes
LogLevel VERBOSE
UsePAM no
StrictModes no
CONF
  if ! "$OPENSSH_BIN/sshd" -f "$cfg" -E "$keydir/sshd.log"; then
    # The authoritative log is the bootstrap log; surface why sshd refused to start
    # (config, privilege separation dir, port binding) instead of a bare failure line.
    log "Standalone sshd failed to start (port $LOCAL_SSH_PORT); last sshd.log lines:" >&2
    tail -n 20 "$keydir/sshd.log" 2>/dev/null | while IFS= read -r line; do log "  $line" >&2; done
    fail "standalone sshd failed to start (port $LOCAL_SSH_PORT); full log: $keydir/sshd.log, bootstrap log: $LOG_FILE"
  fi
  sleep 1
  if [ -f "$keydir/sshd.pid" ]; then
    LOCAL_SSHD_PID="$(cat "$keydir/sshd.pid")"
  fi
  if ! port_in_use "$LOCAL_SSH_PORT"; then
    log "Standalone sshd exited early (port $LOCAL_SSH_PORT); last sshd.log lines:" >&2
    tail -n 20 "$keydir/sshd.log" 2>/dev/null | while IFS= read -r line; do log "  $line" >&2; done
    fail "standalone sshd did not bind $LOCAL_SSH_PORT; full log: $keydir/sshd.log, bootstrap log: $LOG_FILE"
  fi
  LOCAL_SSHD_MODE="standalone"
  log "Standalone sshd active on 127.0.0.1:$LOCAL_SSH_PORT (pid $LOCAL_SSHD_PID); isolated from the system ssh service."
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
  if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" -eq 0 ]; then
    printf 'root\n'
    return
  fi
  fail "Could not detect the signed-in user."
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
  # 711: traversable by the (non-root) target user so the session sshd can read
  # its key store; contents stay non-enumerable.
  install -d -m 711 "$STATE_ROOT/$SESSION_ID"
  cat > "$STATE_ROOT/$SESSION_ID/state.env" <<EOF
SESSION_ID='$SESSION_ID'
TARGET_USER='$TARGET_USER'
AUTH_KEYS='$AUTH_KEYS'
TUNNEL_PID='${TUNNEL_PID:-}'
LOCAL_SSHD_PID='${LOCAL_SSHD_PID:-}'
LOCAL_SSHD_MODE='${LOCAL_SSHD_MODE:-none}'
LOCAL_SSH_PORT='${LOCAL_SSH_PORT:-}'
OPENSSH_PREFIX='${OPENSSH_PREFIX:-}'
RELAY_USER='$RELAY_USER'
RELAY_HOST='$RELAY_HOST'
RELAY_SSH_PORT='$RELAY_SSH_PORT'
REMOTE_PORT='$REMOTE_PORT'
TUNNEL_KEY='$ROOT_DIR/keys/tunnel_ed25519'
EOF
}

start_tunnel() {
  local rc ssh_client local_dst
  TUNNEL_LOG="$STATE_ROOT/$SESSION_ID/tunnel.log"
  chmod 600 "$ROOT_DIR/keys/tunnel_ed25519"
  : > "$TUNNEL_LOG"
  # Prefer the bundled ssh client so the machine does not depend on its own openssh.
  if [ -n "$OPENSSH_BIN" ] && [ -x "$OPENSSH_BIN/ssh" ]; then
    ssh_client="$OPENSSH_BIN/ssh"
  elif command -v ssh >/dev/null 2>&1; then
    ssh_client="$(command -v ssh)"
  else
    fail "no ssh client available (bundled openssh missing and no system ssh)"
  fi
  # Forward the relay reverse listener to the standalone bundled sshd port.
  local_dst="127.0.0.1:$LOCAL_SSH_PORT"
  log "Connecting to restricted relay $RELAY_USER@$RELAY_HOST:$RELAY_SSH_PORT (client $(basename "$ssh_client"))..."
  "$ssh_client" -N \
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
    -R "127.0.0.1:$REMOTE_PORT:$local_dst" \
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
  log "Reverse tunnel is active (PID $TUNNEL_PID); ExitOnForwardFailure verified relay listener 127.0.0.1:$REMOTE_PORT -> $local_dst."
}

install_idle_cleanup() {
  local idle_seconds
  idle_seconds="$(json_get idle_timeout_seconds)"
  if [ "$idle_seconds" -le 0 ]; then
    log "Idle cleanup is disabled; this session remains active until manually closed."
    return
  fi
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
[ -f "$MANIFEST" ] || fail "Manifest is missing: $MANIFEST"

CURRENT_STAGE="reading session manifest"
SESSION_ID="$(json_get session_id)"
RELAY_HOST="$(json_get relay_host)"
RELAY_USER="$(json_get relay_user)"
RELAY_SSH_PORT="$(json_get relay_ssh_port)"
REMOTE_PORT="$(json_get remote_port)"
TARGET_KEY="$(json_get target_authorized_key)"
TARGET_USER="$(resolve_target_user "$(json_get target_user)")"
# Preferred port for the standalone bundled sshd; verified/overridden at run time.
LOCAL_SSH_PORT="$(json_get local_ssh_port 2>/dev/null || true)"
AUTH_KEYS=""
TUNNEL_PID=""

# 711: traversable by the (non-root) target user for the standalone sshd's key store.
install -d -m 711 "$STATE_ROOT/$SESSION_ID"
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

CURRENT_STAGE="enabling standalone bundled sshd"
ensure_standalone_sshd

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
