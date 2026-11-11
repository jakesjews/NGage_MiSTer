#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Drive an N-Gage game on the MiSTer with Jev choosing the keys.

Jev (TypeSafe's decision model, api.typesafe.ai) answers in a few hundred
milliseconds, so the loop capture -> decide -> key runs at about one step a
second, close enough to a person at the keypad for the game to be played
rather than waited on.

    tools/jev_play.py GAME [--core NGage] [--overlay] [--out DIR] [--play 60] [--max 600] [--no-boot]
    tools/jev_play.py --dry-run DIR_OF_PNGS      (classify saved captures only)

GAME names the launcher CORE-GAME.mgl under /media/fat/_Console/_NGage (the
release) or its _Debug folder (the counters and trace builds) (--core, default
NGage; NGageDbg for the counters build). The run boots it (the formatted
save, so the Time and Date dialogs come first), goes to the phone's menu,
finds the game's entry, launches it, and then lets Jev pick every key from
the screen until the game has been played for --play seconds of gameplay,
or --max seconds in all.

Keys and captures go through tools/mister_input.py on the board (a uinput
keyboard that Main sees as a USB keyboard, and Main's own screenshot through
its command pipe), not through Zaparoo. Games poll the keypad once a frame and
miss a short pulse, so in gameplay every key is held for half a second.

With --overlay the debug overlay is switched on through the OSD once the
core is up, checked by decoding a capture, and every capture is decoded
with tools/mister_dbg.py: the per-second counters (frames, pixels,
instructions, idle and bus waits) go into log.csv next to the step,
through the boot and the game alike.

Captures go to DIR (default build/hardware/jev/GAME/) as
NNNN-<screen>-<key>.png, with log.csv: the Mac time, the MiSTer's own time
for every key sent, Jev's screen class and confidence, the key, how much
the screen changed since the last capture, and the counters.

Needs TYPESAFE_API_KEY in the environment and `ssh mister`.
"""
import argparse, base64, csv, json, os, socket, subprocess, sys, time, urllib.request
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageStat
except ImportError:
    sys.exit("needs Pillow (pip install pillow)")

API = "https://api.typesafe.ai/v1/systemone"
HOST = os.environ.get("MISTER_HOST", "mister")
PORT = int(os.environ.get("MISTER_INPUT_PORT", "9123"))
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-o", "ControlMaster=auto",
            "-o", "ControlPath=/tmp/jev-ssh-%r@%h:%p", "-o", "ControlPersist=120"]
SSH = ["ssh"] + SSH_OPTS + ["root@" + HOST]
HERE = Path(__file__).resolve().parent

SCREENS = {
    "phone_idle": "the phone's idle screen: operator name, clock, soft key labels, no game graphics",
    "phone_menu": "the phone's application menu: a list of apps with icons, one highlighted",
    "dialog": "a dialog box asking a question or for input (the time, the date, yes/no, a name)",
    "game_logo": "a company logo, legal text or splash screen shown by a game",
    "game_menu": "a game's title screen or a menu of options (play, options, exit, select a car or character)",
    "gameplay": "the game being played: a level, race, match, course or mission in progress with the player's character, car or view",
    "loading": "a loading or please-wait screen or progress bar",
    "black": "a black, blank or garbled screen",
}
MENU_KEYS = {
    "enter": "confirm or select the highlighted item",
    "down": "move the highlight down",
    "up": "move the highlight up",
    "left": "move the highlight or selection left",
    "right": "move the highlight or selection right",
    "f1": "the left soft key: Options, Select, Yes, OK, Start",
    "f2": "the right soft key: Back, Exit, No, Cancel",
    "5": "the main game action key (also starts or skips in many games)",
    "wait": "no key: the screen is still changing, loading or animating",
}
PLAY_KEYS = {
    "up": "move or accelerate upward / forward",
    "down": "move down / brake / crouch",
    "left": "move, steer or turn left",
    "right": "move, steer or turn right",
    "5": "the main action: accelerate, jump, fire, punch, ollie, confirm",
    "7": "the second action: brake, special move, kick, grind",
    "wait": "no key for now",
}


def ssh(cmd, timeout=30):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True, timeout=timeout).stdout


class Board:
    """Keys and captures through tools/mister_input.py running on the MiSTer."""

    def __init__(self):
        subprocess.run(["scp", "-q"] + SSH_OPTS + [str(HERE / "mister_input.py"), f"root@{HOST}:/tmp/mister_input.py"], check=True)
        ssh(f"pkill -f '[m]ister_input.py serve'; "
            f"for p in $(netstat -tlnp 2>/dev/null | awk '/:{PORT} /{{split($7,a,\"/\"); print a[1]}}'); do kill $p; done; sleep 0.5; "
            f"nohup python3 /tmp/mister_input.py serve {PORT} >/tmp/mister_input.log 2>&1 &")
        for _ in range(20):
            time.sleep(0.5)
            try:
                self.sock = socket.create_connection((HOST, PORT), timeout=60)
                break
            except OSError:
                continue
        else:
            sys.exit("mister_input.py did not come up on the board; see /tmp/mister_input.log there")
        self.f = self.sock.makefile("rw")
        time.sleep(3)                    # Main opens a new input device a moment after it appears

    def cmd(self, line):
        self.f.write(line + "\n")
        self.f.flush()
        r = self.f.readline().strip()
        if not r.startswith("ok"):
            raise RuntimeError(f"board: {r} (for {line})")
        return r.split()[1:]

    def press(self, key, hold_ms=0):
        """Returns the board's time at the press."""
        r = self.cmd(f"hold {key} {hold_ms}" if hold_ms else f"tap {key}")
        return float(r[0])

    def pad(self, button, hold_ms=300):
        """A gamepad button on the board's virtual pad (Main's default map)."""
        return float(self.cmd(f"pad {button} {hold_ms}")[0])

    def shot(self, path):
        """Main ignores screenshot commands while it loads a core or its files: retry for a while."""
        for attempt in range(15):
            try:
                t, remote = self.cmd("shot")[:2]
                break
            except RuntimeError:
                if attempt == 14:
                    raise
                time.sleep(2)
        with open(path, "wb") as out:
            subprocess.run(SSH + [f"cat '{remote}' && rm -f '{remote}'"], stdout=out, check=True, timeout=60)
        return float(t)

    def close(self):
        try:
            self.f.write("quit\n")
            self.f.flush()
            self.sock.close()
        except OSError:
            pass


LAUNCHERS = {"NGage": "/media/fat/_Console/_NGage", "NGageDbg": "/media/fat/_Console/_NGage/_Debug",
             "NGageTrc": "/media/fat/_Console/_NGage/_Debug"}


def overlay_cfg(on):
    """The debug overlay from the core's first picture: Main reads the core's
    status bits from /media/fat/config/NGage.CFG (16 bytes) at the core load,
    and "Debug overlay" is status[8]. With the file in place no OSD key
    sequence has to run while the launcher's file loads restart the core
    (one such run landed on Rotate). off removes the file, so a person's own
    runs start with the defaults again."""
    if on:
        ssh("printf '\\000\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000' > /media/fat/config/NGage.CFG; sync")
    else:
        ssh("rm -f /media/fat/config/NGage.CFG; sync")


def load_launcher(game, core="NGage"):
    folder = LAUNCHERS.get(core, "/media/fat/_Console/_NGage/_Debug")
    out = ssh(f"date +%s.%N; echo 'load_core {folder}/{core}-{game}.mgl' > /dev/MiSTer_cmd")
    return float(out.split()[0]) if out.split() else 0.0


def jev(png, state_text, questions):
    key = os.environ.get("TYPESAFE_API_KEY")
    if not key:
        sys.exit("TYPESAFE_API_KEY is not set")
    # Jev rejects the panel's native 176x208 ("Invalid image dimensions"): send it scaled up 3x
    import io  # noqa: PLC0415
    im = Image.open(png).convert("RGB")
    if im.width < 512:
        k = (512 + im.width - 1) // im.width
        im = im.resize((im.width * k, im.height * k), Image.NEAREST)
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    b64 = base64.b64encode(buf.getvalue()).decode()
    body = {"model": "jev-latest",
            "state": [state_text, "IMG1"],
            "assets": {"IMG1": {"type": "image", "format": "png", "data_base64": b64}},
            "questions": questions}
    req = urllib.request.Request(API, data=json.dumps(body).encode(), headers={
        "Authorization": "Bearer " + key, "Content-Type": "application/json",
        "TypeSafe-Danger-Zone-Images": "true"})
    err = None
    for _ in range(3):
        try:
            return json.load(urllib.request.urlopen(req, timeout=60))["answers"]
        except Exception as e:  # noqa: BLE001
            err = e
            time.sleep(1)
    sys.exit(f"Jev request failed: {err}")


def change(prev, now):
    """Mean absolute pixel difference between two captures, 0..255."""
    if prev is None:
        return 255.0
    a = Image.open(prev).convert("L")
    b = Image.open(now).convert("L")
    if a.size != b.size:
        b = b.resize(a.size)
    return ImageStat.Stat(ImageChops.difference(a, b)).mean[0]


def decode_overlay(png):
    """The per-second counters from a capture with the overlay on, or None if it is off."""
    try:
        sys.path.insert(0, str(HERE))
        import mister_dbg  # noqa: PLC0415
        line = mister_dbg.decode(str(png))
    except Exception:  # noqa: BLE001
        return None
    if " | per s: " not in line:
        return None
    text = line.split(" | per s: ", 1)[1]
    import re  # noqa: PLC0415
    m = re.search(r"(\d+) frames, (\d+) px, ([\d.]+) M instr, idle ([\d.]+)%.*?, (\d+) beats", text)
    if not m:
        return None
    frames, px, instr, idle, beats = int(m[1]), int(m[2]), float(m[3]), float(m[4]), int(m[5])
    # the overlay is off (panel pixels decode as all-ones or zeros) unless every count is possible
    if frames > 1000 or px > 104_000_000 or instr > 104.0 or idle > 100.0 or beats > 104_000_000:
        return None
    if frames == 0 and px == 0 and instr == 0.0 and beats == 0 and idle == 0.0:
        return None
    return text


class Run:
    def __init__(self, game, out, play, maximum, core="NGage", overlay=False):
        self.game, self.play, self.maximum = game, play, maximum
        self.core, self.overlay = core, overlay
        self.board = Board()
        self.out = Path(out)
        self.out.mkdir(parents=True, exist_ok=True)
        self.n = 0
        self.prev = None
        self.last = ("black", 0.0, "wait", 0.0, None, 0.0)
        self.counters = ""
        self.undecoded = 0
        self.logf = open(self.out / "log.csv", "w", newline="")
        self.log = csv.writer(self.logf)
        self.log.writerow(["step", "mac_time", "mister_time", "screen", "confidence", "key", "change", "note", "counters"])
        self.t_start = time.time()

    def context(self, phase):
        return (f"A Nokia N-Gage QD (a Symbian phone with a 176x208 portrait screen) is running "
                f"the game '{self.game}' from its game card. Phase: {phase}. The keypad has a "
                f"rocker (up/down/left/right), 5 and 7 as game keys, two soft keys (left F1, "
                f"right F2) and OK (enter)."
                + (" A small block of black-and-white debug bits is drawn at the top left of the screen; ignore it." if self.overlay else "")
                + " Screenshot of the screen now:")

    def capture(self):
        self.n += 1
        tmp = self.out / f"{self.n:04d}.png"
        t = self.board.shot(tmp)
        return tmp, t

    def step(self, phase, keyset):
        """Capture, ask Jev, return (screen, confidence, key, change)."""
        tmp, t = self.capture()
        ch = change(self.prev, tmp)
        qs = {"screen": {"type": "choice", "instructions": "What is shown on the screen?", "criteria": SCREENS},
              "key": {"type": "choice", "criteria": keyset,
                      "instructions": ("Which key makes progress towards playing, choosing the first or quickest option "
                                       "in menus, answering a Bluetooth or multiplayer question with No, and accepting "
                                       "defaults? Choose wait if the screen is animating, loading or mid-transition."
                                       if keyset is MENU_KEYS else
                                       "Which input makes progress in the game right now (keep moving, racing, "
                                       "fighting; avoid standing still)?")}}
        a = jev(tmp, self.context(phase) + (" The screen has not changed since the last capture." if ch < 1.0 else ""), qs)
        screen, conf, key = a["screen"]["choice"], a["screen"]["confidence"], a["key"]["choice"]
        final = self.out / f"{self.n:04d}-{screen}-{key}.png"
        tmp.rename(final)
        self.prev = final
        self.counters = (decode_overlay(final) or "") if self.overlay else ""
        if self.overlay and screen != "black":
            # a launcher's file loads restart the core and clear the overlay: switch it on
            # once the core shows a picture, and again whenever captures stop decoding
            self.undecoded = 0 if self.counters else self.undecoded + 1
            if self.undecoded >= 3:
                self.overlay_on()
                self.undecoded = 0
        self.last = (screen, conf, key, ch, final, t)
        return screen, conf, key, ch

    def act(self, key, note="", hold=0):
        t = self.board.press(key, hold) if key != "wait" else self.last[5]
        screen, conf, _, ch, _, _ = self.last
        self.log.writerow([self.n, f"{time.time() - self.t_start:.1f}", f"{t:.3f}", screen, f"{conf:.2f}", key, f"{ch:.1f}", note, self.counters])
        self.logf.flush()
        if self.counters:
            print(f"  step {self.n} t={t:.1f} {screen} {key}: {self.counters}")
        return t

    def elapsed(self):
        return time.time() - self.t_start

    def overlay_on(self):
        """The OSD's "Debug overlay" entry (F12, 12 down, enter, two esc), until a capture decodes.
        Only after a launcher's loads are over: see boot_profile.overlay_on."""
        for attempt in range(4):
            for k in ["f12"] + ["down"] * 12 + ["enter", "esc", "esc"]:  # see boot_profile.overlay_on
                self.board.press(k)
                time.sleep(0.4)
            time.sleep(1.5)
            tmp, _ = self.capture()
            if decode_overlay(tmp):
                tmp.rename(self.out / f"{self.n:04d}-overlay-on.png")
                print(f"overlay on at step {self.n}", flush=True)
                return True
            tmp.rename(self.out / f"{self.n:04d}-overlay-try{attempt}.png")
            time.sleep(3)
        print("could not switch the overlay on")
        return False

    def boot(self):
        """Load the launcher and get through the Time/Date dialogs to the idle screen."""
        t0 = load_launcher(self.game, self.core)
        self.log.writerow([0, "0.0", f"{t0:.3f}", "load", "", "", "", "load_core", ""])
        self.logf.flush()
        print(f"loaded at MiSTer time {t0:.1f}", flush=True)
        deadline = time.time() + 400
        while time.time() < deadline:
            time.sleep(2)
            screen, conf, key, ch = self.step("the phone is booting; wait for its Time dialog", MENU_KEYS)
            if screen == "dialog" and conf > 0.6:
                t = self.act("enter", note="time dialog")
                print(f"time dialog at MiSTer time {t:.1f} ({t - t0:.1f} s after load)", flush=True)
                time.sleep(2)
                self.step("the phone's Date dialog", MENU_KEYS)
                self.act("enter", note="date dialog")
                time.sleep(3)
                return True
            self.act("wait", note="booting")
        print("no Time dialog within the limit")
        return False

    def launch(self):
        """Menu, find the game's row, OK."""
        self.step("the phone's idle screen", MENU_KEYS)
        self.act("f5", note="menu")
        for _ in range(12):            # the icon grid takes up to 12 s to fill; presses before that are lost
            time.sleep(2)
            screen, conf, _, _ = self.step("the phone's application menu is opening", MENU_KEYS)
            if screen == "phone_menu" and conf > 0.8:
                break
            self.act("wait", note="menu filling")
        time.sleep(2)
        for _ in range(3):
            self.step("the phone's application menu", MENU_KEYS)
            self.act("down", note="to the card's game")
            time.sleep(1)
        for _ in range(4):
            self.step("the phone's application menu; the game's entry should be highlighted", MENU_KEYS)
            a = jev(self.last[4], self.context("the phone's application menu"), {
                "hl": {"type": "choice", "instructions": f"Where is the highlighted entry relative to the game '{self.game}' (the card's game, usually the last entry)?",
                       "criteria": {"on_it": f"the highlight is on '{self.game}' or the card's game", "above": "the highlight is above it", "below": "the highlight is below it", "unknown": "cannot tell"}}})
            where = a["hl"]["choice"]
            if where == "above":
                self.act("down", note="adjust"); time.sleep(1); continue
            if where == "below":
                self.act("up", note="adjust"); time.sleep(1); continue
            break
        t = self.act("enter", note="launch")
        print(f"launched at MiSTer time {t:.1f}", flush=True)
        return t

    def play_game(self):
        """Let Jev drive until the game has been played for self.play seconds of gameplay."""
        played, same, last_screen = 0.0, 0, None
        t_play = None
        while self.elapsed() < self.maximum:
            screen, conf, key, ch = self.step("the game is running", PLAY_KEYS if last_screen == "gameplay" else MENU_KEYS)
            same = same + 1 if ch < 0.5 else 0
            if same >= 40:
                print("screen frozen for 40 steps; giving up")
                self.act("wait", note="frozen")
                return False
            if screen == "gameplay" and conf > 0.5:
                if t_play is None:
                    t_play = time.time()
                    print(f"gameplay at step {self.n}", flush=True)
                played = time.time() - t_play
                self.act(key, note=f"play {played:.0f}s", hold=500 if key != "wait" else 0)
                if played >= self.play:
                    print(f"played {played:.0f} s")
                    return True
            else:
                if screen in ("game_menu", "dialog", "phone_idle", "phone_menu"):
                    t_play = None
                self.act(key, note=screen)
            last_screen = screen
            time.sleep(0.5)
        print("time limit reached")
        return False

    def close(self):
        self.logf.close()
        self.board.close()


def dry_run(folder):
    for png in sorted(Path(folder).glob("*.png")):
        qs = {"screen": {"type": "choice", "instructions": "What is shown on the screen?", "criteria": SCREENS},
              "key": {"type": "choice", "instructions": "Which key makes progress towards playing?", "criteria": MENU_KEYS}}
        t = time.time()
        a = jev(png, "Screenshot of a Nokia N-Gage QD's 176x208 screen while a game is being started:", qs)
        print(f"{png.name}: {time.time() - t:.2f}s screen={a['screen']['choice']} ({a['screen']['confidence']:.2f}) key={a['key']['choice']} ({a['key']['confidence']:.2f})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game", nargs="?")
    ap.add_argument("--out")
    ap.add_argument("--play", type=float, default=60)
    ap.add_argument("--max", type=float, default=600)
    ap.add_argument("--no-boot", action="store_true", help="the game is already launched: just play")
    ap.add_argument("--core", default="NGage", help="launcher prefix: NGage (release) or NGageDbg (counters build)")
    ap.add_argument("--overlay", action="store_true", help="switch the debug overlay on after the load and decode the counters from every capture")
    ap.add_argument("--dry-run", metavar="DIR", help="classify saved captures, no MiSTer")
    args = ap.parse_args()
    if args.dry_run:
        return dry_run(args.dry_run)
    if not args.game:
        ap.error("GAME is required")
    run = Run(args.game, args.out or f"build/hardware/jev/{args.game}", args.play, args.max, core=args.core, overlay=args.overlay)
    try:
        ok = True
        if not args.no_boot:
            ok = run.boot() and run.launch() is not None
        elif args.overlay:
            run.overlay_on()
        if ok:
            ok = run.play_game()
    finally:
        run.close()
    print("result:", "played" if ok else "not played", "| captures in", run.out)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
