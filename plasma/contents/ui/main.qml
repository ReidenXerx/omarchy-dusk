import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.workspace.dbus as DBus
import org.kde.taskmanager as TaskManager
import "../code/DuskModel.js" as Dusk

// Dusk for Plasma: a companion to KWin's Night Light rather than a second one.
//
// KWin already warms the screen on Plasma's day and night schedule, fading as slowly as Dusk does on Omarchy. What
// it lacks is what Dusk adds here: true colour while the apps you name (or any fullscreen app) are in front, "off
// until morning" that ends by itself, warmth presets you can preview before choosing, and the night on a dial.
// Settings are written where Plasma keeps them (kwinrc, knighttimerc) with change notification, exactly as System
// Settings writes them, so both stay in step.
PlasmoidItem {
  id: root

  // ---------------------------------------------------------------- KWin's Night Light, live

  DBus.Properties {
    id: nl
    busType: DBus.BusType.Session
    service: "org.kde.KWin"
    path: "/org/kde/KWin/NightLight"
    iface: "org.kde.KWin.NightLight"
  }

  readonly property var p: nl.properties
  readonly property bool available: root.p.available === true
  readonly property bool enabled: root.p.enabled === true
  readonly property bool running: root.p.running === true
  readonly property bool inhibited: root.p.inhibited === true
  readonly property bool daylight: root.p.daylight === true
  readonly property int currentTemperature: Number(root.p.currentTemperature) || 6500
  readonly property int targetTemperature: Number(root.p.targetTemperature) || 6500
  // Seconds since the epoch, and seconds long.
  readonly property double nextAt: Number(String(root.p.scheduledTransitionDateTime || 0))
  readonly property double nextFor: Number(String(root.p.scheduledTransitionDuration || 0)) / 1000
  readonly property double lastAt: Number(String(root.p.previousTransitionDateTime || 0))
  readonly property double lastFor: Number(String(root.p.previousTransitionDuration || 0)) / 1000

  // done(value) on success; failed() when KWin refused or did not answer, so no caller is left waiting.
  function call(member, signature, args, done, failed) {
    var message = { service: "org.kde.KWin", path: "/org/kde/KWin/NightLight", iface: "org.kde.KWin.NightLight",
                    member: member, arguments: args }
    if (signature) message.signature = "(" + signature + ")"
    DBus.SessionBus.asyncCall(message, function (reply) { if (done) done(reply.value) }, function (reply) {
      console.warn("dusk:", member, reply.error ? reply.error.message : "")
      if (failed) failed()
    })
  }

  // Asking for a cookie, with a way out: an answer that never comes cannot leave the widget waiting for ever.
  function inhibit(got) {
    root.asking = true
    askTimeout.restart()
    root.call("inhibit", "", [], function (cookie) {
      askTimeout.stop()
      root.asking = false
      var n = Number(cookie)
      got(isFinite(n) && n > 0 ? n : 0)
    }, function () { askTimeout.stop(); root.asking = false; got(0) })
  }
  Timer { id: askTimeout; interval: 5000; onTriggered: root.asking = false }

  // Giving a cookie back, tried once more if KWin did not take it: a cookie never given back keeps Night Light off.
  function uninhibit(cookie) {
    if (!cookie) return
    root.call("uninhibit", "u", [cookie], null, function () {
      retryUninhibit.cookies = retryUninhibit.cookies.concat([cookie])
      retryUninhibit.restart()
    })
  }
  Timer {
    id: retryUninhibit
    property var cookies: []
    interval: 2000
    onTriggered: { var list = cookies; cookies = []; for (var i = 0; i < list.length; i++) root.call("uninhibit", "u", [list[i]], null) }
  }

  // ---------------------------------------------------------------- holding Night Light off

  // Two reasons to hold it off, each with its own cookie: you asked (until morning), or an app that needs true colour
  // is in front. KWin lets go of both if Plasma goes.
  property int morningCookie: 0
  property double morningUntil: 0
  property int asideCookie: 0
  property bool asking: false

  // The end of the coming night: the next morning transition, finished.
  function nextMorning() {
    if (!root.daylight && root.nextAt > 0) return root.nextAt + root.nextFor
    if (root.lastAt > 0) return root.lastAt + 86400 + root.lastFor
    return Date.now() / 1000 + 12 * 3600
  }

  function offUntilMorning() {
    if (root.morningCookie || root.asking) return
    root.inhibit(function (cookie) {
      root.morningCookie = cookie
      root.morningUntil = cookie ? root.nextMorning() : 0
      root.steer()                                   // an app may have come to the front while we asked
    })
  }

  function backToSchedule() {
    root.uninhibit(root.morningCookie)
    root.morningCookie = 0
    root.morningUntil = 0
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.morningCookie > 0
    onTriggered: if (Date.now() / 1000 >= root.morningUntil) root.backToSchedule()
  }

  // ---------------------------------------------------------------- stepping aside

  readonly property var pauseApps: Dusk.appList(Plasmoid.configuration.pauseApps)
  readonly property bool pauseFullscreen: Plasmoid.configuration.pauseFullscreen === true

  TaskManager.TasksModel {
    id: tasks
    filterByVirtualDesktop: false
    filterByScreen: false
    filterByActivity: false
    groupMode: TaskManager.TasksModel.GroupDisabled
    onActiveTaskChanged: root.look()
    onDataChanged: root.look()
  }

  property string frontApp: ""
  property string frontName: ""
  property bool frontFullscreen: false
  // The app last in front, for "Add the app in front" (an open popup is never a task).
  property string lastApp: ""
  property string lastName: ""

  function look() {
    var i = tasks.activeTask
    var app = "", name = "", full = false
    if (i && i.valid) {
      app = String(tasks.data(i, TaskManager.AbstractTasksModel.AppId) || "").replace(/\.desktop$/, "").toLowerCase().slice(0, 64)
      name = String(tasks.data(i, TaskManager.AbstractTasksModel.AppName) || app).slice(0, 64)
      full = tasks.data(i, TaskManager.AbstractTasksModel.IsFullScreen) === true
    }
    root.frontApp = app
    root.frontName = name
    root.frontFullscreen = full
    if (app !== "") { root.lastApp = app; root.lastName = name }
  }

  // A fullscreen window counts even without an app id; the named apps need one.
  readonly property bool wantAside: (root.frontApp !== "" && root.pauseApps.indexOf(root.frontApp) >= 0)
                                    || (root.pauseFullscreen && root.frontFullscreen)
  onWantAsideChanged: root.steer()

  function steer() {
    if (root.wantAside && !root.asideCookie && !root.asking) {
      root.inhibit(function (cookie) {
        root.asideCookie = cookie
        root.steer()                                 // it may have changed while we asked
      })
    } else if (!root.wantAside && root.asideCookie) {
      root.uninhibit(root.asideCookie)
      root.asideCookie = 0
    }
  }

  // KWin forgets every cookie when it restarts. If we hold one and Night Light is no longer held off, ours are gone:
  // drop them, and ask again for what is still wanted.
  onInhibitedChanged: if (!root.inhibited && (root.morningCookie || root.asideCookie) && !root.asking) {
    root.morningCookie = 0
    root.morningUntil = 0
    root.asideCookie = 0
    root.steer()
  }

  // A widget taken off the panel gives its cookies back: KWin only lets go of them when Plasma itself goes.
  Component.onDestruction: {
    if (root.morningCookie) root.call("uninhibit", "u", [root.morningCookie], null)
    if (root.asideCookie) root.call("uninhibit", "u", [root.asideCookie], null)
    root.call("stopPreview", "", [], null)
  }

  function addFrontApp() {
    if (!root.lastApp) return
    var list = root.pauseApps.slice()
    if (list.indexOf(root.lastApp) < 0) list.push(root.lastApp)
    Plasmoid.configuration.pauseApps = Dusk.appListText(list)
  }

  function removeApp(app) {
    Plasmoid.configuration.pauseApps = Dusk.appListText(root.pauseApps.filter(function (a) { return a !== app }))
  }

  // ---------------------------------------------------------------- Plasma's settings

  P5Support.DataSource {
    id: runner
    engine: "executable"
    property var onDone: ({})
    onNewData: function (source, data) {
      disconnectSource(source)
      var cb = runner.onDone[source]
      delete runner.onDone[source]
      if (cb) cb(Number(data["exit code"]), String(data["stdout"] || "").slice(0, 8192))
    }
  }

  function run(command, done) {
    if (runner.onDone[command] !== undefined) return
    runner.onDone[command] = done || null
    runner.connectSource(command)
  }

  // What System Settings would show: read when the panel opens.
  property var settings: ({ mode: "Sun", temperature: 4500, from: "18:00", until: "06:00", fade: 30 })
  property bool settingsRead: false

  readonly property var reads: [
    ["active", "kwinrc", "NightColor", "Active", "false"],
    ["kmode", "kwinrc", "NightColor", "Mode", "DarkLight"],
    ["temperature", "kwinrc", "NightColor", "NightTemperature", "4500"],
    ["source", "knighttimerc", "General", "Source", "Location"],
    ["from", "knighttimerc", "Times", "SunsetStart", "18:00:00"],
    ["until", "knighttimerc", "Times", "SunriseStart", "06:00:00"],
    ["fade", "knighttimerc", "Times", "TransitionDuration", "1800"]
  ]

  function readSettings() {
    var cmd = root.reads.map(function (r) {
      return "printf '" + r[0] + "=%s\\n' \"$(/usr/bin/kreadconfig6 --file " + r[1] + " --group " + r[2] + " --key " + r[3]
             + " --default " + r[4] + ")\""
    }).join("; ")
    root.run(cmd, function (code, out) {
      var v = {}
      out.split("\n").forEach(function (line) {
        var at = line.indexOf("=")
        if (at > 0) v[line.slice(0, at)] = line.slice(at + 1).trim()
      })
      var mode = v.active !== "true" ? "Off" : v.kmode === "Constant" ? "Always on" : v.source === "Times" ? "Fixed times" : "Sun"
      root.settings = {
        mode: mode,
        temperature: Dusk.clamp(Math.round(Number(v.temperature) || 4500), 1000, 6500),
        from: Dusk.clockText(root.clockOr(v.from, 18 * 60)),
        until: Dusk.clockText(root.clockOr(v.until, 6 * 60)),
        fade: Math.round((Number(v.fade) || 1800) / 60)
      }
      root.settingsRead = true
    })
  }

  // "21:30:00" as minutes, or the fallback (midnight is 0, a real answer).
  function clockOr(text, fallback) {
    var m = Dusk.parseClock(String(text || "").slice(0, 5))
    return m === null ? fallback : m
  }

  // Every value written is one of a fixed set or a checked number or clock, so nothing outside reaches the shell.
  function write(file, group, key, value) {
    var q = function (v) { return "'" + String(v).replace(/'/g, "'\\''") + "'" }
    return "/usr/bin/kwriteconfig6 --file " + q(file) + " --group " + q(group) + " --key " + q(key) + " " + q(value) + " --notify"
  }

  function apply(commands) {
    root.run(commands.join(" && ") + " # " + Date.now(), function () { root.readSettings() })
  }

  function setMode(mode) {
    if (mode === "Off") root.apply([root.write("kwinrc", "NightColor", "Active", "false")])
    else if (mode === "Always on") root.apply([root.write("kwinrc", "NightColor", "Mode", "Constant"), root.write("kwinrc", "NightColor", "Active", "true")])
    else root.apply([root.write("knighttimerc", "General", "Source", mode === "Fixed times" ? "Times" : "Location"),
                     root.write("kwinrc", "NightColor", "Mode", "DarkLight"), root.write("kwinrc", "NightColor", "Active", "true")])
  }

  function setTemperature(kelvin) {
    var k = Dusk.clamp(Math.round(Number(kelvin) / 100) * 100, 1000, 6500)
    if (isFinite(k)) root.apply([root.write("kwinrc", "NightColor", "NightTemperature", String(k))])
  }

  function setTimes(fromMinutes, untilMinutes, fadeMinutes) {
    var from = Dusk.clockText(fromMinutes), until = Dusk.clockText(untilMinutes)
    var fade = Dusk.clamp(Math.round(Number(fadeMinutes)), 1, 600)
    root.apply([root.write("knighttimerc", "Times", "SunsetStart", from + ":00"),
                root.write("knighttimerc", "Times", "SunriseStart", until + ":00"),
                root.write("knighttimerc", "Times", "TransitionDuration", String(fade * 60))])
  }

  // Shows a temperature for a few seconds without changing anything: for choosing a preset.
  function preview(kelvin) { root.call("preview", "u", [Dusk.clamp(Math.round(kelvin), 1000, 6500)], null) }
  function stopPreview() { root.call("stopPreview", "", [], null) }

  onExpandedChanged: function () {
    if (root.expanded) root.readSettings()
    else root.stopPreview()
  }

  Component.onCompleted: root.look()

  property int nowMinute: { var d = new Date(); return d.getHours() * 60 + d.getMinutes() }
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: { var d = new Date(); root.nowMinute = d.getHours() * 60 + d.getMinutes() }
  }

  // ---------------------------------------------------------------- the icon

  readonly property bool warm: root.running && root.currentTemperature < 6400
  readonly property string word: {
    if (!root.available) return "Night Light is not available here"
    if (root.asideCookie) return "Stepping aside for " + root.frontName
    if (root.morningCookie) return "Off until morning"
    if (root.inhibited) return "Paused"
    if (!root.enabled) return "Off"
    if (root.warm && root.currentTemperature !== root.targetTemperature) return "Fading, " + root.currentTemperature + " K"
    if (root.warm) return "Warm, " + root.currentTemperature + " K"
    return "Day"
  }

  Plasmoid.icon: !root.enabled || root.inhibited ? "redshift-status-off" : root.warm ? "redshift-status-on" : "redshift-status-day"
  Plasmoid.status: root.available ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.HiddenStatus
  toolTipMainText: "Dusk"
  toolTipSubText: root.word

  preferredRepresentation: compactRepresentation
  fullRepresentation: FullView { dusk: root }
}
