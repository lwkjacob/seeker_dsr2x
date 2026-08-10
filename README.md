# SEEKER DSR 2X

![LWK Radar](nui/images/seeker_dsr2x_base)

A FiveM police radar modelled on the **STALKER DUAL DSR 2X**.

Two antennas run at the same time, each with its own windows — so a car closing from the
front and a car overtaking from behind are both tracked without switching antennas.

```
 SAME  ┌────────────┐  FRONT REAR  ┌────────────┐
 OPP   │   TARGET   │↑  FAST       │  FAST/LOCK │↑   ┌────────────┐
 XMIT  └────────────┘↓  LOCK       └────────────┘↓   │   PATROL   │   <- shared
 SAME  ┌────────────┐↑  FAST       ┌────────────┐↑   └────────────┘
 OPP   │   TARGET   │   LOCK       │  FAST/LOCK │
 XMIT  └────────────┘↓  REAR FRONT └────────────┘↓
```

* **Top row** — FRONT antenna
* **Bottom row** — REAR antenna
* **Right** — PATROL SPEED, shared by both rows

There's no ANT button, because neither antenna is ever "the active one". Zones, hold and
locks are set per row.

For anything not covered here, the real STALKER DSR 2X Operator's Manual applies — the unit
is built to follow it.

## Install

1. Install [ox_lib](https://github.com/overextended/ox_lib).
2. Drop this folder into your `resources` directory.
3. Add `ensure seeker_dsr2x` to `server.cfg`, after `ox_lib`.

The radar only appears for a player driving or riding shotgun in an emergency vehicle
(change with `Config.allowedVehicleClasses`).

Press **F5** to open the remote.

## The windows

* **TARGET (orange)** — the strongest car in that antenna's beam, live.
* **FAST/LOCK (red)** — either a car faster than the one in TARGET (FAST lamp), or a locked
  speed (LOCK lamp). A lock wins.
* **PATROL SPEED (green)** — your own speed.
* **Arrows** — which way the target is going:

| | Closing | Moving away |
| --- | --- | --- |
| FRONT antenna (top row) | ▼ | ▲ |
| REAR antenna (bottom row) | ▲ | ▼ |

A car pacing you lights neither arrow.

## Remote

**You can keep driving with the remote open.** It takes the mouse for the keypad but leaves
the keyboard alone, so WASD, the horn, sirens and your other keybinds still work. Shooting,
aiming and the pause menu are blocked so a click doesn't misfire. ESC or F5 closes it.

| Button | Press | Hold |
| --- | --- | --- |
| MOV/STA | Moving ⇄ stationary; START/STOP in Stopwatch Mode | — |
| OPP (per row) | Select the opposite lane; **once selected, Lk/Rel** | — |
| SAME (per row) | Select the same lane; **once selected, Lk/Rel** | — |
| HOLD (per row) | Put that antenna in and out of standby (HLd) | — |
| MENU | Step through the Operator Menu | Open the settings menu |
| VOLUME/TEST | Step through the volume settings | Run the self test |
| PS BLANK | Cycle patrol-speed blanking | — |

A hold is about half a second.

**You lock with the zone key you're already watching.** The first press selects that lane.
Once it's selected, that same key locks and releases the speed in that row's TARGET window —
so with a car in the top row on SAME, pressing SAME again locks it. Pressing a zone key also
wakes an antenna out of standby.

**MOV/STA switches itself**, like the newer heads — the mode is only ever "is the car
rolling", so the radar picks it. Pull away and it's in moving within a second; park and it
drops to stationary after about three. The key still works, it just gets overruled once the
car has disagreed with it for that long.

A mode that doesn't match the car measures nothing: parked in moving mode, or rolling in
stationary mode, the windows stay empty and nothing can be locked. It only lasts the couple
of seconds until the switch catches up.

* **Moving** — SAME and OPP are one or the other.
* **Stationary** — press both zone keys within a second for both directions at once. To go
  back to one, press HOLD then press the zone you want.
* In stationary mode the zones mean direction, not lanes: front OPP = closing, front SAME =
  away; rear SAME = closing, rear OPP = away.

**HLd** — press HOLD to put an antenna in standby. Its XMIT lamp goes out and `HLd` shows in
that row. Press HOLD again to bring it back.

**FAST Lk/Rel isn't on the remote** — the zone keys took that slot. It's still on
`NUMPAD9`/`NUMPAD3` and on `/seeker2x_fast_front` / `_rear`.

In any menu, the two centre keys become **up** and **down**, and any zone key exits.

**Moving things around** — double-click the remote body to move and scale it, double-click
again to finish. While the remote is open you can drag the radar head and plate reader too.

## Operator Menu

Press MENU to enter and to step; the centre keys change the value; stepping off the end exits.

| Setting | Shown | Range | Default |
| --- | --- | --- | --- |
| Faster display | `FAS` | On / Off | On |
| Opposite-lane range | `OP` `SEn` | 0–4 | 4 |
| Same-lane range | `SL` `SEn` | 0–4 | 3 |
| Audio squelch | `SqL` | On / Off | On |
| Low-end speed cutoff | `PAt` | `Lo5` / `L10` / `L20` | `L20` |
| Stopwatch | `StO` `P` | On / Off | Off |
| Rear traffic alert speed | `ALE` `rt` | 1–200 mph | 30 |
| Antenna count | `Ant` | 1–2 | 2 |

`SEn` is range, not gain — 0 turns that lane off entirely. The two lanes are set separately,
so a same-lane and an opposite-lane car can have different reach.

`PAt` is the slowest speed the radar will report, on the target and lock windows as well as
the patrol one. On `L20` nothing under 20 gets a number — the beam looks straight past the
car crawling in front of you and reads the one behind it instead. Drop it to `Lo5` if you
want slow traffic.

**A menu stops the radar measuring** while it's open — nothing is acquired and no lock can
fire. Existing locks are kept and come back when you exit.

Leaving the menu with `StO P` on drops you into Stopwatch Mode.

Hold MENU for the settings menu instead — display position, plate reader, speed unit and
doppler mode live there.

## VOLUME

Press VOLUME to enter and to step; the centre keys adjust; a fourth press exits.

| Setting | Shown | Range |
| --- | --- | --- |
| Doppler audio | `Aud` | 0–4 |
| Key beep | `bEE` `P` | 0–3 |
| Voice callouts | `UOI` `CE` | 0–3 |

`Aud` remembers a separate level for moving and stationary, and edits whichever you're in.
Zero silences that channel.

## Stopwatch Mode

Turn `StO P` on in the Operator Menu and exit. Set the distance with the centre keys (up to
9999 ft), then use MOV/STA as START and STOP as the car passes your two markers. A bad
reading shows `Err`. Any zone key leaves the mode.

## Rear Traffic Alert

Warns you about a car closing fast from behind: `ALE rt` flashes in the rear row and a horn
tone sounds. It works whatever the rear zones are set to, but only while you're accelerating,
and only at close range. It's off while the rear antenna is in standby.

## Audio

**Doppler** — a tone that tracks the TARGET window's speed, and nothing else. Your own speed
doesn't come into it: the same car sounds the same whether you're parked or doing seventy,
and both rows sound the same for the same reading. Only one row makes noise at a time
(`Config.dopplerSource`: `front`, `rear`, or `strongest`); cycle it in the settings menu. The
pitch stops climbing at 100 mph so fast cars don't shriek.

With squelch on (normal) you only hear it while a car is being tracked. Off, it runs all the
time, like an open beam on the real unit.

**Voice callouts** — on a lock the unit speaks the antenna, the mode and the direction.
`Front`, `Rear`, `Closing` and `Away` ship with the resource; `Stationary`, `Opposite` and
`Same` **do not** — drop your own into `nui/sounds/` for the full three-word phrase. Until
then you get the two-word version.

**Start-up** — switching on lights every lamp and puts `888` in all five windows for three
seconds, then the radar is working.

**Self test** — the full nine-second diagnostic, on demand by holding VOLUME/TEST. It isn't
run on power-up. The radar isn't measuring while it's up, and it ends with `PAS S`.

## PS BLANK

PS BLANK hides your patrol speed. With a lock standing it also steps through the patrol speed
that was captured at the front lock and at the rear lock.

## Plate reader

An optional overlay showing the plate each antenna is reading, with a freeze per side
(`/togglepr2x` to show or hide).

Set `Config.alpr.provider` to `'cde'` or `'imperial'` and every new plate is run through your
CAD automatically. Stolen, impounded, expired registration, no insurance and any other flag
your CAD returns raise an in-game alert, and can be posted to Discord.

ImperialCAD also reports on the owner — wanted, and whether their licence is revoked, expired
or missing — but returns no vehicle description and no impound field, so those alerts show
the plate, owner and flags only.

Results are cached so a unit sat in traffic doesn't hammer your CAD — but **locking a plate
always asks the CAD fresh**, so anything you're about to act on is current.

Your CAD credentials go in `server.cfg`, never in this resource. Setup instructions are in the
comments at the bottom of `shared/config.lua`.

## Commands

| Command | Effect |
| --- | --- |
| `/seeker_dsr2x_menu` | Open the remote (F5 by default) |
| `/seeker2x_settings` | Open the settings menu |
| `/seeker2x_power` | Turn the radar on / off |
| `/seeker2x_move` | Move and scale the radar head |
| `/prmove2x` | Move and scale the plate reader |
| `/togglepr2x` | Show / hide the plate reader |
| `/toggledoppler2x` | Cycle doppler audio mode |
| `/seeker2x_lock_front` / `_rear` | Lock / release a row |
| `/seeker2x_fast_front` / `_rear` | FAST lock / release a row |
| `/seeker2x_plate_lock_front` / `_rear` | Freeze a plate reader slot |
| `/alprlog2x` | Print the recent ALPR log |
| `/seeker2x_windows` | Line the digit windows up against the artwork |
| `/seeker2x_radar_debug` | Draw the radar beams in the world |

Default keybinds: `NUMPAD8`/`NUMPAD2` lock, `NUMPAD9`/`NUMPAD3` FAST lock,
`NUMPAD7`/`NUMPAD1` plate lock. All changeable in the config; set to `''` to unbind.

## What gets saved

Everything you set is remembered per player and comes back after a restart or rejoin: zones,
XMIT/HLd, MOV/STA, PS BLANK, the whole Operator Menu, volumes, stopwatch distance,
speed unit, plate reader and doppler. Display, plate reader and remote positions are saved too.

Four things don't come back, on purpose:

* **The power switch** — the radar always starts off, like walking up to a cold car.
* **Locks** — a locked speed belongs to a moment, not a session.
* **Live readings** — they're out of date the second you leave.
* **Where you were in a menu** — you come back in normal radar mode. The values you set are
  still there.

On the real unit a power-on throws your zones back to the factory positions. Here it doesn't
— switching on brings back the setup you were last running, every time. Set
`Config.rememberOperationalState = false` if you'd rather it behaved like the real thing;
even then the first switch-on after a restart still restores what you had, since every
session has to start with one.

## Calibrating the digit windows

`/seeker2x_windows` lets you line the five digit windows up against the radar artwork. Only
needed if you've replaced the artwork.

| Input | Effect |
| --- | --- |
| click | Select a window |
| drag | Move it |
| arrows | Nudge 0.1% (shift → 1%) |
| scroll | Digit size |
| shift + scroll | Box width |
| ctrl + scroll | Box height |
| alt + scroll | Letter spacing |
| `A` | Apply the selected size to all five |
| `R` | Reset the selected window |
| Show CSS | Print a paste-ready block |
| ESC | Exit |

Paste the exported block over the matching rules in `nui/style.css` to keep it. Everything is
stored as a percentage, so a calibration done at one size is right at every size.

## For developers

Client exports:

```lua
exports.seeker_dsr2x:GetRadarState()        -- full state, rows keyed front/rear
exports.seeker_dsr2x:GetRadarDetailedState()
exports.seeker_dsr2x:IsRadarActive()        -- on and at least one antenna transmitting
exports.seeker_dsr2x:IsRadarDisplayed()
exports.seeker_dsr2x:CanControlRadar()
exports.seeker_dsr2x:CanViewRadar()
```

Server exports:

```lua
exports.seeker_dsr2x:GetPlayerRadarState(source)
exports.seeker_dsr2x:IsPlayerRadarActive(source)
```

State is also on player state bags: `seekerDsr2xPower`, `seekerDsr2xFrontXmit`,
`seekerDsr2xRearXmit`, `seekerDsr2xFrontLocked`, `seekerDsr2xRearLocked`. These names are
distinct from `seeker_dual`'s, so both resources can run side by side.

## Credits

- **J. Dean (Dean Fleet Supply)** — Contributed valuable expertise on the radar's real-world operation, helping ensure a more accurate and authentic implementation. [Website](https://deanfleetsupply.com)

---

## Recommended Hosting

I recommend and personally use [RocketNode](https://rocketnode.us/lwkdev) for hosting your FiveM server running this resource. Use code **LWKDEV** for 25% off.

![LWK Dev](nui/images/LWK_DEV_BANNER_1.png)

---


## License

MIT License — see `LICENSE` for full text.

If redistributing modified versions, retain credits to the original inspirations and contributors listed above. Third-party assets remain under their respective licenses.
