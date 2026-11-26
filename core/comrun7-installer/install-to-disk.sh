#!/bin/sh
# Install comrun7 onto a disk from a booted LiveCD.
# Usage: ./install-to-disk.sh /dev/sdX
#
# This file comes from the gitupacrep core/comrun7-installer package, not from
# the LiveCD image.  Helpers are found next to this script.
#
# The target disk is erased and repartitioned as:
#   1) 1 MiB BIOS boot partition
#   2) 512 MiB EFI system partition
#   3) remaining space, ext4 root filesystem
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Some helper scripts inherited from the build environment expect this to be
# set.  In a booted LiveCD the current root is the install source.
COMRUN7_ROOT="${COMRUN7_ROOT:-/}"
export COMRUN7_ROOT

DEV="${1:-}"

if [ "$(id -u)" != "0" ]; then
    echo "Run as root: sudo install-comrun7 /dev/sdX" >&2
    exit 1
fi

case "$DEV" in
    /dev/sd?|/dev/hd?|/dev/vd?|/dev/nvme?n?) ;;
    *)
        echo "Usage: $0 /dev/sdX" >&2
        echo >&2
        echo "Available disks:" >&2
        lsblk -o NAME,SIZE,TYPE,MODEL >&2 || true
        exit 2
        ;;
esac

[ -b "$DEV" ] || { echo "Not a block device: $DEV" >&2; exit 2; }

REMOVABLE="$(lsblk -no RM "$DEV" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
if [ "$REMOVABLE" != "1" ] && [ "${COMRUN7_FORCE_DISK:-0}" != "1" ]; then
    echo "Refusing to install to a non-removable disk ($DEV)." >&2
    echo "Set COMRUN7_FORCE_DISK=1 if this is the intended T420 drive." >&2
    exit 2
fi

SRC_BOOT=""
for dir in /run/initramfs/cdrom/boot /boot; do
    if [ -f "$dir/vmlinuz" ] && [ -f "$dir/initrd.gz" ]; then
        SRC_BOOT="$dir"
        break
    fi
done
[ -n "$SRC_BOOT" ] || { echo "Cannot find vmlinuz/initrd.gz on the live media" >&2; exit 1; }

ROOTFS_PROFILE=/etc/comrun7/rootfs.conf
if [ -f "$ROOTFS_PROFILE" ]; then
    # shellcheck disable=SC1090
    . "$ROOTFS_PROFILE"
fi
FS_NAME="${FS_NAME:-ext4}"
FS_LABEL="${FS_LABEL:-COMRUN7-ROOT}"
FS_GPT_CODE="${FS_GPT_CODE:-8300}"
MKFS_CMD="${MKFS_CMD:-mkfs.ext4 -F -L $FS_LABEL %PART%}"
ROOT_MOUNTOPTS="${ROOT_MOUNTOPTS:-defaults,noatime}"
ROOT_ID_KIND="${ROOT_ID_KIND:-UUID}"

# Installer profile: hostname, users, locale, home layout, etc. Environment
# variables always win over the selected profile.  The LiveCD no longer ships
# an installer profile; the package example is used when nothing is set.
if [ -n "${COMRUN7_INSTALL_CONF:-}" ]; then
    INSTALL_CONF="$COMRUN7_INSTALL_CONF"
elif [ -f /etc/comrun7/install.conf ]; then
    INSTALL_CONF=/etc/comrun7/install.conf
else
    INSTALL_CONF="$SCRIPT_DIR/install.conf.example"
fi
if [ -f "$INSTALL_CONF" ]; then
    # shellcheck disable=SC1090
    . "$INSTALL_CONF"
fi
INSTALL_HOSTNAME="${INSTALL_HOSTNAME:-comrun7}"
INSTALL_TIMEZONE="${INSTALL_TIMEZONE:-UTC}"
INSTALL_KEYMAP="${INSTALL_KEYMAP:-us}"
INSTALL_LOCALE="${INSTALL_LOCALE:-C.UTF-8}"
INSTALL_USER_NAME="${INSTALL_USER_NAME:-user}"
INSTALL_USER_GECOS="${INSTALL_USER_GECOS:-$INSTALL_USER_NAME}"
INSTALL_USER_HOME="${INSTALL_USER_HOME:-/home/$INSTALL_USER_NAME}"
INSTALL_USER_SHELL="${INSTALL_USER_SHELL:-/bin/sh}"
INSTALL_USER_GROUPS="${INSTALL_USER_GROUPS:-wheel netdev}"
INSTALL_CREATE_HOME="${INSTALL_CREATE_HOME:-1}"
INSTALL_HOME_MODE="${INSTALL_HOME_MODE:-0755}"
INSTALL_ROOT_PASSWORD_MODE="${INSTALL_ROOT_PASSWORD_MODE:-same-as-user}"
INSTALL_ROOT_PASSWORD_HASH="${INSTALL_ROOT_PASSWORD_HASH:-}"
INSTALL_ROOT_PASSWORD="${INSTALL_ROOT_PASSWORD:-}"
INSTALL_USER_PASSWORD_HASH="${INSTALL_USER_PASSWORD_HASH:-}"
INSTALL_USER_PASSWORD="${INSTALL_USER_PASSWORD:-}"
INSTALL_USER_UID="${INSTALL_USER_UID:-}"
INSTALL_USER_GID="${INSTALL_USER_GID:-}"
INSTALL_EFI_SIZE_MB="${INSTALL_EFI_SIZE_MB:-512}"
INSTALL_SWAP_SIZE_MB="${INSTALL_SWAP_SIZE_MB:-0}"
INSTALL_BIOS_GRUB="${INSTALL_BIOS_GRUB:-1}"
INSTALL_SERIAL_ENTRY="${INSTALL_SERIAL_ENTRY:-0}"

case "$INSTALL_EFI_SIZE_MB" in *[!0-9]*|'') echo "invalid EFI size" >&2; exit 2 ;; esac
case "$INSTALL_SWAP_SIZE_MB" in *[!0-9]*|'') echo "invalid swap size" >&2; exit 2 ;; esac

echo "This will ERASE ALL DATA on $DEV and install comrun7 ($FS_NAME root)."
echo "Hostname: $INSTALL_HOSTNAME"
if [ -n "$INSTALL_USER_NAME" ]; then
    echo "Primary user: $INSTALL_USER_NAME ($INSTALL_USER_HOME)"
fi
printf 'Type YES to continue: '
read -r ANSWER
[ "$ANSWER" = "YES" ] || { echo "Cancelled."; exit 0; }

for part in "${DEV}1" "${DEV}2" "${DEV}3" "${DEV}p1" "${DEV}p2" "${DEV}p3"; do
    mountpoint="$(findmnt -rn -S "$part" -o TARGET 2>/dev/null || true)"
    [ -n "$mountpoint" ] && umount "$mountpoint" 2>/dev/null || true
done

wipefs -a "$DEV" 2>/dev/null || true
sgdisk -Z "$DEV"
sgdisk -n 1:0:+1M -t 1:ef02 -c 1:COMRUN7-BIOS "$DEV"
sgdisk -n 2:0:+${INSTALL_EFI_SIZE_MB}M -t 2:ef00 -c 2:COMRUN7-EFI "$DEV"
sgdisk -n 3:0:0 -t 3:$FS_GPT_CODE -c 3:$FS_LABEL "$DEV"
if [ "$INSTALL_SWAP_SIZE_MB" -gt 0 ]; then
    sgdisk -n 4:0:+${INSTALL_SWAP_SIZE_MB}M -t 4:8200 -c 4:COMRUN7-SWAP "$DEV"
fi
partprobe "$DEV" 2>/dev/null || true
sleep 1

case "$DEV" in
    /dev/nvme?n?) P1="${DEV}p1"; P2="${DEV}p2"; P3="${DEV}p3"; P4="${DEV}p4" ;;
    *)            P1="${DEV}1"; P2="${DEV}2"; P3="${DEV}3"; P4="${DEV}4" ;;
esac

mkfs.vfat -F32 -n COMRUN7-EFI "$P2"
FORMAT_CMD=$(printf '%s\n' "$MKFS_CMD" | sed "s|%PART%|$P3|g")
$FORMAT_CMD
if [ "$INSTALL_SWAP_SIZE_MB" -gt 0 ]; then
    mkswap -L COMRUN7-SWAP "$P4"
fi

mkdir -p /mnt/comrun7
mount "$P3" /mnt/comrun7
# Create the EFI mount point on the newly mounted root; creating it before
# mounting P3 would hide it under the root mount.
mkdir -p /mnt/comrun7/boot/efi
mount "$P2" /mnt/comrun7/boot/efi

# Copy the writable view of the live root, excluding virtual and live-only
# mount points. The chroot below is the installed root, not the live overlay.
cd /
tar --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
    --exclude=./mnt --exclude=./boot/efi --exclude=./.old_root \
    --exclude=./home \
    -cf - . | (cd /mnt/comrun7 && tar -xf -)

# --- System identity and user configuration -------------------------------
TARGET=/mnt/comrun7
mkdir -p "$TARGET/etc" "$TARGET/home"

printf '%s\n' "$INSTALL_HOSTNAME" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1   localhost localhost.localdomain $INSTALL_HOSTNAME
::1         localhost ip6-localhost ip6-loopback $INSTALL_HOSTNAME
127.0.1.1   $INSTALL_HOSTNAME
EOF
cat > "$TARGET/etc/locale.conf" <<EOF
LANG=$INSTALL_LOCALE
EOF
cat > "$TARGET/etc/vconsole.conf" <<EOF
KEYMAP=$INSTALL_KEYMAP
EOF

if [ -e "$TARGET/usr/share/zoneinfo/$INSTALL_TIMEZONE" ]; then
    ln -sfn "../usr/share/zoneinfo/$INSTALL_TIMEZONE" "$TARGET/etc/localtime"
else
    echo "WARNING: timezone $INSTALL_TIMEZONE not found; leaving UTC" >&2
fi

# Password helpers. Plaintext never appears in the process list; the helper
# reads it from a pipe.
read_password() {
    label="$1"
    if [ -t 0 ] && command -v stty >/dev/null 2>&1; then
        printf '%s: ' "$label" >&2
        stty -echo
        trap 'stty echo 2>/dev/null || true' INT TERM
        IFS= read -r PASSWORD_RESULT
        stty echo
        trap - INT TERM
        printf '\n' >&2
    else
        printf '%s: ' "$label" >&2
        IFS= read -r PASSWORD_RESULT
    fi
}

ask_password() {
    label="$1"
    while :; do
        read_password "$label" || return 1
        first="$PASSWORD_RESULT"
        read_password "Confirm $label" || return 1
        [ "$first" = "$PASSWORD_RESULT" ] && break
        echo "Passwords do not match; try again." >&2
    done
    PASSWORD_RESULT="$first"
}

hash_password() {
    printf '%s\n' "$1" | "$HASHPW"
}

set_shadow_hash() {
    shadow_file="$1"
    user="$2"
    hash="$3"
    [ -f "$shadow_file" ] || printf 'root:!:0:0:99999:7:::\n' > "$shadow_file"
    if grep -q "^$user:" "$shadow_file"; then
        awk -F: -v u="$user" -v h="$hash" 'BEGIN { OFS = ":" }
            $1 == u { $2 = h }
            { print }' "$shadow_file" > "$shadow_file.new"
    else
        cat "$shadow_file" > "$shadow_file.new"
        printf '%s:%s:0:0:99999:7:::\n' "$user" "$hash" >> "$shadow_file.new"
    fi
    mv "$shadow_file.new" "$shadow_file"
    chmod 0600 "$shadow_file" 2>/dev/null || true
}

USERS_FILE="${COMRUN7_USERS_FILE:-}"
ADDUSER="${COMRUN7_ADDUSER:-$SCRIPT_DIR/comrun7-adduser.sh}"
HASHPW="${COMRUN7_HASHPW:-$SCRIPT_DIR/comrun7-hashpw}"
WRITE_GRUB_CFG="${COMRUN7_WRITE_GRUB_CFG:-$SCRIPT_DIR/write_grub_cfg.sh}"
USER_HASH=""

[ -x "$ADDUSER" ] || { echo "missing helper: $ADDUSER" >&2; exit 1; }
[ -x "$HASHPW" ] || { echo "missing helper: $HASHPW (reinstall the package)" >&2; exit 1; }
[ -r "$WRITE_GRUB_CFG" ] || { echo "missing helper: $WRITE_GRUB_CFG" >&2; exit 1; }

# Additional users can be supplied by the graphical installer as lines of:
# name|hash|home|shell|groups|gecos|uid|gid|create_home|mode
# The GUI leaves INSTALL_USER_NAME empty so users are created here only.
if [ -n "$USERS_FILE" ] && [ -f "$USERS_FILE" ]; then
    first_hash=""
    while IFS='|' read -r u_name u_hash u_home u_shell u_groups u_gecos \
                          u_uid u_gid u_create_home u_mode; do
        [ -n "$u_name" ] || continue
        [ -n "$first_hash" ] || first_hash="$u_hash"
        set --
        set -- "$@" -D "$TARGET" -c "$u_gecos" -h "$u_home" -s "$u_shell"
        set -- "$@" -G "$u_groups" -p "$u_hash"
        [ -n "$u_uid" ] && set -- "$@" -u "$u_uid"
        [ -n "$u_gid" ] && set -- "$@" -g "$u_gid"
        [ "$u_create_home" = "1" ] || set -- "$@" -H
        [ -n "$u_mode" ] && set -- "$@" -m "$u_mode"
        "$ADDUSER" "$@" "$u_name"
    done < "$USERS_FILE"
    USER_HASH="$first_hash"
fi

if [ -n "$INSTALL_USER_NAME" ]; then
    if [ -n "$INSTALL_USER_PASSWORD_HASH" ]; then
        USER_HASH="$INSTALL_USER_PASSWORD_HASH"
    elif [ -n "$INSTALL_USER_PASSWORD" ]; then
        USER_HASH=$(hash_password "$INSTALL_USER_PASSWORD")
    else
        ask_password "Password for $INSTALL_USER_NAME" || exit 1
        USER_HASH=$(hash_password "$PASSWORD_RESULT")
    fi

    set --
    set -- "$@" -D "$TARGET" -c "$INSTALL_USER_GECOS" -h "$INSTALL_USER_HOME"
    set -- "$@" -s "$INSTALL_USER_SHELL" -G "$INSTALL_USER_GROUPS"
    set -- "$@" -p "$USER_HASH"
    [ -n "$INSTALL_USER_UID" ] && set -- "$@" -u "$INSTALL_USER_UID"
    [ -n "$INSTALL_USER_GID" ] && set -- "$@" -g "$INSTALL_USER_GID"
    [ "$INSTALL_CREATE_HOME" = "1" ] || set -- "$@" -H
    set -- "$@" -m "$INSTALL_HOME_MODE"
    "$ADDUSER" "$@" "$INSTALL_USER_NAME"
fi

case "$INSTALL_ROOT_PASSWORD_MODE" in
    lock)
        set_shadow_hash "$TARGET/etc/shadow" root '!'
        ;;
    hash)
        [ -n "$INSTALL_ROOT_PASSWORD_HASH" ] || { echo "root password hash is empty" >&2; exit 1; }
        set_shadow_hash "$TARGET/etc/shadow" root "$INSTALL_ROOT_PASSWORD_HASH"
        ;;
    prompt)
        ask_password "Root password" || exit 1
        set_shadow_hash "$TARGET/etc/shadow" root "$(hash_password "$PASSWORD_RESULT")"
        ;;
    same-as-user)
        [ -n "$USER_HASH" ] || { echo "no user hash for same-as-user root mode" >&2; exit 1; }
        set_shadow_hash "$TARGET/etc/shadow" root "$USER_HASH"
        ;;
    *)
        echo "unknown INSTALL_ROOT_PASSWORD_MODE: $INSTALL_ROOT_PASSWORD_MODE" >&2
        exit 1
        ;;
esac

GRUB_CFG=/mnt/comrun7/boot/grub/grub.cfg
KERNEL_PROFILE=/mnt/comrun7/etc/comrun7/kernel.conf
if [ -f "$KERNEL_PROFILE" ]; then
    # shellcheck disable=SC1090
    . "$KERNEL_PROFILE"
fi
KERNEL_NEEDS_INITRD="${KERNEL_NEEDS_INITRD:-1}"

mkdir -p /mnt/comrun7/boot /mnt/comrun7/boot/efi/boot
cp "$SRC_BOOT/vmlinuz" /mnt/comrun7/boot/vmlinuz
cp /mnt/comrun7/boot/vmlinuz /mnt/comrun7/boot/efi/boot/vmlinuz
if [ "$KERNEL_NEEDS_INITRD" = "1" ]; then
    [ -f "$SRC_BOOT/initrd.gz" ] || { echo "Missing initrd.gz for this kernel profile" >&2; exit 1; }
    cp "$SRC_BOOT/initrd.gz" /mnt/comrun7/boot/initrd.gz
    cp /mnt/comrun7/boot/initrd.gz /mnt/comrun7/boot/efi/boot/initrd.gz
fi

ROOT_UUID="$(blkid -s UUID -o value "$P3" 2>/dev/null || true)"
case "$ROOT_ID_KIND" in
    UUID)
        [ -n "$ROOT_UUID" ] || { echo "Cannot read root filesystem UUID" >&2; exit 1; }
        ROOT_ID="UUID=$ROOT_UUID"
        ROOT_FSTAB="UUID=$ROOT_UUID"
        SEARCH_OPT="--fs-uuid"
        SEARCH_VALUE="$ROOT_UUID"
        ;;
    LABEL)
        [ -n "$FS_LABEL" ] || { echo "No FS_LABEL in rootfs profile" >&2; exit 1; }
        ROOT_ID="LABEL=$FS_LABEL"
        ROOT_FSTAB="LABEL=$FS_LABEL"
        SEARCH_OPT="--label"
        SEARCH_VALUE="$FS_LABEL"
        ;;
    DEV)
        ROOT_ID="$P3"
        ROOT_FSTAB="$P3"
        SEARCH_OPT=""
        SEARCH_VALUE=""
        ;;
    *)
        echo "Unknown ROOT_ID_KIND: $ROOT_ID_KIND" >&2
        exit 1
        ;;
esac

cat > /mnt/comrun7/etc/fstab <<EOF
$ROOT_FSTAB / $FS_NAME $ROOT_MOUNTOPTS 0 1
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF
if [ "$INSTALL_SWAP_SIZE_MB" -gt 0 ]; then
    printf '%s\n' "$P4 none swap sw 0 0" >> /mnt/comrun7/etc/fstab
fi

COMRUN7_SERIAL_ENTRY="$INSTALL_SERIAL_ENTRY" \
"$WRITE_GRUB_CFG" "$GRUB_CFG" "$ROOT_ID" "$KERNEL_PROFILE" \
    /boot/vmlinuz /boot/initrd.gz "$SEARCH_OPT" "$SEARCH_VALUE" "$FS_NAME"

# Install both UEFI and legacy BIOS boot paths when the modules are available.
# With --boot-directory=<ESP>, GRUB looks for <ESP>/grub/grub.cfg, not
# <ESP>/boot/grub/grub.cfg.  Copy the config to every path a firmware may use.
if [ -d /mnt/comrun7/usr/lib/grub/x86_64-efi ]; then
    grub-install --target=x86_64-efi --recheck \
        --efi-directory=/mnt/comrun7/boot/efi \
        --boot-directory=/mnt/comrun7/boot/efi \
        --removable || echo "WARNING: UEFI grub-install failed" >&2
    mkdir -p /mnt/comrun7/boot/efi/grub /mnt/comrun7/boot/efi/boot/grub
    cp "$GRUB_CFG" /mnt/comrun7/boot/efi/grub/grub.cfg
    cp "$GRUB_CFG" /mnt/comrun7/boot/efi/boot/grub/grub.cfg
fi
if [ "$INSTALL_BIOS_GRUB" = "1" ] && [ -d /mnt/comrun7/usr/lib/grub/i386-pc ]; then
    grub-install --target=i386-pc --recheck \
        --boot-directory=/mnt/comrun7/boot \
        "$DEV" || echo "WARNING: BIOS grub-install failed" >&2
fi

sync
umount /mnt/comrun7/boot/efi 2>/dev/null || true
umount /mnt/comrun7 2>/dev/null || true

echo "comrun7 installed to $DEV"
echo "Reboot, remove the live media, and boot from the internal disk."
