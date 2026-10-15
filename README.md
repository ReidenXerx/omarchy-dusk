# Dusk

A night light for [Omarchy](https://omarchy.org) that follows the sun. Dusk warms
the screen from your real sunset and cools it again at sunrise, fading so slowly
that you never see the change happen, and it gets out of the way when an app
needs true colour.

Omarchy already has a night light: one key that flips the screen between 4000 K
and 6500 K. Dusk is the rest of it, built on the same `hyprsunset`.

## What only Dusk does

- **It follows the sun where you are.** Sunrise and sunset are worked out on
  your laptop with NOAA's solar equations, from Omarchy's weather location or,
  without one, your time zone's main city (from tzdata). No account, no network.
  The times move with the seasons and the clock change by themselves.
- **You never see the switch.** The colour moves in steps of about 4 mireds,
  under what the eye can tell apart, over 40 minutes by default, eased so equal
  steps look equal. The room just seems to get cosier.
- **It steps aside.** Name the apps that need true colour (a game, a photo
  editor), or every fullscreen app, and the screen goes neutral while one is in
  front, then warms again when you leave it.
- **It respects your hand on the switch.** Press Omarchy's own night light key
  and Dusk takes that as your choice until the schedule's next edge, instead of
  fighting you. A dot on its bar icon shows when something other than the
  schedule is in charge.
- **Darker than the panel goes.** Late dimming lowers brightness below the
  screen's own minimum for the small hours, eased in over a quarter of an hour.

## Using it

The icon is a sun by day, a setting sun while it fades, and a moon at night.

| Do this | And |
|---|---|
| **Click the icon** | The panel: the night on a 24-hour dial, temperature, schedule, dimming and the apps it steps aside for |
| **Right click the icon** | Off until morning, or, when something else is in charge, back to the schedule |
| **Off until morning** | Neutral now, warm again at the next sunset |
| **Warm for 1 h** | Evening colour now, then back to the schedule |
| **Add the app in front** | Neutral whenever that app is focused |

Everything in the panel is also in the widget's settings in Shell Settings,
including a latitude and longitude for when the automatic location is wrong.

## Install

```bash
omarchy plugin add https://github.com/ReidenXerx/omarchy-dusk.git --enable
```

Then add the Dusk widget to your bar and restart the shell with
`omarchy-restart-shell`.

Omarchy's own night light icon lives in the indicators widget. To leave only
Dusk's, open that widget's settings and take NightLight out of its items; the
night light key keeps working either way.

## Remove

```bash
omarchy plugin remove reidenxerx.dusk
```

The screen keeps the colour it had at that moment; `hyprctl hyprsunset identity`
puts it back to neutral, or Omarchy's own night light key takes over from there.

## Requirements

Omarchy's Quickshell-based shell and `hyprsunset`, which Omarchy ships. Dusk
starts `hyprsunset` itself if it is not running.

## How it decides

The schedule is a pure function of the time, your settings and your location
(`shell/DuskModel.js`, tested with node: `node tests/model-test.js`). Dusk looks
once a minute, or every few seconds during a fade, and writes only through
`hyprctl hyprsunset`. It notices a temperature it did not set by comparing what
`hyprsunset` reports with what it reported after Dusk's own last change, and it
ignores the fixed-time switches in `hyprsunset.conf`, which are not you.

## Licence

MIT

## Support

Dusk is free and always will be. If it earns a place on your bar, you can
support its development at [donatello.to/DuduPhudu](https://donatello.to/DuduPhudu).
