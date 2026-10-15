import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Dusk in the bar: a sun by day, a setting sun while it fades, a moon at night, by the schedule. A dot means something
// other than the schedule is in charge of the colour (off until morning, warm for an hour, your own key, a paused
// app). Left click opens the panel; right click turns it off until morning, or hands it back to the schedule.
BarWidget {
  id: root
  moduleName: "reidenxerx.dusk"

  readonly property string pluginId: "reidenxerx.dusk"
  property var dusk: null

  function findService() {
    if (root.dusk) return
    var shell = root.bar ? root.bar.shell : null
    root.dusk = shell && typeof shell.serviceFor === "function" ? shell.serviceFor(root.pluginId) : null
  }

  Timer {
    interval: 1000
    repeat: true
    running: !root.dusk
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  onBarChanged: root.findService()

  readonly property var wanted: root.dusk ? root.dusk.wanted : null
  // The time of day as the schedule has it, so a night turned off still shows the moon (with the dot).
  readonly property real warmth: root.wanted ? root.wanted.scheduleWarmth : 0
  readonly property bool steered: root.wanted !== null && root.wanted.reason !== "schedule"

  // md-weather-sunny U+F0599, md-weather-sunset U+F059A, md-weather-night U+F0594 (checked in the font's cmap).
  readonly property string glyph: String.fromCodePoint(root.warmth >= 1 ? 0xF0594 : root.warmth > 0 ? 0xF059A : 0xF0599)

  readonly property string tooltip: {
    if (!root.dusk) return "Dusk"
    var w = root.wanted
    var line = "Dusk: " + root.dusk.description
    if (w && !w.identity) line += " · " + w.temperature + " K"
    if (w && w.gamma < 100) line += " · dimmed to " + w.gamma + "%"
    if (root.dusk.hyprsunsetMissing) line += "\nStarting hyprsunset…"
    return line + "\nRight click: " + (root.steered ? "back to the schedule" : "off until morning")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: root.tooltip
    onPressed: function (which) {
      if (!root.dusk) return
      if (which === Qt.RightButton) {
        if (root.steered) root.dusk.resume()
        else root.dusk.offUntilMorning()
        return
      }
      var p = button.mapToItem(null, button.width / 2, 0)
      root.dusk.togglePanel(p.x)
    }
  }

  Rectangle {
    visible: root.steered
    width: Math.max(4, Style.space(5))
    height: width
    radius: width / 2
    color: Commons.Color.accent
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: Style.space(4)
    anchors.topMargin: Style.space(4)
  }
}
