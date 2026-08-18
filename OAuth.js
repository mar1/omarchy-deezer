.pragma library

// Deezer's own authorization flow (not standard OAuth2): a browser redirect
// hands back a one-time "code" on a localhost callback, which is then
// exchanged -- app_id + secret + code -- for a long-lived access token.
// There is no refresh token; when the token is eventually revoked or
// expires, the only recovery is to run the flow again.
//
// app_id is Deezer's public client identifier -- safe to hardcode, exactly
// like every third-party Spotify/Deezer client embeds its client_id. The
// "secret" below is not a user secret; it identifies *this plugin's* Deezer
// application to Deezer, the same pattern used by other open-source desktop
// clients (see README.md). If you fork this plugin, create your own app at
// developers.deezer.com and replace both values.
var APP_ID = "387644"
var APP_SECRET = "5f4b4135e3c73c395e1d5c1551a9a2e9"

var AUTH_URL = "https://connect.deezer.com/oauth/auth.php"
var TOKEN_URL = "https://connect.deezer.com/oauth/access_token.php"
var PERMS = "basic_access,manage_library,listening_history,offline_access"

function normalizedPort(port) {
  var value = Math.floor(Number(port) || 0)
  return value > 0 && value < 65536 ? value : 17845
}

function encode(value) {
  return encodeURIComponent(String(value === undefined || value === null ? "" : value))
}

function buildAuthUrl(redirectUri, state) {
  return AUTH_URL
    + "?app_id=" + encode(APP_ID)
    + "&redirect_uri=" + encode(redirectUri)
    + "&perms=" + encode(PERMS)
    + "&state=" + encode(state)
}

function buildTokenUrl(code) {
  return TOKEN_URL
    + "?app_id=" + encode(APP_ID)
    + "&secret=" + encode(APP_SECRET)
    + "&code=" + encode(code)
}

// Parses the first line of a raw HTTP request read off the socat listener,
// e.g. "GET /callback?code=abc123&state=xyz HTTP/1.1".
function parseCallbackRequestLine(line, callbackPath) {
  var match = String(line || "").match(/^GET\s+(\S+)\s+HTTP/)
  if (!match) return { ok: false, error: "Could not read the Deezer sign-in response" }
  var target = match[1]
  var queryIndex = target.indexOf("?")
  var path = queryIndex >= 0 ? target.substring(0, queryIndex) : target
  if (path !== callbackPath)
    return { ok: false, error: "Unexpected callback path from Deezer sign-in" }

  var query = queryIndex >= 0 ? target.substring(queryIndex + 1) : ""
  var params = ({})
  var pairs = query.split("&")
  for (var i = 0; i < pairs.length; i++) {
    if (!pairs[i]) continue
    var kv = pairs[i].split("=")
    params[decodeURIComponent(kv[0] || "")] = decodeURIComponent((kv[1] || "").replace(/\+/g, "%20"))
  }

  if (params.error)
    return { ok: false, error: "Deezer sign-in was cancelled" }
  if (!params.code)
    return { ok: false, error: "Deezer did not return a sign-in code" }

  return { ok: true, code: params.code, state: params.state || "" }
}

// Deezer's token endpoint replies text/plain, e.g. "access_token=X&expires=0".
// On failure it replies with a JSON body such as {"error":"wrong secret"} or
// occasionally a bare "wrong app_id" style string -- handle both defensively.
function parseTokenResponse(status, text) {
  var body = String(text || "").trim()
  if (status < 200 || status >= 300 || !body)
    return { ok: false, error: "Deezer sign-in failed. Please try again" }

  if (body.charAt(0) === "{") {
    try {
      var json = JSON.parse(body)
      var message = json && json.error ? String(json.error) : "Deezer sign-in failed"
      return { ok: false, error: message }
    } catch (e) {
      return { ok: false, error: "Deezer sign-in failed. Please try again" }
    }
  }

  var params = ({})
  var pairs = body.split("&")
  for (var i = 0; i < pairs.length; i++) {
    if (!pairs[i]) continue
    var kv = pairs[i].split("=")
    params[decodeURIComponent(kv[0] || "")] = decodeURIComponent(kv[1] || "")
  }

  if (!params.access_token)
    return { ok: false, error: "Deezer did not return an access token" }

  return {
    ok: true,
    accessToken: params.access_token,
    // Deezer returns expires=0 for the long-lived (offline_access) grant.
    expiresIn: Math.max(0, Number(params.expires) || 0)
  }
}

function successResponse() {
  var body = "<html><body style=\"font-family:sans-serif;text-align:center;"
    + "padding-top:3em\"><h2>Deezer connected</h2>"
    + "<p>You can close this tab and go back to Omarchy.</p></body></html>"
  return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n"
    + "Content-Length: " + body.length + "\r\n\r\n" + body
}

function failureResponse() {
  var body = "<html><body style=\"font-family:sans-serif;text-align:center;"
    + "padding-top:3em\"><h2>Deezer sign-in failed</h2>"
    + "<p>Close this tab and try again from Omarchy.</p></body></html>"
  return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n"
    + "Content-Length: " + body.length + "\r\n\r\n" + body
}
