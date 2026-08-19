# Omarchy Deezer

Deezer in the [Omarchy Quattro](https://github.com/basecamp/omarchy) bar. Playback runs
entirely inside the unofficial [`deezer-linux`](https://flathub.org/apps/dev.aunetx.deezer)
Flatpak, which exposes an MPRIS2 interface on D-Bus; this plugin reads and controls that
interface from the bar, and separately talks to the public Deezer REST API so you can browse
playlists, favorites, and search the catalog without leaving Omarchy.

This is an independent, community project. It is **not affiliated with, endorsed by, or
supported by Deezer S.A.**

## Prerequisites

- Arch Linux, Hyprland, Omarchy Quattro (Quickshell-based bar)
- [`deezer-linux`](https://flathub.org/apps/dev.aunetx.deezer) (`dev.aunetx.deezer`) installed
  and running: `flatpak install flathub dev.aunetx.deezer`
- A Deezer account (Premium is required by Deezer for uninterrupted playback, same as the
  official app)
- `socat` and `secret-tool` (from `libsecret`) available on `PATH` -- used for the local OAuth
  callback and for storing your access token in the GNOME Keyring
- `python3` (stdlib only, no extra packages) -- drives the autoplay workaround described below

## Install

```
omarchy plugin add https://github.com/mar1/omarchy-deezer.git --enable
```

## Remove

```
omarchy plugin remove io.github.mar1.omarchy-deezer
```

This removes the plugin's bar widget and panel and stops the MPRIS service it ran, but
`deezer-linux` itself and your saved access token are untouched (they aren't installed or
written by the plugin's removal path). To clean those up too:

- **Sign out first, if you can**: open the full player and use its sign-out action before
  removing the plugin -- this clears the access token from the GNOME Keyring the same way
  `AuthManager.qml`'s `clearStoredToken()` does.
- **Already removed the plugin?** Clear the leftover keyring entry directly:
  ```
  secret-tool clear service quickshell-deezer kind access-token app-id deezer
  ```
- **Uninstall `deezer-linux`** (optional -- only if you don't use it outside this plugin):
  ```
  flatpak uninstall dev.aunetx.deezer
  ```

## Setup

1. Start `deezer-linux` (or `deezer-desktop --ozone-platform-hint=auto`) and log in there as you
   normally would -- this is the app that actually plays audio.
2. Click the Deezer icon in the bar, open the full player, and click **Connect with Deezer**.
   Your browser opens Deezer's own sign-in page; approve access and you're done. There is no app
   to create and nothing to configure -- the plugin ships with its own registered Deezer
   application (see *For contributors* below).
3. Once deezer-linux starts playing something, the bar shows the current track and the mini
   player gives you play/pause, skip, and seek controls straight from MPRIS.

## Usage

- **Left click** the bar icon: open the mini player (or the full player, if mini player is
  disabled in settings).
- **Middle click**: play/pause.
- **Scroll**: previous/next track.
- **Full player**: tabs for **Player**, **Playlists**, **Favorites**, and **Search**. Selecting
  a track, album, artist, or playlist opens it in `deezer-desktop` and clicks Play on it there --
  see *Known limitation* below for how (and why it isn't a plain `xdg-open` on the item's
  `deezer.com` link).

## Known limitation: no remote-playback endpoint, worked around via CDP

Unlike Spotify Connect, the public Deezer API has no endpoint to *start* playback of an arbitrary
track/playlist on a device, and -- verified rather than assumed, against live MPRIS dumps and the
app's own bundled source -- `deezer-desktop`'s deep links don't fill that gap either:

- Opening a `deezer://` link only ever navigates the app's window to that catalog page.
  `deezer-desktop` always resumes whatever track its own persisted session last had loaded,
  regardless of which URL it was launched or deep-linked with, cold start or warm.
- Its `?autoplay=true` deep-link handling is dead code for `/track`, `/album`, `/artist`, and
  `/playlist` -- the parameter is read but the result is discarded rather than used to call the
  player (only `/smarttracklist` and `/user/me/flow` genuinely autoplay).
- Forwarding a deep link to an already-running instance (Electron's `second-instance` mechanism)
  never reliably reached the app's own deep-link handler in testing.

The only thing that actually starts the requested item is a real click on that page's own Play
button. `deezer-desktop` is Electron, though, which means it can be launched with a Chrome
DevTools Protocol port -- `scripts/autoplay-click.py` does exactly that, then clicks the right
button by its `data-testid` (`track_mix-play-button` for tracks, `play` for playlists/albums,
`artist-play-button` for artists -- read straight off a live DOM, not guessed, so it isn't
locale-dependent the way matching visible button text would be). Verified end-to-end across all
four content types.

That CDP port can only be set at launch, so the app only gets killed and relaunched when it
genuinely isn't already running with it -- relaunching on every click was pure overhead once it's
already up. A fresh launch uses `--start-in-tray` (a flag this Arch build already carries from its
own patch set, `aunetx/deezer-linux`'s `01-start-in-tray.patch`, applied at package build time) so
no window ever gets mapped by Hyprland in the first place. For an already-running instance, the
obvious move -- handing it the new link the normal way -- turned out to have a catch: its own
`second-instance` handler unconditionally calls `window.show()` as a side effect, popping the
window up on every single click regardless of `--start-in-tray` (which only ever covers the
*initial* launch). Setting the page's own `location.hash` directly through CDP instead reaches
the same client-side router without going through that handler at all, confirmed live to leave
the window untouched. Between the two paths, a window is never shown at any point during normal
use of this plugin -- confirmed live (`hyprctl clients` stays empty throughout) across a cold
start and repeated warm track changes alike.

If your build of `deezer-desktop` doesn't carry the `--start-in-tray` patch, that flag is simply
ignored on a cold launch and the window will flash briefly there instead -- everything else still
works the same.

This is still fundamentally automating around a gap in `deezer-desktop` (currently v7.1.300), not
calling a supported integration point: a future update that renames those testids, or changes how
its deep-link routing works, can break it silently. When that happens, opening an item falls back
to exactly what it did before this workaround -- the right page opens, one press of Play away.

## For contributors

`OAuth.js` embeds an `app_id`/`secret` pair identifying *this plugin's own* Deezer application,
the same way `spotifyd`, `ncspot`, and Omarchy Spotify all embed their own client IDs. Deezer's
`app_id` is a public identifier by design; the `secret` here is not a per-user secret, and
because Deezer has no meaningful per-app rate quota for small open-source clients, embedding it
is the standard, low-friction approach for a project like this.

If you fork this plugin, create your own application at
[developers.deezer.com](https://developers.deezer.com) and replace both `APP_ID` and
`APP_SECRET` at the top of `OAuth.js`.

### A note on transport

The plugin's spec draft assumed `fetch()`/CORS semantics (as in a browser). Quickshell's QML JS
engine is a plain ECMAScript engine with no DOM or WebEngine underneath it -- there is no
`fetch`, and no CORS to work around in the first place. Every network call here (catalog API and
the Deezer OAuth token exchange) uses `XMLHttpRequest`, which Qt provides natively to QML and
which is not subject to same-origin restrictions. This matches how the reference
[Omarchy-Spotify](https://github.com/stappmus/Omarchy-Spotify) plugin talks to Spotify's API.

## Architecture

| Layer | Technology |
|---|---|
| UI shell | QML (Quickshell / Omarchy Quattro) |
| Business logic | JavaScript (`.js` pragma-library modules) |
| Audio playback | MPRIS2 via D-Bus, provided by `deezer-linux` |
| Catalog API | REST `https://api.deezer.com` (no auth required for public catalog reads) |
| User auth | Deezer's proprietary OAuth-like flow (`connect.deezer.com/oauth/...`) |
| Token storage | GNOME Keyring via `secret-tool` |

```
manifest.json        Plugin metadata, bar-widget settings schema
Service.qml           MPRIS watcher + playback controls + catalog/session state
AuthManager.qml        Deezer sign-in flow, keyring-backed token storage
BarWidget.qml           Mini-player bar entry + popup
Panel.qml                Full player window: sign-in, Player/Playlists/Favorites/Search tabs
DeezerApi.js               REST calls + response normalization
OAuth.js                    Auth URL / callback / token-response parsing (app_id + secret live here)
MediaByline.qml               "artist · album" line under a track title
MediaRow.qml                   One row (track/album/artist/playlist) in a list
MediaCollection.qml             Filterable list of MediaRow entries with pagination
PlaybackSlider.qml               Seek/volume slider with drag preview
scripts/keyring-store.sh          Writes the access token to the GNOME Keyring
scripts/autoplay-click.py          Relaunches deezer-desktop with a CDP port and clicks Play
```

## Credits

- [`aunetx/deezer-linux`](https://github.com/aunetx/deezer-linux) -- the Flatpak that actually
  plays audio and exposes it over MPRIS2; this plugin is a remote control and catalog browser
  built around it. Its `01-start-in-tray.patch` is also what lets the autoplay workaround (see
  *Known limitation* above) launch `deezer-desktop` without ever flashing a window.
- [`stappmus/Omarchy-Spotify`](https://github.com/stappmus/Omarchy-Spotify) -- the reference
  Omarchy Quattro plugin this one follows architecturally: bar widget + full player + keyring-backed
  OAuth token storage talking to a REST catalog API via `XMLHttpRequest`.

## License

MIT, see [LICENSE](LICENSE).
