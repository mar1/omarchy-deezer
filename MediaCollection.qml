import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

import "DeezerApi.js" as Api

// A filterable, scrollable list of MediaRow entries with an optional
// "load more" footer for paginated Deezer endpoints.
Item {
  id: root

  required property var service
  property var sourceItems: []
  property string filterText: ""
  property bool showFilter: true
  property bool showFavorite: false
  property bool loading: false
  property bool hasMore: false
  property string emptyMessage: "Nothing here yet."

  readonly property var visibleItems: Api.filteredByText(sourceItems, filterText)

  signal activated(var item)
  signal artistRequested(var item)
  signal albumRequested(var item)
  signal favoriteToggled(var item)
  signal loadMoreRequested()

  Column {
    anchors.fill: parent
    spacing: Style.space(7)

    Row {
      id: tools
      width: parent.width
      height: visible ? Style.space(38) : 0
      visible: root.showFilter
      spacing: Style.space(7)

      TextField {
        id: filterField
        width: parent.width - countLabel.width - parent.spacing
        foreground: Color.foreground
        placeholderText: "Filter this list"
        text: root.filterText
        onTextEdited: root.filterText = text
      }

      Text {
        id: countLabel
        anchors.verticalCenter: parent.verticalCenter
        text: root.visibleItems.length
          + (root.filterText ? (root.visibleItems.length === 1 ? " match" : " matches")
            : (root.visibleItems.length === 1 ? " item" : " items"))
        color: Qt.darker(Color.foreground, 1.42)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    ListView {
      id: mediaList
      width: parent.width
      height: Math.max(30, parent.height - tools.height - moreButton.height
        - emptyLabel.height - parent.spacing * 3)
      model: root.visibleItems
      clip: true
      spacing: Style.space(3)
      reuseItems: true
      cacheBuffer: Style.space(160)
      ScrollBar.vertical: ScrollBar { }

      delegate: MediaRow {
        required property var modelData
        itemData: modelData
        width: mediaList.width
        foreground: Color.foreground
        accent: Color.accent
        fontFamily: Style.font.family
        showFavorite: root.showFavorite
        favorited: root.service ? root.service.isFavorite(modelData) : false
        nowPlaying: root.service && modelData && modelData.type === "track"
          && modelData.id !== "" && modelData.id === root.service.currentTrackId
        isPlaying: root.service ? root.service.playing : false
        onActivated: function(item) { root.activated(item) }
        onArtistRequested: function(item) { root.artistRequested(item) }
        onAlbumRequested: function(item) { root.albumRequested(item) }
        onFavoriteToggled: function(item) { root.favoriteToggled(item) }
      }
    }

    Text {
      id: emptyLabel
      width: parent.width
      height: visible ? contentHeight : 0
      visible: !root.loading && root.visibleItems.length === 0
      text: root.emptyMessage
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Button {
      id: moreButton
      anchors.horizontalCenter: parent.horizontalCenter
      height: visible ? implicitHeight : 0
      visible: root.loading || root.hasMore
      text: root.loading ? "Loading…" : "Load more"
      foreground: Color.foreground
      enabled: root.hasMore && !root.loading
      onClicked: root.loadMoreRequested()
    }
  }
}
