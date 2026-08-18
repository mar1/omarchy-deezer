import QtQuick
import Quickshell
import Quickshell.Io

import "OAuth.js" as OAuth

// Owns the whole Deezer sign-in lifecycle: opening the browser, listening for
// the localhost callback with socat, exchanging the code for an access
// token, and persisting that token in the GNOME Keyring so it survives
// restarts. Deezer has no refresh token -- once accessToken is gone, the
// only way back is beginLogin() again.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string pluginDir
  property int oauthPort: 17845
  property string callbackPath: "/callback"
  readonly property string redirectUri: "http://127.0.0.1:"
    + OAuth.normalizedPort(oauthPort) + callbackPath

  property string accessToken: ""
  property double accessTokenExpiresAt: 0
  property bool loggedIn: false
  property bool sessionChecked: false
  property bool loginBusy: false
  property bool exchangingCode: false
  readonly property bool sessionBusy: secretLookup.running
  property string lastError: ""

  property var tokenWaiters: []
  property string lookupPurpose: ""
  property bool lookupHandled: false
  property string keyringWriteToken: ""
  property string oauthState: ""
  property bool callbackHandled: false
  property var tokenRequest: null
  property int tokenRequestSerial: 0

  signal loginSucceeded()
  signal loggedOut()
  signal sessionUnavailable(string reason)

  function tokenIsFresh() {
    return accessToken !== ""
      && (accessTokenExpiresAt === 0 || Date.now() + 60000 < accessTokenExpiresAt)
  }

  function resetMemorySession() {
    accessToken = ""
    accessTokenExpiresAt = 0
    loggedIn = false
  }

  function invalidateAccessToken() {
    resetMemorySession()
    clearStoredToken()
  }

  function finishWaiters(token, error) {
    var pending = tokenWaiters.slice()
    tokenWaiters = []
    for (var i = 0; i < pending.length; i++) {
      try { pending[i](token || "", error || "") }
      catch (e) { /* callers own their callback errors */ }
    }
  }

  function withAccessToken(callback) {
    if (typeof callback !== "function") return
    if (tokenIsFresh()) {
      callback(accessToken, "")
      return
    }
    var next = tokenWaiters.slice()
    next.push(callback)
    tokenWaiters = next
    if (secretLookup.running) return
    lookupPurpose = "request"
    startSecretLookup()
  }

  function restoreSession() {
    sessionChecked = false
    if (secretLookup.running) return
    lookupPurpose = "restore"
    startSecretLookup()
  }

  function startSecretLookup() {
    lookupHandled = false
    secretLookup.command = [
      "secret-tool", "lookup",
      "service", "quickshell-deezer",
      "kind", "access-token",
      "app-id", "deezer"
    ]
    secretLookup.running = true
  }

  function handleSecretLookup(raw) {
    if (lookupHandled) return
    lookupHandled = true
    var token = String(raw || "").trim()
    var purpose = lookupPurpose
    lookupPurpose = ""
    sessionChecked = true
    if (!token) {
      resetMemorySession()
      if (purpose === "request") finishWaiters("", "Log in to Deezer first")
      return
    }
    accessToken = token
    accessTokenExpiresAt = 0
    loggedIn = true
    if (purpose === "request") finishWaiters(accessToken, "")
  }

  function storeAccessToken(token) {
    if (!token || keyringStore.running) return
    keyringWriteToken = String(token)
    keyringStore.command = [pluginDir + "/scripts/keyring-store.sh", "deezer"]
    keyringStore.running = true
  }

  function clearStoredToken() {
    if (keyringClear.running) return
    keyringClear.command = [
      "secret-tool", "clear",
      "service", "quickshell-deezer",
      "kind", "access-token",
      "app-id", "deezer"
    ]
    keyringClear.running = true
  }

  function logout() {
    cancelLogin()
    resetMemorySession()
    sessionChecked = true
    lastError = ""
    finishWaiters("", "Logged out")
    clearStoredToken()
    loggedOut()
  }

  function beginLogin() {
    if (loginBusy) return
    lastError = ""
    loginBusy = true
    callbackHandled = false
    exchangingCode = false
    oauthState = String(Date.now()) + "-" + String(Math.floor(Math.random() * 1e9))
    callbackListener.command = [
      "socat", "-T", "180",
      "TCP4-LISTEN:" + OAuth.normalizedPort(oauthPort) + ",bind=127.0.0.1,reuseaddr",
      "STDIO"
    ]
    callbackListener.running = true
    authTimeout.restart()
  }

  function openAuthorizationPage() {
    if (!loginBusy || callbackHandled) return
    var url = OAuth.buildAuthUrl(redirectUri, oauthState)
    Quickshell.execDetached(["xdg-open", url])
  }

  function handleCallbackLine(rawLine) {
    if (!loginBusy || callbackHandled) return
    var line = String(rawLine || "").replace(/\r$/, "")
    if (line.indexOf("GET ") !== 0) return
    callbackHandled = true
    authTimeout.stop()
    var callback = OAuth.parseCallbackRequestLine(line, callbackPath)
    if (!callback.ok || callback.state !== oauthState) {
      callbackListener.write(OAuth.failureResponse())
      callbackStopTimer.restart()
      failLogin(callback.ok
        ? "Deezer sign-in could not be verified. Please try again"
        : callback.error, true)
      return
    }
    callbackListener.write(OAuth.successResponse())
    callbackStopTimer.restart()
    exchangeCode(callback.code)
  }

  function exchangeCode(code) {
    exchangingCode = true
    var serial = ++tokenRequestSerial
    var xhr = new XMLHttpRequest()
    tokenRequest = xhr
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (serial !== root.tokenRequestSerial) return
      if (root.tokenRequest === xhr) root.tokenRequest = null
      root.exchangingCode = false
      root.loginBusy = false
      var result = OAuth.parseTokenResponse(xhr.status, xhr.responseText)
      if (!result.ok) {
        root.lastError = result.error
        root.sessionUnavailable(root.lastError)
        return
      }
      root.acceptToken(result)
      root.sessionChecked = true
      root.finishWaiters(root.accessToken, "")
      root.loginSucceeded()
    }
    xhr.open("GET", OAuth.buildTokenUrl(code))
    xhr.send()
  }

  function acceptToken(result) {
    accessToken = result.accessToken
    accessTokenExpiresAt = result.expiresIn > 0 ? Date.now() + result.expiresIn * 1000 : 0
    loggedIn = true
    lastError = ""
    storeAccessToken(result.accessToken)
  }

  function failLogin(reason, listenerAlreadyAnswered) {
    lastError = String(reason || "Deezer sign-in failed. Please try again")
    loginBusy = false
    exchangingCode = false
    authTimeout.stop()
    if (!listenerAlreadyAnswered && callbackListener.running) callbackListener.running = false
    sessionUnavailable(lastError)
  }

  function cancelLogin() {
    authTimeout.stop()
    callbackStopTimer.stop()
    if (callbackListener.running) callbackListener.running = false
    tokenRequestSerial++
    if (tokenRequest && tokenRequest.abort) tokenRequest.abort()
    tokenRequest = null
    loginBusy = false
    exchangingCode = false
    callbackHandled = false
  }

  Timer {
    id: authOpenDelay
    interval: 120
    onTriggered: root.openAuthorizationPage()
  }

  Timer {
    id: callbackStopTimer
    interval: 250
    onTriggered: if (callbackListener.running) callbackListener.running = false
  }

  Timer {
    id: authTimeout
    interval: 180000
    onTriggered: root.failLogin("Deezer sign-in took too long. Please try again")
  }

  Process {
    id: callbackListener
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleCallbackLine(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: authOpenDelay.restart()
    onExited: function(exitCode) {
      if (root.loginBusy && !root.callbackHandled && !root.exchangingCode)
        root.failLogin(exitCode === 0
          ? "The Deezer sign-in window closed before it finished"
          : "Could not complete Deezer sign-in. Close any other sign-in windows and try again")
    }
  }

  Process {
    id: secretLookup
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleSecretLookup(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (!root.lookupHandled) root.handleSecretLookup("")
    }
  }

  Process {
    id: keyringStore
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.keyringWriteToken + "\n")
      root.keyringWriteToken = ""
    }
    onExited: function(exitCode) {
      root.keyringWriteToken = ""
      if (exitCode !== 0)
        root.lastError = "Deezer connected, but the session could not be saved securely. You may need to sign in again after restarting"
    }
  }

  Process {
    id: keyringClear
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }
}
