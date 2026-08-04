#!/usr/bin/env python3
"""Boot an RPG Maker XP project in the *browser* build and assert it plays.

Why this exists: the emscripten page (`src/shell.html` + the wasm runtime) is a
third execution environment beside the native binary and the terminal backends,
and nothing tested it. Its failures are its own -- the shell's zip loader can
mount a project the native path never sees, `rpg_start_game()` picks the runtime
from what landed in the virtual filesystem, keyboard input arrives as DOM events
instead of SDL ones, and a wasm-only mruby divergence (or a missing exported
runtime method) shows up as a blank canvas, not a failed build. So this drives
the real page in a real browser: it serves the built page, hands it a zip of an
XP project exactly as a user would, presses the same keys a player would, and
checks what the runtime logged and what the canvas actually shows.

It talks to headless Chromium over the DevTools protocol using nothing but the
Python standard library (a ~90-line WebSocket client below, and a small PNG
reader for the frame check), so it adds no npm/pip dependency to a repo that
deliberately has neither -- the same reason `src/shell.html` unpacks zips with
`DecompressionStream` instead of a bundled zip library.

What it asserts, in order:

  1. the runtime reaches `onRuntimeInitialized` (the Load button enables),
  2. the shell's loader unpacks the project zip and mounts it under /game,
  3. `rpg_start_game()` starts the RPG Maker XP runtime (the loader panel
     disappears and the canvas is sized to XP's native 640x480),
  4. pressing the decision key on the title screen starts New Game and the
     runtime logs `[RPGXP-MAP] map=.. x=.. y=..` (the marker added for exactly
     this, see --rpgxp_new_game),
  5. arrow keys move the party leader -- the frame changes between captures,
  6. the canvas is not a blank/uniform image, and
  7. nothing in the page log looks like an mruby exception or an abort.

Screenshots of every step are written to the output directory so a human (or a
CI artifact) can see what the browser drew.

Usage:
    python3 scripts/rpgxp_browser_check.py [--page wasm-build]
        [--game data/OpenGame.exe/Testbed/XP] [--out ss] [--chromium PATH]

The browser is found via --chromium, then $CHROMIUM, then the usual names on
PATH (chromium, chromium-browser, google-chrome). Build the page first:
    emcmake cmake -S . -B wasm-build -GNinja && cmake --build wasm-build
"""

import argparse
import base64
import http.server
import json
import os
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import zipfile
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The page's own log element and the markers the runtime writes into it.
MAP_MARKER = "[RPGXP-MAP]"
SCREEN_MARKER = "[RPGXP] display sized to 640x480"
# Anything here in the page log means the run is a failure even if the markers
# showed up: an mruby exception, an emscripten abort or a failed assertion.
ERROR_PATTERNS = (
    "mruby error:",
    "abort(",
    "RuntimeError: Aborted",
    "Uncaught",
)


# --- Minimal WebSocket client (RFC 6455) -----------------------------------
# Chrome's DevTools endpoint speaks WebSocket and nothing else; the standard
# library has a server-side handshake helper but no client, so here is the
# smallest client that can carry CDP: text frames, client-side masking,
# continuation frames and ping/pong. No permessage-deflate (Chrome only uses it
# when offered).


class WebSocket:
    def __init__(self, url, timeout=30.0):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port), timeout)
        self.sock.settimeout(timeout)
        path = u.path or "/"
        if u.query:
            path += "?" + u.query
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {u.hostname}:{u.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            self._fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0]
        if b" 101" not in status:
            raise RuntimeError(f"WebSocket handshake failed: {status!r}")

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ConnectionError("WebSocket closed by peer")
        self.buf += chunk

    def _take(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        header = bytearray([0x81])  # FIN + text opcode
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def recv(self):
        """Return the next complete text message (reassembling fragments)."""
        data = b""
        while True:
            b0, b1 = self._take(2)
            fin, opcode = b0 & 0x80, b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                (n,) = struct.unpack(">H", self._take(2))
            elif n == 127:
                (n,) = struct.unpack(">Q", self._take(8))
            payload = self._take(n)
            if opcode == 0x9:  # ping -> pong, keeping the same payload
                self.sock.sendall(b"\x8a" + bytes([0x80 | len(payload)]) +
                                  b"\x00\x00\x00\x00" + payload)
                continue
            if opcode == 0x8:
                raise ConnectionError("WebSocket closed by peer")
            if opcode == 0xA:  # pong
                continue
            data += payload
            if fin:
                return data.decode("utf-8", "replace")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Devtools:
    """A CDP session on one page target."""

    def __init__(self, ws_url, timeout=60.0):
        self.ws = WebSocket(ws_url, timeout)
        self.next_id = 0
        self.events = []

    def call(self, method, **params):
        self.next_id += 1
        msg_id = self.next_id
        self.ws.send(json.dumps({"id": msg_id, "method": method,
                                 "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") != msg_id:
                self.events.append(msg)
                continue
            if "error" in msg:
                raise RuntimeError(f"{method} failed: {msg['error']}")
            return msg.get("result", {})

    def evaluate(self, expression):
        res = self.call("Runtime.evaluate", expression=expression,
                        returnByValue=True, awaitPromise=True)
        if res.get("exceptionDetails"):
            raise RuntimeError("page JS raised: " +
                               json.dumps(res["exceptionDetails"]))
        return res.get("result", {}).get("value")

    def key(self, code, vkey, text=None, hold=0.12):
        """Press and release one key, holding it long enough to be polled.

        The runtime samples input once a frame, so a key that goes down and up
        between two polls is missed -- the same reason the wine comparison
        scripts hold their keys (see scripts/compare-rpgxp-wine.bash).
        """
        down = {"type": "keyDown" if text else "rawKeyDown", "code": code,
                "key": code if len(code) > 1 else code.lower(),
                "windowsVirtualKeyCode": vkey, "nativeVirtualKeyCode": vkey}
        if text:
            down["text"] = text
            down["unmodifiedText"] = text
        self.call("Input.dispatchKeyEvent", **down)
        time.sleep(hold)
        self.call("Input.dispatchKeyEvent", type="keyUp", code=code,
                  key=down["key"], windowsVirtualKeyCode=vkey,
                  nativeVirtualKeyCode=vkey)

    def screenshot(self, path):
        res = self.call("Page.captureScreenshot", format="png")
        png = base64.b64decode(res["data"])
        with open(path, "wb") as f:
            f.write(png)
        return png

    def close(self):
        self.ws.close()


# --- Just enough PNG to tell a rendered frame from a blank one --------------


def png_pixels(png):
    """Decode a non-interlaced 8-bit RGB/RGBA PNG into (width, height, rows).

    Chrome's screenshots are exactly that, and a real decoder would mean a new
    dependency for one blank-frame assertion.
    """
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, width, height, channels = 8, b"", 0, 0, 4
    while pos < len(png):
        (length,) = struct.unpack(">I", png[pos:pos + 4])
        ctype = png[pos + 4:pos + 8]
        body = png[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
            if depth != 8 or colour not in (2, 6) or body[12] != 0:
                raise ValueError(f"unsupported PNG (depth={depth} "
                                 f"colour={colour} interlace={body[12]})")
            channels = 3 if colour == 2 else 4
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break

    raw = zlib.decompress(idat)
    stride = width * channels
    rows, prev = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        filt = raw[start]
        line = bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prev[x]
            c = prev[x - channels] if x >= channels else 0
            if filt == 1:
                line[x] = (line[x] + a) & 0xFF
            elif filt == 2:
                line[x] = (line[x] + b) & 0xFF
            elif filt == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 0xFF
        rows.append(bytes(line))
        prev = line
    return width, height, rows, channels


def frame_stats(png):
    """(distinct colours, fraction of non-black pixels) for a screenshot."""
    width, height, rows, channels = png_pixels(png)
    colours, lit, total = set(), 0, 0
    # Sampling every 4th pixel is plenty to tell "black screen" from "a game",
    # and keeps the pure-Python decode cheap on a 640x480+ frame.
    for y in range(0, height, 4):
        row = rows[y]
        for x in range(0, width, 4):
            off = x * channels
            px = row[off:off + 3]
            colours.add(px)
            total += 1
            if max(px) > 16:
                lit += 1
    return len(colours), (lit / total if total else 0.0)


# --- Serving the page and the project zip ----------------------------------


def build_zip(game_dir, zip_path):
    """Pack a project the way a user's download would be: one top-level folder."""
    root = os.path.basename(os.path.normpath(game_dir))
    count = 0
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, _dirnames, filenames in os.walk(game_dir):
            for name in filenames:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, game_dir)
                z.write(full, os.path.join(root, rel))
                count += 1
    return count


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve(directory):
    handler = lambda *a, **kw: QuietHandler(*a, directory=directory, **kw)
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def find_chromium(explicit):
    candidates = [explicit, os.environ.get("CHROMIUM"), "chromium",
                  "chromium-browser", "google-chrome", "google-chrome-stable"]
    for c in candidates:
        if not c:
            continue
        path = shutil.which(c) or (c if os.path.isfile(c) else None)
        if path:
            return path
    raise SystemExit(
        "error: no chromium found; pass --chromium PATH or set $CHROMIUM")


def launch_browser(chromium, profile_dir):
    proc = subprocess.Popen(
        [chromium, "--headless=new", "--remote-debugging-port=0",
         f"--user-data-dir={profile_dir}", "--no-sandbox",
         "--disable-dev-shm-usage", "--hide-scrollbars", "--mute-audio",
         # Headless has no GPU: let ANGLE fall back to SwiftShader so the
         # canvas still gets a WebGL context (the SDL2 port needs one).
         "--enable-unsafe-swiftshader", "--use-gl=angle",
         "--use-angle=swiftshader", "--window-size=800,1000",
         "--disable-background-timer-throttling", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    port_file = os.path.join(profile_dir, "DevToolsActivePort")
    deadline = time.time() + 60
    while time.time() < deadline:
        if proc.poll() is not None:
            err = proc.stderr.read().decode("utf-8", "replace")[-2000:]
            raise SystemExit(f"error: chromium exited early:\n{err}")
        if os.path.exists(port_file):
            content = open(port_file).read().split("\n")
            if len(content) >= 2 and content[0].strip():
                return proc, int(content[0].strip())
        time.sleep(0.2)
    raise SystemExit("error: chromium never reported a DevTools port")


def page_target(port):
    """The websocket URL of the browser's first page target."""
    deadline = time.time() + 30
    while time.time() < deadline:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list") as r:
            for target in json.load(r):
                if target.get("type") == "page":
                    return target["webSocketDebuggerUrl"]
        time.sleep(0.2)
    raise SystemExit("error: chromium exposed no page target")


# --- The check itself -------------------------------------------------------


def wait_for(fn, what, timeout, poll=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(poll)
    raise AssertionError(f"timed out after {timeout:.0f}s waiting for {what}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--page", default=os.path.join(REPO, "wasm-build"),
                    help="directory holding the built index.html (default: wasm-build)")
    ap.add_argument("--game",
                    default=os.path.join(REPO, "data/OpenGame.exe/Testbed/XP"),
                    help="RPG Maker XP project directory to load")
    ap.add_argument("--out", default=os.path.join(REPO, "ss"),
                    help="directory for the captured frames (default: ss)")
    ap.add_argument("--chromium", default=None, help="browser binary to drive")
    ap.add_argument("--keep-going", action="store_true",
                    help="report every failed assertion instead of stopping at "
                         "the first one")
    args = ap.parse_args()
    # Each step is minutes apart; block buffering would hold the whole log back
    # to the end of the run, which is exactly when a CI log is least useful.
    sys.stdout.reconfigure(line_buffering=True)

    index = os.path.join(args.page, "index.html")
    if not os.path.exists(index):
        raise SystemExit(f"error: {index} not built; run "
                         "`emcmake cmake -S . -B wasm-build -GNinja && "
                         "cmake --build wasm-build` first")
    if not os.path.exists(os.path.join(args.game, "Game.ini")):
        raise SystemExit(f"error: {args.game} is not an RPG Maker XP project "
                         "(no Game.ini); run scripts/download-opengame-xp.bash")
    os.makedirs(args.out, exist_ok=True)

    chromium = find_chromium(args.chromium)
    failures = []

    def check(ok, message):
        if ok:
            print(f"  ok: {message}")
        else:
            print(f"  FAILED: {message}", file=sys.stderr)
            failures.append(message)
            if not args.keep_going:
                raise AssertionError(message)

    with tempfile.TemporaryDirectory() as tmp:
        # The page and the project zip are served from one directory so the
        # loader's fetch is same-origin (no CORS proxy needed), without copying
        # the build output.
        docroot = os.path.join(tmp, "www")
        os.makedirs(docroot)
        for name in os.listdir(args.page):
            if name.startswith("index."):
                os.symlink(os.path.join(os.path.abspath(args.page), name),
                           os.path.join(docroot, name))
        zip_path = os.path.join(docroot, "game.zip")
        files = build_zip(args.game, zip_path)
        print(f"packed {files} file(s) of {args.game} "
              f"({os.path.getsize(zip_path) // 1024} KiB)")

        httpd, port = serve(docroot)
        profile = os.path.join(tmp, "profile")
        os.makedirs(profile)
        proc, cdp_port = launch_browser(chromium, profile)
        dt = None
        try:
            dt = Devtools(page_target(cdp_port))
            dt.call("Page.enable")
            dt.call("Runtime.enable")
            dt.call("Page.navigate", url=f"http://127.0.0.1:{port}/index.html")

            print("== runtime")
            wait_for(lambda: dt.evaluate(
                "!!document.getElementById('load') && "
                "!document.getElementById('load').disabled"),
                "the wasm runtime to initialise", 120)
            check(True, "runtime initialised (Load enabled)")
            dt.screenshot(os.path.join(args.out, "rpgxp-browser-1-loader.png"))

            print("== load the project")
            dt.evaluate(
                "document.getElementById('url').value = "
                f"'http://127.0.0.1:{port}/game.zip';"
                "document.getElementById('nocache').checked = true;"
                "document.getElementById('load').click(); true")
            log = wait_for(lambda: page_log(dt) if "Mounted" in page_log(dt)
                           else None, "the loader to mount the project", 180)
            mounted = [ln for ln in log.splitlines() if "Mounted" in ln]
            check(bool(mounted), f"project mounted under /game ({mounted[-1]})")
            # Computed style, not the `hidden` property: the loader is dismissed
            # by setting `hidden`, which a `display: flex` rule in the page's own
            # CSS used to override -- leaving the panel on screen above the
            # running game while every property-level check passed.
            check(wait_for(lambda: dt.evaluate(
                "getComputedStyle(document.getElementById('loader')).display"
                " === 'none'"),
                "the loader panel to go away", 60),
                "rpg_start_game() started the game and dismissed the loader")
            size = dt.evaluate("(c => c.width + 'x' + c.height)"
                               "(document.getElementById('canvas'))")
            check(size == "640x480", f"canvas is XP's native 640x480 (got {size})")
            # The canvas size alone cannot catch the real hazard here: a 320x240
            # display doubled to a 640x480 window is the same canvas, but the XP
            # scenes then draw off its edge. The runtime logs the resolution it
            # actually took, so assert on that.
            check(SCREEN_MARKER in page_log(dt),
                  f"runtime sized its display for XP ({SCREEN_MARKER})")
            title = dt.screenshot(os.path.join(args.out,
                                               "rpgxp-browser-2-title.png"))
            colours, lit = frame_stats(title)
            check(colours > 4 and lit > 0.01,
                  f"title screen drew something ({colours} colours, "
                  f"{lit * 100:.1f}% lit)")

            print("== new game")
            # Enter is the decision key (src/sdl_input.cxx maps Return/z/space
            # to RGSS Input::C); the title's first entry is New Game.
            dt.key("Enter", 13, text="\r")
            log = wait_for(lambda: page_log(dt) if MAP_MARKER in page_log(dt)
                           else None, f"the {MAP_MARKER} marker", 60)
            marker = [ln for ln in log.splitlines() if MAP_MARKER in ln][-1]
            check(True, f"reached the map scene ({marker.strip()})")
            before = dt.screenshot(os.path.join(args.out,
                                                "rpgxp-browser-3-map.png"))

            print("== input")
            for _ in range(3):
                dt.key("ArrowDown", 40)
            time.sleep(1.0)
            after = dt.screenshot(os.path.join(args.out,
                                               "rpgxp-browser-4-walk.png"))
            check(before != after, "arrow keys changed the rendered frame")
            colours, lit = frame_stats(after)
            check(colours > 4 and lit > 0.01,
                  f"map frame is not blank ({colours} colours, "
                  f"{lit * 100:.1f}% lit)")

            print("== runtime log")
            log = page_log(dt)
            bad = [ln for ln in log.splitlines()
                   if any(p in ln for p in ERROR_PATTERNS)]
            check(not bad, "no mruby exception or abort in the page log" +
                  (f" (saw: {bad[0]})" if bad else ""))
            with open(os.path.join(args.out, "rpgxp-browser.log"), "w") as f:
                f.write(log)
            for line in log.splitlines():
                if "[RGSS]" in line or MAP_MARKER in line:
                    print(f"  runtime: {line.strip()}")
        except AssertionError as e:
            print(f"error: {e}", file=sys.stderr)
            if dt is not None:
                try:
                    dt.screenshot(os.path.join(args.out,
                                               "rpgxp-browser-failure.png"))
                    with open(os.path.join(args.out, "rpgxp-browser.log"),
                              "w") as f:
                        f.write(page_log(dt))
                except Exception:  # the page may be gone; the failure stands
                    pass
            failures.append(str(e))
        finally:
            if dt is not None:
                dt.close()
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            httpd.shutdown()
            httpd.server_close()

    print(f"frames written to {args.out}/rpgxp-browser-*.png")
    if failures:
        print(f"rpgxp browser check: {len(failures)} assertion(s) FAILED",
              file=sys.stderr)
        return 1
    print("rpgxp browser check: the XP test bed boots and plays in the browser")
    return 0


def page_log(dt):
    """The shell page's runtime log (stdout+stderr of the wasm module)."""
    return dt.evaluate("document.getElementById('log').textContent") or ""


if __name__ == "__main__":
    sys.exit(main())
