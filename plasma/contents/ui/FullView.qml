import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import "../code/DuskModel.js" as Dusk

// The panel: the night on a 24-hour dial, warmth, the schedule, and the apps Night Light steps aside for.
PlasmaExtras.Representation {
  id: view

  required property var dusk

  Layout.preferredWidth: Kirigami.Units.gridUnit * 22
  Layout.preferredHeight: Kirigami.Units.gridUnit * 34
  Layout.minimumWidth: Kirigami.Units.gridUnit * 18
  Layout.minimumHeight: Kirigami.Units.gridUnit * 18

  readonly property var d: view.dusk
  readonly property var s: view.d.settings
  readonly property color faint: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.65)
  // Sizes from a Plasma label (Kirigami.Theme.smallFont answers differently at a popup's root and in delegates).
  readonly property real smallPt: Math.max(7, Math.round(sizer.font.pointSize * 0.9))
  PlasmaComponents.Label { id: sizer; visible: false }

  // A colour close to what a temperature looks like, for the dial and the presets.
  function tint(kelvin) {
    var t = Math.max(0, Math.min(1, (kelvin - 2500) / 4000))
    return Qt.rgba(1, 0.55 + 0.4 * t, 0.25 + 0.7 * t, 1)
  }

  function minuteOf(seconds) {
    var date = new Date(seconds * 1000)
    return date.getHours() * 60 + date.getMinutes()
  }

  // The night as minutes of the day: when the evening fade starts and ends, and the morning one.
  readonly property var night: {
    var d = view.d
    if (!(d.nextAt > 0 && d.lastAt > 0)) return null
    var evening = d.daylight ? [d.nextAt, d.nextFor] : [d.lastAt, d.lastFor]
    var morning = d.daylight ? [d.lastAt, d.lastFor] : [d.nextAt, d.nextFor]
    return { warmFrom: view.minuteOf(evening[0]), warmFull: view.minuteOf(evening[0] + evening[1]),
             coolFrom: view.minuteOf(morning[0]), coolFull: view.minuteOf(morning[0] + morning[1]) }
  }

  component Note: PlasmaComponents.Label {
    Layout.fillWidth: true
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    color: view.faint
    font.pointSize: view.smallPt
  }

  component Heading: PlasmaComponents.Label {
    textFormat: Text.PlainText
    color: view.faint
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 1
    font.pointSize: view.smallPt
    Layout.topMargin: Kirigami.Units.smallSpacing
  }

  PlasmaComponents.ScrollView {
    id: scroller
    anchors.fill: parent
    QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff
    contentWidth: availableWidth

    ColumnLayout {
      width: scroller.availableWidth
      spacing: Kirigami.Units.largeSpacing

      // ------------------------------------------------ the dial
      Canvas {
        id: dial
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: Kirigami.Units.gridUnit * 13
        Layout.preferredHeight: Layout.preferredWidth
        readonly property var night: view.night
        readonly property int now: view.d.nowMinute
        readonly property color ink: Kirigami.Theme.textColor
        readonly property int kelvin: view.s.temperature
        onNightChanged: requestPaint()
        onNowChanged: requestPaint()
        onInkChanged: requestPaint()
        onKelvinChanged: requestPaint()

        onPaint: {
          var c = getContext("2d")
          c.reset()
          var cx = width / 2, cy = height / 2, r = width / 2 - 14
          var ring = Math.max(8, r * 0.16)
          // Midnight at the bottom, noon at the top, so the night sits under you.
          function angle(minute) { return (minute / 1440) * 2 * Math.PI + Math.PI / 2 }
          c.lineWidth = ring
          c.lineCap = "butt"
          c.strokeStyle = Qt.rgba(dial.ink.r, dial.ink.g, dial.ink.b, 0.10)
          c.beginPath(); c.arc(cx, cy, r, 0, 2 * Math.PI); c.stroke()
          var n = dial.night
          if (n) {
            var warmCol = view.tint(dial.kelvin)
            function arc(from, to, alpha) {
              var a0 = angle(from), a1 = angle(to)
              if (a1 <= a0) a1 += 2 * Math.PI
              c.strokeStyle = Qt.rgba(warmCol.r, warmCol.g, warmCol.b, alpha)
              c.beginPath(); c.arc(cx, cy, r, a0, a1); c.stroke()
            }
            arc(n.warmFrom, n.warmFull, 0.45)
            arc(n.warmFull, n.coolFrom, 0.95)
            arc(n.coolFrom, n.coolFull, 0.45)
          }
          // Hours around the ring.
          c.fillStyle = Qt.rgba(dial.ink.r, dial.ink.g, dial.ink.b, 0.6)
          c.font = Math.round(view.smallPt * 4 / 3) + "px sans-serif"
          c.textAlign = "center"; c.textBaseline = "middle"
          var marks = [[0, "00"], [360, "06"], [720, "12"], [1080, "18"]]
          for (var i = 0; i < marks.length; i++) {
            var a = angle(marks[i][0])
            c.fillText(marks[i][1], cx + Math.cos(a) * (r - ring - 10), cy + Math.sin(a) * (r - ring - 10))
          }
          // Now.
          var an = angle(dial.now)
          c.fillStyle = dial.ink
          c.beginPath(); c.arc(cx + Math.cos(an) * r, cy + Math.sin(an) * r, ring * 0.42, 0, 2 * Math.PI); c.fill()
        }

        ColumnLayout {
          anchors.centerIn: parent
          spacing: 0
          Kirigami.Heading {
            Layout.alignment: Qt.AlignHCenter
            level: 2
            textFormat: Text.PlainText
            text: view.d.running && view.d.currentTemperature < 6400 ? view.d.currentTemperature + " K" : view.d.daylight ? "Day" : "Neutral"
          }
          PlasmaComponents.Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: dial.width * 0.55
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            color: view.faint
            font.pointSize: view.smallPt
            text: view.d.word.replace(/, [0-9]+ K$/, "")
          }
        }
      }

      Note {
        horizontalAlignment: Text.AlignHCenter
        visible: view.night !== null && view.d.enabled
        text: view.night ? "Warm from " + Dusk.clockText(view.night.warmFrom) + ", fully by " + Dusk.clockText(view.night.warmFull)
                           + " · neutral again by " + Dusk.clockText(view.night.coolFull) : ""
      }

      PlasmaComponents.Button {
        Layout.alignment: Qt.AlignHCenter
        visible: view.d.enabled || view.d.morningCookie > 0
        icon.name: view.d.morningCookie ? "media-playback-start" : "redshift-status-off"
        text: view.d.morningCookie ? "Back to the schedule" : "Off until morning"
        onClicked: view.d.morningCookie ? view.d.backToSchedule() : view.d.offUntilMorning()
      }

      Kirigami.Separator { Layout.fillWidth: true }

      // ------------------------------------------------ warmth
      Heading { text: "Warmth at night" }
      RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        Repeater {
          model: Dusk.PRESETS
          delegate: PlasmaComponents.Button {
            required property var modelData
            Layout.fillWidth: true
            text: modelData.name
            checkable: true
            checked: view.s.temperature === modelData.temperature
            onClicked: view.d.setTemperature(modelData.temperature)
            onHoveredChanged: hovered ? view.d.preview(modelData.temperature) : view.d.stopPreview()
            PlasmaComponents.ToolTip.text: modelData.temperature + " K · hover to see it"
            PlasmaComponents.ToolTip.visible: hovered
          }
        }
      }
      RowLayout {
        Layout.fillWidth: true
        PlasmaComponents.Slider {
          id: warmth
          Layout.fillWidth: true
          from: 2500
          to: 6000
          stepSize: 100
          value: view.s.temperature
          onMoved: view.d.preview(value)
          onPressedChanged: if (!pressed) { view.d.stopPreview(); view.d.setTemperature(value) }
        }
        PlasmaComponents.Label {
          textFormat: Text.PlainText
          text: Math.round(warmth.value) + " K"
          Layout.preferredWidth: Kirigami.Units.gridUnit * 3
        }
      }

      // ------------------------------------------------ the schedule
      Heading { text: "When" }
      PlasmaComponents.ComboBox {
        Layout.fillWidth: true
        model: ["Follow the sun", "Fixed times", "Always on", "Off"]
        readonly property var modes: ["Sun", "Fixed times", "Always on", "Off"]
        currentIndex: Math.max(0, modes.indexOf(view.s.mode))
        onActivated: function (i) { view.d.setMode(modes[i]) }
      }

      Note {
        visible: view.s.mode === "Sun"
        text: "Sunset and sunrise where you are, as Plasma's own Night Light settings find it."
      }

      // Not editable by typing: a time field would read the clipboard, and steps of a quarter hour are enough.
      GridLayout {
        Layout.fillWidth: true
        visible: view.s.mode === "Fixed times"
        columns: 2
        PlasmaComponents.Label { text: "Warm from"; textFormat: Text.PlainText }
        PlasmaComponents.SpinBox {
          id: fromBox
          from: 0; to: 1439; stepSize: 15
          value: Dusk.parseClock(view.s.from) || 0
          textFromValue: function (v) { return Dusk.clockText(v) }
          onValueModified: view.d.setTimes(value, untilBox.value, fadeBox.value)
        }
        PlasmaComponents.Label { text: "Neutral from"; textFormat: Text.PlainText }
        PlasmaComponents.SpinBox {
          id: untilBox
          from: 0; to: 1439; stepSize: 15
          value: Dusk.parseClock(view.s.until) || 0
          textFromValue: function (v) { return Dusk.clockText(v) }
          onValueModified: view.d.setTimes(fromBox.value, value, fadeBox.value)
        }
        PlasmaComponents.Label { text: "Fade over"; textFormat: Text.PlainText }
        PlasmaComponents.SpinBox {
          id: fadeBox
          from: 1; to: 600; stepSize: 5
          value: view.s.fade
          textFromValue: function (v) { return v + " min" }
          onValueModified: view.d.setTimes(fromBox.value, untilBox.value, value)
        }
      }

      Kirigami.Separator { Layout.fillWidth: true }

      // ------------------------------------------------ stepping aside
      Heading { text: "True colour for" }
      PlasmaComponents.Switch {
        Layout.fillWidth: true
        text: "Every fullscreen app"
        checked: view.d.pauseFullscreen
        onToggled: Plasmoid.configuration.pauseFullscreen = checked
      }
      Flow {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        Repeater {
          model: view.d.pauseApps
          delegate: PlasmaComponents.Button {
            required property string modelData
            text: modelData + "  ×"
            onClicked: view.d.removeApp(modelData)
            PlasmaComponents.ToolTip.text: "Stop stepping aside for " + modelData
            PlasmaComponents.ToolTip.visible: hovered
          }
        }
        PlasmaComponents.Button {
          visible: view.d.lastApp !== "" && view.d.pauseApps.indexOf(view.d.lastApp) < 0
          icon.name: "list-add"
          text: "Add " + view.d.lastName
          onClicked: view.d.addFrontApp()
        }
      }
      Note { text: "While one of these is in front, Night Light steps aside and the screen shows true colour; it warms again when you leave it." }
    }
  }
}
