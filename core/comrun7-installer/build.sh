#!/bin/sh
# Prepare this installer bundle in the package build directory.
# The LiveCD deliberately does NOT carry these scripts or helper binaries.
set -eu

cd "$(dirname "$0")"

CC="${CC:-cc}"
CFLAGS="-march=x86-64 -mtune=generic -O2 -Wall -Wextra"

echo "[installer] building comrun7-hashpw"
if "$CC" $CFLAGS -o comrun7-hashpw hashpw.c -lcrypt 2>/dev/null; then
    :
else
    cryptlib=""
    for candidate in \
        /lib64/libcrypt.so.2 /lib/libcrypt.so.2 \
        /usr/lib64/libcrypt.so.2 /usr/lib/libcrypt.so.2 \
        /lib64/libcrypt.so.1 /lib/libcrypt.so.1 \
        /usr/lib64/libcrypt.so.1 /usr/lib/libcrypt.so.1; do
        if [ -e "$candidate" ]; then
            cryptlib="$candidate"
            break
        fi
    done
    [ -n "$cryptlib" ] || {
        echo "[installer] cannot find libcrypt; install crypt development files" >&2
        exit 1
    }
    "$CC" $CFLAGS -o comrun7-hashpw hashpw.c "$cryptlib"
fi

chmod 0755 comrun7-install.py install-to-disk.sh comrun7-adduser.sh \
    write_grub_cfg.sh comrun7-hashpw

if command -v python3 >/dev/null 2>&1 && \
   python3 -c 'import curses' >/dev/null 2>&1; then
    echo "[installer] Python 3 + curses found"
else
    echo "[installer] WARNING: Python 3 with curses is required for the TUI" >&2
    echo "[installer] You can still use install-to-disk.sh directly." >&2
fi

echo "[installer] ready: ./comrun7-install.py"
