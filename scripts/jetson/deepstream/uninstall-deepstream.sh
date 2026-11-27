#!/usr/bin/env bash
# Remove what install-deepstream.sh added: the DeepStream root
# (/opt/nano-ds601) and /usr/local/bin/nano-deepstream. Ubuntu 26.04 and its
# GPU stack were never changed, so nothing else is touched. The tools the
# installer took from Ubuntu's archive (debootstrap, curl, gpg) are named at
# the end, not removed; your ~/deepstream-check records stay too.
#
# Usage: sudo bash uninstall-deepstream.sh
set -uo pipefail

ROOT=${NANO_DS_ROOT:-/opt/nano-ds601}
LAUNCHER=/usr/local/bin/nano-deepstream

[[ $(id -u) -eq 0 ]] || { echo 'run this with sudo' >&2; exit 1; }
tools=''
if [[ -e $ROOT ]]; then
    [[ -f $ROOT/.nano-ds601 ]] || { echo "$ROOT is not DeepStream's root (no .nano-ds601); nothing removed" >&2; exit 1; }
    findmnt -rn -o TARGET | grep -q "^$ROOT/" && { echo "something is mounted under $ROOT (is nano-deepstream running?); nothing removed" >&2; exit 1; }
    [[ -f $ROOT/.nano-ds601-host-tools ]] && tools=$(sort -u "$ROOT/.nano-ds601-host-tools" | tr '\n' ' ')
    rm -rf --one-file-system -- "$ROOT" || { echo "could not remove all of $ROOT" >&2; exit 1; }
    echo "REMOVED $ROOT"
fi
if [[ -f $LAUNCHER ]]; then
    grep -q '^# nano-deepstream: run a program in DeepStream' "$LAUNCHER" \
        || { echo "$LAUNCHER is not this project's launcher; left as it is" >&2; exit 1; }
    rm -f -- "$LAUNCHER" && echo "REMOVED $LAUNCHER"
fi
tools=${tools% }
[[ -n $tools ]] && echo "The installer also installed: $tools (remove with: sudo apt purge $tools)"
echo 'DEEPSTREAM_UNINSTALL=PASS'
