#!/bin/sh
set -eu

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_dir="${CC_REMOTE_INSTALL_DIR:-$HOME/.local/share/cc-remote}"
bin_dir="${CC_REMOTE_BIN_DIR:-$HOME/.local/bin}"
make_shim=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix|--install-dir)
      [ "$#" -ge 2 ] || { echo "$1 requires a path" >&2; exit 2; }
      install_dir=$2; shift 2 ;;
    --bin-dir)
      [ "$#" -ge 2 ] || { echo "$1 requires a path" >&2; exit 2; }
      bin_dir=$2; shift 2 ;;
    --no-shim)
      make_shim=0; shift ;;
    --help|-h)
      echo "Usage: ./install.sh [--install-dir DIR] [--bin-dir DIR] [--no-shim]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$self_dir/cc-remote" ]; then
  echo "Missing cc-remote executable. Run this from an extracted cc-remote runtime archive." >&2
  exit 1
fi
if [ ! -f "$self_dir/bootstrap/bootstrap.sh" ] || [ ! -f "$self_dir/bootstrap/bootstrap.ps1" ]; then
  echo "Missing bootstrap assets. The archive is incomplete." >&2
  exit 1
fi
# Verify the bundled self-contained OpenSSH payload for THIS platform exists so
# install-and-use works without depending on the machine's own openssh components.
os="$(uname -s)"
arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) cc_arch=arm64 ;;
  x86_64|amd64) cc_arch=x86_64 ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac
case "$os" in
  Darwin) unix_payload="$self_dir/payloads/macos/openssh-darwin-$cc_arch-9.8p1.tar.gz" ;;
  Linux) unix_payload="$self_dir/payloads/linux/openssh-linux-$cc_arch-9.8p1.tar.gz" ;;
  MINGW*|MSYS*|CYGWIN*|*Windows*) unix_payload="" ;;
  *) echo "Unsupported OS: $os" >&2; exit 1 ;;
esac
if [ -n "$unix_payload" ] && [ ! -f "$unix_payload" ]; then
  echo "Missing bundled self-contained OpenSSH payload: $unix_payload"
  echo "Use the full runtime archive for this platform for install-and-use behavior." >&2
  exit 1
fi

case "$install_dir" in
  "$HOME"|"$HOME/"|"$HOME/.local"|"$HOME/.local/"|/|/tmp|/tmp/) echo "Refusing unsafe install directory: $install_dir" >&2; exit 2 ;;
esac
case "$(basename "$install_dir")" in
  cc-remote) ;;
  *) echo "Install directory must end with cc-remote: $install_dir" >&2; exit 2 ;;
esac
install_parent=$(dirname "$install_dir")
mkdir -p "$install_parent" "$bin_dir"
tmp_dir=$(mktemp -d "$install_parent/.cc-remote-install.XXXXXX")
backup_dir=""
cleanup_tmp() { [ -z "${tmp_dir:-}" ] || [ ! -d "$tmp_dir" ] || rm -rf "$tmp_dir"; }
trap cleanup_tmp EXIT HUP INT TERM
(
  cd "$self_dir"
  tar cf - .
) | (
  cd "$tmp_dir"
  tar xf -
)
chmod 755 "$tmp_dir/cc-remote" 2>/dev/null || true
if [ -e "$install_dir" ] || [ -L "$install_dir" ]; then
  backup_dir="$install_dir.previous.$$"
  mv "$install_dir" "$backup_dir"
fi
if mv "$tmp_dir" "$install_dir"; then
  tmp_dir=""
  if [ -n "$backup_dir" ]; then rm -rf "$backup_dir"; fi
else
  if [ -n "$backup_dir" ] && [ -e "$backup_dir" ]; then mv "$backup_dir" "$install_dir"; fi
  exit 1
fi

if [ "$make_shim" -eq 1 ]; then
  cat > "$bin_dir/cc-remote" <<EOF
#!/bin/sh
exec "$install_dir/cc-remote" "\$@"
EOF
  chmod 755 "$bin_dir/cc-remote"
fi

printf 'cc-remote installed to: %s\n' "$install_dir"
if [ "$make_shim" -eq 1 ]; then
  printf 'Command shim: %s\n' "$bin_dir/cc-remote"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) printf 'NOTE: %s is not on PATH. Add it to your shell profile or run the shim by full path.\n' "$bin_dir" ;;
  esac
fi
printf '\nVerify with:\n  cc-remote version\n  cc-remote doctor --json\n\nBefore cc-remote create, configure the relay you control:\n  cc-remote relay set --host <relay-host> --port <relay-ssh-port> --user cc-tunnel\nIf relay details are missing, ask the operator before creating a session.\n'
