#!/bin/sh
cd "$(dirname "$0")" || exit 1
/bin/sh ./install.sh
rc=$?
printf '\n'
if [ "$rc" -eq 0 ]; then
  printf 'Install finished. You can now run: cc-remote doctor --json\n'
else
  printf 'Install failed with exit code %s.\n' "$rc"
fi
printf 'Press Return to close this window...'
IFS= read -r _ || true
exit "$rc"
