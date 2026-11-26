#!/usr/bin/python3
"""comrun7 guided installer (curses TUI, archinstall-style).

This is the friendly front end.  It asks the questions a human expects,
builds an install profile, and then calls the shell backend next to this file
(install-to-disk.sh) to do the partitioning and file copying.

The installer is NOT installed into the LiveCD image; it comes from the
gitupacrep package repository.  Run it from a booted LiveCD after installing
core/comrun7-installer with upac.

No password is ever placed on a command line: passwords are hashed through
the local comrun7-hashpw helper and only the hashes are written to the
generated profile/users file.
"""

import curses
import os
import re
import select
import shlex
import subprocess
import sys
import tempfile
import textwrap

HERE = os.path.dirname(os.path.realpath(__file__))
BACKEND = os.environ.get("COMRUN7_INSTALL_BACKEND",
                         os.path.join(HERE, "install-to-disk.sh"))
HASHER = os.environ.get("COMRUN7_HASHER",
                        os.path.join(HERE, "comrun7-hashpw"))
ADDUSER = os.environ.get("COMRUN7_ADDUSER",
                         os.path.join(HERE, "comrun7-adduser.sh"))
WRITE_GRUB_CFG = os.environ.get("COMRUN7_WRITE_GRUB_CFG",
                                os.path.join(HERE, "write_grub_cfg.sh"))
NAME_RE = re.compile(r"^[a-z_][a-z0-9_-]*$")


# ---------------------------------------------------------------------------
# Small helpers

def shq(value):
    """Quote a value for a POSIX shell profile."""
    return shlex.quote(str(value))


def run(cmd, input_text=None, check=True):
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=check,
    )


def hash_password(password):
    if not HASHER or not os.path.exists(HASHER):
        raise RuntimeError("password hasher is missing: " + HASHER)
    result = run([HASHER], input_text=password + "\n")
    value = result.stdout.strip()
    if not value.startswith("$6$"):
        raise RuntimeError("unexpected password hash from " + HASHER)
    return value


def list_disks():
    try:
        out = run(["lsblk", "-d", "-n", "-o", "NAME,SIZE,TYPE,MODEL"]).stdout
    except Exception:
        out = ""
    disks = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 3:
            continue
        name, size, dtype = parts[0], parts[1], parts[2]
        model = parts[3] if len(parts) > 3 else ""
        if dtype != "disk":
            continue
        if not (name.startswith(("sd", "hd", "vd", "nvme"))):
            continue
        disks.append({
            "dev": "/dev/" + name,
            "size": size,
            "model": model.strip() or "unknown model",
        })
    return disks


def default_timezones():
    zones = [
        "UTC", "America/New_York", "America/Chicago", "America/Denver",
        "America/Los_Angeles", "America/Sao_Paulo", "Europe/London",
        "Europe/Berlin", "Europe/Paris", "Europe/Moscow", "Asia/Tokyo",
        "Asia/Shanghai", "Asia/Kolkata", "Australia/Sydney",
    ]
    if os.path.isdir("/usr/share/zoneinfo"):
        found = []
        for root, _dirs, files in os.walk("/usr/share/zoneinfo"):
            for fn in files:
                if fn in ("UTC", "Local") or "." in fn:
                    continue
                rel = os.path.relpath(os.path.join(root, fn), "/usr/share/zoneinfo")
                found.append(rel)
        zones = list(dict.fromkeys(zones + sorted(found)))
    return zones


def default_locales():
    return ["C.UTF-8", "en_US.UTF-8", "de_DE.UTF-8", "fr_FR.UTF-8",
            "ja_JP.UTF-8", "ru_RU.UTF-8", "pt_BR.UTF-8"]


def default_keymaps():
    return ["us", "de", "fr", "ru", "jp", "br", "uk", "dvorak"]


# ---------------------------------------------------------------------------
# curses drawing helpers

def put(stdscr, y, x, text, attr=0):
    try:
        stdscr.addnstr(y, x, text, max(0, curses.COLS - x - 1), attr)
    except curses.error:
        pass


def clear_line(stdscr, y, x=0):
    put(stdscr, y, x, " " * max(0, curses.COLS - x - 1))


def centered(stdscr, y, text, attr=0):
    x = max(0, (curses.COLS - len(text)) // 2)
    put(stdscr, y, x, text, attr)


def frame(stdscr, title, footer="Up/Down move  Enter select  Esc back"):
    stdscr.clear()
    if curses.COLS > 2 and curses.LINES > 2:
        try:
            stdscr.border()
        except curses.error:
            pass
    centered(stdscr, 1, title, curses.A_BOLD)
    put(stdscr, curses.LINES - 2, 2, footer, curses.A_DIM)
    stdscr.refresh()


def menu(stdscr, title, items, selected=0, footer=None):
    """Return selected index, or None when cancelled."""
    idx = selected
    while True:
        frame(stdscr, title, footer or "Up/Down move  Enter select  Esc cancel")
        top = 3
        maxrows = max(1, curses.LINES - 6)
        start = max(0, idx - maxrows + 1)
        for pos, item in enumerate(items[start:start + maxrows]):
            y = top + pos
            label = item if isinstance(item, str) else item[0]
            attr = curses.A_REVERSE if pos + start == idx else curses.A_NORMAL
            put(stdscr, y, 3, label, attr)
        stdscr.refresh()
        ch = stdscr.getch()
        if ch in (curses.KEY_UP, ord("k")):
            idx = (idx - 1) % len(items) if items else 0
        elif ch in (curses.KEY_DOWN, ord("j")):
            idx = (idx + 1) % len(items) if items else 0
        elif ch in (10, 13, curses.KEY_ENTER):
            return idx if items else None
        elif ch in (27, curses.KEY_BACKSPACE, 127, ord("q")):
            return None


def text_prompt(stdscr, title, prompt, initial="", masked=False):
    """Return entered string, or None when cancelled."""
    value = list(initial)
    while True:
        frame(stdscr, title, "Enter accept  Esc cancel")
        put(stdscr, 4, 3, prompt + ": ")
        shown = "*" * len(value) if masked else "".join(value)
        clear_line(stdscr, 5, 3)
        put(stdscr, 5, 3, shown + "_", curses.A_UNDERLINE)
        stdscr.refresh()
        ch = stdscr.getch()
        if ch in (10, 13, curses.KEY_ENTER):
            return "".join(value)
        if ch in (27,):
            return None
        if ch in (curses.KEY_BACKSPACE, 127, 8):
            if value:
                value.pop()
        elif ch == 21:  # Ctrl-U
            value = []
        elif 32 <= ch <= 126:
            value.append(chr(ch))


def form(stdscr, title, fields, footer="Up/Down field  Enter accept  Esc cancel"):
    """fields: list of (label, initial_value, masked_bool). Returns dict or None."""
    values = [list(v) for _l, v, _m in fields]
    idx = 0
    while True:
        frame(stdscr, title, footer)
        for n, (label, _initial, masked) in enumerate(fields):
            y = 3 + n * 2
            if y >= curses.LINES - 3:
                break
            put(stdscr, y, 3, label + ": ")
            shown = "*" * len(values[n]) if masked else "".join(values[n])
            clear_line(stdscr, y + 1, 3)
            attr = curses.A_UNDERLINE if n == idx else curses.A_NORMAL
            put(stdscr, y + 1, 3, shown + ("_" if n == idx else ""), attr)
        stdscr.refresh()
        ch = stdscr.getch()
        if ch in (curses.KEY_UP,):
            idx = (idx - 1) % len(fields)
        elif ch in (curses.KEY_DOWN, 9):
            idx = (idx + 1) % len(fields)
        elif ch in (10, 13, curses.KEY_ENTER):
            return {fields[n][0]: "".join(values[n]) for n in range(len(fields))}
        elif ch == 27:
            return None
        elif ch in (curses.KEY_BACKSPACE, 127, 8):
            if values[idx]:
                values[idx].pop()
        elif ch == 21:
            values[idx] = []
        elif 32 <= ch <= 126:
            values[idx].append(chr(ch))


def ask_password(stdscr, label):
    while True:
        first = text_prompt(stdscr, "Password", "New " + label, masked=True)
        if first is None:
            return None
        second = text_prompt(stdscr, "Password", "Confirm " + label, masked=True)
        if second is None:
            return None
        if first == second:
            return first
        message(stdscr, "Passwords do not match", "Try again.")


def message(stdscr, title, body):
    frame(stdscr, title, "Press any key to continue")
    for n, line in enumerate(textwrap.wrap(body, max(20, curses.COLS - 8))):
        put(stdscr, 4 + n, 3, line)
    stdscr.refresh()
    stdscr.getch()


# ---------------------------------------------------------------------------
# Config and profile generation

class Config:
    def __init__(self):
        self.disk = ""
        self.hostname = "comrun7"
        self.locale = "C.UTF-8"
        self.keymap = "us"
        self.timezone = "UTC"
        self.efi_size = "512"
        self.swap_size = "0"
        self.bios_grub = True
        self.serial_entry = False
        self.root_mode = "same-as-user"
        self.root_hash = ""
        self.users = []


def new_user(stdscr, existing_names):
    while True:
        data = form(stdscr, "Add user", [
            ("Username", "", False),
            ("Full name / GECOS", "", False),
            ("Home directory", "", False),
            ("Shell", "/bin/sh", False),
            ("Groups (comma separated)", "wheel netdev", False),
            ("UID (blank = auto)", "", False),
            ("GID (blank = auto)", "", False),
            ("Home mode", "0755", False),
        ])
        if data is None:
            return None
        name = data["Username"].strip()
        if not NAME_RE.match(name):
            message(stdscr, "Invalid username", "Use lowercase letters, digits, _ or - and start with a letter/_.")
            continue
        if name in existing_names:
            message(stdscr, "Duplicate user", "That username is already in the list.")
            continue
        groups = re.sub(r"[\s|]+", " ", data["Groups (comma separated)"].strip())
        groups = ",".join(g for g in groups.split(",") if g)
        password = ask_password(stdscr, "password for " + name)
        if password is None:
            continue
        try:
            user_hash = hash_password(password)
        except Exception as exc:
            message(stdscr, "Hash failed", str(exc))
            continue
        home = data["Home directory"].strip() or ("/home/" + name)
        for key in ("UID (blank = auto)", "GID (blank = auto)", "Home mode"):
            if data[key] and re.search(r"[^0-9]", data[key]):
                message(stdscr, "Invalid number", key + " must contain digits only.")
                data[key] = ""
        return {
            "name": name,
            "hash": user_hash,
            "gecos": data["Full name / GECOS"].strip() or name,
            "home": home,
            "shell": data["Shell"].strip() or "/bin/sh",
            "groups": groups,
            "uid": data["UID (blank = auto)"].strip(),
            "gid": data["GID (blank = auto)"].strip(),
            "create_home": "1",
            "mode": data["Home mode"].strip() or "0755",
        }


def edit_users(stdscr, cfg):
    while True:
        items = []
        for u in cfg.users:
            items.append("%-16s %-22s %s" % (u["name"], u["home"], u["groups"]))
        items += ["[Add user]", "[Done]"]
        choice = menu(stdscr, "Users", items, footer="Up/Down move  Enter select  Esc done")
        if choice is None or choice >= len(cfg.users):
            return
        if choice == len(cfg.users):
            user = new_user(stdscr, [u["name"] for u in cfg.users])
            if user:
                cfg.users.append(user)
            continue
        # Selected an existing user: offer delete or password change.
        sub = menu(stdscr, "User " + cfg.users[choice]["name"],
                   ["Change password", "Delete user", "Back"])
        if sub == 0:
            password = ask_password(stdscr, "new password for " + cfg.users[choice]["name"])
            if password:
                try:
                    cfg.users[choice]["hash"] = hash_password(password)
                except Exception as exc:
                    message(stdscr, "Hash failed", str(exc))
        elif sub == 1:
            del cfg.users[choice]
        elif sub is None:
            return


def root_password_screen(stdscr, cfg):
    modes = [
        ("same-as-user", "Same password as first user (default)"),
        ("prompt", "Ask for a separate root password"),
        ("hash", "Enter a precomputed SHA-512 hash"),
        ("lock", "Lock the root password (no easy admin without sudo)"),
        ("__back__", "[Back to users]"),
    ]
    while True:
        choice = menu(stdscr, "Root password",
                      ["%-14s %s" % m for m in modes],
                      footer="Up/Down move  Enter select  Esc back")
        if choice is None:
            return False
        mode = modes[choice][0]
        if mode == "__back__":
            return False
        if mode == "same-as-user" and not cfg.users:
            message(stdscr, "No user",
                    "Add at least one user first, or choose another root mode.")
            continue
        cfg.root_mode = mode
        if mode == "same-as-user":
            cfg.root_hash = cfg.users[0]["hash"]
        elif mode == "prompt":
            password = ask_password(stdscr, "root password")
            if password is None:
                continue
            try:
                cfg.root_hash = hash_password(password)
            except Exception as exc:
                message(stdscr, "Hash failed", str(exc))
                continue
        elif mode == "hash":
            value = text_prompt(stdscr, "Root hash", "Paste SHA-512 hash")
            if value is None:
                continue
            if not value.startswith("$6$"):
                message(stdscr, "Invalid hash", "Hash must start with $6$.")
                continue
            cfg.root_hash = value.strip()
        else:
            cfg.root_hash = "!"
        return True


def write_profile(cfg, conf_path, users_path):
    lines = [
        "# Generated by comrun7-install.py",
        "INSTALL_HOSTNAME=%s" % shq(cfg.hostname),
        "INSTALL_LOCALE=%s" % shq(cfg.locale),
        "INSTALL_KEYMAP=%s" % shq(cfg.keymap),
        "INSTALL_TIMEZONE=%s" % shq(cfg.timezone),
        "INSTALL_EFI_SIZE_MB=%s" % shq(cfg.efi_size),
        "INSTALL_SWAP_SIZE_MB=%s" % shq(cfg.swap_size),
        "INSTALL_BIOS_GRUB=%s" % ("1" if cfg.bios_grub else "0"),
        "INSTALL_SERIAL_ENTRY=%s" % ("1" if cfg.serial_entry else "0"),
        "INSTALL_USER_NAME=\"\"",
        "INSTALL_ROOT_PASSWORD_MODE=%s" % shq(cfg.root_mode),
        "INSTALL_ROOT_PASSWORD_HASH=%s" % shq(cfg.root_hash),
    ]
    with open(conf_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    fields = ["name", "hash", "home", "shell", "groups", "gecos",
              "uid", "gid", "create_home", "mode"]
    with open(users_path, "w", encoding="utf-8") as fh:
        for user in cfg.users:
            vals = [str(user.get(k, "")) for k in fields]
            if any(("|" in v or "\n" in v) for v in vals):
                raise ValueError("illegal character in user fields")
            fh.write("|".join(vals) + "\n")


def install(stdscr, cfg):
    tmpdir = tempfile.mkdtemp(prefix="comrun7-install-")
    conf_path = os.path.join(tmpdir, "install.conf")
    users_path = os.path.join(tmpdir, "users.tsv")
    try:
        write_profile(cfg, conf_path, users_path)
    except Exception as exc:
        message(stdscr, "Config error", str(exc))
        return False

    env = os.environ.copy()
    env.update({
        "COMRUN7_INSTALL_CONF": conf_path,
        "COMRUN7_USERS_FILE": users_path,
        "COMRUN7_ADDUSER": ADDUSER,
        "COMRUN7_HASHPW": HASHER,
        "COMRUN7_WRITE_GRUB_CFG": WRITE_GRUB_CFG,
        "COMRUN7_FORCE_DISK": "1",
        "LC_ALL": "C",
    })

    frame(stdscr, "Installing comrun7", "Do not power off.  Installing to " + cfg.disk)
    put(stdscr, 3, 3, "Starting installer...")
    stdscr.refresh()

    try:
        proc = subprocess.Popen(
            [BACKEND, cfg.disk],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            text=True,
            bufsize=1,
        )
    except Exception as exc:
        message(stdscr, "Install failed", "Cannot start backend: " + str(exc))
        return False

    try:
        proc.stdin.write("YES\n")
        proc.stdin.close()
    except Exception:
        pass

    log_lines = []
    while True:
        ready, _, _ = select.select([proc.stdout], [], [], 0.2)
        if ready:
            line = proc.stdout.readline()
            if not line:
                break
            log_lines.append(line.rstrip())
            if len(log_lines) > 200:
                log_lines = log_lines[-200:]
        elif proc.poll() is not None:
            break
        frame(stdscr, "Installing comrun7", "Working... (Ctrl-C not recommended)")
        put(stdscr, 3, 3, "Target: " + cfg.disk)
        for n, line in enumerate(log_lines[-max(1, curses.LINES - 7):]):
            put(stdscr, 5 + n, 3, line[:max(0, curses.COLS - 6)])
        stdscr.refresh()
    rc = proc.wait()

    frame(stdscr, "Install finished" if rc == 0 else "Install failed",
          "Press any key to continue")
    put(stdscr, 3, 3, "Backend exit status: %d" % rc)
    for n, line in enumerate(log_lines[-max(1, curses.LINES - 7):]):
        put(stdscr, 5 + n, 3, line[:max(0, curses.COLS - 6)])
    stdscr.refresh()
    stdscr.getch()
    return rc == 0


def summary_screen(stdscr, cfg):
    lines = [
        ("Target disk", cfg.disk + "  (ALL DATA WILL BE ERASED)"),
        ("Hostname", cfg.hostname),
        ("Locale / keymap", cfg.locale + " / " + cfg.keymap),
        ("Timezone", cfg.timezone),
        ("EFI partition", cfg.efi_size + " MiB"),
        ("Swap", cfg.swap_size + " MiB"),
        ("BIOS GRUB", "yes" if cfg.bios_grub else "no"),
        ("Serial GRUB entry", "yes" if cfg.serial_entry else "no"),
        ("Root password", cfg.root_mode),
        ("Users", ", ".join(u["name"] for u in cfg.users) or "(none)"),
    ]
    frame(stdscr, "Review and install", "Enter start install  Esc go back")
    for n, (label, value) in enumerate(lines):
        put(stdscr, 3 + n, 3, "%-18s %s" % (label, value))
        clear_line(stdscr, 3 + n, 24)
        put(stdscr, 3 + n, 24, value)
    y = 5 + len(lines)
    put(stdscr, y, 3, "Type YES to confirm:", curses.A_BOLD)
    answer = text_prompt(stdscr, "Final confirmation", "Type YES", initial="")
    if answer is None or answer != "YES":
        return False
    return install(stdscr, cfg)


# ---------------------------------------------------------------------------
# Main flow

def main(stdscr):
    curses.curs_set(1)
    stdscr.keypad(True)
    os.environ.setdefault("TERM", "xterm")

    cfg = Config()
    frame(stdscr, "Welcome to comrun7", "Enter begin  Esc exit")
    for n, line in enumerate([
        "Guided installation",
        "",
        "1. Choose target disk",
        "2. Set hostname, locale, keymap, timezone",
        "3. Add one or more users",
        "4. Choose root password mode",
        "5. Review and install",
        "",
        "The selected disk will be completely erased.",
    ]):
        put(stdscr, 4 + n, 4, line)
    stdscr.refresh()
    if stdscr.getch() in (27,):
        return

    disks = list_disks()
    if not disks:
        message(stdscr, "No disks", "No installable disk was found.")
        return
    choice = menu(stdscr, "Select target disk",
                  ["%s  %s  %s" % (d["dev"], d["size"], d["model"]) for d in disks],
                  footer="Up/Down move  Enter select  Esc exit")
    if choice is None:
        return
    cfg.disk = disks[choice]["dev"]

    data = form(stdscr, "System identity", [
        ("Hostname", cfg.hostname, False),
        ("Locale", cfg.locale, False),
        ("Keymap", cfg.keymap, False),
        ("Timezone", cfg.timezone, False),
    ])
    if data is None:
        return
    cfg.hostname = data["Hostname"].strip() or "comrun7"
    cfg.locale = data["Locale"].strip() or "C.UTF-8"
    cfg.keymap = data["Keymap"].strip() or "us"
    cfg.timezone = data["Timezone"].strip() or "UTC"

    while True:
        edit_users(stdscr, cfg)
        if root_password_screen(stdscr, cfg):
            break

    data = form(stdscr, "Disk layout", [
        ("EFI partition size (MiB)", cfg.efi_size, False),
        ("Swap size (MiB, 0 = none)", cfg.swap_size, False),
        ("Install BIOS GRUB (1/0)", "1" if cfg.bios_grub else "0", False),
        ("Add serial GRUB entry (1/0)", "1" if cfg.serial_entry else "0", False),
    ])
    if data is None:
        return
    cfg.efi_size = data["EFI partition size (MiB)"] or "512"
    cfg.swap_size = data["Swap size (MiB, 0 = none)"] or "0"
    cfg.bios_grub = data["Install BIOS GRUB (1/0)"] == "1"
    cfg.serial_entry = data["Add serial GRUB entry (1/0)"] == "1"

    while True:
        done = summary_screen(stdscr, cfg)
        if done:
            return
        sub = menu(stdscr, "Installation complete?", ["Review again", "Exit"])
        if sub is None or sub == 1:
            return


def selftest():
    tmp = tempfile.mkdtemp(prefix="comrun7-install-selftest-")
    cfg = Config()
    cfg.disk = "/dev/vda"
    cfg.hostname = "t420test"
    cfg.users = [{
        "name": "alex", "hash": "$6$test$abcdef", "home": "/home/alex",
        "shell": "/bin/sh", "groups": "wheel,netdev", "gecos": "Alex",
        "uid": "", "gid": "", "create_home": "1", "mode": "0755",
    }]
    cfg.root_hash = cfg.users[0]["hash"]
    conf = os.path.join(tmp, "install.conf")
    users = os.path.join(tmp, "users.tsv")
    write_profile(cfg, conf, users)
    print(conf)
    print(users)
    with open(conf, encoding="utf-8") as fh:
        print(fh.read(), end="")
    with open(users, encoding="utf-8") as fh:
        print(fh.read(), end="")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    missing = [path for path in (BACKEND, HASHER, ADDUSER, WRITE_GRUB_CFG)
               if not os.path.exists(path)]
    if missing:
        print("missing installer helper(s):", file=sys.stderr)
        for path in missing:
            print("  " + path, file=sys.stderr)
        print("Reinstall core/comrun7-installer with upac.", file=sys.stderr)
        sys.exit(1)
    os.environ.setdefault("TERM", "xterm")
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        sys.exit(130)
