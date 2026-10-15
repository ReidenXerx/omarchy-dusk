import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "DuskModel.js" as Model

// Dusk's engine: what the screen should be now, and getting hyprsunset there in small steps.
//
// The model decides; this reads the world (settings, where you are, the app in front, what hyprsunset says) and
// writes one thing: hyprsunset's temperature and gamma, through hyprctl. A temperature Dusk did not set, such as a
// press of Omarchy's own night light key, is your choice and stands until the schedule's next edge.
Item {
  id: dusk

  property var shell: null
  property var manifest: null
  readonly property string pluginId: "reidenxerx.dusk"

  // ---------------------------------------------------------------- settings

  // Dusk's entry in shell.json: its place on the bar, or its line in the plugin list.
  function findEntry(config) {
    if (!config || typeof config !== "object") return null
    var layout = config.bar && config.bar.layout ? config.bar.layout : {}
    for (var section in layout) {
      var list = layout[section]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === dusk.pluginId) return list[i]
    }
    var plugins = Array.isArray(config.plugins) ? config.plugins : []
    for (var j = 0; j < plugins.length; j++) if (plugins[j] && plugins[j].id === dusk.pluginId) return plugins[j]
    return null
  }

  readonly property var entry: findEntry(dusk.shell ? dusk.shell.shellConfig : null)
  readonly property var saved: Model.readSettings(dusk.entry)
  // While the temperature slider is held, the screen follows the finger before anything is saved.
  property int previewTemperature: 0
  readonly property var settings: dusk.previewTemperature > 0
    ? Object.assign({}, dusk.saved, { temperature: dusk.previewTemperature }) : dusk.saved

  property string message: ""

  function save(next) {
    if (!dusk.shell || typeof dusk.shell.updateEntryInline !== "function" || !dusk.entry) {
      dusk.message = "Dusk can only save its settings while its widget is on the bar."
      return false
    }
    dusk.shell.updateEntryInline(dusk.pluginId, Model.settingsPayload(next))
    dusk.message = ""
    return true
  }

  function set(key, value) {
    var next = Object.assign({}, dusk.saved)
    next[key] = value
    return dusk.save(next)
  }

  // ---------------------------------------------------------------- where you are

  property var weatherLocation: null
  property var zoneLocation: null
  property string zoneName: ""
  readonly property var location: Model.chooseLocation(dusk.settings, dusk.weatherLocation, dusk.zoneLocation)

  FileView {
    id: weatherFile
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: dusk.weatherLocation = Model.coordsFromWeather(text())
    onLoadFailed: dusk.weatherLocation = null
  }

  FileView {
    id: zoneTable
    path: "/usr/share/zoneinfo/zone1970.tab"
    printErrors: false
    onLoaded: dusk.zoneLocation = Model.coordsFromZoneTab(text(), dusk.zoneName)
  }

  Process {
    id: zoneProbe
    command: ["/usr/bin/readlink", "/etc/localtime"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        dusk.zoneName = Model.zoneFromLink(text.slice(0, 512))
        dusk.zoneLocation = Model.coordsFromZoneTab(zoneTable.text(), dusk.zoneName)
      }
    }
  }

  // hyprsunset's own profiles switch it at fixed times (Omarchy ships one that goes neutral at 07:00). Those are not
  // you pressing a key, so a change that lands on one of them is put right instead of taken as your choice.
  property var profileMinutes: []

  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/hypr/hyprsunset.conf"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var out = []
      var lines = text().slice(0, 64 * 1024).split("\n")
      for (var i = 0; i < lines.length; i++) {
        var m = /^\s*time\s*=\s*(\d{1,2}:\d{2})\s*$/.exec(lines[i])
        var minute = m ? Model.parseClock(m[1]) : null
        if (minute !== null) out.push(minute)
      }
      dusk.profileMinutes = out
    }
  }

  function nearProfile(ms) {
    var d = new Date(ms)
    var minute = d.getHours() * 60 + d.getMinutes()
    for (var i = 0; i < dusk.profileMinutes.length; i++)
      if (Math.abs(minute - dusk.profileMinutes[i]) <= 1) return true
    return false
  }

  // ---------------------------------------------------------------- the app in front

  readonly property var focused: ToplevelManager.activeToplevel
  readonly property string appClass: dusk.focused ? String(dusk.focused.appId || "") : ""
  readonly property string appName: dusk.focused ? String(dusk.focused.title || dusk.appClass).slice(0, 60) : ""
  readonly property bool fullscreen: (dusk.focused !== null && dusk.focused.fullscreen === true)
    || (Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.hasFullscreen === true)
  readonly property bool paused: Model.pausedFor(dusk.settings, dusk.appClass, dusk.fullscreen)

  // ---------------------------------------------------------------- overrides

  // Kept across shell reloads, so "off until morning" survives editing a setting.
  PersistentProperties {
    id: kept
    reloadableId: "reidenxerx.dusk.state"
    property string overrideJson: ""
  }

  readonly property var override: {
    if (!kept.overrideJson) return null
    try { return JSON.parse(kept.overrideJson) } catch (e) { return null }
  }

  function setOverride(o) {
    kept.overrideJson = o ? JSON.stringify(o) : ""
    dusk.kick()
  }

  function offUntilMorning() { dusk.setOverride(Model.offUntilMorning(Date.now(), dusk.settings, dusk.location)) }
  function warmForHour() { dusk.setOverride(Model.warmFor(Date.now(), 60)) }
  function resume() { dusk.setOverride(null) }
  function pauseApp(appClass, on) { dusk.save(Model.withPausedApp(dusk.saved, appClass, on)) }

  // ---------------------------------------------------------------- now

  property double nowMs: Date.now()
  readonly property var wanted: Model.target(dusk.nowMs, dusk.settings,
                                             { location: dusk.location, override: dusk.override, paused: dusk.paused })
  readonly property string description: Model.describe(dusk.wanted, dusk.settings, dusk.location, dusk.nowMs)
  readonly property var today: {
    var day = Model.localDay(dusk.nowMs)
    var sun = dusk.location ? Model.sunTimes(day.start, dusk.location.latitude, dusk.location.longitude, day.offset) : null
    return { sun: sun, schedule: Model.scheduleFor(dusk.settings, sun), minute: day.minute }
  }

  onWantedChanged: dusk.kick()

  function kick() { Qt.callLater(dusk.tick) }

  Timer {
    id: ticker
    interval: Model.tickMs(dusk.wanted, dusk.settings)
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: dusk.tick()
  }

  // ---------------------------------------------------------------- talking to hyprsunset

  property var applied: null          // what Dusk last asked for: { temperature, gamma, identity }
  property var expected: null         // what hyprsunset answered right after that
  property string sunsetPid: ""
  property int reading: 0             // hyprsunset's temperature at the last look
  property bool hyprsunsetMissing: false
  property double startedAt: 0

  function tick() {
    dusk.nowMs = Date.now()
    if (!probe.running && !applier.running) probe.running = true
  }

  // One look: hyprsunset's process and its temperature.
  Process {
    id: probe
    command: ["/usr/bin/sh", "-c", "/usr/bin/pgrep -x -o hyprsunset; echo; /usr/bin/hyprctl hyprsunset temperature"]
    stdout: StdioCollector {
      onStreamFinished: dusk.look(text.slice(0, 1024))
    }
  }

  function look(out) {
    var parts = out.split("\n")
    var pid = /^\d+$/.test(parts[0]) ? parts[0] : ""
    if (!pid) {
      dusk.hyprsunsetMissing = true
      dusk.startHyprsunset()
      return
    }
    dusk.hyprsunsetMissing = false
    if (pid !== dusk.sunsetPid) {
      // A new hyprsunset has its own idea of the colour; nothing it says yet is anyone's choice.
      dusk.sunsetPid = pid
      dusk.applied = null
      dusk.expected = null
    }
    var r = Model.readingFrom(parts.slice(1).join("\n"))
    if (r === null) return
    dusk.reading = r
    var now = Date.now()
    if (Model.isForeign(r, dusk.expected) && now - dusk.startedAt > 5000) {
      if (dusk.nearProfile(now)) {
        dusk.applied = null           // hyprsunset's own clock moved it: put it back
      } else {
        dusk.expected = r
        dusk.setOverride(Model.manualOverride(now, r, dusk.settings, dusk.location))
        return
      }
    }
    var w = dusk.wanted
    var a = dusk.applied
    if (!a || a.identity !== w.identity || a.gamma !== w.gamma || (!w.identity && a.temperature !== w.temperature))
      dusk.apply(w)
  }

  function apply(w) {
    var t = Math.round(w.temperature)
    var g = Math.round(w.gamma)
    var colour = w.identity ? "/usr/bin/hyprctl hyprsunset identity" : "/usr/bin/hyprctl hyprsunset temperature " + t
    applier.command = ["/usr/bin/sh", "-c", colour + " >/dev/null; /usr/bin/hyprctl hyprsunset gamma " + g
                       + " >/dev/null; /usr/bin/hyprctl hyprsunset temperature"]
    dusk.applied = { temperature: t, gamma: g, identity: w.identity }
    applier.running = true
  }

  Process {
    id: applier
    stdout: StdioCollector {
      onStreamFinished: {
        var r = Model.readingFrom(text.slice(0, 1024))
        if (r !== null) { dusk.expected = r; dusk.reading = r }
      }
    }
  }

  function startHyprsunset() {
    if (Date.now() - dusk.startedAt < 15000) return
    dusk.startedAt = Date.now()
    Quickshell.execDetached(["/usr/bin/uwsm-app", "--", "/usr/bin/hyprsunset"])
  }

  // ---------------------------------------------------------------- the panel

  property real anchorX: -1
  property var overlay: null

  function togglePanel(x) {
    if (x !== undefined && x >= 0) dusk.anchorX = x
    if (dusk.shell && typeof dusk.shell.toggle === "function") dusk.shell.toggle(dusk.pluginId, "{}")
  }
}
