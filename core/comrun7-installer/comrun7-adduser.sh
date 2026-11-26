#!/bin/sh
# Create a user in a target root tree without relying on shadow-utils.
# Used by install-to-disk.sh and usable later from an installed system.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

ROOT="/"
NAME=""
GECOS=""
HOME_DIR=""
SHELL_PATH="/bin/sh"
EXTRA_GROUPS=""
UID_VALUE=""
GID_VALUE=""
CREATE_HOME=1
HOME_MODE=0755
PASSWORD=""
PASSWORD_HASH=""

usage() {
    cat >&2 <<EOF
Usage: comrun7-adduser [options] USER
  -D ROOT          target root tree (default /)
  -u UID           numeric uid (auto if omitted)
  -g GID           primary gid (auto if omitted)
  -c GECOS         user description
  -h DIR           home directory (default /home/USER)
  -s SHELL         login shell (default /bin/sh)
  -G GROUPS        comma/space separated supplementary groups
  -p HASH          pre-hashed password (preferred)
  -P PASSWORD      plaintext password (hashed with comrun7-hashpw)
  -H               do not create the home directory
  -m MODE          home directory mode (default 0755)
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -D) ROOT="$2"; shift 2 ;;
        -u) UID_VALUE="$2"; shift 2 ;;
        -g) GID_VALUE="$2"; shift 2 ;;
        -c) GECOS="$2"; shift 2 ;;
        -h) HOME_DIR="$2"; shift 2 ;;
        -s) SHELL_PATH="$2"; shift 2 ;;
        -G) EXTRA_GROUPS="$2"; shift 2 ;;
        -p) PASSWORD_HASH="$2"; shift 2 ;;
        -P) PASSWORD="$2"; shift 2 ;;
        -H) CREATE_HOME=0; shift ;;
        -m) HOME_MODE="$2"; shift 2 ;;
        -*) usage ;;
        *)
            [ -z "$NAME" ] || usage
            NAME="$1"
            shift
            ;;
    esac
done

[ -n "$NAME" ] || usage
case "$NAME" in
    *[!a-z0-9_-]*|''|[0-9]*) echo "invalid user name: $NAME" >&2; exit 2 ;;
esac

PASSWD="$ROOT/etc/passwd"
SHADOW="$ROOT/etc/shadow"
GROUP="$ROOT/etc/group"
GSHADOW="$ROOT/etc/gshadow"
[ -f "$PASSWD" ] || { echo "missing $PASSWD" >&2; exit 1; }

if grep -q "^$NAME:" "$PASSWD"; then
    echo "user already exists: $NAME" >&2
    exit 1
fi

[ -n "$GECOS" ] || GECOS="$NAME"
[ -n "$HOME_DIR" ] || HOME_DIR="/home/$NAME"

if [ -z "$UID_VALUE" ]; then
    UID_VALUE=$(awk -F: '$3 >= 1000 && $3 < 65534 { if ($3 > m) m = $3 } END { print (m ? m + 1 : 1000) }' "$PASSWD")
fi
case "$UID_VALUE" in *[!0-9]*|'') echo "invalid uid: $UID_VALUE" >&2; exit 1 ;; esac
if awk -F: -v u="$UID_VALUE" '$3 == u { found = 1 } END { exit !found }' "$PASSWD"; then
    echo "uid already in use: $UID_VALUE" >&2
    exit 1
fi

if [ -z "$GID_VALUE" ]; then
    GID_VALUE="$UID_VALUE"
fi
case "$GID_VALUE" in *[!0-9]*|'') echo "invalid gid: $GID_VALUE" >&2; exit 1 ;; esac

# Always give the user a private primary group unless one was requested.
if ! grep -q "^$NAME:" "$GROUP"; then
    used_gid=$(awk -F: -v g="$GID_VALUE" '$3 == g { found = 1 } END { exit !found }' "$GROUP" && echo yes || echo no)
    if [ "$used_gid" = "yes" ]; then
        GID_VALUE=$(awk -F: '$3 >= 1000 && $3 < 65534 { if ($3 > m) m = $3 } END { print (m ? m + 1 : 1000) }' "$GROUP")
        while awk -F: -v g="$GID_VALUE" '$3 == g { found = 1 } END { exit !found }' "$GROUP"; do
            GID_VALUE=$((GID_VALUE + 1))
        done
    fi
    printf '%s:x:%s:\n' "$NAME" "$GID_VALUE" >> "$GROUP"
    [ -f "$GSHADOW" ] || : > "$GSHADOW"
    printf '%s:*::\n' "$NAME" >> "$GSHADOW"
fi

# Supplementary groups. Names must already exist or are created with a new gid.
EXTRA_GROUPS=$(printf '%s\n' "$EXTRA_GROUPS" | tr ',' ' ')
for group in $EXTRA_GROUPS; do
    case "$group" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
    if ! grep -q "^$group:" "$GROUP"; then
        new_gid=$(awk -F: '$3 >= 1000 && $3 < 65534 { if ($3 > m) m = $3 } END { print (m ? m + 1 : 1000) }' "$GROUP")
        while awk -F: -v g="$new_gid" '$3 == g { found = 1 } END { exit !found }' "$GROUP"; do
            new_gid=$((new_gid + 1))
        done
        printf '%s:x:%s:\n' "$group" "$new_gid" >> "$GROUP"
        [ -f "$GSHADOW" ] || : > "$GSHADOW"
        printf '%s:*::\n' "$group" >> "$GSHADOW"
    fi
    awk -F: -v g="$group" -v u="$NAME" 'BEGIN { OFS = ":" }
        $1 == g {
            n = split($4, members, ",")
            seen = 0
            for (i = 1; i <= n; i++) if (members[i] == u) seen = 1
            $4 = seen ? $4 : ($4 == "" ? u : $4 "," u)
        }
        { print }' "$GROUP" > "$GROUP.new"
    mv "$GROUP.new" "$GROUP"
done

# Shadow files are created on demand so an installed system always has them.
[ -f "$SHADOW" ] || : > "$SHADOW"
[ -f "$GSHADOW" ] || : > "$GSHADOW"
chmod 0600 "$SHADOW" "$GSHADOW" 2>/dev/null || true

if [ -n "$PASSWORD_HASH" ]; then
    hash="$PASSWORD_HASH"
elif [ -n "$PASSWORD" ]; then
    HASHER="$SCRIPT_DIR/comrun7-hashpw"
    [ -x "$HASHER" ] || HASHER=/usr/bin/comrun7-hashpw
    [ -x "$HASHER" ] || HASHER=$(command -v comrun7-hashpw || true)
    [ -n "$HASHER" ] || { echo "comrun7-hashpw not found" >&2; exit 1; }
    hash=$(printf '%s\n' "$PASSWORD" | "$HASHER")
else
    hash='!'
fi

printf '%s:x:%s:%s:%s:%s:%s\n' \
    "$NAME" "$UID_VALUE" "$GID_VALUE" "$GECOS" "$HOME_DIR" "$SHELL_PATH" >> "$PASSWD"
printf '%s:%s:0:0:99999:7:::\n' "$NAME" "$hash" >> "$SHADOW"

if [ "$CREATE_HOME" = "1" ]; then
    mkdir -p "$ROOT$HOME_DIR"
    if [ -d "$ROOT/etc/skel" ]; then
        cp -a "$ROOT/etc/skel/." "$ROOT$HOME_DIR/"
    fi
    chown -R "$UID_VALUE:$GID_VALUE" "$ROOT$HOME_DIR"
    chmod "$HOME_MODE" "$ROOT$HOME_DIR"
fi

echo "created user $NAME (uid $UID_VALUE, gid $GID_VALUE)"
