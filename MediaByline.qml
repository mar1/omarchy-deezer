import QtQuick

// A small "artist · album" byline used under a track/playlist title.
// Clicking the artist or album name emits artistRequested/albumRequested
// with the underlying {id, name} ref.
Row {
  id: root

  property var itemData: null
  property color foreground: "white"
  property color accent: foreground
  property string fontFamily: ""
  property real fontPixelSize: 12

  signal artistRequested(var item)
  signal albumRequested(var item)

  readonly property var artists: itemData && itemData.artists ? itemData.artists : []
  readonly property var album: itemData ? itemData.album : null
  readonly property string albumName: album ? album.name : ""

  spacing: 4

  Text {
    id: artistText
    text: root.artists.length ? root.artists[0].name
      : (root.itemData ? String(root.itemData.subtitle || "") : "")
    visible: text !== ""
    color: root.artists.length ? root.accent : Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: root.fontPixelSize
    elide: Text.ElideRight

    MouseArea {
      anchors.fill: parent
      enabled: root.artists.length > 0
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.artistRequested(root.artists[0])
    }
  }

  Text {
    id: albumText
    text: root.albumName ? "· " + root.albumName : ""
    visible: text !== ""
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: root.fontPixelSize
    elide: Text.ElideRight

    MouseArea {
      anchors.fill: parent
      enabled: !!(root.album && root.album.id)
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.albumRequested(root.album)
    }
  }
}
