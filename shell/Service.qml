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

  // What a process Dusk starts may see: nothing it inherits from the shell beyond what hyprctl needs to find
  // Hyprland. Every process here clears its environment and gets this.
  readonly property var hyprEnv: ({
    PATH: "/usr/bin",
    HOME: Quickshell.env("HOME") || "",
    XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR") || "",
    HYPRLAND_INSTANCE_SIGNATURE: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
  })

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

  // Read from shell.json itself, as the shell's own config is not handed to plugin services.
  property var entry: null
  // Nothing is applied before Dusk has read its settings, so someone with Dusk set to Off never gets a moment of the
  // defaults.
  property bool settingsRead: false

  FileView {
    id: shellJson
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = text()
      if (raw.length <= 4 * 1024 * 1024) {
        try { dusk.entry = dusk.findEntry(JSON.parse(raw)) } catch (e) { }
      }
      dusk.draft = null
      dusk.settingsRead = true
    }
    onLoadFailed: dusk.settingsRead = true
  }
  readonly property var saved: Model.readSettings(dusk.entry)
  // Settings just saved but not yet read back, so a second click builds on the first instead of on the old value.
  property var draft: null
  // While the temperature slider is held, the screen follows the finger before anything is saved. Let go, it stays on
  // that value until the saved setting reads back (or two seconds pass), so it never flicks back to the old one.
  property int previewTemperature: 0
  property int previewSaving: 0

  function releasePreview(value) {
    dusk.previewSaving = value
    previewFallback.restart()
  }

  onSavedChanged: {
    if (dusk.previewSaving > 0 && dusk.saved.temperature === dusk.previewSaving) {
      dusk.previewTemperature = 0
      dusk.previewSaving = 0
    }
  }

  Timer {
    id: previewFallback
    interval: 2000
    onTriggered: { dusk.previewTemperature = 0; dusk.previewSaving = 0 }
  }
  readonly property var settings: dusk.previewTemperature > 0
    ? Object.assign({}, dusk.saved, { temperature: dusk.previewTemperature }) : dusk.saved

  property string message: ""

  function save(next) {
    if (!dusk.shell || typeof dusk.shell.updateEntryInline !== "function" || !dusk.entry) {
      dusk.message = "Dusk can only save its settings while its widget is on the bar."
      return false
    }
    dusk.draft = Model.settingsPayload(next)
    dusk.shell.updateEntryInline(dusk.pluginId, dusk.draft)
    dusk.message = ""
    return true
  }

  function set(key, value) {
    var next = Object.assign({}, dusk.draft || dusk.saved)
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

  // zone1970.tab names each zone's main city; zones it folds into another (Stockholm, Amsterdam, Oslo) are in the
  // older zone.tab, which is asked when the first has no answer.
  FileView {
    id: zoneTable
    path: "/usr/share/zoneinfo/zone1970.tab"
    printErrors: false
    onLoaded: dusk.locateZone()
  }

  FileView {
    id: zoneTableOld
    path: "/usr/share/zoneinfo/zone.tab"
    printErrors: false
    onLoaded: dusk.locateZone()
  }

  function locateZone() {
    dusk.zoneLocation = Model.coordsFromZoneTab(zoneTable.text(), dusk.zoneName)
                        || Model.coordsFromZoneTab(zoneTableOld.text(), dusk.zoneName)
  }

  Process {
    id: zoneProbe
    command: ["/usr/bin/readlink", "/etc/localtime"]
    clearEnvironment: true
    environment: ({ PATH: "/usr/bin" })
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        dusk.zoneName = Model.zoneFromLink(text.slice(0, 512))
        dusk.locateZone()
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

  // Whether one of hyprsunset's own switch times fell between two looks (a sleep or a stall can make that gap long).
  function profileBetween(fromMs, toMs) {
    if (!(fromMs > 0) || toMs - fromMs > 26 * 3600 * 1000) return false
    var d = new Date(fromMs)
    for (var k = 0; k <= 2; k++) {
      for (var i = 0; i < dusk.profileMinutes.length; i++) {
        var at = new Date(d.getFullYear(), d.getMonth(), d.getDate() + k, 0, dusk.profileMinutes[i]).getTime()
        if (at >= fromMs - 60000 && at <= toMs + 60000) return true
      }
    }
    return false
  }
  property double lastLook: 0

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
    var sun = Model.sunOf(day, dusk.location)
    return { sun: sun, schedule: Model.scheduleFor(dusk.settings, sun), minute: day.minute }
  }

  onWantedChanged: dusk.kick()

  function kick() { Qt.callLater(dusk.tick) }

  Timer {
    id: ticker
    interval: Model.tickMs(dusk.wanted, dusk.settings)
    repeat: true
    running: dusk.settingsRead
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
    if (!dusk.settingsRead) return
    if (probe.running || applier.running) {
      dusk.again = true               // asked while busy: look again as soon as the current call is done
      return
    }
    dusk.again = false
    probe.running = true
    deadline.restart()
  }
  property bool again: false

  // hyprctl answers in milliseconds; one that has not in five seconds is stopped, so a stuck compositor socket
  // cannot pile processes up.
  Timer {
    id: deadline
    interval: 5000
    onTriggered: {
      if (probe.running) probe.signal(9)
      if (applier.running) applier.signal(9)
    }
  }

  // One look: hyprsunset's process and its temperature.
  Process {
    id: probe
    command: ["/usr/bin/sh", "-c", "/usr/bin/pgrep -x -o hyprsunset; echo; /usr/bin/timeout 4 /usr/bin/hyprctl hyprsunset temperature"]
    clearEnvironment: true
    environment: dusk.hyprEnv
    stdout: StdioCollector {
      onStreamFinished: dusk.look(text.slice(0, 1024))
    }
    onExited: if (dusk.again && !applier.running) dusk.kick()
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
    var since = dusk.lastLook
    dusk.lastLook = now
    if (Model.isForeign(r, dusk.expected) && now - dusk.startedAt > 5000) {
      if (dusk.profileBetween(since, now)) {
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
    var ctl = "/usr/bin/timeout 4 /usr/bin/hyprctl hyprsunset "
    var colour = w.identity ? ctl + "identity" : ctl + "temperature " + t
    applier.command = ["/usr/bin/sh", "-c", colour + " >/dev/null; " + ctl + "gamma " + g + " >/dev/null; " + ctl + "temperature"]
    dusk.applied = { temperature: t, gamma: g, identity: w.identity }
    // Until hyprsunset answers, there is nothing to compare a reading with: Dusk's own change in flight must not
    // look like someone else's.
    dusk.expected = null
    applier.running = true
    deadline.restart()
  }

  Process {
    id: applier
    clearEnvironment: true
    environment: dusk.hyprEnv
    stdout: StdioCollector {
      onStreamFinished: {
        var r = Model.readingFrom(text.slice(0, 1024))
        if (r !== null) { dusk.expected = r; dusk.reading = r }
        else dusk.applied = null      // no answer: apply again on the next look rather than trust it took
      }
    }
    onExited: function (code) {
      if (code !== 0) dusk.applied = null
      if (dusk.again) dusk.kick()
    }
  }

  function startHyprsunset() {
    if (Date.now() - dusk.startedAt < 15000) return
    dusk.startedAt = Date.now()
    // Started the way Omarchy starts it, as its own app unit, with only what that needs to reach the session.
    Quickshell.execDetached({
      command: ["/usr/bin/uwsm-app", "--", "/usr/bin/hyprsunset"],
      clearEnvironment: true,
      environment: Object.assign({}, dusk.hyprEnv, {
        WAYLAND_DISPLAY: Quickshell.env("WAYLAND_DISPLAY") || "",
        DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS") || ""
      })
    })
  }

  // ---------------------------------------------------------------- the panel

  property real anchorX: -1
  property var overlay: null

  function togglePanel(x) {
    if (x !== undefined && x >= 0) dusk.anchorX = x
    if (dusk.shell && typeof dusk.shell.toggle === "function") dusk.shell.toggle(dusk.pluginId, "{}")
  }
}
