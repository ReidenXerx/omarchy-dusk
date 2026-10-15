import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DuskModel.js" as Model

// Dusk's panel: the whole night on a 24-hour dial, then everything you can change about it.
//
// Held by the shell as an overlay rather than inside the bar widget: the shell rebuilds bar widgets whenever a
// setting is saved, and this panel saves settings, so a popup inside the widget would close under your cursor.
// There are no text fields: times and amounts move in steps, so nothing here ever reads the clipboard.
Item {
  id: overlay

  property var shell: null
  property var manifest: null
  property var dusk: null
  property bool opened: false

  readonly property string pluginId: "reidenxerx.dusk"

  function findService() {
    if (!overlay.dusk && overlay.shell && typeof overlay.shell.serviceFor === "function")
      overlay.dusk = overlay.shell.serviceFor(overlay.pluginId)
  }

  Timer {
    interval: 1000
    repeat: true
    running: !overlay.dusk
    triggeredOnStart: true
    onTriggered: overlay.findService()
  }

  function open(payloadJson) {
    overlay.findService()
    overlay.opened = true
    if (overlay.dusk) overlay.dusk.tick()
  }

  function close() {
    if (!overlay.opened) return
    overlay.opened = false
    if (overlay.dusk) overlay.dusk.previewTemperature = 0
  }

  function dismiss() {
    overlay.close()
    if (overlay.shell && typeof overlay.shell.hide === "function") overlay.shell.hide(overlay.pluginId)
  }

  function toggle() {
    if (overlay.opened) overlay.dismiss()
    else overlay.open("{}")
  }

  readonly property var s: overlay.dusk ? overlay.dusk.saved : Model.readSettings({})
  readonly property var w: overlay.dusk ? overlay.dusk.wanted : null
  readonly property color ink: Commons.Color.popups.text
  readonly property color faint: Qt.rgba(overlay.ink.r, overlay.ink.g, overlay.ink.b, 0.6)
  readonly property color hairline: Qt.rgba(overlay.ink.r, overlay.ink.g, overlay.ink.b, 0.14)
  readonly property color accent: Commons.Color.accent
  readonly property color paper: Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g,
                                         Commons.Color.popups.background.b, 1)
  readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Commons.Color.popups.border,
                                                              Commons.Color.popups.border, Math.max(1, Style.space(2)))

  function kelvinColor(k, alpha) {
    var c = Model.kelvinColor(k)
    return Qt.rgba(c.r, c.g, c.b, alpha === undefined ? 1 : alpha)
  }

  function minutesOf(text) { var m = Model.parseClock(text); return m === null ? 0 : m }
  function shiftClock(key, by) { overlay.dusk.set(key, Model.clockText(overlay.minutesOf(overlay.s[key]) + by)) }
  function step(key, by, lo, hi) { overlay.dusk.set(key, Math.max(lo, Math.min(hi, overlay.s[key] + by))) }

  // A value with a minus and a plus: times and amounts move in steps. Self-contained: an inline component does not
  // see this file's ids, so it takes its colours from the theme directly.
  component Stepper: RowLayout {
    id: stepper
    property string label: ""
    property string value: ""
    readonly property color ink: Commons.Color.popups.text
    signal down()
    signal up()
    spacing: Style.space(6)
    Text {
      Layout.fillWidth: true
      text: stepper.label
      color: stepper.ink
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    Button { text: "−"; bordered: true; foreground: stepper.ink; accent: Commons.Color.accent; onClicked: stepper.down() }
    Text {
      Layout.preferredWidth: Style.space(64)
      horizontalAlignment: Text.AlignHCenter
      text: stepper.value
      color: stepper.ink
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Button { text: "+"; bordered: true; foreground: stepper.ink; accent: Commons.Color.accent; onClicked: stepper.up() }
  }

  component Heading: Text {
    color: Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 1
    Layout.topMargin: Style.space(4)
  }

  PanelWindow {
    id: surface
    visible: overlay.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "dusk-panel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: overlay.opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    // A click anywhere off the card puts it away.
    MouseArea {
      anchors.fill: parent
      onClicked: overlay.dismiss()
    }

    Item {
      anchors.fill: parent
      focus: overlay.opened
      Keys.onEscapePressed: overlay.dismiss()
    }

    BorderSurface {
      id: card
      width: Style.space(400)
      height: content.implicitHeight + Style.spacing.popupPadding * 2
      x: {
        var want = overlay.dusk && overlay.dusk.anchorX >= 0 ? overlay.dusk.anchorX - width / 2 : surface.width - width
        return Math.max(Style.gapsOut, Math.min(surface.width - width - Style.gapsOut, want))
      }
      y: Style.bar.sizeHorizontal + Style.gapsOut * 2
      color: overlay.paper
      borderSpec: overlay.borderSpec
      radius: Style.cornerRadius

      // Clicks on the card stay on the card.
      MouseArea { anchors.fill: parent }

      ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: Style.spacing.popupPadding
        spacing: Style.space(10)

        // ------------------------------------------------ the night at a glance
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(14)

          Canvas {
            id: dial
            Layout.preferredWidth: Style.space(150)
            Layout.preferredHeight: Style.space(150)

            readonly property var today: overlay.dusk ? overlay.dusk.today : null
            readonly property int night: overlay.s.temperature
            readonly property color ink: overlay.ink
            onTodayChanged: requestPaint()
            onNightChanged: requestPaint()
            onInkChanged: requestPaint()
            Component.onCompleted: requestPaint()

            function angle(minute) { return minute / 1440 * Math.PI * 2 - Math.PI / 2 }

            onPaint: {
              var c = getContext("2d")
              c.reset()
              var size = Math.min(width, height)
              var cx = width / 2, cy = height / 2
              var ring = size * 0.075
              var r = size / 2 - ring - size * 0.08
              c.lineWidth = ring
              c.lineCap = "butt"
              c.strokeStyle = Qt.rgba(dial.ink.r, dial.ink.g, dial.ink.b, 0.12)
              c.beginPath(); c.arc(cx, cy, r, 0, Math.PI * 2); c.stroke()

              var t = dial.today
              var sch = t ? t.schedule : null
              var warm = overlay.kelvinColor(dial.night, 1)
              var mode = overlay.s.mode
              if (mode === "Always on") {
                c.strokeStyle = warm
                c.beginPath(); c.arc(cx, cy, r, 0, Math.PI * 2); c.stroke()
              } else if (sch) {
                // The fades in a lighter tint, the full night in the colour you chose.
                c.strokeStyle = overlay.kelvinColor(dial.night, 0.45)
                c.beginPath(); c.arc(cx, cy, r, dial.angle(sch.evening.start), dial.angle(sch.evening.end)); c.stroke()
                c.beginPath(); c.arc(cx, cy, r, dial.angle(sch.morning.start), dial.angle(sch.morning.end)); c.stroke()
                c.strokeStyle = warm
                c.beginPath(); c.arc(cx, cy, r, dial.angle(sch.evening.end), dial.angle(sch.morning.start)); c.stroke()
              }

              // The hours, at the four quarters.
              c.fillStyle = Qt.rgba(dial.ink.r, dial.ink.g, dial.ink.b, 0.55)
              c.font = Math.round(size * 0.075) + "px sans-serif"
              c.textAlign = "center"; c.textBaseline = "middle"
              var labels = ["00", "06", "12", "18"]
              for (var i = 0; i < 4; i++) {
                var a = dial.angle(i * 360)
                var lr = r + ring / 2 + size * 0.055
                c.fillText(labels[i], cx + Math.cos(a) * lr, cy + Math.sin(a) * lr)
              }

              // Now.
              if (t) {
                var na = dial.angle(t.minute)
                c.strokeStyle = dial.ink
                c.lineWidth = Math.max(2, size * 0.018)
                c.lineCap = "round"
                c.beginPath()
                c.moveTo(cx + Math.cos(na) * (r - ring * 0.9), cy + Math.sin(na) * (r - ring * 0.9))
                c.lineTo(cx + Math.cos(na) * (r + ring * 0.9), cy + Math.sin(na) * (r + ring * 0.9))
                c.stroke()
              }
            }

            Column {
              anchors.centerIn: parent
              spacing: 0
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: overlay.w ? (overlay.w.identity ? "Day" : overlay.w.temperature + " K") : ""
                color: overlay.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: overlay.w !== null && overlay.w.gamma < 100
                text: overlay.w ? "dimmed " + overlay.w.gamma + "%" : ""
                color: overlay.faint
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(4)
            Text {
              text: "Dusk"
              color: overlay.ink
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: overlay.dusk ? overlay.dusk.description : ""
              color: overlay.ink
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              visible: text !== ""
              text: {
                var t = overlay.dusk ? overlay.dusk.today : null
                if (!t || !t.sun) return ""
                if (t.sun.polar) return t.sun.polar === "night" ? "The sun stays down today" : "The sun stays up today"
                return "Sunset " + Model.clockText(t.sun.sunset) + " · sunrise " + Model.clockText(t.sun.sunrise)
              }
              color: overlay.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: {
                var l = overlay.dusk ? overlay.dusk.location : null
                if (!l) return "No location yet: set one in Dusk's settings, or Omarchy's weather location"
                var where = l.name ? l.name : (l.latitude.toFixed(2) + ", " + l.longitude.toFixed(2))
                return where + " · from " + (l.source === "settings" ? "your settings" : l.source === "weather" ? "the weather location" : "your time zone")
              }
              color: overlay.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ------------------------------------------------ right now
        Flow {
          Layout.fillWidth: true
          spacing: Style.space(6)
          Button {
            text: "Off until morning"; bordered: true; foreground: overlay.ink; accent: overlay.accent
            selected: overlay.w !== null && overlay.w.reason === "off"
            onClicked: overlay.dusk.offUntilMorning()
          }
          Button {
            text: "Warm for 1 h"; bordered: true; foreground: overlay.ink; accent: overlay.accent
            selected: overlay.w !== null && overlay.w.reason === "warm"
            onClicked: overlay.dusk.warmForHour()
          }
          Button {
            visible: overlay.w !== null && (overlay.w.reason === "off" || overlay.w.reason === "warm" || overlay.w.reason === "manual")
            text: "Back to schedule"; bordered: true; foreground: overlay.ink; accent: overlay.accent
            onClicked: overlay.dusk.resume()
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // ------------------------------------------------ how warm
        Heading { text: "Night temperature" }

        Item {
          id: slider
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(26)
          readonly property int lo: 2500
          readonly property int hi: 6000
          readonly property int value: overlay.dusk && overlay.dusk.previewTemperature > 0 ? overlay.dusk.previewTemperature : overlay.s.temperature

          function valueAt(x) {
            var f = Math.max(0, Math.min(1, x / track.width))
            return Math.round((slider.lo + (slider.hi - slider.lo) * f) / 100) * 100
          }

          Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: Style.space(10)
            radius: height / 2
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: overlay.kelvinColor(2500) }
              GradientStop { position: 0.35; color: overlay.kelvinColor(3700) }
              GradientStop { position: 0.7; color: overlay.kelvinColor(4950) }
              GradientStop { position: 1.0; color: overlay.kelvinColor(6000) }
            }
          }

          Rectangle {
            width: Style.space(18)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            x: (slider.value - slider.lo) / (slider.hi - slider.lo) * track.width - width / 2
            color: overlay.kelvinColor(slider.value)
            border.color: overlay.ink
            border.width: Math.max(2, Style.space(2))
          }

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            preventStealing: true
            onPressed: function (mouse) { overlay.dusk.previewTemperature = slider.valueAt(mouse.x - Style.space(6)) }
            onPositionChanged: function (mouse) { if (pressed) overlay.dusk.previewTemperature = slider.valueAt(mouse.x - Style.space(6)) }
            onReleased: function (mouse) {
              var v = slider.valueAt(mouse.x - Style.space(6))
              overlay.dusk.set("temperature", v)
              overlay.dusk.previewTemperature = 0
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          ButtonGroup {
            Layout.fillWidth: true
            options: Model.PRESETS.map(function (p) { return { value: String(p.temperature), label: p.name + " " + p.temperature } })
            value: String(overlay.s.temperature)
            foreground: overlay.ink
            accent: overlay.accent
            onChanged: function (v) { overlay.dusk.set("temperature", Number(v)) }
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // ------------------------------------------------ when
        Heading { text: "Schedule" }

        ButtonGroup {
          Layout.fillWidth: true
          options: Model.MODES
          value: overlay.s.mode
          foreground: overlay.ink
          accent: overlay.accent
          onChanged: function (v) { overlay.dusk.set("mode", v) }
        }

        Stepper {
          Layout.fillWidth: true
          visible: overlay.s.mode === "Sun"
          label: "Start before sunset"
          value: overlay.s.beforeSunset + " min"
          onDown: overlay.step("beforeSunset", -10, 0, 180)
          onUp: overlay.step("beforeSunset", 10, 0, 180)
        }
        Stepper {
          Layout.fillWidth: true
          visible: overlay.s.mode === "Fixed times"
          label: "Warm from"
          value: overlay.s.warmFrom
          onDown: overlay.shiftClock("warmFrom", -15)
          onUp: overlay.shiftClock("warmFrom", 15)
        }
        Stepper {
          Layout.fillWidth: true
          visible: overlay.s.mode === "Fixed times"
          label: "Day again at"
          value: overlay.s.warmUntil
          onDown: overlay.shiftClock("warmUntil", -15)
          onUp: overlay.shiftClock("warmUntil", 15)
        }
        Stepper {
          Layout.fillWidth: true
          visible: overlay.s.mode === "Sun" || overlay.s.mode === "Fixed times"
          label: "Fade over"
          value: overlay.s.fadeMinutes === 0 ? "at once" : overlay.s.fadeMinutes + " min"
          onDown: overlay.step("fadeMinutes", -10, 0, 180)
          onUp: overlay.step("fadeMinutes", 10, 0, 180)
        }

        RowLayout {
          Layout.fillWidth: true
          Text {
            Layout.fillWidth: true
            text: "Dim late at night"
            color: overlay.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          ToggleSwitch {
            checked: overlay.s.dimLate
            foreground: overlay.ink
            accent: overlay.accent
            onToggled: overlay.dusk.set("dimLate", !overlay.s.dimLate)
          }
        }
        Stepper {
          Layout.fillWidth: true
          visible: overlay.s.dimLate
          label: "From"
          value: overlay.s.dimFrom
          onDown: overlay.shiftClock("dimFrom", -15)
          onUp: overlay.shiftClock("dimFrom", 15)
        }
        Stepper {
          Layout.fillWidth: true
          visible: overlay.s.dimLate
          label: "Brightness"
          value: overlay.s.dimPercent + "%"
          onDown: overlay.step("dimPercent", -5, 50, 100)
          onUp: overlay.step("dimPercent", 5, 50, 100)
        }

        PanelSeparator { Layout.fillWidth: true }

        // ------------------------------------------------ apps that need true colour
        Heading { text: "Step aside for" }

        Repeater {
          model: Model.appList(overlay.s.pauseApps)
          delegate: RowLayout {
            required property string modelData
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: modelData
              color: overlay.ink
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
            Button {
              text: "Remove"; foreground: overlay.faint; accent: overlay.accent
              onClicked: overlay.dusk.pauseApp(modelData, false)
            }
          }
        }

        Button {
          readonly property string cls: overlay.dusk ? overlay.dusk.appClass.toLowerCase() : ""
          visible: cls !== "" && Model.appList(cls).length === 1 && Model.appList(overlay.s.pauseApps).indexOf(cls) < 0
          text: "Add " + cls + ", the app in front"
          bordered: true
          foreground: overlay.ink
          accent: overlay.accent
          onClicked: overlay.dusk.pauseApp(cls, true)
        }

        RowLayout {
          Layout.fillWidth: true
          Text {
            Layout.fillWidth: true
            text: "Any fullscreen app"
            color: overlay.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          ToggleSwitch {
            checked: overlay.s.pauseFullscreen
            foreground: overlay.ink
            accent: overlay.accent
            onToggled: overlay.dusk.set("pauseFullscreen", !overlay.s.pauseFullscreen)
          }
        }

        Text {
          Layout.fillWidth: true
          visible: overlay.dusk !== null && overlay.dusk.message !== ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: overlay.dusk ? overlay.dusk.message : ""
          color: Commons.Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
