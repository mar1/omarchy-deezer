import QtQuick
import qs.Commons
import qs.Ui

import "DeezerApi.js" as Api

// One row in a MediaCollection: artwork, title + byline, and a couple of
// action buttons (favorite, open in Deezer).
BorderSurface {
  id: root

  required property var itemData
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool selected: false
  // "This is the track currently loaded in the player" / "and it's actively
  // playing (vs. paused on it)" -- kept separate so a paused track still
  // reads as highlighted, just without the play glyph animating.
  property bool nowPlaying: false
  property bool isPlaying: false
  property bool showFavorite: false
  property bool favorited: false
  property bool hovered: hoverHandler.hovered

  signal activated(var item)
  signal artistRequested(var item)
  signal albumRequested(var item)
  signal favoriteToggled(var item)

  function triggerPrimary() { root.activated(root.itemData) }

  width: parent ? parent.width : implicitWidth
  implicitWidth: Style.space(420)
  implicitHeight: Style.space(60)
  height: implicitHeight
  radius: Style.cornerRadius
  color: (selected || nowPlaying) ? Style.selectedFillFor(foreground, accent)
    : (hovered ? Style.hoverFillFor(foreground, accent) : "transparent")
  borderSpec: (selected || nowPlaying) ? Border.controlSpec("selected", foreground, accent) : Border.none()
  clip: true

  HoverHandler { id: hoverHandler }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.triggerPrimary()
  }

  Row {
    id: contentRow
    anchors.fill: parent
    anchors.margins: Style.space(6)
    spacing: Style.space(9)

    BorderSurface {
      id: artworkSurface
      width: parent.height
      height: width
      radius: Style.spacing.labelGap
      color: Style.normalFillFor(root.foreground, root.accent)
      borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

      Image {
        id: rowArtwork
        anchors.fill: parent
        anchors.margins: Style.space(2)
        source: root.itemData && root.itemData.imageUrl ? root.itemData.imageUrl : ""
        sourceSize.width: 96
        sourceSize.height: 96
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        visible: status === Image.Ready
      }

      Text {
        anchors.centerIn: parent
        visible: rowArtwork.status !== Image.Ready
        text: !root.itemData ? ""
          : (root.itemData.type === "playlist" ? ""
          : (root.itemData.type === "artist" ? ""
          : (root.itemData.type === "album" ? "" : "")))
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
    }

    Column {
      width: Math.max(20, parent.width - artworkSurface.width - actionRow.width
        - parent.spacing * 2)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: root.itemData ? String(root.itemData.name || "Untitled") : "Untitled"
        color: root.nowPlaying ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: root.selected || root.nowPlaying
        elide: Text.ElideRight
      }

      MediaByline {
        width: parent.width
        itemData: root.itemData
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontPixelSize: Style.font.bodySmall
        onArtistRequested: function(item) { root.artistRequested(item) }
        onAlbumRequested: function(item) { root.albumRequested(item) }
      }
    }

    Row {
      id: actionRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        visible: root.nowPlaying
        anchors.verticalCenter: parent.verticalCenter
        text: root.isPlaying ? "󰐊" : "󰏤"
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: !root.nowPlaying && root.itemData && root.itemData.durationMs > 0
        anchors.verticalCenter: parent.verticalCenter
        text: Api.millisecondsToClock(root.itemData ? root.itemData.durationMs : 0)
        color: Qt.darker(root.foreground, 1.45)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Button {
        visible: root.showFavorite
        iconText: root.favorited ? "" : ""
        foreground: root.foreground
        selected: root.favorited
        tooltipText: root.favorited ? "Remove from favorites" : "Add to favorites"
        horizontalPadding: Style.space(7)
        onClicked: root.favoriteToggled(root.itemData)
      }

      Button {
        iconText: ""
        foreground: root.foreground
        tooltipText: "Open in Deezer"
        horizontalPadding: Style.space(7)
        onClicked: root.triggerPrimary()
      }
    }
  }
}
