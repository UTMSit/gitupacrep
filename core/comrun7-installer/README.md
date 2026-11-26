# comrun7 installer (gitupacrep package)

The comrun7 installer is intentionally **not installed into the LiveCD image**.
It is a package in the `gitupacrep` repository, so there are two supported ways
to put comrun7 on a disk:

1. **Scripted** - boot the LiveCD, install `core/comrun7-installer` with upac,
   and run the guided Python TUI. It collects hostname/locale/keymap/timezone,
   one or more users, root password mode, disk layout, then calls
   `install-to-disk.sh`.
2. **Manual** - boot the LiveCD and run the partitioning, copy, identity,
   user, and GRUB commands yourself. Nothing hidden is required.

The selected disk is erased. Double-check `DEV` before pressing Enter.

## Contents

| File | Purpose |
| --- | --- |
| `comrun7-install.py` | Guided curses front end (archinstall-style) |
| `install-to-disk.sh` | Safe backend: GPT, ext4, copy, users, GRUB |
| `comrun7-adduser.sh` | Add users to a target root without shadow-utils |
| `hashpw.c` | Source for the SHA-512 password hash helper |
| `write_grub_cfg.sh` | Kernel-profile-driven GRUB config generator |
| `install.conf.example` | Example non-interactive install profile |
| `build.sh` | Compiles the hash helper and checks the runtime |

## Get the installer from a booted LiveCD

The LiveCD already has Python 3 with `curses`, a compiler, and the disk/GRUB
tools, but it does not carry these scripts or the hash helper. Clone this
repository and run the TUI directly from the checkout:

```sh
git clone --depth 1 https://github.com/UTMSit/gitupacrep /tmp/gitupacrep
cd /tmp/gitupacrep/core/comrun7-installer
sh build.sh
python3 comrun7-install.py
```

`upac -u` refreshes the package database from the same repository. Do not use
`upac ogr:core/comrun7-installer` until the corrected package recipe is
available from the remote repository; the old recipe tries to rebuild Python
and its dependencies. If the LiveCD has no network, copy the
`core/comrun7-installer` directory onto other media, mount it in the live
system, and run `sh build.sh` there.

## 1. Scripted install (recommended)

```sh
python3 comrun7-install.py
# after installing the package manually: comrun7-install
```

The TUI asks for:

- target disk (with an explicit destructive confirmation)
- hostname, locale, keymap, timezone
- one or more users, each with a masked password
- root password mode: same as first user, separate prompt, pasted hash, or locked
- EFI size, optional swap, BIOS GRUB, and the optional serial GRUB entry
- a final review screen; type `YES` to start

Passwords are piped into the local `comrun7-hashpw` helper and only SHA-512
hashes are written to the generated temporary profile. No plaintext password
is placed on a command line.

### Non-interactive script

For automation, edit `install.conf.example` and call the backend directly:

```sh
cp /usr/share/comrun7-installer/install.conf.example install.conf
# edit install.conf: hostname, users, hashes, layout
COMRUN7_INSTALL_CONF=$PWD/install.conf COMRUN7_FORCE_DISK=1 \
    /usr/share/comrun7-installer/install-to-disk.sh /dev/sda
```

The backend refuses a non-removable disk unless `COMRUN7_FORCE_DISK=1` is set.
`INSTALL_SERIAL_ENTRY=0` keeps a single normal GRUB entry; set it to `1` if
you also want the serial console entry.

## 2. Fully manual install

These are the same steps the backend performs. Run them as root from the
LiveCD. Replace `/dev/sda` with the intended disk.

### Partition and format

```sh
DEV=/dev/sda
ROOT=/mnt/comrun7
lsblk -o NAME,SIZE,TYPE,MODEL

# Unmount anything already mounted from this disk.
for p in "${DEV}1" "${DEV}2" "${DEV}3" "${DEV}p1" "${DEV}p2" "${DEV}p3"; do
    mp=$(findmnt -rn -S "$p" -o TARGET 2>/dev/null || true)
    [ -z "$mp" ] || umount "$mp"
done

wipefs -a "$DEV"
sgdisk -Z "$DEV"
sgdisk -n 1:0:+1M    -t 1:ef02 -c 1:COMRUN7-BIOS "$DEV"
sgdisk -n 2:0:+512M  -t 2:ef00 -c 2:COMRUN7-EFI  "$DEV"
sgdisk -n 3:0:0      -t 3:8300 -c 3:COMRUN7-ROOT "$DEV"
partprobe "$DEV"
sleep 1

mkfs.vfat -F32 -n COMRUN7-EFI "${DEV}1"
mkfs.ext4 -F -L COMRUN7-ROOT "${DEV}3"
mount "${DEV}3" "$ROOT"
mkdir -p "$ROOT/boot/efi"
mount "${DEV}2" "$ROOT/boot/efi"
```

For NVMe devices use `${DEV}p1`, `${DEV}p2`, `${DEV}p3` instead.

### Copy the live root

```sh
cd /
tar --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
    --exclude=./mnt --exclude=./boot/efi --exclude=./.old_root \
    --exclude=./home \
    -cf - . | (cd "$ROOT" && tar -xf -)
```

`./home` is excluded on purpose: users are created explicitly below.

### Set identity

```sh
HOST=comrun7
printf '%s\n' "$HOST" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1   localhost localhost.localdomain $HOST
::1         localhost ip6-localhost ip6-loopback $HOST
127.0.1.1   $HOST
EOF
printf 'LANG=C.UTF-8\n' > "$ROOT/etc/locale.conf"
printf 'KEYMAP=us\n' > "$ROOT/etc/vconsole.conf"
ln -sfn ../usr/share/zoneinfo/UTC "$ROOT/etc/localtime"
```

Use another timezone by linking to the matching file under
`/usr/share/zoneinfo`.

### Create users and set the root password

If the package is installed, use its helpers directly:

```sh
B=/usr/share/comrun7-installer

printf 'Password for alex: ' >&2
stty -echo
IFS= read -r PW
stty echo
printf '\n' >&2
HASH=$(printf '%s\n' "$PW" | "$B/comrun7-hashpw")

"$B/comrun7-adduser.sh" -D "$ROOT" -c 'Alex' -h /home/alex -s /bin/sh \
    -G wheel,netdev -p "$HASH" alex

# Use the same hash for root, or generate another one with comrun7-hashpw.
awk -F: -v h="$HASH" 'BEGIN { OFS = ":" } $1 == "root" { $2 = h } { print }' \
    "$ROOT/etc/shadow" > "$ROOT/etc/shadow.new"
mv "$ROOT/etc/shadow.new" "$ROOT/etc/shadow"
chmod 0600 "$ROOT/etc/shadow"
```

To lock root instead, set its shadow password field to `!`.

### Install boot files and GRUB

```sh
SRC=/run/initramfs/cdrom/boot
[ -f "$SRC/vmlinuz" ] || SRC=/boot

mkdir -p "$ROOT/boot" "$ROOT/boot/efi/boot" "$ROOT/boot/efi/grub"
cp "$SRC/vmlinuz" "$ROOT/boot/vmlinuz"
cp "$ROOT/boot/vmlinuz" "$ROOT/boot/efi/boot/vmlinuz"

# The active Linux kernel profile needs an initrd.
. "$ROOT/etc/comrun7/kernel.conf"
if [ "${KERNEL_NEEDS_INITRD:-1}" = "1" ]; then
    cp "$SRC/initrd.gz" "$ROOT/boot/initrd.gz"
    cp "$ROOT/boot/initrd.gz" "$ROOT/boot/efi/boot/initrd.gz"
fi

ROOT_UUID=$(blkid -s UUID -o value "${DEV}3")
cat > "$ROOT/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF

COMRUN7_SERIAL_ENTRY=0 "$B/write_grub_cfg.sh" \
    "$ROOT/boot/grub/grub.cfg" \
    "UUID=$ROOT_UUID" \
    "$ROOT/etc/comrun7/kernel.conf" \
    /boot/vmlinuz /boot/initrd.gz \
    --fs-uuid "$ROOT_UUID" ext4

grub-install --target=x86_64-efi --recheck \
    --efi-directory="$ROOT/boot/efi" \
    --boot-directory="$ROOT/boot/efi" --removable
cp "$ROOT/boot/grub/grub.cfg" "$ROOT/boot/efi/grub/grub.cfg"
cp "$ROOT/boot/grub/grub.cfg" "$ROOT/boot/efi/boot/grub/grub.cfg"

grub-install --target=i386-pc --recheck \
    --boot-directory="$ROOT/boot" "$DEV"

sync
umount "$ROOT/boot/efi"
umount "$ROOT"
```

Reboot, remove the live media, and boot the new system. The kernel and
filesystem are selected by the profiles in `/etc/comrun7/kernel.conf` and
`/etc/comrun7/rootfs.conf`; `%ROOTID%` and `%ROOTFSTYPE%` are expanded by
`write_grub_cfg.sh`.

## Testing safely

Use QEMU with a qcow2 image when testing. Never point these commands at a
production disk. The repository installer is not part of the ISO, so a stale
LiveCD cannot silently run an outdated installer.
