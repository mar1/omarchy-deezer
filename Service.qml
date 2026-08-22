import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

import "DeezerApi.js" as Api

// Shared state for the bar widget and the full panel. Playback state comes
// straight from MPRIS -- deezer-linux is the only thing that actually plays
// audio, this plugin only ever remote-controls it and browses the catalog.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "io.github.mar1.omarchy-deezer"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir) : ""

  property var settings: defaults()

  readonly property bool showMiniPlayer: String(settings.showMiniPlayer || "On") !== "Off"
  readonly property bool showTrackTitle: String(settings.showTrackTitle || "On") !== "Off"
  readonly property bool showArtistName: String(settings.showArtistName || "Off") === "On"
  readonly property bool scrollBarText: String(settings.scrollBarText || "Off") === "On"
  readonly property real scrollSpeed: Api.normalizedScrollSpeed(settings.scrollSpeed)

  readonly property alias auth: authManager

  function defaults() {
    var fallback = {
      showMiniPlayer: "On",
      showTrackTitle: "On",
      showArtistName: "Off",
      scrollBarText: "Off",
      scrollSpeed: "1"
    }
    var source = manifest && manifest.barWidget && manifest.barWidget.defaults
      ? manifest.barWidget.defaults : null
    if (!source) return fallback
    for (var key in source) fallback[key] = source[key]
    return fallback
  }

  function normalizedSettings(values) {
    var next = defaults()
    var source = values || {}
    if (source.showMiniPlayer !== undefined) next.showMiniPlayer = source.showMiniPlayer
    if (source.showTrackTitle !== undefined) next.showTrackTitle = source.showTrackTitle
    if (source.showArtistName !== undefined) next.showArtistName = source.showArtistName
    if (source.scrollBarText !== undefined) next.scrollBarText = source.scrollBarText
    if (source.scrollSpeed !== undefined) next.scrollSpeed = source.scrollSpeed
    next.showMiniPlayer = String(next.showMiniPlayer || "On") === "Off" ? "Off" : "On"
    next.showTrackTitle = String(next.showTrackTitle || "On") === "Off" ? "Off" : "On"
    next.showArtistName = String(next.showArtistName || "Off") === "On" ? "On" : "Off"
    next.scrollBarText = String(next.scrollBarText || "Off") === "On" ? "On" : "Off"
    next.scrollSpeed = String(Api.normalizedScrollSpeed(next.scrollSpeed))
    return next
  }

  function applySettings(values) {
    var next = normalizedSettings(values)
    if (JSON.stringify(next) !== JSON.stringify(settings)) settings = next
  }

  function persistSettings(values) {
    var merged = ({})
    for (var existing in settings) merged[existing] = settings[existing]
    var source = values || {}
    for (var key in source) merged[key] = source[key]
    var next = normalizedSettings(merged)
    applySettings(next)
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(pluginId, next)
  }

  function configuredEntry() {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (!config) return null
    var layout = config.bar && config.bar.layout ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    if (layout) {
      for (var s = 0; s < sections.length; s++) {
        var rows = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
        for (var i = 0; i < rows.length; i++)
          if (rows[i] && String(rows[i].id || "") === pluginId) return rows[i]
      }
    }
    return null
  }

  function syncSettings() {
    applySettings(configuredEntry() || {})
  }

  // --- MPRIS -----------------------------------------------------------

  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []

  function isDeezer(player) {
    if (!player) return false
    var identity = [player.dbusName, player.desktopEntry, player.identity]
      .join(" ").toLowerCase()
    return identity.indexOf("deezer") !== -1
  }

  readonly property var deezerPlayer: {
    var fallback = null
    for (var i = 0; i < mprisPlayers.length; i++) {
      var player = mprisPlayers[i]
      if (!isDeezer(player)) continue
      if (player.isPlaying) return player
      if (!fallback) fallback = player
    }
    return fallback
  }

  readonly property bool hasPlayer: deezerPlayer !== null
  readonly property bool hasMedia: hasPlayer
    && !!(deezerPlayer.trackTitle || deezerPlayer.trackArtist)
  readonly property bool playing: hasPlayer && deezerPlayer.isPlaying
  readonly property string title: hasPlayer ? String(deezerPlayer.trackTitle || "") : ""
  readonly property string artist: hasPlayer ? String(deezerPlayer.trackArtist || "") : ""
  readonly property string album: hasPlayer ? String(deezerPlayer.trackAlbum || "") : ""
  readonly property string artUrl: hasPlayer ? String(deezerPlayer.trackArtUrl || "") : ""
  property int playbackPositionTick: 0
  // MPRIS doesn't push Position at all -- it's poll-only (see
  // refreshPosition and the 1s Timer that drives it from the UI), and
  // deezer-desktop's own backend doesn't reset it to ~0 for a just-started
  // track the instant currentTrackId itself changes -- confirmed live
  // (raw MPRIS Position dumped straight off D-Bus around a real track
  // switch): it kept reporting the *previous* track's own real position
  // for up to roughly a second after the switch, not a merely-stale cached
  // read but the backend's own genuinely-still-old value. A first attempt
  // at covering that gap by counting up locally on our own wall clock
  // turned out worse in practice -- isPlaying flickers false for a beat
  // during the same transition, and elapsed wall-clock time kept accruing
  // underneath that pause anyway, so control handed back to the real
  // value with a sudden jump instead of a smooth count. Simply pinning
  // the display at 0 and *not* advancing it ourselves avoids that failure
  // mode entirely -- worst case it briefly under-reports by sitting at 0
  // a little longer than strictly necessary, never jumps or skips.
  // positionOverrideTimer hands control back once the backend's had long
  // enough to settle.
  property real positionOverrideSeconds: -1
  readonly property int positionOverrideWindowMs: 2500
  readonly property real positionSeconds: {
    playbackPositionTick
    if (positionOverrideSeconds >= 0) return positionOverrideSeconds
    return hasPlayer && deezerPlayer.positionSupported
      ? Math.max(0, Number(deezerPlayer.position) || 0) : 0
  }

  function startPositionOverride() {
    positionOverrideSeconds = 0
    positionOverrideTimer.restart()
  }

  Timer {
    id: positionOverrideTimer
    interval: root.positionOverrideWindowMs
    repeat: false
    onTriggered: root.positionOverrideSeconds = -1
  }
  readonly property real lengthSeconds: hasPlayer && deezerPlayer.lengthSupported
    ? Math.max(0, Number(deezerPlayer.length) || 0) : 0
  readonly property bool volumeSupported: hasPlayer && deezerPlayer.volumeSupported
  readonly property real volume: volumeSupported
    ? Math.max(0, Math.min(1, Number(deezerPlayer.volume) || 0)) : 0
  readonly property bool shuffle: hasPlayer && deezerPlayer.shuffleSupported
    && deezerPlayer.shuffle === true
  readonly property string repeatMode: {
    if (!hasPlayer || !deezerPlayer.loopSupported) return "off"
    if (deezerPlayer.loopState === MprisLoopState.Track) return "track"
    if (deezerPlayer.loopState === MprisLoopState.Playlist) return "context"
    return "off"
  }
  readonly property bool playbackControllable: hasPlayer

  // MPRIS only ever gives plain title/artist/album strings, no catalog IDs
  // to link anywhere with -- so the currently playing track's own id is
  // pulled out of its "xesam:url" ("https://deezer.com/track/12345") and
  // looked up once per track change to get real, clickable artist/album
  // refs instead of guessing from a name search.
  readonly property string currentTrackUrl: hasPlayer && deezerPlayer.metadata
    ? String(deezerPlayer.metadata["xesam:url"] || "") : ""
  // Same id, pulled out once for UI code that just wants to know "is this
  // the track that's loaded right now?" (e.g. highlighting it in a list)
  // without duplicating the regex everywhere.
  readonly property string currentTrackId: {
    var match = currentTrackUrl.match(/\/track\/(\d+)/)
    return match ? match[1] : ""
  }
  property var currentTrackArtist: null
  property var currentTrackAlbum: null

  onCurrentTrackUrlChanged: {
    currentTrackArtist = null
    currentTrackAlbum = null
    var match = currentTrackUrl.match(/\/track\/(\d+)/)
    if (!match) return
    var trackId = match[1]
    Api.get("/track/" + trackId, null, authManager.accessToken, function(ok, payload) {
      if (!ok || !payload || String(payload.id || "") !== trackId) return
      if (root.currentTrackUrl.indexOf("/track/" + trackId) === -1) return
      var normalized = Api.normalizeTrack(payload)
      root.currentTrackArtist = normalized.artists.length ? normalized.artists[0] : null
      root.currentTrackAlbum = normalized.album
    })
  }

  function refreshPosition() {
    if (hasPlayer && deezerPlayer.positionSupported) deezerPlayer.positionChanged()
    else playbackPositionTick++
  }

  function togglePlayback() {
    if (hasPlayer && deezerPlayer.canTogglePlaying) deezerPlayer.togglePlaying()
  }
  function next() {
    if (hasPlayer && deezerPlayer.canGoNext) deezerPlayer.next()
  }
  function previous() {
    if (hasPlayer && deezerPlayer.canGoPrevious) deezerPlayer.previous()
  }
  function seekSeconds(value) {
    if (!hasPlayer || !deezerPlayer.canSeek || !deezerPlayer.positionSupported) return
    var maximum = lengthSeconds > 0 ? lengthSeconds : Number.MAX_VALUE
    deezerPlayer.position = Math.max(0, Math.min(maximum, Number(value) || 0))
    // A manual seek moves positionSeconds out from under whatever estimate
    // schedulePreemptiveAdvance() last used -- redo it against the new
    // position so a seek backward doesn't cut the track short early and a
    // seek forward doesn't leave the mix pick a window to sneak in again.
    if (playQueue.length && playQueueConfirmed) schedulePreemptiveAdvance()
  }
  function setVolume(value) {
    if (!volumeSupported) return
    deezerPlayer.volume = Math.max(0, Math.min(1, Number(value) || 0))
  }
  function setShuffle(value) {
    if (hasPlayer && deezerPlayer.shuffleSupported) deezerPlayer.shuffle = value === true
  }
  function cycleRepeat() {
    if (!hasPlayer || !deezerPlayer.loopSupported) return
    deezerPlayer.loopState = repeatMode === "off" ? MprisLoopState.Playlist
      : (repeatMode === "context" ? MprisLoopState.Track : MprisLoopState.None)
  }

  // Deezer's public API has no remote-playback-control endpoint (unlike
  // Spotify Connect), and -- verified against a live MPRIS dump, not
  // assumed -- deezer-desktop's own deep links don't fill that gap either.
  // Opening one only ever navigates its window to that catalog page: the
  // app always resumes whatever its own persisted session last had loaded
  // into the player, regardless of which URL it was launched or forwarded
  // with, cold start or warm. Its `?autoplay=true` handling is dead code
  // for /track, /album, /artist, and /playlist (only /smarttracklist and
  // /user/me/flow call the player). The only thing that actually starts
  // the requested item is a real click on that page's own Play button.
  //
  // scripts/autoplay-click.py drives exactly that: relaunch deezer-desktop
  // with a Chrome DevTools Protocol port (it's Electron) and click the
  // right button by data-testid once the page has actually routed there --
  // confirmed end-to-end across /track, /playlist, /album, and /artist.
  // Fully best-effort: if python3 is missing, the script fails, or a future
  // Deezer UI update renames those testids, this quietly does nothing more
  // than opening deezer-desktop already did on its own.
  function openInDeezer(item) {
    if (!item || !item.link) return
    clearQueue()
    runAutoplayClick(item.link)
  }

  // Playing a track by opening its own standalone page starts a Deezer
  // "track mix" queue around it instead of continuing into whatever
  // playlist/library it came from -- confirmed live, the track after it was
  // Deezer's own algorithmic pick, not the next one in that context. An
  // earlier version worked around that by clicking the track's own row
  // *within* the context page instead, keeping the context itself as the
  // queue -- abandoned because deezer-desktop's virtualized row list never
  // mounts a row beyond whatever handful were already there on load while
  // its window stays hidden (--start-in-tray), which scrolling by any means
  // couldn't work around (see scripts/autoplay-click.py's own docstring).
  //
  // playQueue/advanceQueue below reimplement that continuity ourselves
  // instead: play each track by its own simple, reliable page (same as
  // openInDeezer), and when MPRIS reports it's moved on to something we
  // didn't ask for, immediately override with the *actual* next track in
  // our own list.
  property var playQueue: []
  property string playQueueExpectedId: ""
  // Whether currentTrackId has ever matched (or been adopted as, see
  // below) what we're currently waiting on -- distinguishes "never
  // actually confirmed playing" (a click still in flight, failed outright)
  // from a genuine advance below.
  property bool playQueueConfirmed: false
  property double playQueueLaunchedAt: 0
  // A real "this track finished" MPRIS change never arrives less than a
  // few seconds after launching it -- even the shortest real songs run
  // longer than this. Below this threshold, a currentTrackId that doesn't
  // match what was asked for is a catalog id redirect settling (see
  // below), not the track ending.
  readonly property int minTrackElapsedMs: 3000

  // How long the warm path of scripts/autoplay-click.py takes to land a
  // click, roughly (its own sleeps alone add up to ~1s -- see its
  // docstring). Waiting for MPRIS to report the queued track actually
  // ending before starting that meant deezer-desktop's own algorithmic
  // "track mix" pick got to play audibly for about that long every time,
  // since it always fills the gap the instant the real track ends and we
  // don't override it until the click above finally lands. Firing the next
  // click this long *before* the natural end instead means our own click's
  // latency is absorbed inside the current track's own tail, so the mix
  // pick never gets a chance to start.
  readonly property int preemptiveAdvanceLeadMs: 1000

  // Loose title match (case/whitespace-insensitive) used to tell a same-
  // song catalog-id redirect apart from a genuinely different track
  // loading this fast -- e.g. an unavailable/region-locked track falling
  // back to something unrelated, which should NOT be adopted as "this is
  // just our track under a different id".
  function looksLikeSameTrack(a, b) {
    var norm = function(s) { return String(s || "").trim().toLowerCase() }
    a = norm(a); b = norm(b)
    return a.length > 0 && a === b
  }

  function clearQueue() {
    playQueue = []
    playQueueExpectedId = ""
    playQueueConfirmed = false
    preemptiveAdvanceTimer.stop()
  }

  function playFromQueue(tracks, startIndex) {
    if (startIndex < 0) { clearQueue(); return }
    playQueue = tracks.slice(startIndex)
    advanceQueue()
  }

  function advanceQueue() {
    preemptiveAdvanceTimer.stop()
    if (!playQueue.length) { playQueueExpectedId = ""; playQueueConfirmed = false; return }
    var track = playQueue[0]
    playQueueExpectedId = String(track.id)
    playQueueConfirmed = false
    playQueueLaunchedAt = Date.now()
    runAutoplayClick(track.link)
  }

  // Drops the confirmed head of the queue and moves on to the next one --
  // shared by the reactive "MPRIS says it already changed" path below and
  // the proactive timer that preempts it.
  function advanceToNextQueuedTrack() {
    playQueue.shift()
    advanceQueue()
  }

  // Schedules advanceToNextQueuedTrack() to fire preemptiveAdvanceLeadMs
  // before the just-confirmed track's own natural end, so our own click
  // lands before deezer-desktop's "track mix" ever gets a gap to fill.
  // Only possible when MPRIS actually gives a usable length -- when it
  // doesn't, this silently does nothing more and onCurrentTrackIdChanged's
  // reactive handling below remains the only path, same as before this
  // existed.
  function schedulePreemptiveAdvance() {
    preemptiveAdvanceTimer.stop()
    if (!playQueue.length || !hasPlayer || !deezerPlayer.lengthSupported
        || !deezerPlayer.positionSupported) return
    var remainingMs = (lengthSeconds - positionSeconds) * 1000 - preemptiveAdvanceLeadMs
    if (remainingMs <= 0) return
    preemptiveAdvanceTimer.interval = remainingMs
    preemptiveAdvanceTimer.start()
  }

  Timer {
    id: preemptiveAdvanceTimer
    repeat: false
    onTriggered: root.advanceToNextQueuedTrack()
  }

  // Fires on every MPRIS track change, including the one where our own
  // click above lands (currentTrackId becomes playQueueExpectedId -- the
  // "nothing to do" case below). It's only a *later* change after that --
  // the queued track ending, on to Deezer's own algorithmic pick -- that
  // this needs to catch and override.
  onCurrentTrackIdChanged: {
    // See positionOverrideSeconds/startPositionOverride above: pin the
    // elapsed-time display at 0 for a bit on any track change, real or
    // queue-driven, rather than showing whatever stale figure the backend
    // hasn't caught up to replacing yet.
    startPositionOverride()
    if (!playQueue.length) return
    if (currentTrackId === playQueueExpectedId) {
      playQueueConfirmed = true
      schedulePreemptiveAdvance()
      return
    }
    // MPRIS metadata briefly clears (xesam:url stops matching a /track/
    // link, so currentTrackId reads "") while deezer-desktop is still
    // mid-transition to the track we just asked for -- confirmed live as
    // one reason a queued track got cut short early: that transient blank
    // was being read as "it already ended, advance". It isn't a real
    // track change; wait for the next one instead of treating a gap as
    // evidence of anything.
    if (currentTrackId === "") return
    if (Date.now() - playQueueLaunchedAt < minTrackElapsedMs
        && looksLikeSameTrack(title, playQueue[0].name)) {
      // Too soon to be the track actually ending -- confirmed live:
      // Deezer sometimes settles the id we asked for to a different
      // canonical id for the very same song (duplicate catalog entries
      // merged) well under a second after loading, which read exactly
      // like "it ended, advance" before this guard existed and skipped an
      // extra track ahead despite the requested one playing correctly.
      // Adopt whatever id it actually settled on instead of assuming
      // anything ended. The title check keeps this from also swallowing a
      // genuinely different track that happened to load this fast (an
      // unavailable/region-locked track falling back to something
      // unrelated) -- that's not this queue's next track either, so it
      // falls through to the "never confirmed" branch below instead.
      playQueueExpectedId = currentTrackId
      playQueueConfirmed = true
      schedulePreemptiveAdvance()
      return
    }
    if (!playQueueConfirmed) {
      // Never actually confirmed this queue head loaded at all (the click
      // is still in flight, failed outright, or something unrelated took
      // over in the meantime) -- don't guess, just stop trying to steer
      // whatever's happening now.
      clearQueue()
      return
    }
    // The preemptive timer above should normally beat this -- reaching here
    // means MPRIS reported the change before that timer fired (no usable
    // length, or the click landed later than preemptiveAdvanceLeadMs
    // predicted). Same continuation either way.
    advanceToNextQueuedTrack()
  }

  // Looked up by id rather than plain Array.indexOf(track) -- the clicked
  // item comes from a ListView delegate's modelData, which is only
  // guaranteed structurally equal to whatever's in these lists right now,
  // not necessarily the exact same object reference indexOf's strict
  // equality needs. A reference mismatch there silently returned -1 and
  // dropped the click entirely (playFromQueue's own startIndex < 0 guard),
  // with nothing to show for it -- no error, no process spawned.
  function indexOfTrackId(list, track) {
    if (!track) return -1
    var id = String(track.id)
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id) === id) return i
    }
    return -1
  }

  function openPlaylistTrack(track) {
    if (!track) return
    playFromQueue(playlistTracks, indexOfTrackId(playlistTracks, track))
  }

  function openFavoriteTrack(track) {
    if (!track) return
    playFromQueue(favoriteTracks, indexOfTrackId(favoriteTracks, track))
  }

  function openArtistTrack(track) {
    if (!track) return
    playFromQueue(artistTopTracks, indexOfTrackId(artistTopTracks, track))
  }

  function openAlbumTrack(track) {
    if (!track) return
    playFromQueue(albumTracks, indexOfTrackId(albumTracks, track))
  }

  function runAutoplayClick(link) {
    var url = link.indexOf("https://") === 0
      ? "deezer://" + link.slice("https://".length)
      : link
    var args = ["python3", pluginDir + "/scripts/autoplay-click.py", url]
    // A click while a previous one is still mid-relaunch would otherwise be
    // silently dropped (setting `running` true again while already true is
    // a no-op) -- always honor the latest click instead.
    if (autoplayClickProcess.running) autoplayClickProcess.running = false
    autoplayClickProcess.command = args
    autoplayClickProcess.running = true
  }

  Process {
    id: autoplayClickProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  // --- Auth + catalog ----------------------------------------------------

  AuthManager {
    id: authManager
    pluginDir: root.pluginDir
    onLoginSucceeded: root.activate(root.activeView)
  }

  readonly property bool loggedIn: authManager.loggedIn
  readonly property bool loginBusy: authManager.loginBusy
    || authManager.exchangingCode || authManager.sessionBusy || !authManager.sessionChecked

  property string activeView: "player"
  property string currentUserName: ""

  property var playlists: []
  property string playlistsNext: ""
  property bool playlistsLoaded: false
  property bool playlistsLoading: false

  property var favoriteTracks: []
  property bool favoriteTracksLoaded: false
  property bool favoriteTracksLoading: false
  property var favoriteTrackIds: ({})

  property var selectedPlaylist: null
  property var playlistTracks: []
  property bool playlistTracksLoading: false

  property var selectedArtist: null
  property var artistTopTracks: []
  property var artistAlbums: []
  property bool artistLoading: false

  property var selectedAlbum: null
  property var albumTracks: []
  property bool albumLoading: false

  property string searchQuery: ""
  property var searchResults: []
  property bool searchLoading: false
  property int searchSerial: 0

  property string lastError: ""
  property var visibleSurfaces: ({})
  readonly property bool uiVisible: Object.keys(visibleSurfaces).length > 0

  signal operationFailed(string reason)

  function fail(reason) {
    lastError = String(reason || "Deezer request failed")
    operationFailed(lastError)
  }

  function setUiVisible(key, value) {
    var name = String(key || "surface")
    var next = ({})
    for (var oldKey in visibleSurfaces)
      if (oldKey !== name && visibleSurfaces[oldKey]) next[oldKey] = true
    if (value) next[name] = true
    visibleSurfaces = next
    if (value) activate(activeView)
  }

  function activate(view) {
    activeView = String(view || "player")
    authManager.withAccessToken(function(token, error) {
      if (!token) {
        if (error && error !== "Log in to Deezer first") root.fail(error)
        return
      }
      root.loadProfile()
      root.openView(root.activeView, false)
    })
  }

  function openView(view, force) {
    activeView = String(view || "player")
    if (!authManager.loggedIn) return
    if (activeView === "playlists" && (force || !playlistsLoaded)) loadPlaylists(false)
    else if (activeView === "favorites" && (force || !favoriteTracksLoaded)) loadFavoriteTracks()
  }

  function refreshView(view) { openView(view, true) }

  function loadProfile() {
    if (currentUserName) return
    Api.get("/user/me", null, authManager.accessToken, function(ok, payload) {
      if (ok && payload) root.currentUserName = String(payload.name || "")
    })
  }

  function loadPlaylists(append) {
    if (playlistsLoading) return
    var path = append ? playlistsNext : "/user/me/playlists"
    if (!path) return
    playlistsLoading = true
    Api.get(path, append ? null : { limit: 30 }, authManager.accessToken,
      function(ok, payload, error) {
        root.playlistsLoading = false
        if (!ok) { root.fail(error); return }
        var page = Api.normalizePage(payload)
        root.playlists = append ? Api.mergeUnique(root.playlists, page.items) : page.items
        root.playlistsNext = page.next
        root.playlistsLoaded = true
      })
  }

  function loadMorePlaylists() { loadPlaylists(true) }

  property int favoriteTracksSerial: 0

  // Fetches every page up front (same reasoning as fetchAllPlaylistTracks):
  // a manual "load more" left the "most recently loved first" sort only
  // ever correct within whatever had been clicked through so far, since a
  // track loved after the currently-loaded pages could belong anywhere
  // among them once the rest showed up.
  function loadFavoriteTracks() {
    if (favoriteTracksLoading) return
    favoriteTracksLoading = true
    var serial = ++favoriteTracksSerial
    fetchAllFavoriteTracks("/user/me/tracks", { limit: 50 }, [], serial)
  }

  function fetchAllFavoriteTracks(path, query, accumulated, serial) {
    Api.get(path, query, authManager.accessToken, function(ok, payload, error) {
      if (serial !== root.favoriteTracksSerial) return
      if (!ok) {
        root.favoriteTracksLoading = false
        root.fail(error)
        return
      }
      var page = Api.normalizePage(payload)
      var merged = accumulated.concat(page.items)
      if (page.next) {
        root.fetchAllFavoriteTracks(page.next, null, merged, serial)
        return
      }
      // Same reasoning as playlist tracks: the API's own fetch order isn't
      // chronological, so sort explicitly by its "time_add" timestamp.
      merged.sort(function(a, b) { return (b.addedAt || 0) - (a.addedAt || 0) })
      root.favoriteTracksLoading = false
      root.favoriteTracks = merged
      root.favoriteTracksLoaded = true
      var ids = ({})
      for (var i = 0; i < merged.length; i++) ids[merged[i].id] = true
      root.favoriteTrackIds = ids
    })
  }

  function isFavorite(item) {
    return !!item && item.type === "track" && favoriteTrackIds[item.id] === true
  }

  function toggleFavorite(item) {
    if (!item || item.type !== "track") return
    var adding = !isFavorite(item)
    Api.request(adding ? "POST" : "DELETE", "/user/me/tracks",
      { track_id: item.id }, authManager.accessToken, function(ok, payload, error) {
        if (!ok) { root.fail(error); return }
        var ids = ({})
        for (var k in root.favoriteTrackIds) ids[k] = root.favoriteTrackIds[k]
        if (adding) ids[item.id] = true
        else delete ids[item.id]
        root.favoriteTrackIds = ids
        if (root.favoriteTracksLoaded) root.loadFavoriteTracks()
      })
  }

  property int playlistTracksSerial: 0

  function openPlaylist(item) {
    if (!item || item.type !== "playlist") return
    selectedPlaylist = item
    activeView = "detail"
    playlistTracks = []
    playlistTracksLoading = true
    var serial = ++playlistTracksSerial
    fetchAllPlaylistTracks("/playlist/" + item.id + "/tracks", { limit: 100 }, [], serial)
  }

  // A single `limit: 100` fetch silently truncated any playlist past 100
  // tracks (e.g. a 138-track playlist showed only its first 100) -- follow
  // the API's own pagination ("next") until it's exhausted instead. `serial`
  // drops a stale chain's response if the user opens a different playlist
  // (or leaves the detail view) before it finishes.
  function fetchAllPlaylistTracks(path, query, accumulated, serial) {
    Api.get(path, query, authManager.accessToken, function(ok, payload, error) {
      if (serial !== root.playlistTracksSerial) return
      if (!ok) {
        root.playlistTracksLoading = false
        root.fail(error)
        return
      }
      var page = Api.normalizePage(payload)
      var merged = accumulated.concat(page.items)
      if (page.next) {
        root.fetchAllPlaylistTracks(page.next, null, merged, serial)
        return
      }
      // The API's own fetch order isn't chronological at all (checked
      // live: time_add values come back scattered, not ascending or
      // descending) -- sorting by it explicitly is required to get
      // most-recently-added-first.
      merged.sort(function(a, b) { return (b.addedAt || 0) - (a.addedAt || 0) })
      root.playlistTracksLoading = false
      root.playlistTracks = merged
    })
  }

  function closeDetail() {
    playlistTracksSerial++
    selectedPlaylist = null
    playlistTracks = []
    playlistTracksLoading = false
    activeView = "playlists"
  }

  // Wherever the user was standing right before opening an artist or album
  // -- search results, a playlist's own tracks, favorites -- so "back"
  // returns them there instead of always landing on the same fixed tab.
  property string detailReturnView: "search"

  function openArtist(ref) {
    if (!ref || !ref.id) return
    detailReturnView = activeView
    activeView = "artist-detail"
    var link = ref.link || ("https://www.deezer.com/artist/" + ref.id)
    selectedArtist = { type: "artist", id: String(ref.id), name: String(ref.name || ""),
      subtitle: ref.subtitle || "", imageUrl: ref.imageUrl || "", link: link, artists: [] }
    artistTopTracks = []
    artistAlbums = []
    artistLoading = true
    var pending = 3
    function settle() { pending--; if (pending <= 0) root.artistLoading = false }
    Api.get("/artist/" + ref.id, null, authManager.accessToken, function(ok, payload) {
      if (ok && payload) root.selectedArtist = Api.normalizeArtist(payload)
      settle()
    })
    Api.get("/artist/" + ref.id + "/top", { limit: 25 }, authManager.accessToken,
      function(ok, payload, error) {
        if (ok) root.artistTopTracks = Api.normalizePage(payload).items
        else root.fail(error)
        settle()
      })
    Api.get("/artist/" + ref.id + "/albums", { limit: 50 }, authManager.accessToken,
      function(ok, payload, error) {
        if (ok) root.artistAlbums = Api.normalizePage(payload).items
        else root.fail(error)
        settle()
      })
  }

  function closeArtistDetail() {
    selectedArtist = null
    artistTopTracks = []
    artistAlbums = []
    artistLoading = false
    activeView = detailReturnView
  }

  // Accepts either a fully normalized album item (search results, an
  // artist's discography) or a lightweight {id, name} ref -- all a track's
  // own "· Album Name" byline carries, since normalizeTrack's embedded
  // album field has no link/imageUrl of its own.
  function openAlbum(ref) {
    if (!ref || !ref.id) return
    detailReturnView = activeView
    activeView = "album-detail"
    var link = ref.link || ("https://www.deezer.com/album/" + ref.id)
    selectedAlbum = { type: "album", id: String(ref.id), name: String(ref.name || ""),
      subtitle: ref.subtitle || "", imageUrl: ref.imageUrl || "", link: link, artists: [] }
    albumTracks = []
    albumLoading = true
    Api.get("/album/" + ref.id + "/tracks", { limit: 100 }, authManager.accessToken,
      function(ok, payload, error) {
        root.albumLoading = false
        if (!ok) { root.fail(error); return }
        root.albumTracks = Api.normalizePage(payload).items
      })
  }

  function closeAlbumDetail() {
    selectedAlbum = null
    albumTracks = []
    albumLoading = false
    activeView = detailReturnView
  }

  // The catalog search endpoint is public and needs no access token; only
  // per-user actions (favorites, playlists) require being signed in.
  function search(query) {
    searchQuery = String(query || "")
    var term = searchQuery.trim()
    var serial = ++searchSerial
    if (!term) {
      searchResults = []
      searchLoading = false
      return
    }
    searchLoading = true
    Api.get("/search", { q: term, limit: 30 }, "", function(ok, payload, apiError) {
      if (serial !== root.searchSerial) return
      root.searchLoading = false
      if (!ok) { root.fail(apiError); return }
      root.searchResults = Api.normalizePage(payload).items
    })
  }
}
