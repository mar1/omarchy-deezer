import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "DeezerApi.js" as Api

BarWidget {
  id: root

  moduleName: "io.github.mar1dev.omarchy-deezer"

  readonly property var deezer: bar && bar.shell
    ? bar.shell.serviceFor(moduleName) : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string surfaceKey: "deezer-popup-" + String(root)
  readonly property string barText: {
    if (!deezer || !deezer.hasMedia) return ""
    if (deezer.showTrackTitle && deezer.showArtistName)
      return deezer.title + (deezer.artist ? " — " + deezer.artist : "")
    if (deezer.showArtistName) return deezer.artist
    return deezer.title
  }
  readonly property bool miniPlayerEnabled: deezer && deezer.showMiniPlayer
  readonly property bool iconOnly: !deezer || vertical || !deezer.hasMedia || barText === ""
  property bool popupOpen: false
  readonly property bool opened: popupOpen

  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() {
    if (miniPlayerEnabled) popupOpen ? close() : open()
    else openFullPanel()
  }

  function openFullPanel(payload) {
    close()
    if (!bar || !bar.shell) return
    var encoded = JSON.stringify(payload || {})
    if (typeof bar.shell.hide === "function" && typeof bar.shell.summon === "function") {
      // toggle() would close an already-open panel instead of navigating it
      // to the requested artist/album -- force a hide+summon instead so a
      // click here always lands where it says it will.
      bar.shell.hide(moduleName)
      Qt.callLater(function() {
        if (root.bar && root.bar.shell) root.bar.shell.summon(root.moduleName, encoded)
      })
    } else {
      bar.shell.toggle(moduleName, encoded)
    }
  }

  IpcHandler {
    target: root.moduleName + ".player"
    function togglePlayer(): string {
      root.toggle()
      return "ok"
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onDeezerChanged: if (deezer) deezer.applySettings(settings)
  onSettingsChanged: if (deezer) deezer.applySettings(settings)
  onMiniPlayerEnabledChanged: if (!miniPlayerEnabled) close()
  onPopupOpenChanged: if (deezer) deezer.setUiVisible(surfaceKey, popupOpen)
  Component.onDestruction: if (deezer) deezer.setUiVisible(surfaceKey, false)

  TextMetrics {
    id: labelMetrics
    text: root.barText
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // WidgetButton renders `text` itself only while iconOnly (labelVisible)
    // is true -- that's the *only* thing drawn when nothing is playing, so
    // it has to be the glyph, not empty. Once there's a track, our own Row
    // below takes over instead, so the icon and the scrolling title/artist
    // can sit side by side.
    text: ""
    labelVisible: root.iconOnly
    hasVisualContent: true
    fontSize: root.iconOnly ? Style.font.bodySmall : Style.font.body
    active: root.deezer && root.deezer.playing
    activeColor: button.foreground
    tooltipText: root.deezer && root.deezer.hasMedia
      ? root.deezer.title + (root.deezer.artist ? " — " + root.deezer.artist : "")
      : "Deezer"
    // The +48 here has to match the Text's own "button.width - Style.space(48)"
    // below exactly -- it's the icon glyph + Row spacing + button padding
    // budget. A mismatch here previously reserved only 28px for that up top
    // while the Text subtracted 48px back out, so the label was elided 20px
    // short of what the button was actually wide enough to show.
    fixedWidth: root.vertical ? root.barSize
      : (root.iconOnly ? Style.bar.statusSlot
        : Math.min(Style.space(340), Math.max(root.barSize,
          labelMetrics.advanceWidth + Style.space(48))))
    clip: true

    Row {
      anchors.centerIn: parent
      spacing: Style.space(6)
      visible: !root.iconOnly
      enabled: false

      Text {
        text: ""
        color: button.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
      }

      Text {
        text: root.barText
        color: button.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: Math.max(0, button.width - Style.space(48))
      }
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.deezer) root.deezer.togglePlayback()
      } else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.deezer) return
      if (delta > 0) root.deezer.previous()
      else if (delta < 0) root.deezer.next()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: miniKeyCatcher
    contentWidth: fittedContentWidth(Style.space(320))
    contentHeight: fittedContentHeight(contentColumn.implicitHeight)

    Item {
      id: miniKeyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
        else if (event.key === Qt.Key_Space) {
          if (root.deezer && !event.isAutoRepeat) root.deezer.togglePlayback()
          event.accepted = true
        }
      }

      Column {
        id: contentColumn
        anchors.fill: parent
        spacing: Style.space(10)

        Row {
          width: parent.width
          spacing: Style.space(12)

          BorderSurface {
            width: Style.space(72)
            height: width
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, Color.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

            Image {
              id: popupArtwork
              anchors.fill: parent
              anchors.margins: Style.space(3)
              source: root.popupOpen && root.deezer ? root.deezer.artUrl : ""
              sourceSize.width: 144
              sourceSize.height: 144
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              visible: status === Image.Ready
            }

            Text {
              anchors.centerIn: parent
              visible: popupArtwork.status !== Image.Ready
              text: ""
              color: root.foreground
              font.pixelSize: Style.font.displayLarge
            }

            MouseArea {
              anchors.fill: parent
              enabled: root.deezer && !!root.deezer.currentTrackAlbum
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.openFullPanel({ tab: "album-detail", albumRef: root.deezer.currentTrackAlbum })
            }
          }

          Column {
            width: parent.width - Style.space(84)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              width: parent.width
              text: root.deezer && root.deezer.title ? root.deezer.title : "Nothing playing"
              color: root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.deezer ? root.deezer.artist : ""
              visible: text !== ""
              color: Qt.darker(root.foreground, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight

              MouseArea {
                anchors.fill: parent
                enabled: root.deezer && !!root.deezer.currentTrackArtist
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.openFullPanel({ tab: "artist-detail", artistRef: root.deezer.currentTrackArtist })
              }
            }

            Text {
              width: parent.width
              text: root.deezer ? root.deezer.album : ""
              visible: text !== ""
              color: Qt.darker(root.foreground, 1.55)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight

              MouseArea {
                anchors.fill: parent
                enabled: root.deezer && !!root.deezer.currentTrackAlbum
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.openFullPanel({ tab: "album-detail", albumRef: root.deezer.currentTrackAlbum })
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(3)
          visible: root.deezer && root.deezer.lengthSeconds > 0

          PlaybackSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: Math.max(1, root.deezer ? root.deezer.lengthSeconds : 1)
            sourceValue: root.deezer ? root.deezer.positionSeconds : 0
            acknowledgeTolerance: 2
            step: 5
            onCommitted: function(value) { if (root.deezer) root.deezer.seekSeconds(value) }
          }

          Row {
            width: parent.width
            Text {
              id: miniPositionLabel
              text: Api.millisecondsToClock((root.deezer ? root.deezer.positionSeconds : 0) * 1000)
              color: Qt.darker(root.foreground, 1.45)
              font.pixelSize: Style.font.caption
            }
            Item {
              width: Math.max(0, parent.width - miniPositionLabel.implicitWidth - miniDurationLabel.implicitWidth)
              height: 1
            }
            Text {
              id: miniDurationLabel
              text: Api.millisecondsToClock((root.deezer ? root.deezer.lengthSeconds : 0) * 1000)
              color: Qt.darker(root.foreground, 1.45)
              font.pixelSize: Style.font.caption
            }
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(8)

          Button {
            iconText: "󰒮"
            foreground: root.foreground
            tooltipText: "Previous"
            enabled: root.deezer && root.deezer.playbackControllable
            onClicked: if (root.deezer) root.deezer.previous()
          }
          Button {
            iconText: root.deezer && root.deezer.playing ? "󰏤" : "󰐊"
            iconSize: Style.font.iconLarge
            foreground: root.foreground
            tooltipText: root.deezer && root.deezer.playing ? "Pause" : "Play"
            enabled: root.deezer && root.deezer.playbackControllable
            onClicked: if (root.deezer) root.deezer.togglePlayback()
          }
          Button {
            iconText: "󰒭"
            foreground: root.foreground
            tooltipText: "Next"
            enabled: root.deezer && root.deezer.playbackControllable
            onClicked: if (root.deezer) root.deezer.next()
          }
        }

        PanelSeparator { foreground: root.foreground }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width - openButton.width - Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: !root.deezer || !root.deezer.hasPlayer
              ? "Waiting for deezer-linux to start playback…"
              : (root.deezer.playing ? "Playing on this computer" : "Paused")
            color: Qt.darker(root.foreground, 1.35)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            wrapMode: Text.WordWrap
          }

          Button {
            id: openButton
            text: "Open"
            iconText: ""
            foreground: root.foreground
            tooltipText: "Open full player"
            onClicked: root.openFullPanel()
          }
        }
      }
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.popupOpen && root.deezer && root.deezer.playing
    onTriggered: root.deezer.refreshPosition()
  }
}
