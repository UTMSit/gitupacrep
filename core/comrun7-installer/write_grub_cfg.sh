#!/bin/sh
# Generate the installed-system GRUB config from a kernel profile.
#
# Usage:
#   write_grub_cfg.sh OUTPUT ROOT_ID PROFILE [VMLINUZ] [INITRD] [SEARCH_OPT] [SEARCH_VALUE] [ROOT_FSTYPE]
#
# ROOT_ID is what the kernel receives: UUID=..., LABEL=..., or a device path.
# VMLINUZ/INITRD are GRUB paths (default /boot/vmlinuz, /boot/initrd.gz).
# SEARCH_OPT/SEARCH_VALUE override GRUB's root search, e.g. --label COMRUN7.
set -eu

OUT="$1"
ROOT_ID="$2"
PROFILE="$3"
VMLINUZ="${4:-/boot/vmlinuz}"
INITRD="${5:-/boot/initrd.gz}"
SEARCH_OPT="${6:-}"
SEARCH_VALUE="${7:-}"
ROOT_FSTYPE="${8:-ext4}"

[ -f "$PROFILE" ] || { echo "missing kernel profile: $PROFILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$PROFILE"

: "${KERNEL_NAME:=comrun7}"
: "${KERNEL_ROOT_PARAM:=comrun7.root=%ROOTID%}"
: "${KERNEL_NEEDS_INITRD:=1}"
: "${KERNEL_CONSOLE:=console=tty0 loglevel=4}"
: "${KERNEL_CONSOLE_SERIAL:=console=ttyS0,115200n8 loglevel=4}"
: "${KERNEL_EXTRA:=}"
: "${KERNEL_SERIAL_ENTRY:=1}"
: "${COMRUN7_SERIAL_ENTRY:=$KERNEL_SERIAL_ENTRY}"

ROOT_UUID=""
case "$ROOT_ID" in
    UUID=*) ROOT_UUID="${ROOT_ID#UUID=}" ;;
esac

if [ -z "$SEARCH_OPT" ]; then
    case "$ROOT_ID" in
        UUID=*) SEARCH_OPT="--fs-uuid"; SEARCH_VALUE="$ROOT_UUID" ;;
        LABEL=*) SEARCH_OPT="--label"; SEARCH_VALUE="${ROOT_ID#LABEL=}" ;;
    esac
fi

ROOT_PARAM=$(printf '%s\n' "$KERNEL_ROOT_PARAM" | \
    sed -e "s|%ROOTID%|$ROOT_ID|g" \
        -e "s|%UUID%|$ROOT_UUID|g" \
        -e "s|%ROOTFSTYPE%|$ROOT_FSTYPE|g")

ROOT_SEARCH_LINE=""
if [ -n "$SEARCH_OPT" ] && [ -n "$SEARCH_VALUE" ]; then
    ROOT_SEARCH_LINE="    search --no-floppy $SEARCH_OPT --set=root $SEARCH_VALUE"
fi

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
set default=0
set timeout=5

# grub-install's core image normally carries these, but loading them again
# makes the config work even when firmware changes the disk order.
insmod part_gpt
insmod ext2
insmod search_fs_uuid

menuentry "comrun7 ($KERNEL_NAME)" {
$ROOT_SEARCH_LINE
    linux $VMLINUZ $ROOT_PARAM $KERNEL_CONSOLE $KERNEL_EXTRA
EOF

if [ "$KERNEL_NEEDS_INITRD" = "1" ]; then
    printf '    initrd %s\n' "$INITRD" >> "$OUT"
fi

printf '}\n' >> "$OUT"

if [ "$COMRUN7_SERIAL_ENTRY" = "1" ]; then
    cat >> "$OUT" <<EOF

menuentry "comrun7 serial ($KERNEL_NAME)" {
$ROOT_SEARCH_LINE
    linux $VMLINUZ $ROOT_PARAM $KERNEL_CONSOLE_SERIAL $KERNEL_EXTRA
EOF

    if [ "$KERNEL_NEEDS_INITRD" = "1" ]; then
        printf '    initrd %s\n' "$INITRD" >> "$OUT"
    fi

    printf '}\n' >> "$OUT"
fi
