#!/usr/bin/env python3
"""Best-effort autoplay for deezer-desktop.

Verified facts this script works around (see Service.qml and README for how
they were confirmed): deezer-desktop's deep links only ever navigate its
window to a catalog page -- they never load anything into the player, on a
cold launch or a warm one, autoplay query param or not. The only thing that
actually starts a track is a real click on that page's own Play button.

Being Electron, deezer-desktop can be launched with a Chrome DevTools
Protocol port, which lets us run real JavaScript in the page -- including a
genuine `.click()` on the Play button -- without depending on window
position/size the way synthetic mouse-coordinate automation would. It
targets the button by its `data-testid` (read straight off the live DOM,
listed below per content type), not by visible label text, so it isn't
locale-dependent -- but it is still inherently fragile in the sense that any
of it will need updating if a Deezer UI update renames these testids.

That CDP port can only be set at launch, not attached to an already-running
process, so this only kills and relaunches deezer-desktop (with
--start-in-tray, so no window ever flashes) when its CDP port isn't already
reachable. When it is, this navigates the already-running instance by
setting its page's own `location.hash` directly through CDP rather than
handing it a new deezer:// link -- a link would also work (its own
single-instance forwarding navigates correctly on its own), but the app's
second-instance handler unconditionally calls `window.show()` as a side
effect of that, popping the window up on every single click regardless of
--start-in-tray (which only ever covers the *initial* launch). Setting the
hash directly reaches the same client-side router without going through
that handler at all, confirmed live to leave the window untouched.

Always targets a single item's own page (a track, playlist, album, or
artist) and clicks that page's own top-level Play button -- never a
specific row inside a longer list. An earlier version also supported
clicking a named track's row within a playlist/loved-tracks context page,
to start playback with that context (rather than a track_mix) as the
queue; that depended on deezer-desktop's virtualized row list mounting rows
for whatever wasn't already rendered on load, which never actually
happened -- confirmed live, deezer-desktop runs with --start-in-tray so its
window is never shown, and Chromium suspends layout/paint work (which
row virtualization depends on) for an occluded window, so scrolling by any
means never revealed a row beyond the initial handful. Service.qml now
handles context/queue continuation itself instead, by watching MPRIS for
when a queued track ends and launching the next one in its own list with
another call to this script, rather than depending on deezer-desktop's own
in-app queue at all.

Usage: autoplay-click.py <deezer://...-or-https://... url>
Exit 0 if the click landed, 1 otherwise. Always best-effort -- callers
should not treat a nonzero exit as more than "didn't work this time".
"""
import base64
import hashlib
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CDP_PORT = 9331
CDP_STARTUP_TIMEOUT_S = 20
CLICK_RETRY_TIMEOUT_S = 8

# Every Electron app's bundle is named app.asar, so "app.asar" alone matches
# any of them -- pkill/CDP-target-selection on that substring alone risks
# hitting an unrelated Electron app that happens to be running at the same
# time (killing it, or navigating/clicking inside *its* window instead of
# deezer-desktop's). /usr/bin/deezer-desktop is a wrapper script that execs
# `electron42 /usr/share/deezer/app.asar "$@"` -- confirmed live against a
# running instance's own /proc/<pid>/cmdline -- so the process image is
# just "electron"/"electron42" and the literal string "deezer-desktop"
# never appears anywhere in its cmdline, on the main process or any of its
# renderers. The one thing that *is* present on all of them is the asar's
# own install path, so match on that instead.
DEEZER_PROCESS_MARKER = "/deezer/app.asar"

# The primary Play action's data-testid per content type, read straight off
# a live DOM dump for each page kind rather than guessed. Each CSS attribute
# selector requires an exact match, so e.g. "play" can't accidentally match
# the unrelated "playlist-play_small-button" secondary control that's also
# present on the same page.
PLAY_BUTTON_SELECTOR = ",".join([
    '[data-testid="track_mix-play-button"]',  # /track
    '[data-testid="play"]',                   # /playlist, /album
    '[data-testid="artist-play-button"]',     # /artist
])


def _play_button_probe(expected_path, click):
    # The click can land before the SPA has actually finished routing to the
    # requested item -- verified live: an early click just hit whatever
    # Play control was already on screen (the persisted, already loaded
    # track's own mini-player button) and left the target track never
    # loaded. Requiring the location hash to already match the deep link's
    # own path (e.g. "/track/12345") before considering a click closes
    # that gap.
    #
    # Even once the hash and the button both check out, the button's own
    # click handler can still be a beat behind (React hydration) -- clicking
    # the very instant it's found landed on a not-yet-wired element in
    # testing. `click=False` lets the caller confirm readiness on a couple
    # of consecutive polls (letting hydration catch up) before a `click=True`
    # call actually presses it for real.
    path_pattern = json.dumps(re.escape(expected_path))
    action = "el.click(); return true;" if click else "return true;"
    return f"""
    (function() {{
      if (!new RegExp({path_pattern}).test(location.hash)) return false;
      var el = document.querySelector({json.dumps(PLAY_BUTTON_SELECTOR)});
      if (!el) return false;
      // /playlist and /album's "play" testid lands on a wrapping <div>, not
      // the actual <button> inside it -- a native click() on that div never
      // reaches the button's own listener (clicks don't propagate to
      // descendants), so descend into it when the match isn't already one.
      if (el.tagName !== "BUTTON") {{
        el = el.querySelector("button");
        if (!el) return false;
      }}
      {action}
    }})()
    """


def expected_path_from_url(url):
    # Mirrors the app's own DeepLink.getPathFromUrl: everything after the
    # scheme, minus the domain, e.g. "deezer://www.deezer.com/track/123"
    # and "https://www.deezer.com/track/123" both become "/track/123".
    path = url.split("://", 1)[-1]
    path = re.sub(r"^[^/]*", "", path)  # drop the domain
    return path or "/"


def _is_deezer_target(target):
    # Port 9331 is just whatever's currently listening there -- some other
    # Electron/Chromium app started with the same --remote-debugging-port
    # (or a port-forwarded/proxied one) would look identical over CDP
    # otherwise. A loose "deezer" substring anywhere in the target's url or
    # title is not enough to trust it: an unrelated app's page could easily
    # carry that substring incidentally (a tab titled "Deezer" in a browser,
    # a URL with "deezer" in a query string, etc.), which would still let
    # navigation/click/Runtime.evaluate run against a page that isn't
    # deezer-desktop at all.
    #
    # deezer-desktop's own page is *not* loaded from the deezer.com origin
    # at all, confirmed live against a running instance's own CDP target
    # list -- it's the bundled Electron frontend, loaded from local disk as
    # file:///usr/share/deezer/app.asar/build/index.html, with client-side
    # hash routing on top (the same #/... routing navigate_via_cdp drives).
    # Requiring a deezer.com hostname, as this used to, never matched that
    # real target at all -- it only ever matched an unrelated page that
    # happened to actually be browsing deezer.com, which is not what this
    # script drives. Match the asar's own install path instead, the same
    # identity anchor _deezer_desktop_pids already keys off of in the
    # process's cmdline. Before deezer-desktop's own first navigation its
    # page target briefly sits at about:blank; that's deliberately treated
    # as *not* a match here, so the polling loops in
    # cdp_reachable/wait_for_page_target just keep waiting until the real
    # navigation lands instead of trusting an unnavigated page prematurely.
    url = target.get("url") or ""
    parsed = urllib.parse.urlparse(url)
    return (parsed.scheme == "file"
            and DEEZER_PROCESS_MARKER in parsed.path
            and parsed.path.endswith("/build/index.html"))


def _deezer_desktop_pids():
    # pkill/pgrep -f "app.asar" alone would match *any* Electron app -- that
    # bundle filename is generic to Electron itself, not specific to
    # deezer-desktop. Require DEEZER_PROCESS_MARKER -- the asar's own
    # install path, not deezer-desktop's executable name (see its
    # definition above for why) -- in the full command line too, so an
    # unrelated Electron/Chromium app that happens to be running never
    # gets targeted.
    try:
        out = subprocess.run(["pgrep", "-f", "app.asar"],
                              capture_output=True, text=True)
    except OSError:
        return []
    pids = []
    for token in out.stdout.split():
        try:
            pid = int(token)
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmdline = f.read()
        except (ValueError, OSError):
            continue
        if DEEZER_PROCESS_MARKER.encode() in cmdline:
            pids.append(pid)
    return pids


def _pid_listening_on_cdp_port():
    # Resolve which pid actually holds CDP_PORT's listening socket, straight
    # off the kernel's own tables -- not from anything the process itself
    # could claim over CDP. /proc/net/tcp{,6} give every listening socket's
    # local port and inode; matching that inode against each process's own
    # /proc/<pid>/fd/* symlinks (which the kernel renders as
    # "socket:[<inode>]") identifies the owning pid without shelling out to
    # lsof/ss (neither is guaranteed installed).
    port_hex = f"{CDP_PORT:04X}"
    inodes = set()
    for proc_file in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(proc_file) as f:
                lines = f.readlines()[1:]
        except OSError:
            continue
        for line in lines:
            fields = line.split()
            if len(fields) < 10:
                continue
            local_port = fields[1].split(":")[-1]
            tcp_listen = "0A"
            if local_port == port_hex and fields[3] == tcp_listen:
                inodes.add(fields[9])
    if not inodes:
        return None
    try:
        proc_entries = os.listdir("/proc")
    except OSError:
        return None
    for entry in proc_entries:
        if not entry.isdigit():
            continue
        fd_dir = f"/proc/{entry}/fd"
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue  # not our process, or it already exited
        for fd in fds:
            try:
                link = os.readlink(f"{fd_dir}/{fd}")
            except OSError:
                continue
            m = re.match(r"socket:\[(\d+)\]", link)
            if m and m.group(1) in inodes:
                return int(entry)
    return None


def _cdp_port_owned_by_deezer_desktop():
    # _is_deezer_target only proves a given CDP *target* is a deezer.com
    # page -- it says nothing about which process is actually serving CDP
    # on this port. Some other debug-enabled Chromium/Electron instance
    # that merely happens to have a deezer.com tab open (or is deliberately
    # squatting on the port) would pass that check identically and still
    # receive navigation/click/Runtime.evaluate commands. Cross-check the
    # port's real owning pid against deezer-desktop's own process list --
    # the same identity check already trusted for the kill path -- so a
    # same-origin page served by anything else is rejected regardless of
    # its URL.
    pid = _pid_listening_on_cdp_port()
    return pid is not None and pid in _deezer_desktop_pids()


def cdp_reachable():
    if not _cdp_port_owned_by_deezer_desktop():
        return False
    try:
        with urllib.request.urlopen(
                f"http://127.0.0.1:{CDP_PORT}/json", timeout=1) as resp:
            targets = json.loads(resp.read())
        return any(_is_deezer_target(t) for t in targets)
    except (urllib.error.URLError, ConnectionError, json.JSONDecodeError, OSError):
        return False


def relaunch_cold(url):
    for pid in _deezer_desktop_pids():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.6)
    # --start-in-tray comes from this Arch build's own patch set
    # (aunetx/deezer-linux's 01-start-in-tray.patch, applied at package
    # build time): it makes the app call window.hide() instead of .show()
    # on startup. Confirmed live: with it, no window is ever mapped by
    # Hyprland at any point, while CDP still exposes the page target and a
    # click through it still starts real playback -- a hidden BrowserWindow
    # keeps running normally, it just never gets shown compositor-side.
    subprocess.Popen(
        ["deezer-desktop", url, "--start-in-tray",
         f"--remote-debugging-port={CDP_PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)


def navigate_via_cdp(sock, expected_path):
    # Deliberately *not* xdg-open here: handing a link to an already-running
    # instance navigates it correctly (Electron's single-instance forwarding
    # gets that part right), but its own second-instance handler also
    # unconditionally calls window.show() -- confirmed live, popping the
    # window up on every single warm click regardless of --start-in-tray
    # (that flag only ever covers the *initial* launch). Setting the SPA's
    # own location.hash directly through CDP reaches the exact same router
    # without going through that handler at all, so the window stays hidden
    # throughout -- confirmed live (0 windows mapped, correct track played).
    #
    # The hash also carries a locale segment ("#/fr/track/123") that the
    # deep-link URL itself doesn't -- reuse whatever's already active rather
    # than guessing one.
    expr = f"""
    (function() {{
      var m = location.hash.match(/^#\\/([^\\/]+)/);
      var locale = m ? m[1] : "en";
      location.hash = "#/" + locale + {json.dumps(expected_path)};
      return location.hash;
    }})()
    """
    evaluate(sock, 0, expr)


def wait_for_page_target():
    deadline = time.monotonic() + CDP_STARTUP_TIMEOUT_S
    while time.monotonic() < deadline:
        try:
            if not _cdp_port_owned_by_deezer_desktop():
                raise ConnectionError("CDP port not (yet) owned by deezer-desktop")
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{CDP_PORT}/json", timeout=1) as resp:
                targets = json.loads(resp.read())
            for target in targets:
                if (target.get("type") == "page"
                        and target.get("webSocketDebuggerUrl")
                        and _is_deezer_target(target)):
                    return target["webSocketDebuggerUrl"]
        except (urllib.error.URLError, ConnectionError, json.JSONDecodeError):
            pass
        time.sleep(0.3)
    return None


# --- Minimal RFC 6455 WebSocket client (stdlib only, no deps available) ---

def ws_connect(ws_url):
    m = re.match(r"ws://([^:/]+):(\d+)(/.*)?", ws_url)
    if not m:
        raise ValueError(f"unexpected websocket url: {ws_url}")
    host, port, path = m.group(1), int(m.group(2)), (m.group(3) or "/")
    sock = socket.create_connection((host, port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode())
    response = b""
    while b"\r\n\r\n" not in response:
        response += sock.recv(4096)
    if b" 101 " not in response.split(b"\r\n", 1)[0]:
        raise ConnectionError(f"websocket handshake failed: {response[:200]!r}")
    return sock


def ws_send_text(sock, text):
    payload = text.encode()
    header = bytearray([0x81])  # FIN + text frame
    length = len(payload)
    mask_bit = 0x80
    if length < 126:
        header.append(mask_bit | length)
    elif length < 65536:
        header.append(mask_bit | 126)
        header += struct.pack(">H", length)
    else:
        header.append(mask_bit | 127)
        header += struct.pack(">Q", length)
    mask_key = os.urandom(4)
    masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + mask_key + masked)


def ws_recv_text(sock, timeout):
    try:
        sock.settimeout(timeout)
        header = sock.recv(2)
        if len(header) < 2:
            return None
        length = header[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", sock.recv(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", sock.recv(8))[0]
        payload = b""
        while len(payload) < length:
            chunk = sock.recv(length - len(payload))
            if not chunk:
                break
            payload += chunk
        return payload.decode(errors="replace")
    except (TimeoutError, OSError):
        return None


def evaluate(sock, msg_id, expression, timeout=2):
    # CDP can deliver unsolicited notifications on the same socket (e.g.
    # console/network events some Electron builds emit without being asked)
    # interleaved with our own request/response pairs -- taking whatever
    # frame arrived next as "the" response, unchecked, risked pairing a
    # request with someone else's message entirely. Reading until a frame
    # whose own "id" actually matches this call closes that gap.
    ws_send_text(sock, json.dumps({
        "id": msg_id,
        "method": "Runtime.evaluate",
        "params": {"expression": expression, "returnByValue": True},
    }))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(0.05, deadline - time.monotonic())
        raw = ws_recv_text(sock, timeout=remaining)
        if not raw:
            return None
        try:
            reply = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if reply.get("id") != msg_id:
            continue
        return reply.get("result", {}).get("result", {}).get("value")
    return None


def try_click(sock, expected_path):
    ready_expr = _play_button_probe(expected_path, click=False)
    click_expr = _play_button_probe(expected_path, click=True)
    deadline = time.monotonic() + CLICK_RETRY_TIMEOUT_S
    msg_id = 0
    consecutive_ready = 0
    while time.monotonic() < deadline:
        msg_id += 1
        if evaluate(sock, msg_id, ready_expr) is True:
            consecutive_ready += 1
            if consecutive_ready >= 2:
                msg_id += 1
                if evaluate(sock, msg_id, click_expr) is True:
                    return True
                consecutive_ready = 0
        else:
            consecutive_ready = 0
        time.sleep(0.3)
    return False


def main():
    if len(sys.argv) != 2:
        print("usage: autoplay-click.py <url>", file=sys.stderr)
        return 2
    url = sys.argv[1]
    expected_path = expected_path_from_url(url)
    warm = cdp_reachable()
    if not warm:
        relaunch_cold(url)
    ws_url = wait_for_page_target()
    if not ws_url:
        return 1
    sock = ws_connect(ws_url)
    try:
        if warm:
            navigate_via_cdp(sock, expected_path)
        return 0 if try_click(sock, expected_path) else 1
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
