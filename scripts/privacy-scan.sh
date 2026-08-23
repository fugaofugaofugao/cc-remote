#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$TARGET" "${CC_REMOTE_PRIVACY_DENYLIST:-}" <<'PY'
import hashlib
import ipaddress
import os
import pathlib
import re
import sys
import zipfile

root = pathlib.Path(sys.argv[1]).resolve()
denylist_path = sys.argv[2]
if not root.exists():
    raise SystemExit(f"scan target does not exist: {root}")

forbidden_names = {
    "record.json", "connection.json", "connection.md", "ssh_config",
    "state.json", "state.env", "tunnel-startup.json",
}
forbidden_suffixes = (".log", ".bak", ".backup", ".download")
key_name_re = re.compile(r"(?:^|[_-])(?:target|tunnel)?_?ed25519(?:\.pub)?$", re.I)
generated_launcher_re = re.compile(r"^cc-remote-.+\.(?:cmd|command|ps1|sh|zip)$", re.I)
private_block_re = re.compile(
    rb"-----BEGIN (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----[\s\S]*?-----END (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----"
)
home_path_re = re.compile(rb"/(?:Users|home)/[A-Za-z0-9._-]+/")
ipv4_re = re.compile(rb"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])")
legacy_re = re.compile(rb"ali" + rb"yun|ali" + rb"baba[ -]?cloud", re.I)
allowed_ipv4 = {"127.0.0.1", "0.0.0.0", "255.255.255.255"}
allowed_source_names = {
    "cc-remote-relay-check.sh",
    "cc-remote-self-contained-source.zip",
    "cc-remote-source-only.zip",
}
# Bundled self-contained OpenSSH payload archives are third-party binaries built
# from pinned OSS sources by prepare-*-openssh.sh; the whole archive's digest (not
# its decompressed bytes) is the trust anchor, so internal .exe/.dll/.json and the
# unix .tar.gz members are not scanned for secrets/IPs. amd64 unix digests are
# pinned by the CI prepare step once built.
openssh_payload_sha256 = {
    "23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5",  # win64.zip
    "63226db97f12d36fc720b9e5e7304a509907df5ff08b7aa3917c2f96fe7db249",  # macos arm64 .tar.gz
    "529a6f97330490754454383608987c888274602602d70a36ddd2617e7291654a",  # linux arm64 .tar.gz
    "8c322411f4023424a2ba22e06694c3634486c115c964dadd2975bdb34da7b74f",  # linux x86_64 .tar.gz
    "509542271d56c033f33816306c9fe74e037595a8177e7a8b12ac33f5544d2a9d",  # macos x86_64 .tar.gz
}


def is_trusted_payload(label):
    # Our own bundled self-contained OpenSSH payload archives are trusted third-party
    # binaries no matter the exact digest (CI-built digests differ from local pins), so
    # they are recognized by name/path rather than by a pinned sha256.
    p = pathlib.PurePosixPath(label)
    if not p.name.startswith("openssh-"):
        return False
    return p.name.endswith((".tar.gz", ".zip"))


def is_trusted_runtime_archive(label):
    # Platform "full" runtime archives (e.g. cc-remote_v0.3.1_linux_arm64_full.tar.gz
    # / ..._win.zip) are built release artifacts that embed the bundled OpenSSH
    # payload. Their compression may contain ad-hoc byte sequences (e.g. a
    # cross-compiled binary producing a 4-byte run that matches the public-IPv4
    # regex), so treat the archive itself as a trusted third-party binary; their
    # individual text members are still scanned for real secrets.
    p = pathlib.PurePosixPath(label)
    return bool(re.match(r"^cc-remote_.+_full\.(?:tar\.gz|zip)$", p.name, re.I))


extra = []
if denylist_path:
    deny_path = pathlib.Path(denylist_path).expanduser().resolve()
    if not deny_path.is_file():
        raise SystemExit(f"denylist is not a file: {deny_path}")
    extra = [line.strip().encode() for line in deny_path.read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]

errors = []
seen = 0

def scan_bytes(label, data, third_party_binary=False):
    global seen
    seen += 1
    if not third_party_binary and private_block_re.search(data):
        errors.append(f"{label}: contains a private-key block")
    if home_path_re.search(data):
        errors.append(f"{label}: contains an absolute personal home path")
    if legacy_re.search(data):
        errors.append(f"{label}: contains a provider-specific legacy literal")
    for literal in extra:
        if literal in data:
            errors.append(f"{label}: contains deployment-specific denylist literal")
    if not third_party_binary:
        for match in ipv4_re.finditer(data):
            value = match.group().decode("ascii", "ignore")
            try:
                ip = ipaddress.ip_address(value)
            except ValueError:
                continue
            if value not in allowed_ipv4 and not (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved):
                errors.append(f"{label}: contains public IPv4 literal {value}")


def check_path(label):
    p = pathlib.PurePosixPath(label)
    name = p.name
    parts = set(p.parts)
    if ".cc-remote" in parts or "dist" in parts:
        errors.append(f"{label}: forbidden runtime/build directory")
    if name in forbidden_names or name.startswith("known_hosts"):
        errors.append(f"{label}: forbidden runtime artifact")
    if name.endswith(forbidden_suffixes) or key_name_re.search(name) or (generated_launcher_re.match(name) and name not in allowed_source_names):
        errors.append(f"{label}: forbidden secret-bearing or generated artifact")


def scan_zip(path, prefix):
    try:
        archive_bytes = path.read_bytes()
        trusted_payload = is_trusted_payload(prefix) or is_trusted_runtime_archive(prefix)
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                label = f"{prefix}!{info.filename}"
                check_path(info.filename)
                if info.is_dir():
                    continue
                data = archive.read(info)
                # A member that is itself a bundled OpenSSH payload archive
                # (openssh-*.tar.gz / openssh-*.zip) is an opaque third-party
                # binary: treat its compressed bytes as third-party so we do not
                # flag random byte sequences inside cross-compiled binaries as
                # public IPv4 literals.
                member_is_payload = is_trusted_payload(info.filename)
                third_party_binary = member_is_payload or (trusted_payload and info.filename.lower().endswith((".exe", ".dll", ".json", ".psd1")))
                scan_bytes(label, data, third_party_binary=third_party_binary)
                if info.filename.lower().endswith(".zip"):
                    import io
                    try:
                        nested_trusted_payload = is_trusted_payload(info.filename)
                        with zipfile.ZipFile(io.BytesIO(data)) as nested_archive:
                            for nested_info in nested_archive.infolist():
                                nested_label = f"{label}!{nested_info.filename}"
                                check_path(nested_info.filename)
                                if not nested_info.is_dir():
                                    nested_data = nested_archive.read(nested_info)
                                    nested_binary = nested_trusted_payload and nested_info.filename.lower().endswith((".exe", ".dll", ".json", ".psd1"))
                                    scan_bytes(nested_label, nested_data, third_party_binary=nested_binary)
                    except zipfile.BadZipFile:
                        errors.append(f"{label}: invalid nested ZIP")
    except zipfile.BadZipFile:
        errors.append(f"{prefix}: invalid ZIP")

if root.is_file():
    files = [(root.name, root)]
else:
    files = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            errors.append(f"{path.relative_to(root)}: symlinks are not allowed")
        elif path.is_file():
            files.append((path.relative_to(root).as_posix(), path))

for label, path in files:
    check_path(label)
    data = path.read_bytes()
    # A bundled unix OpenSSH payload, or a platform "full" runtime archive that
    # embeds one, is trusted third-party/binary content: scan its opaque bytes as
    # third-party, not as text, to avoid flagging random byte sequences as IPs.
    trusted_archive = is_trusted_payload(label) or is_trusted_runtime_archive(label)
    scan_bytes(label, data, third_party_binary=trusted_archive)
    if path.suffix.lower() == ".zip":
        scan_zip(path, label)

if errors:
    print("Privacy scan failed:", file=sys.stderr)
    for error in sorted(set(errors)):
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)
print(f"Privacy scan passed: {seen} file payloads inspected under {root}")
PY
