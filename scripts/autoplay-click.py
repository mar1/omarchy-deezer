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
ROW_SEARCH_TIMEOUT_S = 25

# Every Electron app's bundle is named app.asar, so "app.asar" alone matches
# any of them -- pkill/CDP-target-selection on that substring alone risks
# hitting an unrelated Electron app that happens to be running at the same
# time (killing it, or navigating/clicking inside *its* window instead of
# deezer-desktop's). deezer-desktop's own executable name is distinctive
# enough to require in addition to app.asar wherever either check happens.
DEEZER_PROCESS_MARKER = "deezer-desktop"

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


def path_match_source(expected_path):
    # Deezer silently resolves a "me" path segment to the real numeric user
    # id in some routes -- confirmed live: navigating to
    # "/profile/me/loved" leaves the hash as "/profile/493227/loved" a
    # moment later, which a plain substring check against "/profile/me/..."
    # would then never match again. Treat "me" as a wildcard so the match
    # still holds after that swap.
    segments = expected_path.strip("/").split("/")
    return "/".join(re.escape(s) if s != "me" else "[^/]+" for s in segments)


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
    path_pattern = json.dumps(path_match_source(expected_path))
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


def _track_row_probe(expected_path, track_title, click):
    # Clicking a track's own standalone page starts a "track mix" -- a
    # Deezer radio queue around that one song (hence the button's own
    # testid, track_mix-play-button) -- instead of continuing into whatever
    # played it (a playlist, the loved-tracks library): confirmed live, the
    # track after it was Deezer's algorithmic pick, not the next one in
    # context. Playing the row's own per-track button *within* that
    # context page instead keeps the context as the queue, so playback
    # continues into it normally once the track ends.
    #
    # Rows carry no stable track-id attribute anywhere in their DOM
    # (checked live) -- only aria-rowindex (position, not identity) and
    # hashed CSS module classes. The one durable anchor is each row's
    # data-testid="title" span, whose text is the literal, unlocalized
    # song title, so rows are matched by that instead. Its own play button
    # is the first <button> in the row's DOM order (checked live across
    # playlist and loved-tracks pages).
    # Long playlists/libraries are virtualized -- checked live, a 41-track
    # playlist only ever had ~24 rows in the DOM at once, so a track sorted
    # near the top of *our* panel (by time_add) but sitting near the bottom
    # of the app's own native order was never found. When no row matches
    # among what's currently rendered, scroll and let the next poll re-check
    # rather than giving up -- the interval between polls is what gives the
    # virtualized renderer time to mount the newly-revealed rows.
    path_pattern = json.dumps(path_match_source(expected_path))
    title_json = json.dumps(track_title)
    action = "btn.click(); return true;" if click else "return true;"
    return f"""
    (function() {{
      if (!new RegExp({path_pattern}).test(location.hash)) return false;
      var titles = Array.prototype.slice.call(
        document.querySelectorAll('[data-testid="title"]'));
      var target = {title_json};
      // Album pages number each title ("5. Strategy") where playlist and
      // loved-tracks rows don't -- strip a leading "N. " before comparing
      // so the same match works on both.
      var stripNumber = function(s) {{ return s.replace(/^\\d+\\.\\s*/, ""); }};
      for (var i = 0; i < titles.length; i++) {{
        if (stripNumber(titles[i].textContent.trim()) !== target) continue;
        var row = titles[i];
        while (row && row.getAttribute("role") !== "row") row = row.parentElement;
        if (!row) continue;
        var btn = row.querySelector("button");
        if (!btn) continue;
        {action}
      }}
      var scroller = document.scrollingElement || document.documentElement;
      if (scroller && scroller.scrollHeight > scroller.clientHeight) {{
        var atBottom = scroller.scrollTop + scroller.clientHeight
          >= scroller.scrollHeight - 4;
        scroller.scrollTop = atBottom ? 0
          : scroller.scrollTop + scroller.clientHeight * 0.8;
      }}
      return false;
    }})()
    """


# The "Added" column header, across the same handful of locales as the
# retired label-matching Play-button lookup. Sorting a playlist/library page
# by it (descending) puts the item our own panel already shows first --
# most recently added -- at the top of the app's own rendering too, which
# is what actually solves the virtualization problem below: a track that's
# first in *our* order no longer needs scrolling through however many
# hundred rows separate it from wherever the app's default ordering put it.
# Confirmed live against a 138-track playlist: one click reordered it to
# exactly the order our own time_add sort already produces.
ADDED_COLUMN_WORDS = [
    "added", "ajouté", "hinzugefügt", "añadido", "aggiunto",
    "adicionado", "toegevoegd",
]


def _sort_header_probe(expected_path):
    path_pattern = json.dumps(path_match_source(expected_path))
    words_json = json.dumps(ADDED_COLUMN_WORDS)
    return f"""
    (function() {{
      if (!new RegExp({path_pattern}).test(location.hash)) return false;
      var words = {words_json};
      var headers = Array.prototype.slice.call(
        document.querySelectorAll('[role="columnheader"]'));
      for (var i = 0; i < headers.length; i++) {{
        var label = (headers[i].innerText || headers[i].textContent || '')
          .trim().toLowerCase();
        if (words.indexOf(label) === -1) continue;
        var btn = headers[i].querySelector("button");
        if (!btn) continue;
        btn.click();
        // The scroll position from a previous visit persists across an
        // in-app hash navigation (checked live) -- reset it so the row
        // search below starts scanning from the freshly-resorted top.
        var scroller = document.scrollingElement || document.documentElement;
        if (scroller) scroller.scrollTop = 0;
        return true;
      }}
      return false;
    }})()
    """


def _title_at_top_probe(track_title):
    # Whether the target is already among the currently-rendered rows with
    # the list scrolled to the very top -- i.e. whether the sort is already
    # the one we want, without side effects (no click, no scrolling past
    # what's already visible).
    title_json = json.dumps(track_title)
    return f"""
    (function() {{
      var scroller = document.scrollingElement || document.documentElement;
      if (scroller) scroller.scrollTop = 0;
      var titles = Array.prototype.slice.call(
        document.querySelectorAll('[data-testid="title"]'));
      var stripNumber = function(s) {{ return s.replace(/^\\d+\\.\\s*/, ""); }};
      for (var i = 0; i < titles.length; i++)
        if (stripNumber(titles[i].textContent.trim()) === {title_json}) return true;
      return false;
    }})()
    """


def presort_by_added(sock, expected_path, track_title, timeout=8):
    # The header is a bare ascending/descending toggle, not an idempotent
    # "sort descending" action -- clicking it unconditionally risked
    # flipping an already-correctly-sorted page (e.g. left that way by an
    # earlier run against the same long-lived deezer-desktop instance) to
    # the wrong order instead, confirmed live as the exact reason a retry
    # against the same session intermittently failed where the first
    # attempt had succeeded. Check first; only toggle if the target isn't
    # already visible at the top, and confirm it actually worked afterward.
    #
    # Best-effort and non-fatal throughout: some context pages (e.g. an
    # artist's own page) have no such column at all, in which case this
    # just leaves the row search below to fall back on scrolling through
    # whatever order is already there.
    check_expr = _title_at_top_probe(track_title)
    sort_expr = _sort_header_probe(expected_path)
    deadline = time.monotonic() + timeout
    msg_id = 90000
    attempts = 0
    while time.monotonic() < deadline and attempts < 2:
        msg_id += 1
        if evaluate(sock, msg_id, check_expr) is True:
            return True
        msg_id += 1
        if evaluate(sock, msg_id, sort_expr) is not True:
            return False  # no such column on this page -- nothing to toggle
        attempts += 1
        time.sleep(0.6)
    msg_id += 1
    return evaluate(sock, msg_id, check_expr) is True


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
    # deezer-desktop at all. Require the target's actual URL to be on the
    # deezer.com origin -- not merely a URL/title that happens to mention
    # "deezer". Before deezer-desktop's own first navigation its page target
    # briefly sits at about:blank; that's deliberately treated as *not* a
    # match here, so the polling loops in cdp_reachable/wait_for_page_target
    # just keep waiting until the real navigation lands instead of trusting
    # an unnavigated page prematurely.
    url = target.get("url") or ""
    host = urllib.parse.urlparse(url).hostname or ""
    return host == "deezer.com" or host.endswith(".deezer.com")


def cdp_reachable():
    try:
        with urllib.request.urlopen(
                f"http://127.0.0.1:{CDP_PORT}/json", timeout=1) as resp:
            targets = json.loads(resp.read())
        return any(_is_deezer_target(t) for t in targets)
    except (urllib.error.URLError, ConnectionError, json.JSONDecodeError, OSError):
        return False


def _deezer_desktop_pids():
    # pkill/pgrep -f "app.asar" alone would match *any* Electron app -- that
    # bundle filename is generic to Electron itself, not specific to
    # deezer-desktop. Require deezer-desktop's own executable name in the
    # full command line too, so an unrelated Electron/Chromium app that
    # happens to be running never gets targeted.
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


def try_click(sock, expected_path, track_title=None):
    if track_title:
        presort_by_added(sock, expected_path, track_title)
        ready_expr = _track_row_probe(expected_path, track_title, click=False)
        click_expr = _track_row_probe(expected_path, track_title, click=True)
        # Finding a row can mean several scroll-and-recheck cycles through a
        # long, virtualized list, unlike the fixed top-of-page Play button.
        timeout = ROW_SEARCH_TIMEOUT_S
    else:
        ready_expr = _play_button_probe(expected_path, click=False)
        click_expr = _play_button_probe(expected_path, click=True)
        timeout = CLICK_RETRY_TIMEOUT_S
    deadline = time.monotonic() + timeout
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
    if len(sys.argv) not in (2, 3):
        print("usage: autoplay-click.py <url> [track-title]", file=sys.stderr)
        return 2
    url = sys.argv[1]
    # An optional track title switches from "click this page's own Play
    # button" to "click this specific track's row within the page" -- pass
    # a playlist/loved-tracks context URL with the track's title to start
    # it with that context as the playback queue instead of a track_mix.
    track_title = sys.argv[2] if len(sys.argv) == 3 else None
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
        return 0 if try_click(sock, expected_path, track_title) else 1
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
