.pragma library

// All Deezer REST calls, plus normalization of the catalog's JSON shapes into
// a single flat "item" shape the QML views understand.
//
// NOTE ON TRANSPORT: the QML JS engine (QJSEngine) is a plain ECMAScript
// engine with no DOM, no WebEngine, and no fetch()/Promise-network stack --
// contrary to what a browser-side script could assume. XMLHttpRequest *is*
// available (Qt ships it for QML) and, unlike a browser XHR, it is not
// subject to CORS -- there is no origin/document to enforce it against. That
// makes plain callback-based XMLHttpRequest both the only option and, for
// this use case, a strictly simpler one than fetch() would have been.

var API_BASE = "https://api.deezer.com"

function encode(value) {
  return encodeURIComponent(String(value === undefined || value === null ? "" : value))
}

function appendQuery(url, params) {
  var pairs = []
  var source = params || {}
  for (var key in source) {
    var value = source[key]
    if (value === undefined || value === null || value === "") continue
    pairs.push(encode(key) + "=" + encode(value))
  }
  if (!pairs.length) return url
  return url + (url.indexOf("?") >= 0 ? "&" : "?") + pairs.join("&")
}

function parseJson(text, fallback) {
  try {
    var value = JSON.parse(text)
    return value === undefined ? fallback : value
  } catch (e) {
    return fallback
  }
}

function responseError(status, payload) {
  if (payload && payload.error && payload.error.message)
    return String(payload.error.message)
  if (status === 0) return "Could not reach the Deezer catalog"
  if (status === 401 || status === 403) return "Your Deezer session has expired. Please sign in again"
  if (status === 429) return "Too many requests to Deezer. Try again shortly"
  return "Deezer could not complete this request"
}

// path may be a plain "/user/me/playlists"-style path or a full URL, since
// Deezer's pagination "next" field is already an absolute URL.
function request(method, path, query, token, callback) {
  var url = String(path || "").indexOf("http") === 0 ? path : API_BASE + path
  url = appendQuery(url, query)
  url = appendQuery(url, token ? { access_token: token } : null)

  var xhr = new XMLHttpRequest()
  xhr.onreadystatechange = function() {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    var payload = parseJson(xhr.responseText, null)
    var ok = xhr.status >= 200 && xhr.status < 300 && !(payload && payload.error)
    var error = ok ? "" : responseError(xhr.status, payload)
    if (typeof callback === "function") callback(ok, payload, error)
  }
  xhr.open(String(method || "GET"), url)
  xhr.send()
  return xhr
}

function get(path, query, token, callback) {
  return request("GET", path, query, token, callback)
}

// --- Normalization -------------------------------------------------------

function pickImage(source) {
  if (!source) return ""
  return String(source.picture_medium || source.cover_medium
    || source.picture || source.cover || source.picture_small
    || source.cover_small || "")
}

// /album/{id}/tracks rows carry neither an embedded "album" object nor any
// cover field of their own (checked live) -- only "md5_image", from which a
// cover URL can still be built directly using Deezer's own CDN pattern (the
// same one every other cover URL already follows).
function imageFromMd5(md5) {
  return md5 ? "https://cdn-images.dzcdn.net/images/cover/" + md5 + "/250x250-000000-80-0-0.jpg" : ""
}

function normalizeArtistRef(raw) {
  if (!raw) return null
  return { id: String(raw.id || ""), name: String(raw.name || "Unknown artist") }
}

function normalizeTrack(raw) {
  if (!raw) return null
  var artist = raw.artist ? normalizeArtistRef(raw.artist) : null
  return {
    type: "track",
    id: String(raw.id || ""),
    name: String(raw.title || raw.title_short || "Untitled"),
    subtitle: artist ? artist.name : "",
    imageUrl: pickImage(raw.album) || pickImage(raw) || imageFromMd5(raw.md5_image),
    link: String(raw.link || ""),
    durationMs: Math.max(0, Number(raw.duration) || 0) * 1000,
    artists: artist ? [artist] : [],
    album: raw.album ? {
      id: String(raw.album.id || ""),
      name: String(raw.album.title || ""),
      imageUrl: pickImage(raw.album),
      link: String(raw.album.link || "")
    } : null,
    // Present on /playlist/{id}/tracks and /user/me/tracks rows (Unix
    // seconds); 0 elsewhere (e.g. search results), which sorts last.
    addedAt: raw.time_add !== undefined ? Number(raw.time_add) || 0 : 0,
    raw: raw
  }
}

function normalizeAlbum(raw) {
  if (!raw) return null
  var artist = raw.artist ? normalizeArtistRef(raw.artist) : null
  return {
    type: "album",
    id: String(raw.id || ""),
    name: String(raw.title || "Untitled album"),
    subtitle: artist ? artist.name : "",
    imageUrl: pickImage(raw),
    link: String(raw.link || ""),
    durationMs: 0,
    artists: artist ? [artist] : [],
    raw: raw
  }
}

function normalizeArtist(raw) {
  if (!raw) return null
  return {
    type: "artist",
    id: String(raw.id || ""),
    name: String(raw.name || "Unknown artist"),
    subtitle: raw.nb_fan !== undefined ? Number(raw.nb_fan).toLocaleString() + " fans" : "",
    imageUrl: pickImage(raw),
    link: String(raw.link || ""),
    durationMs: 0,
    artists: [],
    raw: raw
  }
}

function normalizePlaylist(raw) {
  if (!raw) return null
  return {
    type: "playlist",
    id: String(raw.id || ""),
    name: String(raw.title || "Untitled playlist"),
    subtitle: raw.creator ? String(raw.creator.name || "") : "",
    imageUrl: pickImage(raw),
    link: String(raw.link || ""),
    durationMs: 0,
    trackCount: Number(raw.nb_tracks) || 0,
    artists: [],
    raw: raw
  }
}

function normalizeItem(raw) {
  if (!raw) return null
  var kind = String(raw.type || "")
  if (kind === "track") return normalizeTrack(raw)
  if (kind === "album") return normalizeAlbum(raw)
  if (kind === "artist") return normalizeArtist(raw)
  if (kind === "playlist") return normalizePlaylist(raw)
  // Fallback for library rows that omit "type" (e.g. /user/me/tracks items
  // are already track objects without an explicit "type" field).
  if (raw.duration !== undefined) return normalizeTrack(raw)
  if (raw.nb_tracks !== undefined) return normalizePlaylist(raw)
  if (raw.nb_fan !== undefined) return normalizeArtist(raw)
  if (raw.nb_album !== undefined) return normalizeArtist(raw)
  return normalizeAlbum(raw)
}

function normalizePage(payload) {
  var rows = payload && Array.isArray(payload.data) ? payload.data : []
  var items = []
  for (var i = 0; i < rows.length; i++) {
    var item = normalizeItem(rows[i])
    if (item) items.push(item)
  }
  return { items: items, next: payload && payload.next ? String(payload.next) : "" }
}

function mergeUnique(existing, added) {
  var seen = ({})
  var result = []
  var rows = (existing || []).concat(added || [])
  for (var i = 0; i < rows.length; i++) {
    var key = rows[i].type + ":" + rows[i].id
    if (seen[key]) continue
    seen[key] = true
    result.push(rows[i])
  }
  return result
}

function millisecondsToClock(ms) {
  var total = Math.max(0, Math.round(Number(ms) || 0) / 1000)
  var minutes = Math.floor(total / 60)
  var seconds = Math.floor(total % 60)
  return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
}

function normalizedScrollSpeed(value) {
  var speed = Number(value)
  if (!isFinite(speed) || speed <= 0) return 1
  return Math.max(0.25, Math.min(3, speed))
}

function filteredByText(items, filterText) {
  var term = String(filterText || "").trim().toLowerCase()
  if (!term) return items || []
  var result = []
  var rows = items || []
  for (var i = 0; i < rows.length; i++) {
    var item = rows[i]
    var haystack = (item.name + " " + item.subtitle).toLowerCase()
    if (haystack.indexOf(term) >= 0) result.push(item)
  }
  return result
}
