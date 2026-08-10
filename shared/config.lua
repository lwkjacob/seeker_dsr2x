--[[
    SEEKER DSR 2X - Configuration

    Two antennas, both running at the same time:
      Top row    = FRONT antenna
      Bottom row = REAR antenna
      Right side = PATROL SPEED (shared)

    Every setting below is safe to change unless it says otherwise.
]]

Config = {}

-- ── Keybinds ──────────────────────────────────────────────────────────────
-- Set any of these to '' to turn them off.

Config.defaultKeybind = 'F5'            -- open the radar remote / settings menu

Config.keybindLockFront = 'NUMPAD8'     -- lock / release the front (top) target
Config.keybindLockRear = 'NUMPAD2'      -- lock / release the rear (bottom) target

Config.keybindFastLockFront = 'NUMPAD9' -- lock / release the front FAST target
Config.keybindFastLockRear = 'NUMPAD3'  -- lock / release the rear FAST target

Config.keybindPlateLockFront = 'NUMPAD7' -- lock the front plate on the plate reader
Config.keybindPlateLockRear = 'NUMPAD1'  -- lock the rear plate on the plate reader

Config.keybindPower = ''                -- turn the radar on / off without opening the remote

-- ── Detection ─────────────────────────────────────────────────────────────

Config.speedUnit = 'mph'                -- 'mph' or 'kmh'

Config.antennaMaxDist = 1000.0          -- furthest a target can ever be picked up

-- How sensitive each lane is, 0.2 (tight) to 1.0 (wide). Lower these if the radar
-- picks up cars you would not expect it to.
Config.sameSensitivity = 0.6
Config.oppSensitivity = 0.6

-- Ignore targets more than this many metres above or below you (stops reads off
-- bridges and overpasses). Set to 0 to turn off.
Config.maxTargetVerticalDelta = 10.0

-- How far in front of your car the beam starts, in metres. Raise it if traffic
-- crossing your own hood gets picked up.
Config.radarRayForwardOffsetM = 2.75

-- Stricter line-of-sight check. Blocks more reads through walls, but can also miss
-- valid targets. Leave off unless you know you want it.
Config.strictShapeTestLos = false

-- ── Which car the TARGET window shows ─────────────────────────────────────
-- 'echo'      strongest return, like the real unit (recommended)
-- 'hybrid'    same, but favours cars straight ahead of you
-- 'boresight' closest and most centred car
-- 'strongest' biggest vehicle only
Config.targetPriority = 'echo'

-- Fine tuning for the modes above. Leave these alone unless you are chasing a
-- specific feel.
Config.radarRangeFalloff = 4            -- how quickly distance weakens a target
Config.radarBeamLateralSigmaM = 14.0    -- beam width; higher = picks up wider
Config.radarHybridLateralSigmaM = 7.0   -- beam width for 'hybrid' only

-- ── FAST window ───────────────────────────────────────────────────────────

Config.fastRequiresFasterThanTarget = true  -- FAST must be quicker than the main target
Config.fastRequiresStrongerPrimary = false  -- only show FAST behind a bigger, closer vehicle
Config.fastMaxDistanceBeyondPrimaryM = 70.0 -- ignore FAST cars further than this past the
                                            -- main target (0 = no limit)

-- Arrows stay dark until a car is closing or pulling away by at least this much,
-- so a car pacing you doesn't flicker.
Config.closingDeadbandMph = 1.5

-- ── Operator Menu defaults ────────────────────────────────────────────────
-- What the unit comes up holding. Operators can change all of these in-game with
-- the MENU key on the remote.

Config.defaultFasterDisplay = true      -- FAS   — show faster targets
Config.defaultOppSen = 4                -- OP SEn — opposite lane range, 0-4
Config.defaultSameSen = 3               -- SL SEn — same lane range, 0-4
Config.senRanges = { [0] = 0, [1] = 125, [2] = 250, [3] = 375, [4] = 500 } -- range per level

Config.defaultSquelch = true            -- SqL   — audio only while tracking a target
Config.patrolSpeedThresholds = { 5, 10, 20 }  -- PAt options
Config.defaultPatrolCutoff = 20         -- PAt   — slowest speed reported: below it the patrol
                                        --         window blanks and no target reads or locks

Config.defaultStopwatch = false         -- StO P — start up in stopwatch mode
Config.defaultStopwatchDistanceFt = 1320 -- stopwatch zone length in feet (max 9999)
Config.stopwatchFeetPerSecToMph = 0.682 -- stopwatch maths, don't change

Config.defaultAlertClosingSpeed = 30    -- ALE rt — rear traffic alert speed, mph
Config.defaultAntennaCount = 2          -- Ant   — 1 = front only, 2 = both

-- ── Master switches ───────────────────────────────────────────────────────
-- Turning one off also hides its step from the Operator Menu.

Config.optFasterEnable = true           -- faster target tracking at all
Config.optFastLock = true               -- allow locking a faster target
Config.optStopwatchEnable = true        -- stopwatch mode
Config.optVoiceEnunciator = true        -- spoken callouts on lock
Config.optTrafficAlert = true           -- rear traffic alert

-- ── Rear traffic alert ────────────────────────────────────────────────────
-- Warns you about a car coming up behind while you are pulling away.

Config.alertMinAccelMphPerSec = 1.5     -- only warns while you are accelerating
Config.alertRangeUnits = 90             -- how close the car has to be
Config.alertFlashMs = 400               -- flash / tone speed

-- ── Remote ────────────────────────────────────────────────────────────────

Config.holdThresholdMs = 500            -- how long to hold a key for its second function
Config.zonePairWindowMs = 1000          -- press OPP and SAME within this to select both

-- Menus stop the radar tracking, so it drops back to normal after this long with
-- no keypress. Nothing you changed is lost. Set to 0 to leave menus open forever.
Config.menuIdleTimeoutMs = 5000

-- FRONT / REAR lamps.
--   false = top row always says FRONT, bottom always says REAR (like the real unit)
--   true  = the lamp shows which side of your car the target is actually on
Config.rowIconFollowsTargetSide = false

-- How each antenna comes up when you switch the radar on.
Config.rowDefaults = {
    front = {
        xmit  = true,                   -- transmitting (false = HLd)
        hold  = false,
        zones = { same = false, opp = true },
    },
    rear = {
        xmit  = true,
        hold  = false,
        zones = { same = true, opp = false },
    },
}

-- ── Audio ─────────────────────────────────────────────────────────────────

-- The doppler tone rises with target speed, then stays flat above the cap so fast
-- cars don't turn into a shriek.
Config.dopplerPitchMin = 0.7
Config.dopplerPitchMax = 2.5
Config.dopplerPitchMaxSpeedMph = 100    -- speed the pitch stops climbing at

-- Volume rises with speed the same way.
Config.dopplerVolMin = 0.2
Config.dopplerVolMax = 1.0
Config.dopplerVolMaxSpeedMph = 150

-- In "stationary only" doppler mode, this counts as stopped.
Config.dopplerStationaryMaxMph = 2.0

-- Both antennas make noise at once, which is a mess through one speaker, so only
-- one feeds the tone: 'front', 'rear' or 'strongest'.
Config.dopplerSource = 'strongest'

-- Starting volumes. Aud is 0-4, the other two are 0-3. Aud switches automatically
-- between the moving and stationary values.
Config.defaultAudMoving = 3
Config.defaultAudStationary = 3
Config.defaultBeepLevel = 2             -- key beeps
Config.defaultVoiceLevel = 2            -- spoken callouts

Config.voiceEnunciator = true           -- speak the antenna, mode and direction on lock

-- ── Start-up and self test ────────────────────────────────────────────────

-- Switching on lights every lamp and puts 888 in all five windows for three seconds.
-- The full self test is not run on power-up; hold TEST on the remote for that.
Config.lampTestOnPowerUp = true

Config.autoSelfTest = false             -- run the full self test on a timer while transmitting
Config.autoSelfTestInterval = 600       -- how often, in seconds

-- ── Vehicles ──────────────────────────────────────────────────────────────

-- Which vehicle classes the radar works in. 18 = emergency.
Config.allowedVehicleClasses = { 18 }

-- ── On-screen positions ───────────────────────────────────────────────────
-- Only used the first time. After that your in-game position is remembered.
-- Move the radar with /seeker2x_move, the plate reader with /prmove2x, and the
-- remote by double-clicking its body (double-click again to stop).

Config.displayDefaults = {
    x = 0.72,                           -- 72% across the screen
    y = 0.74,                           -- 74% down the screen
    width = 480,
    height = 173,
    scale = 1.0,
}

Config.plateReaderDefaults = {
    x = 0.43,
    y = 0.03,
    width = 278,
    height = 101,
    scale = 1.0,
}

Config.remoteDefaults = {
    -- x = 0.43,
    -- y = 0.20,
    width = 300,
    scale = 1.0,
}

-- Keep driving while the remote is open. On: the mouse works the keypad but your
-- keyboard still drives, steers, and runs your sirens (shooting and the pause menu
-- are blocked so clicks don't misfire). Off: the remote takes the keyboard too.
Config.remoteKeepGameInput = true

-- ── Debug ─────────────────────────────────────────────────────────────────

Config.remoteDebug = false              -- show the remote button hitboxes
Config.detectionZoneDebug = false       -- draw the radar beams in the world
                                        -- (also /seeker2x_radar_debug in-game)

-- ── Saved settings ────────────────────────────────────────────────────────

-- Bring the antennas back up the way you left them.
-- On:  your XMIT/HLd, zones, MOV-STA and PS BLANK come back every time you switch
--      on, across power cycles and restarts alike.
-- Off: like the real unit — every power-on starts from the defaults above, except
--      the first one after a restart, which restores what you had.
-- Either way the Operator Menu, volumes and script options are always remembered,
-- the radar always starts switched off, and locks are never restored.
Config.rememberOperationalState = true

-- Storage keys. DO NOT EDIT UNLESS YOU KNOW WHAT YOU'RE DOING.
Config.kvpDisplay = 'seeker_dsr2x_display'
Config.kvpPlateDisplay = 'seeker_dsr2x_plate_display'
Config.kvpRemote = 'seeker_dsr2x_remote'
Config.kvpSettings = 'seeker_dsr2x_settings'

-- ── ALPR ──────────────────────────────────────────────────────────────────
-- Automatically reads the plates of cars around you and runs them through your
-- CAD. Only flagged vehicles raise an alert.

Config.alpr = {
    -- Which CAD to run plates through:
    --   'none'      off — plates are still read, just never run
    --   'cde'       CDE CAD (setup below)
    --   'imperial'  ImperialCAD (setup below)
    provider = 'none',

    radius       = 25.0,  -- how far around the car plates are read, in metres
    rescanDelay  = 300,   -- seconds before the same plate is read again
    scanInterval = 200,   -- ms between scans

    -- How long a result is reused before asking the CAD again, in minutes.
    -- Locking a plate always asks the CAD fresh, so this only affects background
    -- scanning. Probably shouldn't change.
    cacheMinutes = 60,

    -- Seconds before locking the same plate again asks the CAD fresh a second time.
    -- Probably shouldn't change.
    lockCooldown = 120,

    -- Most lookups one player can run per minute, so a unit sat in traffic can't
    -- flood your CAD. Anything over the cap is retried later, not lost.
    -- Set to 0 for no limit.
    maxQueriesPerMinute = 60,

    -- Posts every flagged hit to Discord. Leave empty to disable.
    discordWebhook     = '',
    discordWebhookName = 'ALPR System',
}

-- CDE CAD setup. There is nothing to fill in here — your credentials go in
-- server.cfg, and most communities already have these set from CDE's own resource:
--
--   set CDE_CAD_API_URL      "https://your-cdecad-instance.com/api"
--   set CDE_CAD_API_KEY      "fvm_your_api_key"    e  -- Admin Panel > FiveM Settings
--   set CDE_CAD_COMMUNITY_ID "your-discord-guild-id"
--
-- Alerts include warrants, BOLOs and dangerous/missing person flags on top of the
-- usual stolen, impound, registration and insurance checks.

-- ImperialCAD setup. Runs through the ImperialCAD resource, so make sure it's
-- started and your credentials (Admin Panel > Settings > API) are at the top of
-- server.cfg, above `ensure ImperialCAD`:
--
--   setr imperial_community_id "yourCommunityId"
--   set imperialAPI "yourApiKey"
--
-- ImperialCAD doesn't return the make/model/colour of a vehicle, so those alerts
-- show the plate and flags only. It has no impound field at all either, so impounds
-- can't be reported through this provider. What it does return on top of the usual
-- stolen / registration / insurance checks is the owner: a wanted owner raises a red
-- alert, and a revoked, expired or missing driver's licence raises a flag.
Config.imperialCad = {
    -- Only change this if you renamed the ImperialCAD resource folder.
    resourceName = 'ImperialCAD',
}
