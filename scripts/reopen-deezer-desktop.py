#!/usr/bin/env python3
"""Reopen deezer-desktop visibly, for the user to sign back in.

Companion to autoplay-click.py, used only when that script reports its
specific "signed_out" result (exit 3): deezer-desktop's own session (stored
under ~/.config/Deezer, independent of this plugin's own OAuth login) has
expired, and every future autoplay click will keep landing on its login
screen instead of a Play button until a human signs back in through the
app's own window.

That window is normally never shown -- autoplay-click.py always launches
deezer-desktop with --start-in-tray precisely so no window ever flashes on
an ordinary click -- so there is no existing hidden window to reveal; a
signed-out session must be relaunched *without* that flag instead, which is
all this script does: kill whatever deezer-desktop instance is currently
running (same identity check autoplay-click.py itself uses, so this can't
accidentally kill an unrelated Electron app) and start a fresh one with a
normal, visible window.

Usage: reopen-deezer-desktop.py
Always exits 0 -- best-effort, same as autoplay-click.py; there is nothing
useful to retry here, and any failure just leaves the app not visibly
reopened for reasons a human debugging this can see directly (no window
appeared) without this script needing to diagnose it further.
"""
import os
import signal
import subprocess
import sys
import time

# Kept in sync with autoplay-click.py's own constant -- see its definition
# there for why this exact path, not a substring or the executable name, is
# the identity check.
DEEZER_ASAR_PATH = "/usr/share/deezer/app.asar"


def _deezer_desktop_pids():
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
        # See autoplay-click.py's _deezer_desktop_pids for why this also
        # splits on whitespace within each NUL-separated element, not just
        # on NUL: Electron rewrites its own argv memory for its process
        # title, which can collapse the whole cmdline into one element.
        args = cmdline.decode(errors="replace").replace("\0", " ").split()
        if DEEZER_ASAR_PATH in args:
            pids.append(pid)
    return pids


def main():
    for pid in _deezer_desktop_pids():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.6)
    # Deliberately no --start-in-tray and no --remote-debugging-port: this
    # is the one case where a visible, ordinary window is exactly what's
    # wanted. The next autoplay click after a successful sign-in relaunches
    # deezer-desktop the normal hidden way on its own, same as any other
    # cold start.
    subprocess.Popen(["deezer-desktop"], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL, start_new_session=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
