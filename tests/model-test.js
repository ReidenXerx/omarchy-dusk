#!/usr/bin/env node
// Dusk's model: the sun, the day's shape, fades, overrides, pauses and settings. Runs in Kyiv's time zone so the
// clock change and real sunsets can be checked against known values.
process.env.TZ = "Europe/Kyiv"
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "shell", "DuskModel.js"), "utf8")
const box = {}
vm.runInNewContext(source + "\nthis.M = { DEFAULTS, readSettings, parseClock, clockText, appList, coordsFromWeather, " +
  "coordsFromZoneTab, zoneFromLink, chooseLocation, sunTimes, scheduleFor, warmthAt, temperatureFor, gammaAt, " +
  "localDay, wallTime, sunOf, nextEdge, target, tickMs, offUntilMorning, warmFor, manualOverride, isForeign, pausedFor, withPausedApp, " +
  "readingFrom, describe, settingsPayload, kelvinColor, centreWord }", box)
const M = box.M

let passed = 0
let failed = 0
function test(name, fn) {
  try { fn(); passed++ } catch (e) {
    failed++
    console.log("FAIL " + name + ": " + e.message + " @ " + String(e.stack).split(String.fromCharCode(10)).slice(1, 3).join(" | "))
  }
}
const plain = (v) => JSON.parse(JSON.stringify(v))
const eq = (a, b, msg) => (msg === undefined ? assert.deepStrictEqual(plain(a), plain(b)) : assert.deepStrictEqual(plain(a), plain(b), msg))
const near = (a, b, tol, msg) => assert(Math.abs(a - b) <= tol, (msg || "") + " " + a + " not within " + tol + " of " + b)
const at = (y, mo, d, h, mi) => new Date(y, mo - 1, d, h, mi || 0).getTime()
const ternopil = { latitude: 49.553, longitude: 25.594, name: "Ternopil", source: "test" }
const kyivTab = "# comment\nUA\t+5026+03031\tEurope/Kyiv\tmost of Ukraine\nNO,SJ\t+5955+01045\tEurope/Oslo\nUS\t+404251-0740023\tAmerica/New_York\tEastern (most areas)\n"
const sun = (y, mo, d, loc) => M.sunOf(M.localDay(at(y, mo, d, 12)), loc)

test("sunrise and sunset in Ternopil match the almanac, across the clock change", () => {
  const oct16 = sun(2026, 10, 16, ternopil)
  near(oct16.sunrise, 7 * 60 + 40, 3, "16 Oct sunrise")
  near(oct16.sunset, 18 * 60 + 26, 3, "16 Oct sunset")
  // Summer time ends on 25 Oct 2026: the clock reads an hour earlier for the same sun.
  const oct26 = sun(2026, 10, 26, ternopil)
  near(oct26.sunrise, 6 * 60 + 56, 3, "26 Oct sunrise")
  near(oct26.sunset, 17 * 60 + 7, 3, "26 Oct sunset")
  eq([M.localDay(at(2026, 10, 16, 12)).offset, M.localDay(at(2026, 10, 26, 12)).offset], [180, 120])
})

test("the day the clocks change is read by the clock on the wall", () => {
  // 25 Oct 2026, Kyiv: 04:00 summer time became 03:00 winter time.
  const fixed = M.readSettings({ mode: "Fixed times", warmFrom: "21:00", warmUntil: "07:00", fadeMinutes: 0 })
  eq(M.target(at(2026, 10, 25, 20, 30), fixed, {}).phase, "day", "20:30 is before 21:00, whatever happened at 4 a.m.")
  eq(M.target(at(2026, 10, 25, 21, 1), fixed, {}).phase, "night")
  eq(M.target(at(2026, 3, 29, 21, 30), fixed, {}).phase, "night", "spring forward too")
  const day = M.localDay(at(2026, 10, 25, 20, 30))
  eq([day.minute, day.offset], [20 * 60 + 30, 120])
  const sunDay = sun(2026, 10, 25, ternopil)
  near(sunDay.sunset, 17 * 60 + 9, 3, "25 Oct sunset in winter time")
  const s = M.readSettings({})
  const fadeStart = new Date(M.nextEdge(at(2026, 10, 25, 12), s, ternopil, "eveningStart"))
  eq(fadeStart.getHours() * 60 + fadeStart.getMinutes(), Math.round(sunDay.sunset - 30))
  const morning = new Date(M.offUntilMorning(at(2026, 10, 24, 23), s, ternopil).until)
  eq([morning.getDate(), morning.getHours()], [25, 7], "off until morning across the change ends by the new clock")
})

test("midsummer in Kyiv, and polar day and night in Tromsø", () => {
  const kyiv = { latitude: 50.45, longitude: 30.52 }
  const june = sun(2026, 6, 21, kyiv)
  near(june.sunrise, 4 * 60 + 47, 4, "Kyiv June sunrise")
  near(june.sunset, 21 * 60 + 13, 4, "Kyiv June sunset")
  const tromso = { latitude: 69.65, longitude: 18.96 }
  eq(sun(2026, 12, 21, tromso).polar, "night")
  eq(sun(2026, 6, 21, tromso).polar, "day")
  const s = M.readSettings({})
  eq(M.target(at(2026, 12, 21, 13), s, { location: tromso }).phase, "night")
  eq(M.target(at(2026, 6, 21, 1), s, { location: tromso }).identity, true)
})

test("where you are: typed coordinates, then the weather setting, then the time zone", () => {
  const zone = M.coordsFromZoneTab(kyivTab, "Europe/Kyiv")
  near(zone.latitude, 50.4333, 0.001); near(zone.longitude, 30.5167, 0.001)
  eq(zone.name, "Kyiv")
  const ny = M.coordsFromZoneTab(kyivTab, "America/New_York")
  near(ny.latitude, 40.7142, 0.001); near(ny.longitude, -74.0064, 0.001)
  eq(M.coordsFromZoneTab(kyivTab, "Mars/Olympus"), null)
  eq(M.coordsFromZoneTab("x".repeat(70000), "Europe/Kyiv"), null, "bounded")
  eq(M.zoneFromLink("/usr/share/zoneinfo/Europe/Kyiv"), "Europe/Kyiv")
  eq(M.zoneFromLink("../usr/share/zoneinfo/America/Argentina/Buenos_Aires\n"), "America/Argentina/Buenos_Aires")
  eq(M.zoneFromLink("/etc/passwd"), "")
  const weather = M.coordsFromWeather(JSON.stringify({ name: "Ternopil", latitude: 49.55, longitude: 25.59 }))
  eq(weather.source, "weather")
  eq(M.coordsFromWeather("{\"latitude\": 91, \"longitude\": 0}"), null)
  eq(M.coordsFromWeather("not json"), null)
  const typed = M.readSettings({ latitude: "48.5", longitude: "35" })
  eq(M.chooseLocation(typed, weather, zone).source, "settings")
  eq(M.chooseLocation(M.readSettings({}), weather, zone).source, "weather")
  eq(M.chooseLocation(M.readSettings({}), null, zone).source, "time zone")
  eq(M.chooseLocation(M.readSettings({ latitude: "48.5" }), null, null), null, "half a location is none")
})

test("every time zone finds a city, from zone1970.tab or the older zone.tab", () => {
  const new_ = fs.readFileSync("/usr/share/zoneinfo/zone1970.tab", "utf8")
  const old = fs.readFileSync("/usr/share/zoneinfo/zone.tab", "utf8")
  const find = (z) => M.coordsFromZoneTab(new_, z) || M.coordsFromZoneTab(old, z)
  for (const z of ["Europe/Kyiv", "Europe/Stockholm", "Europe/Amsterdam", "Europe/Oslo", "Asia/Kuala_Lumpur", "America/New_York"])
    assert(find(z), z)
  near(find("Europe/Stockholm").latitude, 59.33, 0.05)
})

test("settings are checked and clamped", () => {
  const s = M.readSettings({ mode: "Moon", temperature: 900, fadeMinutes: -5, warmFrom: "25:00", dimPercent: 10,
                             pauseApps: "cs2, GIMP ,, ../../etc, " + "x".repeat(80), latitude: "abc" })
  eq([s.mode, s.temperature, s.fadeMinutes, s.warmFrom, s.dimPercent], ["Sun", 2500, 0, "21:00", 50])
  eq(s.pauseApps, "cs2, gimp")
  eq(s.latitude, "")
  eq(M.readSettings({ temperature: 3456 }).temperature, 3500, "to the hundred")
  eq(M.readSettings({ temperature: 9000 }).temperature, 6000)
  eq(M.readSettings(null), M.readSettings({}))
  eq(M.settingsPayload({ mode: "Always on", extra: 1 }).mode, "Always on")
  assert(!("extra" in M.settingsPayload({ extra: 1 })))
})

test("the sun schedule fades in around sunset and out around sunrise", () => {
  const s = M.readSettings({})       // 40-minute fades, starting 30 minutes before sunset
  const sch = M.scheduleFor(s, { sunrise: 460, sunset: 1106 })
  eq(sch, { evening: { start: 1076, end: 1116 }, morning: { start: 450, end: 490 } })
  eq(M.warmthAt(12 * 60, sch), 0, "noon")
  eq(M.warmthAt(0, sch), 1, "midnight")
  eq(M.warmthAt(1096, sch), 0.5, "half way into the evening fade")
  eq(M.warmthAt(470, sch), 0.5, "half way out in the morning")
  eq(M.warmthAt(1116, sch), 1, "fully warm when the fade ends")
  eq(M.warmthAt(490, sch), 0, "fully day when the morning fade ends")
})

test("fixed times wrap midnight either way, and a zero fade switches at once", () => {
  const s = M.readSettings({ mode: "Fixed times", warmFrom: "21:00", warmUntil: "07:00", fadeMinutes: 0 })
  const sch = M.scheduleFor(s, null)
  eq([M.warmthAt(20 * 60 + 59, sch), M.warmthAt(21 * 60, sch), M.warmthAt(3 * 60, sch), M.warmthAt(7 * 60, sch)], [0, 1, 1, 0])
  const late = M.scheduleFor(M.readSettings({ mode: "Fixed times", warmFrom: "02:00", warmUntil: "05:00", fadeMinutes: 20 }), null)
  eq([M.warmthAt(60, late), M.warmthAt(130, late), M.warmthAt(150, late), M.warmthAt(290, late), M.warmthAt(301, late)], [0, 0.5, 1, 0.5, 0])
  eq(M.scheduleFor(M.readSettings({ mode: "Fixed times", warmFrom: "07:00", warmUntil: "07:00" }), null), null)
})

test("temperature eases evenly to the eye, and stays on round numbers", () => {
  eq(M.temperatureFor(0, 3400), 6500)
  eq(M.temperatureFor(1, 3400), 3400)
  eq(M.temperatureFor(0.5, 3400), 4460, "the mired midpoint, not the kelvin one (4950)")
  eq(M.temperatureFor(2, 3400), 3400, "clamped")
})

test("what the screen should be: day, a fade, night, and the words for each", () => {
  const s = M.readSettings({})
  const ctx = { location: ternopil }
  const noon = M.target(at(2026, 10, 16, 12), s, ctx)
  eq([noon.phase, noon.identity, noon.temperature, noon.gamma], ["day", true, 6500, 100])
  eq(M.describe(noon, s, ternopil, at(2026, 10, 16, 12)).slice(0, 9), "Warms at ")
  const night = M.target(at(2026, 10, 16, 23), s, ctx)
  eq([night.phase, night.identity, night.temperature], ["night", false, 3400])
  assert(/^Warm until 0[78]:\d\d$/.test(M.describe(night, s, ternopil, at(2026, 10, 16, 23))))
  const fading = M.target(at(2026, 10, 16, 18, 15), s, ctx)
  eq(fading.phase, "evening")
  assert(fading.temperature < 6500 && fading.temperature > 3400)
  const steady = M.tickMs(noon, s)
  eq(steady, 60000)
  assert(M.tickMs(fading, M.readSettings({ fadeMinutes: 5 })) < 15000, "short fades step faster")
  eq(M.target(at(2026, 10, 16, 23), M.readSettings({ mode: "Off" }), ctx).identity, true)
  eq(M.target(at(2026, 10, 16, 12), M.readSettings({ mode: "Always on", temperature: 2700 }), ctx).temperature, 2700)
  eq(M.target(at(2026, 10, 16, 23), s, {}).phase, "nolocation", "the sun mode with nowhere to put the sun")
})

test("late dimming eases in after its hour and ends when the morning fade begins", () => {
  const s = M.readSettings({ dimLate: true, dimFrom: "23:30", dimPercent: 70 })
  const ctx = { location: ternopil }
  eq(M.target(at(2026, 10, 16, 23, 0), s, ctx).gamma, 100)
  eq(M.target(at(2026, 10, 16, 23, 45), s, ctx).gamma, 70)
  eq(M.target(at(2026, 10, 17, 3, 0), s, ctx).gamma, 70)
  eq(M.target(at(2026, 10, 17, 12, 0), s, ctx).gamma, 100)
  eq(M.target(at(2026, 10, 17, 3, 0), s, ctx).identity, false)
})

test("overrides: off until morning, warm for an hour, a flip by hand; each ends on its own", () => {
  const s = M.readSettings({})
  const ctx = { location: ternopil }
  const now = at(2026, 10, 16, 22)
  const off = M.offUntilMorning(now, s, ternopil)
  const morning = new Date(off.until)
  eq([morning.getDate(), morning.getHours()], [17, 8], "until the end of tomorrow's morning fade")
  eq(M.target(now, s, Object.assign({ override: off }, ctx)).identity, true)
  eq(M.target(off.until + 60000, s, Object.assign({ override: off }, ctx)).reason, "schedule", "it lapses")
  const warm = M.warmFor(at(2026, 10, 16, 12), 60)
  eq(M.target(at(2026, 10, 16, 12, 30), s, Object.assign({ override: warm }, ctx)).temperature, 3400)
  eq(M.target(at(2026, 10, 16, 13, 1), s, Object.assign({ override: warm }, ctx)).identity, true)
  const hand = M.manualOverride(at(2026, 10, 16, 15), 4000, s, ternopil)
  const handEnds = new Date(hand.until)
  eq([handEnds.getDate(), handEnds.getHours()], [16, 17], "until the evening fade starts (17:56)")
  eq(M.target(at(2026, 10, 16, 16), s, Object.assign({ override: hand }, ctx)).temperature, 4000)
  assert(/by hand until 17:5\d/.test(M.describe(M.target(at(2026, 10, 16, 16), s, Object.assign({ override: hand }, ctx)), s, ternopil, 0)))
})

test("night stays night on the dial and the bar when something else is in charge", () => {
  const s = M.readSettings({})
  const ctx = { location: ternopil }
  const now = at(2026, 10, 16, 1, 27)
  const off = M.target(now, s, Object.assign({ override: M.offUntilMorning(now, s, ternopil) }, ctx))
  eq([off.identity, off.scheduleWarmth, M.centreWord(off)], [true, 1, "Off"])
  eq(M.centreWord(M.target(now, s, Object.assign({ paused: true }, ctx))), "Paused")
  eq(M.centreWord(M.target(at(2026, 10, 16, 12), s, ctx)), "Day")
  eq(M.centreWord(M.target(now, s, ctx)), "3400 K")
  eq(M.target(at(2026, 10, 16, 12), s, Object.assign({ override: M.warmFor(at(2026, 10, 16, 12), 60) }, ctx)).scheduleWarmth, 0)
})

test("a flip by hand is told apart from Dusk's own setting", () => {
  eq(M.isForeign(4000, 6000), true)
  eq(M.isForeign(6000, 6000), false)
  eq(M.isForeign(3405, 3400), false, "rounding is not a flip")
  eq(M.isForeign(null, 3400), false)
  eq(M.readingFrom("4000\n"), 4000)
  eq(M.readingFrom("Temperature: 6000 K"), 6000)
  eq(M.readingFrom("couldn't connect"), null)
})

test("pausing for the app in front", () => {
  const s = M.readSettings({ pauseApps: "cs2, gimp" })
  eq(M.pausedFor(s, "cs2", false), true)
  eq(M.pausedFor(s, "org.gimp.GIMP", false), true, "the last part of a reverse-DNS class")
  eq(M.pausedFor(s, "firefox", true), false)
  eq(M.pausedFor(M.readSettings({ pauseFullscreen: true }), "firefox", true), true)
  eq(M.pausedFor(M.readSettings({ mode: "Off", pauseApps: "cs2" }), "cs2", false), false)
  eq(M.target(at(2026, 10, 16, 23), s, { location: ternopil, paused: true }).identity, true)
  eq(M.withPausedApp(s, "Darktable", true).pauseApps, "cs2, gimp, darktable")
  eq(M.withPausedApp(s, "cs2", false).pauseApps, "gimp")
  eq(M.withPausedApp(s, "bad;name", true).pauseApps, "cs2, gimp", "only plain names are kept")
})

test("warmth is painted in the colour it really is", () => {
  const candle = M.kelvinColor(2700), day = M.kelvinColor(6500)
  eq(candle.r, 1)
  assert(candle.b < 0.65 && candle.g < 0.75, "2700 K is orange")
  assert(day.r > 0.99 && day.b > 0.97, "6500 K is near white")
  assert(M.kelvinColor(3400).b > candle.b, "warmer is less blue")
  eq(M.kelvinColor(-5), M.kelvinColor(1000), "clamped")
})

console.log(passed + " passed, " + failed + " failed")
process.exit(failed ? 1 : 0)
