import QtQuick
import qs.Ui

// Wraps the shell's PanelSlider so a drag preview sticks until MPRIS
// confirms the change, instead of snapping back while the command is still
// in flight.
PanelSlider {
  id: root

  property real sourceValue: 0
  property int minimumFeedbackMs: 250
  property int feedbackTimeoutMs: 4000
  // What counts as "MPRIS caught up with the seek". Position only refreshes
  // once a second (see Service.qml's refreshPosition, polled from a 1s
  // Timer), so a volume-scale 0.01 tolerance on a 0..lengthSeconds range
  // was effectively never met -- the preview sat frozen on wherever the
  // drag was released for the full feedbackTimeoutMs after every seek,
  // however far playback had actually already moved on. Callers on a much
  // larger range (seconds, not 0..1) should pass a matching tolerance.
  property real acknowledgeTolerance: 0.01

  property real pendingValue: -1
  property double pendingStartedAt: 0
  readonly property bool awaitingFeedback: pendingValue >= minimum

  value: awaitingFeedback ? pendingValue : sourceValue

  signal committed(real value)

  function clearPreview() {
    feedbackTimer.stop()
    pendingValue = -1
    pendingStartedAt = 0
  }

  onMoved: function(value) {
    pendingValue = Math.max(minimum, Math.min(maximum, Number(value) || 0))
  }
  onReleased: function(value) {
    pendingValue = Math.max(minimum, Math.min(maximum, Number(value) || 0))
    pendingStartedAt = Date.now()
    feedbackTimer.restart()
    committed(pendingValue)
  }

  Timer {
    id: feedbackTimer
    interval: 50
    repeat: true
    onTriggered: {
      if (!root.awaitingFeedback) { stop(); return }
      if (root.dragging) return
      var elapsed = Date.now() - root.pendingStartedAt
      var close = Math.abs(root.sourceValue - root.pendingValue) <= root.acknowledgeTolerance
      if ((close && elapsed >= root.minimumFeedbackMs) || elapsed >= root.feedbackTimeoutMs)
        root.clearPreview()
    }
  }
}
