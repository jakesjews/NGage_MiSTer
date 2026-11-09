#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Keys and screenshots on the MiSTer without Zaparoo.

Runs ON THE MISTER (python3, no modules): makes a virtual keyboard through
/dev/uinput, which Main sees as a USB keyboard, and serves one command a
line on a TCP port:

    tap KEY            press and release (about 40 ms)
    hold KEY MS        hold for MS milliseconds
    shot               Main's own screenshot (its command pipe), reply
                       with the file it wrote under /media/fat/screenshots
    quit

Replies: "ok <time>" (the board's time at the press) or "ok <time> <path>"
for shot, "err <reason>" otherwise. tools/jev_play.py copies this file to
/tmp on the board, starts it with `python3 /tmp/mister_input.py serve PORT`
and talks to it; it can also be used by hand:

    ssh mister 'python3 /tmp/mister_input.py tap f12'
    ssh mister 'python3 /tmp/mister_input.py shot'
"""
import fcntl, os, socket, struct, sys, time

KEYS = {"esc": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
        "backspace": 14, "enter": 28, "space": 57, "z": 44, "x": 45,
        "f1": 59, "f2": 60, "f3": 61, "f4": 62, "f5": 63, "f8": 66, "f12": 88,
        "up": 103, "down": 108, "left": 105, "right": 106, "home": 102,
        "sysrq": 99, "kpasterisk": 55, "kpslash": 98, "lshift": 42}
EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
SHOTS = "/media/fat/screenshots"


class Keyboard:
    def __init__(self, name="NGage driver"):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        # look like a whole USB keyboard: every key code, scan codes, autorepeat
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_SYN)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, 0x04)          # EV_MSC
        fcntl.ioctl(self.fd, UI_SET_EVBIT, 0x14)          # EV_REP
        fcntl.ioctl(self.fd, 0x40045568, 0x04)            # UI_SET_MSCBIT MSC_SCAN
        for code in range(1, 249):
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        # struct uinput_user_dev: name[80], input_id {bustype, vendor, product, version},
        # ff_effects_max, absmax[64], absmin[64], absfuzz[64], absflat[64]
        dev = struct.pack("80sHHHHI", name.encode(), 0x03, 0x046D, 0xC31C, 0x0110, 0) + b"\0" * (4 * 64 * 4)
        os.write(self.fd, dev)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(0.5)          # let Main pick the new device up

    def event(self, etype, code, value):
        os.write(self.fd, struct.pack("llHHi", 0, 0, etype, code, value))

    def key(self, name, down):
        self.event(0x04, 0x04, KEYS[name])             # MSC_SCAN, as a real keyboard sends
        self.event(EV_KEY, KEYS[name], 1 if down else 0)
        self.event(EV_SYN, 0, 0)

    def tap(self, name, ms=40):
        t = time.time()
        self.key(name, True)
        time.sleep(ms / 1000.0)
        self.key(name, False)
        return t

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


def newest_shot(after):
    best = None
    for root, _, files in os.walk(SHOTS):
        for f in files:
            if f.endswith(".png"):
                p = os.path.join(root, f)
                try:
                    m = os.path.getmtime(p)
                except OSError:
                    continue
                if m >= after - 1 and (best is None or m > best[0]):
                    best = (m, p)
    return best[1] if best else None


_shot_n = 0


def shot(kb):
    """Main's own screenshot through its command pipe: `screenshot NAME`, then
    the file it writes under /media/fat/screenshots/<core>/<stamp>-NAME.png."""
    global _shot_n
    _shot_n += 1
    name = "jev%d-%d" % (os.getpid() % 1000, _shot_n)
    t = time.time()
    with open("/dev/MiSTer_cmd", "w") as f:
        f.write("screenshot %s\n" % name)
    deadline = time.time() + 4
    while time.time() < deadline:
        time.sleep(0.05)
        for root, _, files in os.walk(SHOTS):
            for f in files:
                if f.endswith("-%s.png" % name):
                    p = os.path.join(root, f)
                    try:
                        with open(p, "rb") as image:
                            image.seek(-12, os.SEEK_END)
                            if image.read() == b"\x00\x00\x00\x00IEND\xaeB\x60\x82":
                                return t, p
                    except (OSError, ValueError):
                        pass  # The screenshot writer has not finished yet.
    return t, None


def run(kb, line):
    parts = line.strip().split()
    if not parts:
        return "err empty"
    cmd = parts[0]
    try:
        if cmd == "tap" and len(parts) == 2:
            return "ok %.3f" % kb.tap(parts[1])
        if cmd == "hold" and len(parts) == 3:
            return "ok %.3f" % kb.tap(parts[1], int(parts[2]))
        if cmd == "shot":
            t, p = shot(kb)
            return "ok %.3f %s" % (t, p) if p else "err no screenshot file appeared"
    except KeyError:
        return "err unknown key"
    return "err bad command"


def serve(port):
    kb = Keyboard()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(1)
    sys.stdout.write("serving on %d\n" % port)
    sys.stdout.flush()
    try:
        while True:
            conn, _ = srv.accept()
            f = conn.makefile("rw")
            for line in f:
                if line.strip() == "quit":
                    return
                f.write(run(kb, line) + "\n")
                f.flush()
            conn.close()
    finally:
        kb.close()


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "serve":
        return serve(int(sys.argv[2]) if len(sys.argv) > 2 else 9123)
    kb = Keyboard()
    try:
        print(run(kb, " ".join(sys.argv[1:])))
    finally:
        kb.close()


if __name__ == "__main__":
    main()
