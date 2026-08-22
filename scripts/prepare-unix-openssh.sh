#!/usr/bin/env bash
#
# prepare-unix-openssh.sh — build a standalone/self-contained OpenSSH payload for
# macOS (Darwin) and Linux, so a controlled machine never depends on its own system
# openssh binaries. Produces:
#   payloads/<os>/openssh-<os>-<arch>-<ver>.tar.gz
#
# OpenSSH 9.8+ splits sshd into a small parent + an `sshd-session` helper that sshd
# locates via a build-time absolute path. To keep that path resolvable at runtime we
# bake a FIXED install prefix into the binary and the payload carries an install.sh;
# the controlled-side bootstrap (running as root) installs the payload to that same
# fixed prefix. The bundled sshd then reliably finds sshd-session without touching the
# system ssh daemon, service, config, or system OpenSSH binaries.
#
# This script needs NO root and NO `make install`: it builds in-tree and assembles the
# payload directly from the build tree.
#
# Usage:
#   scripts/prepare-unix-openssh.sh [--os darwin|linux] [--arch arm64|x86_64] [--work DIR] [--prefix DIR]
set -euo pipefail

# ---- pinned versions + sha256 ----
ZLIB_VER=1.3.1
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
OPENSSL_VER=3.0.15
OPENSSL_SHA256=23c666d0edf20f14249b3d8f0368acaee9ab585b09e1de82107c66e1f3ec9533
OPENSSH_VER=9.8p1
OPENSSH_SHA256=dd8bd002a379b5d499dfb050dd1fa9af8029e80461f4bb6c523c49973f5a39f3

OS=""
ARCH=""
WORK=""
PREFIX_OVERRIDE=""
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "usage: $0 [--os darwin|linux] [--arch arm64|x86_64] [--work DIR] [--prefix DIR]"
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --os) OS="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --work) WORK="$2"; shift 2;;
    --prefix) PREFIX_OVERRIDE="$2"; shift 2;;
    *) echo "unknown arg: $1"; usage;;
  esac
done

if [ -z "$OS" ]; then
  case "$(uname -s)" in Darwin) OS=darwin;; Linux) OS=linux;; *) echo "unsupported host OS"; exit 1;; esac
fi
if [ -z "$ARCH" ]; then
  case "$(uname -m)" in aarch64|arm64) ARCH=arm64;; x86_64|amd64) ARCH=x86_64;; *) echo "unsupported host arch"; exit 1;; esac
fi
[ "$OS" = darwin ] || [ "$OS" = linux ] || { echo "os must be darwin|linux"; exit 1; }
[ "$ARCH" = arm64 ] || [ "$ARCH" = x86_64 ] || { echo "arch must be arm64|x86_64"; exit 1; }

# Cross-compilation: an arm64 macOS host can build a darwin x86_64 payload with
# clang -target x86_64-apple-darwin + a cross-built x86_64 OpenSSL, so we do not
# depend on GitHub's scarce Intel (macos-13) hosted runners registry to produce it.
HOST_ARCH="$(uname -m | sed -e 's/aarch64/arm64/' -e 's/amd64/x86_64/')"
CC_TARGET_FLAG=""
CONFIGURE_HOST_FLAG=""
LIBS_EXTRA=""
CROSS_NOTE=""
if [ "$OS" = darwin ] && [ "$HOST_ARCH" != "$ARCH" ]; then
  CC_TARGET_FLAG="-target ${ARCH}-apple-macosx11.0"
  CONFIGURE_HOST_FLAG="--host=${ARCH}-apple-darwin"
  LIBS_EXTRA="-lpthread"
  if [ "$HOST_ARCH" = arm64 ] && [ "$ARCH" = x86_64 ]; then
    CROSS_NOTE="cross-compiling darwin x86_64 on arm64 host"
  else
    echo "unsupported cross-compile combination: host $HOST_ARCH -> darwin $ARCH" >&2
    exit 1
  fi
fi

# Fixed install prefix baked into sshd so it can find sshd-session at runtime.
if [ -n "$PREFIX_OVERRIDE" ]; then
  PREFIX="$PREFIX_OVERRIDE"
elif [ "$OS" = linux ]; then
  PREFIX=/opt/cc-remote/openssh
else
  PREFIX=/usr/local/cc-remote/openssh
fi

if [ -z "$WORK" ]; then WORK="${TMPDIR:-/tmp}/cc-remote-openssh-build-${OS}-${ARCH}"; fi
SRC="$WORK/src"; PJ="$WORK/jobs"; FINAL="$WORK/final"
mkdir -p "$SRC" "$PJ" "$FINAL"

fail() { echo "FAIL[$1] $(tail -8 "$PJ/$2" 2>/dev/null)"; exit 1; }

echo "==> building self-contained OpenSSH ${OPENSSH_VER} for ${OS}/${ARCH} (baked prefix=${PREFIX})"

dl_pin() { # $1=name $2=url $3=sha256 $4=outfile
  local name="$1"
  local url="$2"
  local want="$3"
  local out="$4"
  local tmp="$out.dl"
  if [ -f "$out" ]; then
    [ "$(shasum -a 256 "$out" | cut -d' ' -f1)" = "$want" ] && { echo "  $name: cached"; return 0; }
  fi
  echo "  $name: downloading"
  curl -fL --connect-timeout 20 --retry 3 --retry-all-errors -o "$tmp" "$url"
  local got; got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { rm -f "$tmp"; echo "  $name sha mismatch: want $want got $got" >&2; exit 1; }
  mv "$tmp" "$out"
}

dl_pin zlib    "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" "$ZLIB_SHA256" "$SRC/zlib.tar.gz"
dl_pin openssl "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" "$OPENSSL_SHA256" "$SRC/openssl.tar.gz"
dl_pin openssh "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VER}.tar.gz" "$OPENSSH_SHA256" "$SRC/openssh.tar.gz"

NCPU="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# ----- zlib (static) -----
if [ "$OS" = linux ] && [ ! -f "$PREFIX/lib/libz.a" ]; then
  mkdir -p "$PREFIX/lib" 2>/dev/null || true
fi
if [ "$OS" = linux ]; then
  if [ ! -f "$WORK/libz-built" ]; then
    cd "$SRC" && rm -rf "zlib-$ZLIB_VER" && tar xzf zlib.tar.gz && cd "zlib-$ZLIB_VER"
    CPPFLAGS="-fPIC" ./configure --static --prefix="$WORK/zprefix" >"$PJ/zlib.cfg" 2>&1 || fail zlib zlib.cfg
    make -j"$NCPU" >"$PJ/zlib.make" 2>&1 || fail zlib zlib.make
    make install >"$PJ/zlib.inst" 2>&1 || fail zlib zlib.inst
    touch "$WORK/libz-built"
    echo "  zlib ok"
  fi
  ZLIB_PREFIX="$WORK/zprefix"
fi

# ----- openssl -----
if [ "$OS" = linux ]; then
  if [ ! -f "$WORK/libcrypto-built" ]; then
    cd "$SRC" && rm -rf "openssl-$OPENSSL_VER" && tar xzf openssl.tar.gz && cd "openssl-$OPENSSL_VER"
    case "$ARCH" in arm64) T=linux-aarch64;; x86_64) T=linux-x86_64;; esac
    ./Configure "$T" no-shared no-tests no-async no-dso --prefix="$WORK/oprefix" --openssldir="$WORK/oprefix/ssl" \
      >"$PJ/ossl.cfg" 2>&1 || fail openssl ossl.cfg
    make -j"$NCPU" >"$PJ/ossl.make" 2>&1 || fail openssl ossl.make
    make install_sw >"$PJ/ossl.inst" 2>&1 || fail openssl ossl.inst
    touch "$WORK/libcrypto-built"
    echo "  openssl ok"
  fi
  OSSL_PREFIX="$WORK/oprefix"
else
  if [ -n "$CROSS_NOTE" ]; then
    # Cross-compile: build a static x86_64 OpenSSL from source with clang -target,
    # because Homebrew openssl@3 on an arm64 host is arm64-only.
    echo "  $CROSS_NOTE"
    rm -rf "$SRC/openssl-$OPENSSL_VER" && cd "$SRC" && tar xzf openssl.tar.gz && cd "openssl-$OPENSSL_VER"
    CC="clang $CC_TARGET_FLAG" ./Configure darwin64-${ARCH}-cc no-shared no-tests no-async no-dso \
      --prefix="$WORK/x64oprefix" >"$PJ/ossl-x64.cfg" 2>&1 || fail openssl-x64 ossl-x64.cfg
    make -j"$NCPU" build_libs >"$PJ/ossl-x64.make" 2>&1 || fail openssl-x64 ossl-x64.make
    make install_sw >"$PJ/ossl-x64.inst" 2>&1 || fail openssl-x64 ossl-x64.inst
    OSSL_PREFIX="$WORK/x64oprefix"
    echo "  openssl-x64: $OSSL_PREFIX"
  else
    # macOS native: use brew OpenSSL (static libcrypto.a) for a mostly-self-contained client.
    BREW_OSSL=""
    for c in /opt/homebrew/opt/openssl@3 /usr/local/opt/openssl@3; do [ -d "$c" ] && BREW_OSSL="$c" && break; done
    if [ -z "$BREW_OSSL" ] || [ ! -f "$BREW_OSSL/lib/libcrypto.a" ]; then
      echo "macOS build requires Homebrew openssl@3 (with libcrypto.a) at /opt/homebrew/opt/openssl@3 or /usr/local/opt/openssl@3" >&2
      exit 1
    fi
    echo "  openssl: brew $BREW_OSSL"
  fi
fi

# ----- openssh -----
cd "$SRC" && rm -rf "openssh-$OPENSSH_VER" && tar xzf openssh.tar.gz && cd "openssh-$OPENSSH_VER"

CFG_SSL=""
CPP_FLAGS=""
LD_FLAGS=""
EXTLIBS=""
if [ "$OS" = linux ]; then
  CFG_SSL="--with-zlib=$ZLIB_PREFIX --with-ssl-dir=$OSSL_PREFIX"
elif [ -n "$CROSS_NOTE" ]; then
  CFG_SSL="--with-ssl-dir=$OSSL_PREFIX"
  CPP_FLAGS="-I$OSSL_PREFIX/include"
  LD_FLAGS="-L$OSSL_PREFIX/lib"
else
  CFG_SSL="--with-ssl-dir=$BREW_OSSL"
  CPP_FLAGS="-I$BREW_OSSL/include"
  LD_FLAGS="-L$BREW_OSSL/lib"
fi

[ -n "$CC_TARGET_FLAG" ] && export CC="clang $CC_TARGET_FLAG"
# shellcheck disable=SC2086
env LIBS="-lpthread $LIBS_EXTRA" ./configure \
  --prefix="$PREFIX" --libexecdir="$PREFIX/libexec" --sbindir="$PREFIX/bin" --bindir="$PREFIX/bin" \
  $CONFIGURE_HOST_FLAG \
  $CFG_SSL \
  --without-openssl-header-check --disable-libutil --disable-utmp --disable-wtmp \
  --with-mantype=man --disable-security-key --without-pam \
  CPPFLAGS="$CPP_FLAGS" LDFLAGS="$LD_FLAGS" \
  >"$PJ/oss.cfg" 2>&1 || fail openssh oss.cfg
echo "  openssh configure ok"
make -j"$NCPU" >"$PJ/oss.make" 2>&1 || fail openssh oss.make
echo "  openssh make ok"

# ----- capture built binaries (from build tree, no make install needed) -----
rm -rf "$FINAL" && mkdir -p "$FINAL"
for b in sshd ssh ssh-keygen sshd-session sftp-server; do
  if [ -f "$b" ]; then cp -f "$b" "$FINAL/"; fi
done
# Linux static link: relink sshd/ssh/ssh-keygen fully static so no target dynlibs are needed.
if [ "$OS" = linux ]; then
  echo "  static-linking sshd/ssh/ssh-keygen"
  for bin in sshd ssh ssh-keygen; do
    if [ -f "$FINAL/$bin" ]; then
      # determine the object list used; simplest: relink using the build Makefile flags
      # via a fresh -static link of the same command (see configure EXTLIBS) is fragile,
      # so rebuild that one binary with static flags.
      make "$bin" clean >/dev/null 2>&1 || true
      make "$bin" LIBS="-lpthread" LDFLAGS="-static" \
        EXTLIBS="$OSSL_PREFIX/lib/libcrypto.a $ZLIB_PREFIX/lib/libz.a -lcrypt -ldl -lpthread" \
        >"$PJ/$bin.staticlink" 2>&1 || { echo "static-link $bin failed; keeping dynamic"; }
      [ -f "$bin" ] && cp -f "$bin" "$FINAL/$bin"
    fi
  done
fi
[ -f "$FINAL/sshd-session" ] || { echo "sshd-session missing in build tree"; exit 1; }
cp -f moduli sshd_config "$FINAL/" 2>/dev/null || true
cp -f LICENCE "$FINAL/LICENSE" 2>/dev/null || cp -f LICENSE "$FINAL/LICENSE" 2>/dev/null || true

echo "  smoke: sshd -V -> $($FINAL/sshd -V 2>&1 | head -1 | tr -d '\n')"
file "$FINAL/sshd" 2>/dev/null | sed 's/^/  /'

# ----- stage + package (records baked prefix) -----
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/openssh/bin" "$STAGE/openssh/libexec"
cp -f "$FINAL"/sshd "$FINAL"/ssh "$FINAL"/ssh-keygen "$FINAL"/sftp-server "$STAGE/openssh/bin/" 2>/dev/null || true
cp -f "$FINAL"/sshd-session "$STAGE/openssh/libexec/" 2>/dev/null || true
cp -f "$FINAL"/moduli "$FINAL"/sshd_config "$STAGE/openssh/" 2>/dev/null || true
cp -f "$FINAL"/LICENSE "$STAGE/openssh/LICENSE" 2>/dev/null || true
printf '%s\n' "$PREFIX" > "$STAGE/openssh/.install-prefix"
chmod 755 "$STAGE/openssh/bin/"* "$STAGE/openssh/libexec/"* 2>/dev/null || true

# cc-remote uses the logical platform name "macos" for Darwin launchers/bundles.
PKG_OS="$OS"
[ "$PKG_OS" = darwin ] && PKG_OS=macos
OUTDIR="$ROOT/payloads/$PKG_OS"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/openssh-$OS-$ARCH-$OPENSSH_VER.tar.gz"
( cd "$STAGE" && tar czf "$OUT" openssh )
rm -rf "$STAGE"

echo "==> payload: $OUT"
echo "==> sha256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
echo "==> baked prefix: $PREFIX (bootstrap installs to this same path)"
echo "PREPARE_DONE os=$OS arch=$ARCH ver=$OPENSSH_VER prefix=$PREFIX"
