import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

import "DeezerApi.js" as Api

// Full player: sign-in screen when logged out, otherwise a player header plus
// Playlists / Favorites / Search tabs backed by the Deezer catalog API.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false
  property bool closingFromHost: false
  property string currentTab: "player"
  property string pendingArtistLink: ""

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "io.github.mar1.omarchy-deezer"
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property bool loggedIn: service && service.loggedIn
  readonly property bool loginBusy: service && service.loginBusy
  // PlaybackSlider (built on the shell's PanelSlider) expects a "bar"-shaped
  // object for its styling; the panel itself isn't a bar widget, so hand it
  // a minimal stand-in exposing the same colors.
  readonly property var panelBar: QtObject {
    readonly property color foreground: root.foreground
    readonly property color background: root.background
    readonly property string fontFamily: Style.font.family
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) || ({}) } catch (e) {}
    if (shell && shell.bar && typeof shell.bar.hideBarWidget === "function")
      shell.bar.hideBarWidget(pluginId)
    if (payload.tab) currentTab = String(payload.tab)
    else if (!loggedIn) currentTab = "player"
    closingFromHost = false
    opened = true
    if (service) {
      service.setUiVisible("full-panel", true)
      // Opened from the mini-player's artist/album links (BarWidget.qml) --
      // navigate straight there instead of landing on whatever tab was last
      // active.
      if (payload.artistRef) openArtist(payload.artistRef)
      else if (payload.albumRef) openAlbum(payload.albumRef)
    }
    Qt.callLater(function() { focusScope.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    opened = false
    if (service) service.setUiVisible("full-panel", false)
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function chooseTab(tab) {
    currentTab = String(tab || "player")
    if (service) service.openView(currentTab, false)
  }

  function openArtist(ref) {
    if (!ref || !ref.id || !service) return
    service.openArtist(ref)
    currentTab = "artist-detail"
  }

  function openAlbum(item) {
    if (!item || !service) return
    service.openAlbum(item)
    currentTab = "album-detail"
  }

  function closeArtistDetail() {
    if (service) service.closeArtistDetail()
    currentTab = service ? service.activeView : "search"
  }

  function closeAlbumDetail() {
    if (service) service.closeAlbumDetail()
    currentTab = service ? service.activeView : "search"
  }

  FloatingWindow {
    id: window
    visible: root.opened
    title: "Deezer"
    color: root.background
    implicitWidth: 760
    implicitHeight: 620
    minimumSize: Qt.size(560, 480)

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: function(event) {
        root.requestClose()
        event.accepted = true
      }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.space(12)

        // --- Header ---------------------------------------------------
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "Deezer"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Item { width: parent.width - headerRight.width - Style.space(120); height: 1 }

          Row {
            id: headerRight
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Button {
              visible: root.loggedIn
              text: "Sign out"
              iconText: "󰍃"
              foreground: root.foreground
              onClicked: if (root.service) root.service.auth.logout()
            }
          }
        }

        // --- Signed-out screen ------------------------------------------
        Column {
          width: parent.width
          height: parent.height - Style.space(48)
          visible: !root.loggedIn
          spacing: Style.space(18)
          anchors.verticalCenterOffset: -20

          Item { width: 1; height: parent.height * 0.18 }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Connect your Deezer account"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            width: Math.min(parent.width, Style.space(420))
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Browse your playlists, favorites, and the Deezer catalog "
              + "from the bar. Playback itself is handled by the deezer-linux "
              + "app running in the background -- make sure it's open."
            color: Qt.darker(root.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.loginBusy ? "Waiting for browser sign-in…" : "Connect with Deezer"
            iconText: "󰐊"
            foreground: root.foreground
            enabled: !root.loginBusy
            onClicked: if (root.service) root.service.auth.beginLogin()
          }

          Text {
            width: Math.min(parent.width, Style.space(420))
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: root.service && root.service.auth.lastError !== ""
            text: root.service ? root.service.auth.lastError : ""
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // --- Signed-in shell ---------------------------------------------
        Column {
          width: parent.width
          height: parent.height - Style.space(48)
          visible: root.loggedIn
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: [
                { key: "player", label: "Player" },
                { key: "playlists", label: "Playlists" },
                { key: "favorites", label: "Favorites" },
                { key: "search", label: "Search" }
              ]
              delegate: Button {
                required property var modelData
                text: modelData.label
                foreground: root.foreground
                selected: root.currentTab === modelData.key
                  || (root.currentTab === "detail" && modelData.key === "playlists")
                onClicked: root.chooseTab(modelData.key)
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Player tab. The content itself is a Column (playerColumn) sized
          // to its own contents and centered as a whole via anchors.centerIn
          // on this plain, non-positioner Item -- a Column's own children
          // always stack from the top of whatever height it's given, so the
          // old version just sat near the top with growing empty space
          // below it as the window got taller (confirmed live: fine at a
          // small size, visibly top-heavy once maximized).
          Item {
            width: parent.width
            height: parent.height - Style.space(44)
            visible: root.currentTab === "player"

            Column {
            id: playerColumn
            anchors.centerIn: parent
            width: parent.width
            spacing: Style.space(16)

            // A plain Item wrapper, not the BorderSurface itself, is what
            // anchors.horizontalCenter targets below -- Column is a
            // positioner and sets its children's x directly, which fights
            // an anchor on that same child in ways that only really show up
            // at wider window sizes (confirmed live: fine narrow, visibly
            // off-center once the panel is maximized).
            Item {
              width: parent.width
              height: Style.space(220)

              BorderSurface {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(220)
                height: width
                radius: Style.cornerRadius
                color: Style.normalFillFor(root.foreground, root.accent)
                borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

                Image {
                  id: playerArtwork
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  source: root.service ? root.service.artUrl : ""
                  sourceSize.width: 440
                  sourceSize.height: 440
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  visible: status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  visible: playerArtwork.status !== Image.Ready
                  text: "󰝚"
                  color: root.foreground
                  font.pixelSize: Style.font.displayLarge * 2
                }
              }
            }

            Item {
              width: parent.width
              height: trackInfoColumn.implicitHeight

              Column {
              id: trackInfoColumn
              width: Math.min(parent.width, Style.space(420))
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.service && root.service.title ? root.service.title : "Nothing playing"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: text !== ""
                text: root.service ? root.service.artist : ""
                color: Qt.darker(root.foreground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight

                MouseArea {
                  anchors.fill: parent
                  enabled: root.service && !!root.service.currentTrackArtist
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.openArtist(root.service.currentTrackArtist)
                }
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: text !== ""
                text: root.service ? root.service.album : ""
                color: Qt.darker(root.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight

                MouseArea {
                  anchors.fill: parent
                  enabled: root.service && !!root.service.currentTrackAlbum
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.openAlbum(root.service.currentTrackAlbum)
                }
              }
              }
            }

            Item {
              width: parent.width
              height: seekColumn.implicitHeight
              visible: root.service && root.service.lengthSeconds > 0

              Column {
              id: seekColumn
              width: Math.min(parent.width, Style.space(420))
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)
              visible: root.service && root.service.lengthSeconds > 0

              PlaybackSlider {
                width: parent.width
                bar: root.panelBar
                minimum: 0
                maximum: Math.max(1, root.service ? root.service.lengthSeconds : 1)
                sourceValue: root.service ? root.service.positionSeconds : 0
                acknowledgeTolerance: 2
                step: 5
                onCommitted: function(value) { if (root.service) root.service.seekSeconds(value) }
              }

              Row {
                width: parent.width
                Text {
                  id: positionLabel
                  text: Api.millisecondsToClock((root.service ? root.service.positionSeconds : 0) * 1000)
                  color: Qt.darker(root.foreground, 1.45)
                  font.pixelSize: Style.font.caption
                }
                Item {
                  width: Math.max(0, parent.width - positionLabel.implicitWidth - durationLabel.implicitWidth)
                  height: 1
                }
                Text {
                  id: durationLabel
                  text: Api.millisecondsToClock((root.service ? root.service.lengthSeconds : 0) * 1000)
                  color: Qt.darker(root.foreground, 1.45)
                  font.pixelSize: Style.font.caption
                }
              }
              }
            }

            Item {
              width: parent.width
              height: controlsRow.implicitHeight

              Row {
              id: controlsRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(10)

              Button {
                iconText: "󰒟"
                foreground: root.foreground
                selected: root.service && root.service.shuffle
                enabled: root.service && root.service.playbackControllable
                onClicked: if (root.service) root.service.setShuffle(!root.service.shuffle)
              }
              Button {
                iconText: "󰒮"
                foreground: root.foreground
                enabled: root.service && root.service.playbackControllable
                onClicked: if (root.service) root.service.previous()
              }
              Button {
                iconText: root.service && root.service.playing ? "󰏤" : "󰐊"
                iconSize: Style.font.iconLarge
                foreground: root.foreground
                enabled: root.service && root.service.playbackControllable
                onClicked: if (root.service) root.service.togglePlayback()
              }
              Button {
                iconText: "󰒭"
                foreground: root.foreground
                enabled: root.service && root.service.playbackControllable
                onClicked: if (root.service) root.service.next()
              }
              Button {
                iconText: root.service && root.service.repeatMode === "track" ? "󰑘" : "󰑖"
                foreground: root.foreground
                selected: root.service && root.service.repeatMode !== "off"
                enabled: root.service && root.service.playbackControllable
                onClicked: if (root.service) root.service.cycleRepeat()
              }
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.service && root.service.hasPlayer
                ? "" : "Waiting for deezer-linux to start playing…"
              color: Qt.darker(root.foreground, 1.4)
              font.pixelSize: Style.font.caption
            }
            }
          }

          // Playlists tab
          MediaCollection {
            width: parent.width
            height: parent.height - Style.space(44)
            visible: root.currentTab === "playlists"
            service: root.service
            sourceItems: root.service ? root.service.playlists : []
            loading: root.service && root.service.playlistsLoading
            hasMore: root.service && root.service.playlistsNext !== ""
            emptyMessage: "No playlists yet."
            onActivated: function(item) {
              if (!root.service) return
              root.service.openPlaylist(item)
              root.currentTab = "detail"
            }
            onLoadMoreRequested: if (root.service) root.service.loadMorePlaylists()
          }

          // Favorites tab
          MediaCollection {
            width: parent.width
            height: parent.height - Style.space(44)
            visible: root.currentTab === "favorites"
            service: root.service
            sourceItems: root.service ? root.service.favoriteTracks : []
            // Always fetched in full up front now (see Service.qml), so
            // there's never a "more" to load.
            loading: root.service && root.service.favoriteTracksLoading
            hasMore: false
            showFavorite: true
            emptyMessage: "No favorite tracks yet."
            onActivated: function(item) { if (root.service) root.service.openFavoriteTrack(item) }
            onArtistRequested: function(item) { root.openArtist(item) }
            onAlbumRequested: function(item) { root.openAlbum(item) }
            onFavoriteToggled: function(item) { if (root.service) root.service.toggleFavorite(item) }
          }

          // Search tab
          Column {
            width: parent.width
            height: parent.height - Style.space(44)
            visible: root.currentTab === "search"
            spacing: Style.space(8)

            TextField {
              width: parent.width
              foreground: root.foreground
              placeholderText: "Search tracks, artists, albums, playlists…"
              text: root.service ? root.service.searchQuery : ""
              onTextEdited: if (root.service) root.service.search(text)
            }

            MediaCollection {
              width: parent.width
              height: parent.height - Style.space(46)
              service: root.service
              showFilter: false
              sourceItems: root.service ? root.service.searchResults : []
              loading: root.service && root.service.searchLoading
              emptyMessage: root.service && root.service.searchQuery
                ? "No results." : "Search the Deezer catalog."
              onActivated: function(item) {
                if (!root.service || !item) return
                if (item.type === "artist") root.openArtist(item)
                else if (item.type === "album") root.openAlbum(item)
                else root.service.openInDeezer(item)
              }
              onArtistRequested: function(item) { root.openArtist(item) }
              onAlbumRequested: function(item) { root.openAlbum(item) }
            }
          }

          // Playlist detail tab
          Column {
            width: parent.width
            height: parent.height - Style.space(44)
            visible: root.currentTab === "detail"
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                iconText: "󰁍"
                text: "Back"
                foreground: root.foreground
                onClicked: {
                  if (root.service) root.service.closeDetail()
                  root.currentTab = "playlists"
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.service && root.service.selectedPlaylist
                  ? String(root.service.selectedPlaylist.name || "") : ""
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
            }

            MediaCollection {
              width: parent.width
              height: parent.height - Style.space(46)
              service: root.service
              showFilter: false
              sourceItems: root.service ? root.service.playlistTracks : []
              loading: root.service && root.service.playlistTracksLoading
              emptyMessage: "This playlist is empty."
              onActivated: function(item) { if (root.service) root.service.openPlaylistTrack(item) }
              onArtistRequested: function(item) { root.openArtist(item) }
              onAlbumRequested: function(item) { root.openAlbum(item) }
            }
          }

          // Artist detail tab
          Column {
            width: parent.width
            height: parent.height - Style.space(44)
            visible: root.currentTab === "artist-detail"
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                iconText: "󰁍"
                text: "Back"
                foreground: root.foreground
                onClicked: root.closeArtistDetail()
              }

              BorderSurface {
                width: Style.space(44)
                height: width
                anchors.verticalCenter: parent.verticalCenter
                radius: width / 2
                color: Style.normalFillFor(root.foreground, root.accent)
                borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

                Image {
                  id: artistDetailArtwork
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  source: root.service && root.service.selectedArtist
                    ? (root.service.selectedArtist.imageUrl || "") : ""
                  sourceSize.width: 88
                  sourceSize.height: 88
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  visible: status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  visible: artistDetailArtwork.status !== Image.Ready
                  text: "󰠃"
                  color: root.foreground
                  font.pixelSize: Style.font.iconLarge
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.service && root.service.selectedArtist
                  ? String(root.service.selectedArtist.name || "") : ""
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
            }

            Text {
              width: parent.width
              visible: root.service && root.service.artistLoading
              text: "Loading…"
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              text: "Top tracks"
              visible: root.service && root.service.artistTopTracks.length > 0
              color: Qt.darker(root.foreground, 1.2)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MediaCollection {
              width: parent.width
              height: Math.round((parent.height - Style.space(90)) * 0.55)
              service: root.service
              showFilter: false
              sourceItems: root.service ? root.service.artistTopTracks : []
              emptyMessage: ""
              onActivated: function(item) { if (root.service) root.service.openArtistTrack(item) }
            }

            Text {
              width: parent.width
              text: "Albums"
              visible: root.service && root.service.artistAlbums.length > 0
              color: Qt.darker(root.foreground, 1.2)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MediaCollection {
              width: parent.width
              height: Math.round((parent.height - Style.space(90)) * 0.45)
              service: root.service
              showFilter: false
              sourceItems: root.service ? root.service.artistAlbums : []
              emptyMessage: root.service && !root.service.artistLoading ? "No albums found." : ""
              onActivated: function(item) { root.openAlbum(item) }
            }
          }

          // Album detail tab
          Column {
            width: parent.width
            height: parent.height - Style.space(44)
            visible: root.currentTab === "album-detail"
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                iconText: "󰁍"
                text: "Back"
                foreground: root.foreground
                onClicked: root.closeAlbumDetail()
              }

              BorderSurface {
                width: Style.space(44)
                height: width
                anchors.verticalCenter: parent.verticalCenter
                radius: Style.spacing.labelGap
                color: Style.normalFillFor(root.foreground, root.accent)
                borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

                Image {
                  id: albumDetailArtwork
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  source: root.service && root.service.selectedAlbum
                    ? (root.service.selectedAlbum.imageUrl || "") : ""
                  sourceSize.width: 88
                  sourceSize.height: 88
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  visible: status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  visible: albumDetailArtwork.status !== Image.Ready
                  text: "󰀥"
                  color: root.foreground
                  font.pixelSize: Style.font.iconLarge
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.service && root.service.selectedAlbum
                  ? String(root.service.selectedAlbum.name || "") : ""
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
            }

            MediaCollection {
              width: parent.width
              height: parent.height - Style.space(46)
              service: root.service
              showFilter: false
              sourceItems: root.service ? root.service.albumTracks : []
              loading: root.service && root.service.albumLoading
              emptyMessage: "This album is empty."
              onActivated: function(item) { if (root.service) root.service.openAlbumTrack(item) }
              onArtistRequested: function(item) { root.openArtist(item) }
              onAlbumRequested: function(item) { root.openAlbum(item) }
            }
          }
        }
      }
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.service && root.service.playing
    onTriggered: root.service.refreshPosition()
  }
}
