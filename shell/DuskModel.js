// DuskModel.js -- what Dusk decides, with no Qt in it, so node can test it.
//
// When the sun sets and rises where you are, how warm the screen should be at any minute of the day, the fades in
// between, and how an override (off until morning, warm for an hour, or a flip of Omarchy's own toggle) or a pause
// for an app changes that. Everything read from shell.json, the weather setting or the time zone table is untrusted:
// shapes are checked and values clamped before anything is built from them.

var DAY_TEMPERATURE = 6500      // what "no warmth" means; at full day Dusk asks hyprsunset for identity instead
var MIN_TEMPERATURE = 2500
var MAX_TEMPERATURE = 6000      // warmer than this is not a night light
var MIN_GAMMA = 50
var MINUTE = 60 * 1000
var DAY_MINUTES = 24 * 60
var STEP_KELVIN = 10            // temperatures are rounded to this; hyprsunset takes whole kelvin
var APPS_MAX = 24
var APP_MAX = 64
var ZONE_TAB_MAX = 64 * 1024

var MODES = ["Sun", "Fixed times", "Always on", "Off"]
var PRESETS = [{ name: "Candle", temperature: 2700 }, { name: "Evening", temperature: 3400 }, { name: "Soft", temperature: 4500 }]

var DEFAULTS = {
  mode: "Sun",
  temperature: 3400,
  fadeMinutes: 40,
  beforeSunset: 30,
  warmFrom: "21:00",
  warmUntil: "07:00",
  dimLate: false,
  dimFrom: "23:30",
  dimPercent: 80,
  pauseApps: "",
  pauseFullscreen: false,
  latitude: "",
  longitude: ""
}

function isObject(v) { return v !== null && typeof v === "object" && !Array.isArray(v) }
function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
function num(v, fallback) { var n = Number(v); return typeof v !== "boolean" && v !== "" && v !== null && isFinite(n) ? n : fallback }
function mod(a, n) { return ((a % n) + n) % n }

// "HH:MM" as minutes after midnight, or null.
function parseClock(s) {
  var m = /^([01]?[0-9]|2[0-3]):([0-5][0-9])$/.exec(String(s === undefined || s === null ? "" : s).trim())
  return m ? Number(m[1]) * 60 + Number(m[2]) : null
}

function clockText(minutes) {
  var m = mod(Math.round(minutes), DAY_MINUTES)
  var h = Math.floor(m / 60), mm = m % 60
  return (h < 10 ? "0" : "") + h + ":" + (mm < 10 ? "0" : "") + mm
}

// The app list in a setting: names separated by commas, lower-cased, bounded.
function appList(s) {
  return String(typeof s === "string" ? s : "").split(",").map(function (a) { return a.trim().toLowerCase() })
    .filter(function (a) { return a.length > 0 && a.length <= APP_MAX && /^[a-z0-9][a-z0-9._ +-]*$/.test(a) })
    .slice(0, APPS_MAX)
}

function appListText(list) {
  return list.join(", ")
}

// Settings from Dusk's entry in shell.json, every value checked and clamped.
function readSettings(raw) {
  var r = isObject(raw) ? raw : {}
  var lat = num(r.latitude, NaN), lon = num(r.longitude, NaN)
  return {
    mode: MODES.indexOf(r.mode) >= 0 ? r.mode : DEFAULTS.mode,
    temperature: Math.round(clamp(num(r.temperature, DEFAULTS.temperature), MIN_TEMPERATURE, MAX_TEMPERATURE) / 100) * 100,
    fadeMinutes: Math.round(clamp(num(r.fadeMinutes, DEFAULTS.fadeMinutes), 0, 180)),
    beforeSunset: Math.round(clamp(num(r.beforeSunset, DEFAULTS.beforeSunset), 0, 180)),
    warmFrom: parseClock(r.warmFrom) !== null ? String(r.warmFrom).trim() : DEFAULTS.warmFrom,
    warmUntil: parseClock(r.warmUntil) !== null ? String(r.warmUntil).trim() : DEFAULTS.warmUntil,
    dimLate: r.dimLate === true,
    dimFrom: parseClock(r.dimFrom) !== null ? String(r.dimFrom).trim() : DEFAULTS.dimFrom,
    dimPercent: Math.round(clamp(num(r.dimPercent, DEFAULTS.dimPercent), MIN_GAMMA, 100)),
    pauseApps: appListText(appList(r.pauseApps)),
    pauseFullscreen: r.pauseFullscreen === true,
    latitude: isFinite(lat) && Math.abs(lat) <= 90 ? String(lat) : "",
    longitude: isFinite(lon) && Math.abs(lon) <= 180 ? String(lon) : ""
  }
}

// ---------------------------------------------------------------- where you are

// Omarchy's weather location (~/.local/state/omarchy/settings/weather.json), when it has coordinates.
function coordsFromWeather(text) {
  if (typeof text !== "string" || text.length > 64 * 1024) return null
  var o
  try { o = JSON.parse(text) } catch (e) { return null }
  if (!isObject(o)) return null
  var lat = num(o.latitude, NaN), lon = num(o.longitude, NaN)
  if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null
  return { latitude: lat, longitude: lon, name: typeof o.name === "string" ? o.name.slice(0, 80) : "", source: "weather" }
}

// One ISO 6709 coordinate from tzdata (+DDMM, +DDMMSS, +DDDMM, +DDDMMSS) in degrees.
function iso6709(s, degreeDigits) {
  var m = /^([+-])(\d+)$/.exec(s)
  if (!m) return NaN
  var d = m[2]
  if (d.length !== degreeDigits + 2 && d.length !== degreeDigits + 4) return NaN
  var deg = Number(d.slice(0, degreeDigits)), min = Number(d.slice(degreeDigits, degreeDigits + 2))
  var sec = d.length === degreeDigits + 4 ? Number(d.slice(degreeDigits + 2)) : 0
  if (min >= 60 || sec >= 60) return NaN
  return (m[1] === "-" ? -1 : 1) * (deg + min / 60 + sec / 3600)
}

// The coordinates tzdata's zone1970.tab gives the main city of a time zone such as "Europe/Kyiv".
function coordsFromZoneTab(text, zone) {
  if (typeof text !== "string" || text.length > ZONE_TAB_MAX || typeof zone !== "string" || !zone) return null
  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].charAt(0) === "#") continue
    var cols = lines[i].split("\t")
    if (cols.length < 3 || cols[2] !== zone) continue
    var m = /^([+-]\d+)([+-]\d+)$/.exec(cols[1])
    if (!m) return null
    var lat = iso6709(m[1], 2), lon = iso6709(m[2], 3)
    if (!isFinite(lat) || !isFinite(lon)) return null
    var city = zone.split("/").pop().replace(/_/g, " ")
    return { latitude: lat, longitude: lon, name: city, source: "time zone" }
  }
  return null
}

// The time zone /etc/localtime points at ("/usr/share/zoneinfo/Europe/Kyiv" gives "Europe/Kyiv").
function zoneFromLink(link) {
  var m = /zoneinfo\/((?:[A-Za-z0-9_+-]+\/)*[A-Za-z0-9_+-]+)\s*$/.exec(String(link || ""))
  return m ? m[1] : ""
}

// Which location wins: one typed into the settings, then the weather setting, then the time zone.
function chooseLocation(settings, weather, zone) {
  if (settings.latitude !== "" && settings.longitude !== "")
    return { latitude: Number(settings.latitude), longitude: Number(settings.longitude), name: "", source: "settings" }
  return weather || zone || null
}

// ---------------------------------------------------------------- the sun

function rad(d) { return d * Math.PI / 180 }
function deg(r) { return r * 180 / Math.PI }

// Sunrise and sunset in minutes after local midnight for the calendar day of `dayStartMs` (local midnight), from
// NOAA's solar calculator (good to a minute away from the poles). `offsetMinutes` is the local time's offset from
// UTC on that day. Where the sun does not rise or does not set that day, `polar` says which.
function sunTimes(dayStartMs, latitude, longitude, offsetMinutes) {
  var noonUtcMs = dayStartMs + 12 * 60 * MINUTE - offsetMinutes * MINUTE
  var jd = noonUtcMs / 86400000 + 2440587.5
  var t = (jd - 2451545) / 36525
  var L0 = mod(280.46646 + t * (36000.76983 + 0.0003032 * t), 360)
  var M = 357.52911 + t * (35999.05029 - 0.0001537 * t)
  var e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
  var C = Math.sin(rad(M)) * (1.914602 - t * (0.004817 + 0.000014 * t)) + Math.sin(rad(2 * M)) * (0.019993 - 0.000101 * t)
    + Math.sin(rad(3 * M)) * 0.000289
  var trueLong = L0 + C
  var omega = 125.04 - 1934.136 * t
  var lambda = trueLong - 0.00569 - 0.00478 * Math.sin(rad(omega))
  var eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
  var eps = eps0 + 0.00256 * Math.cos(rad(omega))
  var decl = deg(Math.asin(Math.sin(rad(eps)) * Math.sin(rad(lambda))))
  var y = Math.pow(Math.tan(rad(eps / 2)), 2)
  var eqTime = 4 * deg(y * Math.sin(2 * rad(L0)) - 2 * e * Math.sin(rad(M)) + 4 * e * y * Math.sin(rad(M)) * Math.cos(2 * rad(L0))
    - 0.5 * y * y * Math.sin(4 * rad(L0)) - 1.25 * e * e * Math.sin(2 * rad(M)))
  var cosH = (Math.cos(rad(90.833)) - Math.sin(rad(latitude)) * Math.sin(rad(decl))) / (Math.cos(rad(latitude)) * Math.cos(rad(decl)))
  var solarNoon = 720 - 4 * longitude - eqTime + offsetMinutes
  if (cosH > 1) return { polar: "night", noon: solarNoon }
  if (cosH < -1) return { polar: "day", noon: solarNoon }
  var ha = deg(Math.acos(cosH))
  return { sunrise: solarNoon - 4 * ha, sunset: solarNoon + 4 * ha, noon: solarNoon }
}

// ---------------------------------------------------------------- the day's shape

// The two fades of a day, in minutes after local midnight: warming in the evening and cooling in the morning. Each
// is { start, end }; a fade of zero minutes switches at once. Null means no schedule: always on, off, or a polar
// day or night the sun mode cannot place.
function scheduleFor(settings, sun) {
  var F = settings.fadeMinutes
  if (settings.mode === "Sun") {
    if (!sun || sun.polar) return null
    var b = Math.min(settings.beforeSunset, F)
    return { evening: { start: sun.sunset - b, end: sun.sunset - b + F },
             morning: { start: sun.sunrise - (F - b), end: sun.sunrise + b } }
  }
  if (settings.mode === "Fixed times") {
    var on = parseClock(settings.warmFrom), off = parseClock(settings.warmUntil)
    if (on === null || off === null || on === off) return null
    return { evening: { start: on, end: on + F }, morning: { start: off - F, end: off } }
  }
  return null
}

// How far into the night a minute of the day is: 0 is full day, 1 full warmth. Fades are linear in time; the
// temperature curve below makes them even to the eye.
function warmthAt(minute, schedule) {
  var m = mod(minute, DAY_MINUTES)
  function inside(w) {
    var len = w.end - w.start
    if (len <= 0) return -1
    var into = mod(m - w.start, DAY_MINUTES)
    return into < len ? into / len : -1
  }
  var e = inside(schedule.evening)
  if (e >= 0) return e
  var r = inside(schedule.morning)
  if (r >= 0) return 1 - r
  // Outside both fades: night if the evening fade ended more recently than the morning one did.
  var sinceEvening = mod(m - schedule.evening.end, DAY_MINUTES)
  var sinceMorning = mod(m - schedule.morning.end, DAY_MINUTES)
  return sinceEvening < sinceMorning ? 1 : 0
}

// The temperature for a warmth, eased in mireds (a millionth of a kelvin's inverse), where equal steps look equal.
function temperatureFor(warmth, night) {
  var w = clamp(warmth, 0, 1)
  var mired = 1e6 / DAY_TEMPERATURE + (1e6 / night - 1e6 / DAY_TEMPERATURE) * w
  return Math.round(1e6 / mired / STEP_KELVIN) * STEP_KELVIN
}

// Late-night dimming: from dimFrom until the morning fade begins, eased in over a quarter of an hour.
function gammaAt(minute, settings, schedule) {
  if (!settings.dimLate) return 100
  var from = parseClock(settings.dimFrom)
  if (from === null) return 100
  var until = schedule ? schedule.morning.start : parseClock(settings.warmUntil)
  if (until === null) return 100
  var span = mod(until - from, DAY_MINUTES)
  var into = mod(minute - from, DAY_MINUTES)
  if (span === 0 || into >= span) return 100
  var ease = clamp(into / 15, 0, 1)
  return Math.round(100 - (100 - settings.dimPercent) * ease)
}

// ---------------------------------------------------------------- the moment

// The local midnight that starts the day holding `nowMs`, and that day's UTC offset in minutes.
function localDay(nowMs) {
  var d = new Date(nowMs)
  var start = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  return { start: start, minute: (nowMs - start) / MINUTE, offset: -d.getTimezoneOffset() }
}

// When, after `nowMs`, the schedule next starts or ends a fade (ms), searching today and the next two days.
// `which` limits it to "eveningStart", "morningEnd" or any edge.
function nextEdge(nowMs, settings, location, which) {
  for (var k = 0; k < 3; k++) {
    var day = localDay(nowMs + k * 24 * 60 * MINUTE)
    var sun = location ? sunTimes(day.start, location.latitude, location.longitude, day.offset) : null
    var s = scheduleFor(settings, sun)
    if (!s) continue
    var edges = []
    if (!which || which === "eveningStart") edges.push(s.evening.start)
    if (!which) edges.push(s.evening.end, s.morning.start)
    if (!which || which === "morningEnd") edges.push(s.morning.end)
    var best = null
    edges.forEach(function (m) {
      for (var shift = -1; shift <= 1; shift++) {
        var at = day.start + (m + shift * DAY_MINUTES) * MINUTE
        if (at > nowMs + 1000 && (best === null || at < best)) best = at
      }
    })
    if (best !== null) return best
  }
  return null
}

// What the screen should be at `nowMs`:
//   { temperature, gamma, identity, phase, warmth, until, reason }
// `ctx` carries what the service knows: location, override ({ kind: "off" | "warm" | "manual", temperature,
// until }), and paused (an app that wants true colour is in front).
function target(nowMs, settings, ctx) {
  var c = isObject(ctx) ? ctx : {}
  var day = localDay(nowMs)
  var sun = c.location ? sunTimes(day.start, c.location.latitude, c.location.longitude, day.offset) : null
  var schedule = scheduleFor(settings, sun)

  var warmth = 0
  var phase = "day"
  if (settings.mode === "Always on") { warmth = 1; phase = "night" }
  else if (settings.mode === "Off") { warmth = 0; phase = "off" }
  else if (settings.mode === "Sun" && sun && sun.polar) { warmth = sun.polar === "night" ? 1 : 0; phase = sun.polar === "night" ? "night" : "day" }
  else if (schedule) {
    warmth = warmthAt(day.minute, schedule)
    phase = warmth >= 1 ? "night" : warmth <= 0 ? "day" : (inFade(day.minute, schedule.evening) ? "evening" : "morning")
  } else if (settings.mode === "Sun") {
    phase = "nolocation"
  }
  var temperature = temperatureFor(warmth, settings.temperature)
  var gamma = settings.mode === "Off" ? 100 : gammaAt(day.minute, settings, schedule)
  var out = { temperature: temperature, gamma: gamma, identity: warmth <= 0 && gamma >= 100, phase: phase,
              warmth: warmth, until: null, reason: "schedule" }

  var o = c.override
  if (isObject(o) && typeof o.until === "number" && o.until > nowMs) {
    out.until = o.until
    if (o.kind === "off") {
      out.temperature = DAY_TEMPERATURE; out.gamma = 100; out.identity = true; out.warmth = 0; out.reason = "off"
    } else if (o.kind === "warm") {
      out.temperature = settings.temperature; out.identity = false; out.warmth = 1; out.reason = "warm"
    } else if (o.kind === "manual") {
      var t = clamp(num(o.temperature, DAY_TEMPERATURE), 1000, 20000)
      out.temperature = t; out.identity = t >= 6000; out.warmth = t >= 6000 ? 0 : 1; out.gamma = 100; out.reason = "manual"
    }
  }
  if (c.paused) {
    out.temperature = DAY_TEMPERATURE; out.gamma = 100; out.identity = true; out.reason = "paused"
  }
  return out
}

function inFade(minute, w) {
  var len = w.end - w.start
  return len > 0 && mod(minute - w.start, DAY_MINUTES) < len
}

// When to look again: soon during a fade, so the steps stay small, and otherwise at the next edge or in a minute.
function tickMs(t, settings) {
  if (t.phase === "evening" || t.phase === "morning") {
    var span = Math.abs(1e6 / settings.temperature - 1e6 / DAY_TEMPERATURE)
    // About 4 mireds a step (under the ~5 a viewer can just tell apart), never faster than every 5 seconds.
    var steps = Math.max(1, span / 4)
    return clamp(Math.floor(settings.fadeMinutes * MINUTE / steps), 5000, 60000)
  }
  return 60000
}

// ---------------------------------------------------------------- overrides and pauses

// "Off until morning": neutral until the next end of a morning fade.
function offUntilMorning(nowMs, settings, location) {
  var until = nextEdge(nowMs, settings, location, "morningEnd")
  return { kind: "off", until: until !== null ? until : nowMs + 12 * 60 * MINUTE }
}

function warmFor(nowMs, minutes) {
  return { kind: "warm", until: nowMs + clamp(minutes, 1, 24 * 60) * MINUTE }
}

// A temperature Dusk did not set (Omarchy's own toggle, a key binding, a script) is your choice until the
// schedule's next edge.
function manualOverride(nowMs, temperature, settings, location) {
  var until = nextEdge(nowMs, settings, location, "")
  return { kind: "manual", temperature: temperature, until: until !== null ? until : nowMs + 12 * 60 * MINUTE }
}

// Whether a reading of hyprsunset's temperature is something Dusk did not set. Readings are compared with what
// hyprsunset answered after Dusk's own last change, so identity reading back as 6000 is not mistaken for a flip.
function isForeign(reading, expected) {
  if (reading === null || expected === null || reading === undefined || expected === undefined) return false
  return Math.abs(reading - expected) > STEP_KELVIN
}

// Whether the app in front wants true colour: its class is in the list, or it is fullscreen and that counts.
function pausedFor(settings, appClass, fullscreen) {
  if (settings.mode === "Off") return false
  if (settings.pauseFullscreen && fullscreen) return true
  var cls = String(appClass || "").toLowerCase()
  if (!cls) return false
  return appList(settings.pauseApps).some(function (a) { return cls === a || cls.split(".").pop() === a })
}

function withPausedApp(settings, appClass, add) {
  var cls = String(appClass || "").toLowerCase()
  var list = appList(settings.pauseApps).filter(function (a) { return a !== cls })
  if (add && appList(cls).length === 1) list.push(cls)
  return Object.assign({}, settings, { pauseApps: appListText(list.slice(0, APPS_MAX)) })
}

// The temperature in hyprsunset's answer to `hyprctl hyprsunset temperature`, or null.
function readingFrom(output) {
  var m = /(\d{3,5})/.exec(String(output || "").slice(0, 200))
  return m ? Number(m[1]) : null
}

// ---------------------------------------------------------------- words

function describe(t, settings, location, nowMs) {
  if (t.reason === "paused") return "Paused for the app in front"
  if (t.reason === "off") return "Off until " + clockOf(t.until)
  if (t.reason === "warm") return "Warm until " + clockOf(t.until)
  if (t.reason === "manual") return (t.identity ? "Off" : t.temperature + " K") + " by hand until " + clockOf(t.until)
  if (t.phase === "off") return "Off"
  if (t.phase === "nolocation") return "Needs a location for the sun"
  if (settings.mode === "Always on") return "Always on"
  var next = nextEdge(nowMs, settings, location, t.phase === "night" || t.phase === "morning" ? "morningEnd" : "eveningStart")
  if (t.phase === "night") return "Warm until " + clockOf(next)
  if (t.phase === "evening") return "Warming up"
  if (t.phase === "morning") return "Cooling down"
  return "Warms at " + clockOf(next)
}

function clockOf(ms) {
  if (typeof ms !== "number") return "later"
  var d = new Date(ms)
  return clockText(d.getHours() * 60 + d.getMinutes())
}

// What a colour temperature looks like, as { r, g, b } from 0 to 1 (Tanner Helland's fit to the blackbody curve, good
// to the eye from 1000 K to 40000 K). The dial and the slider paint warmth in the colour it really is.
function kelvinColor(kelvin) {
  var t = clamp(kelvin, 1000, 40000) / 100
  var r, g, b
  if (t <= 66) {
    r = 255
    g = 99.4708025861 * Math.log(t) - 161.1195681661
    b = t <= 19 ? 0 : 138.5177312231 * Math.log(t - 10) - 305.0447927307
  } else {
    r = 329.698727446 * Math.pow(t - 60, -0.1332047592)
    g = 288.1221695283 * Math.pow(t - 60, -0.0755148492)
    b = 255
  }
  return { r: clamp(r, 0, 255) / 255, g: clamp(g, 0, 255) / 255, b: clamp(b, 0, 255) / 255 }
}

// The saved form of the settings, for shell.json.
function settingsPayload(s) {
  var r = readSettings(s)
  return { mode: r.mode, temperature: r.temperature, fadeMinutes: r.fadeMinutes, beforeSunset: r.beforeSunset,
           warmFrom: r.warmFrom, warmUntil: r.warmUntil, dimLate: r.dimLate, dimFrom: r.dimFrom, dimPercent: r.dimPercent,
           pauseApps: r.pauseApps, pauseFullscreen: r.pauseFullscreen, latitude: r.latitude, longitude: r.longitude }
}
