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
  readonly property real positionSeconds: {
    playbackPositionTick
    return hasPlayer && deezerPlayer.positionSupported
      ? Math.max(0, Number(deezerPlayer.position) || 0) : 0
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
    runAutoplayClick(item.link, "")
  }

  // Playing a track by opening its own standalone page starts a Deezer
  // "track mix" queue around it -- confirmed live, the track after it was
  // Deezer's algorithmic pick, not the next one in the playlist/library it
  // came from. Playing it from *within* that context page instead (its own
  // per-row Play button) keeps the context itself as the queue. See
  // scripts/autoplay-click.py for how the row is matched.
  function openPlaylistTrack(track) {
    if (!track || !selectedPlaylist || !selectedPlaylist.link) return
    runAutoplayClick(selectedPlaylist.link, track.name)
  }

  readonly property string lovedTracksLink: "https://www.deezer.com/profile/me/loved"

  function openFavoriteTrack(track) {
    if (!track) return
    runAutoplayClick(lovedTracksLink, track.name)
  }

  function runAutoplayClick(link, trackTitle) {
    var url = link.indexOf("https://") === 0
      ? "deezer://" + link.slice("https://".length)
      : link
    var args = ["python3", pluginDir + "/scripts/autoplay-click.py", url]
    if (trackTitle) args.push(trackTitle)
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

  // Same context-preserving trick as openPlaylistTrack: playing a top track
  // by opening its own standalone page would start a track_mix instead of
  // continuing through the artist's other top tracks.
  function openArtistTrack(track) {
    if (!track || !selectedArtist || !selectedArtist.link) return
    runAutoplayClick(selectedArtist.link, track.name)
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

  function openAlbumTrack(track) {
    if (!track || !selectedAlbum || !selectedAlbum.link) return
    runAutoplayClick(selectedAlbum.link, track.name)
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
