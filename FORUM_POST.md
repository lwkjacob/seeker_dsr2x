# SEEKER DSR 2X — Dual-Antenna Police Radar with ALPR

> **Suggested title:** `[FREE][STANDALONE] SEEKER DSR 2X — Dual Antenna Police Radar (Front + Rear at once, Doppler audio, ALPR/CAD)`
>
> **Tags to set:** `script` `free` `standalone` `ox` — add `escrow` **only** if you actually ship it through Asset Escrow.
>
> Everything in `[[ double brackets ]]` below is a placeholder you need to fill or delete before posting.

---

![preview|690x230]([[UPLOAD seeker_dsr2x_base.png HERE — this first image becomes the category preview thumbnail]])

<p align="center">
  <a href="[[YOUTUBE DEMO URL]]"><strong>▶ Video Demo</strong></a> &nbsp;•&nbsp;
  <a href="[[GITHUB REPO URL]]"><strong>⬇ Download (GitHub)</strong></a> &nbsp;•&nbsp;
  <a href="[[DISCORD INVITE]]"><strong>💬 Support</strong></a>
</p>

---

## OVERVIEW

A police radar for FiveM modelled on the **STALKER DUAL DSR 2X**, built to follow the real
unit's operator manual rather than approximate it.

The thing that makes a dual unit a dual unit: **both antennas run at the same time.** A car
closing on you from the front and a car overtaking from behind each get their own TARGET
window, their own FAST/LOCK window, their own zone selection and their own lock — no
switching between antennas, no ANT key, nothing to miss while you're looking the other way.
Patrol speed is shared, exactly like the hardware.

```
 SAME  ┌────────────┐  FRONT REAR  ┌────────────┐
 OPP   │   TARGET   │↑  FAST       │  FAST/LOCK │↑   ┌────────────┐
 XMIT  └────────────┘↓  LOCK       └────────────┘↓   │   PATROL   │  <- shared
 SAME  ┌────────────┐↑  FAST       ┌────────────┐↑   └────────────┘
 OPP   │   TARGET   │   LOCK       │  FAST/LOCK │
 XMIT  └────────────┘↓  REAR FRONT └────────────┘↓
```

Top row is the FRONT antenna, bottom row is the REAR, and the green window on the right is
your own speed.

---

## FEATURES

🚦 **Two antennas, live at once** — independent zones, standby, targets, FAST and locks per
row. Lock the front while the rear is still tracking.

📡 **Real beam geometry** — five parallel raycasts per sweep, split into same-lane and
opposite-lane paths. Targets are ranked by a received-power model (radar cross-section over
range, with a Gaussian beam falloff), so the strongest return wins the window — not just the
nearest or the fastest car.

🎚 **The full Operator Menu** — `FAS`, `OP SEn` / `SL SEn` (separate range for each lane, 0–4),
`SqL` squelch, `PAt` low-end cutoff (`Lo5`/`L10`/`L20`), `StO P`, `ALE rt`, `Ant`. Same
three-character segment readout as the real head.

🔊 **Doppler audio that behaves** — a Web Audio tone tracking the TARGET window's speed and
nothing else. Your own speed doesn't colour it: the same car sounds the same parked or doing
seventy. Squelch on, you hear it only while tracking; off, it's an open beam.

🗣 **Voice callouts on a lock** — antenna, mode and direction ("Front — Stationary — Closing").

🔁 **MOV/STA switches itself** — like the newer heads. Pull away and it's in moving inside a
second; park and it drops to stationary after about three. A mode that doesn't match the car
measures nothing, so you can't fake a reading you couldn't have taken.

⏱ **Stopwatch Mode** — set a distance up to 9999 ft, START/STOP on your two markers, `Err` on
a bad run.

⚠️ **Rear Traffic Alert** — flashing `ALE rt` and a horn tone for a car closing hard from
behind, at your chosen threshold.

🔎 **Plate reader + ALPR** — an optional overlay showing the plate each antenna is reading,
with a freeze per side. Point `Config.alpr.provider` at **CDE** or **ImperialCAD** and every
new plate runs through your CAD: stolen, impounded, expired registration, no insurance,
wanted owner, revoked licence — in-game alerts plus optional Discord webhook. Results are
cached so a unit sat in traffic doesn't hammer your CAD, but **locking a plate always asks
fresh**, so anything you're about to act on is current.

🖱 **You can keep driving with the remote open.** It takes the mouse for the keypad and leaves
the keyboard alone — WASD, horn, sirens and your other binds all still work. Shooting, aiming
and the pause menu are blocked so a click can't misfire.

💾 **Everything persists per player** — zones, XMIT/HLd, MOV/STA, PS BLANK, the whole Operator
Menu, volumes, stopwatch distance, speed unit, plate reader, doppler, and the on-screen
position and scale of the head, remote and plate reader. Locks and the power switch
deliberately don't: the unit always comes up dark, like walking to a cold car.

🧰 **Exports and state bags** for your own scripts (see below).

---

## PREVIEW

**Radar head**
![radar head|690x230]([[UPLOAD seeker_dsr2x_base.png]])

**Remote**
![remote|332x612]([[UPLOAD seeker_dsr2x_remote.png]])

[[ADD 2–4 IN-GAME SCREENSHOTS — see the shot list I gave you. A short video is worth more than
all of them: the rules explicitly prefer a demo video, and the dual-window behaviour and the
doppler audio are the two things a still image cannot show.]]

---

## REQUIREMENTS

* [ox_lib](https://github.com/overextended/ox_lib)
* No framework required — **standalone**. Works alongside ESX / QBCore / Qbox / ND without a bridge.
* Optional: a CAD with a plate-lookup API (CDE or ImperialCAD) for the ALPR features.

The radar only appears for a player driving or riding shotgun in an emergency vehicle
(`Config.allowedVehicleClasses`).

---

## INSTALL

```cfg
ensure ox_lib
ensure seeker_dsr2x
```

Drop the folder in `resources`, add the lines above to `server.cfg` in that order, restart.
Press **F5** for the remote. That's it — no SQL, no framework config, no exports to wire up.

CAD credentials go in `server.cfg` as convars, never in the resource. Setup notes are in the
comments at the bottom of `shared/config.lua`.

---

## USING IT

| Button | Press | Hold |
| --- | --- | --- |
| MOV/STA | Moving ⇄ stationary; START/STOP in Stopwatch Mode | — |
| OPP *(per row)* | Select the opposite lane; **once selected, Lk/Rel** | — |
| SAME *(per row)* | Select the same lane; **once selected, Lk/Rel** | — |
| HOLD *(per row)* | Put that antenna in and out of standby (`HLd`) | — |
| MENU | Step through the Operator Menu | Open the script settings |
| VOLUME/TEST | Step through the volume settings | Run the self test |
| PS BLANK | Cycle patrol-speed blanking | — |

**You lock with the zone key you're already watching.** First press selects that lane; once
selected, the same key locks and releases the speed in that row's TARGET window. Car in the
top row on SAME? Press SAME again and it's locked.

Default binds: `NUMPAD8`/`NUMPAD2` lock, `NUMPAD9`/`NUMPAD3` FAST lock, `NUMPAD7`/`NUMPAD1`
plate lock — all rebindable, or set to `''` to unbind. There are commands for every one of
them if you'd rather use a keybind manager.

Double-click the remote body to move and scale it. While it's open you can drag the radar
head and the plate reader too. Positions are saved.

---

## FOR DEVELOPERS

```lua
-- client
exports.seeker_dsr2x:GetRadarState()          -- full state, rows keyed front/rear
exports.seeker_dsr2x:GetRadarDetailedState()
exports.seeker_dsr2x:IsRadarActive()          -- on, and at least one antenna transmitting
exports.seeker_dsr2x:IsRadarDisplayed()
exports.seeker_dsr2x:CanControlRadar()
exports.seeker_dsr2x:CanViewRadar()

-- server
exports.seeker_dsr2x:GetPlayerRadarState(source)
exports.seeker_dsr2x:IsPlayerRadarActive(source)
```

State is also mirrored onto player state bags: `seekerDsr2xPower`, `seekerDsr2xFrontXmit`,
`seekerDsr2xRearXmit`, `seekerDsr2xFrontLocked`, `seekerDsr2xRearLocked`.

---

## PERFORMANCE

| | |
| --- | --- |
| Idle (radar off) | `[[X.XX ms — measure with resmon 1]]` |
| Radar on, both antennas transmitting | `[[X.XX ms]]` |
| Remote open | `[[X.XX ms]]` |
| Resource size | 7.1 MB total (4.1 MB of that is audio, 85 KB stream assets) |

Detection runs one shared raycast pass per tick for both antennas rather than one per row,
and the NUI is only updated when a value actually changes.

[[REPLACE THE PLACEHOLDERS WITH REAL resmon NUMBERS BEFORE POSTING. Do not guess them —
posting made-up performance figures is the fastest way to get picked apart in the replies.]]

---

## DOWNLOAD

**[[GITHUB REPO URL]]**

Free and open source under the MIT licence. The rules require a free release to be
immediately available via a public git repo, a direct forum upload, or a free Tebex package —
so this link has to be live before you post.

---

## CREDITS

* **J. Dean — [Dean Fleet Supply](https://deanfleetsupply.com)** — contributed real-world
  expertise on how the unit actually operates, which is most of the reason the behaviour is
  right rather than merely plausible.

Third-party assets remain under their respective licences.

---

## SUPPORT

Issues and feature requests: [[GITHUB ISSUES URL]]
Discord: [[INVITE — support only; the rules allow Discord links for support, not for delivery]]

---

| Code Information | |
| --- | --- |
| Code is accessible | Yes |
| Subscription-based | No |
| Lines (approximately) | ~6,900 |
| Requirements | ox_lib |
| Support | Yes |
