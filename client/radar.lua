--[[
    SEEKER DSR 2X - Radar core logic
    Vehicle detection, dual-row state management, menu, NUI updates

    The 2X runs BOTH antennas at once. Everything that was a single global on the
    DUAL DSR (zone selection, XMIT, lock, FAST) is per-row here:

        Radar.rows.front  -> top row     (front antenna)
        Radar.rows.rear   -> bottom row  (rear antenna)

    Each row drives one orange TARGET window, one red LOCK/FAST window, its own
    SAME / OPP / XMIT / FAST / LOCK lamps and its own two pairs of arrows. Patrol
    speed is shared.
]]

--- Builds a fresh runtime row from Config.rowDefaults.
local function newRow(defaults)
    local d = Utils.DeepCopy(defaults or {})
    return {
        xmit  = d.xmit ~= false,
        hold  = d.hold == true,
        zones = { same = (d.zones and d.zones.same) == true, opp = (d.zones and d.zones.opp) == true },

        -- STRG lock (the "strongest target" lock, LOCK lamp)
        locked = false,
        lockedSpeed = nil,
        lockedDir = nil,       -- 'closing' / 'away' / nil - target motion, not antenna side
        lockedZone = nil,      -- 'same' / 'opp' - which zone produced the lock (drives the enunciator)
        lockedPatrolSpeed = nil, -- manual p.13: a lock also freezes patrol speed until the patrol car stops

        -- FAST lock (freezes the FAST reading, FAST lamp)
        fastLocked = false,
        fastLockedSpeed = nil,
        fastLockedDir = nil,
        fastLockedZone = nil,

        -- Live values, refilled every tick by sendToNUI
        targetSpeed = nil,     -- m/s
        targetDir = nil,
        targetZone = nil,      -- 'same' / 'opp' - which zone the live target came through
        targetSide = nil,      -- 'front' / 'rear' - which side of the patrol car the target sits on
        fastSpeed = nil,
        fastDir = nil,
        fastZone = nil,

        --[[ Stationary OPP/SAME pairing (manual p.26).

             In stationary mode both zones of one antenna go live "when both the OPP mode
             key and the SAME mode key are pressed within 1 second of each other". These
             two fields remember the last zone key press so the second press can tell a
             deliberate pairing from an ordinary zone change. ]]
        lastZonePressed = nil,
        lastZonePressAt = 0,

        -- Plate reader
        plateLocked = false,
        lockedPlate = nil,
        lockedPlateStyle = nil,
    }
end

Radar = {
    power = false,
    displayed = false,
    hidden = false,

    rows = {
        front = newRow(Config.rowDefaults and Config.rowDefaults.front),
        rear  = newRow(Config.rowDefaults and Config.rowDefaults.rear),
    },

    plateReaderEnabled = true,
    speedUnit = Config.speedUnit,

    --[[ MOV/STA is a plain two-state toggle on the real unit.

         The DUAL DSR port had this as a four-way (moving / stationary-closing /
         stationary-away / bi-directional) because that radar has one antenna and needed
         somewhere to put the direction choice. On the 2X the direction lives in the ZONE
         keys instead - each antenna picks OPP and/or SAME, and what those mean flips
         between moving and stationary (see zoneWantsClosing). ]]
    stationaryMode = false,

    --[[ ---- Operator Menu values (manual pp.21-22) ---- ]]
    fasterDisplay      = Config.defaultFasterDisplay ~= false,   -- FAS
    oppSen             = Config.defaultOppSen or 4,              -- OP  SEn   0..4
    sameSen            = Config.defaultSameSen or 3,             -- SL  SEn   0..4
    squelch            = Config.defaultSquelch ~= false,         -- SqL
    patrolCutoff       = Config.defaultPatrolCutoff or 20,       -- PAt       5 / 10 / 20
    stopwatchOn        = Config.defaultStopwatch == true,        -- StO  P
    alertClosingSpeed  = Config.defaultAlertClosingSpeed or 30,  -- ALE  rt   1..200
    antennaCount       = Config.defaultAntennaCount or 2,        -- Ant       1 / 2

    --[[ ---- VOLUME key values (manual p.14) ----
         Aud is stored twice; the unit swaps between them with MOV/STA so you can run the
         doppler loud on patrol and quiet while parked. ]]
    audMoving     = Config.defaultAudMoving or 3,      -- 0..4
    audStationary = Config.defaultAudStationary or 3,  -- 0..4
    beepLevel     = Config.defaultBeepLevel or 2,      -- 0..3
    voiceLevel    = Config.defaultVoiceLevel or 2,     -- 0..3

    --[[ ---- Remote UI state machine ----
         'radar'     normal operation
         'menu'      Operator Menu, stepped by MENU, edited by up/down
         'volume'    VOLUME cycle (Aud -> bEE P -> UOI CE), edited by up/down
         'stopwatch' Stopwatch Mode
         Any Target Zone key returns to 'radar' from any of the others (manual p.13). ]]
    uiMode = 'radar',
    menuStep = 0,        -- index into MENU_STEPS
    volumeStep = 0,      -- 0 = none, 1 = Aud, 2 = bEE P, 3 = UOI CE

    --[[ ---- Stopwatch Mode (manual pp.28-29) ---- ]]
    stopwatchDistanceFt = Config.defaultStopwatchDistanceFt or 1320,
    stopwatchRunning = false,
    stopwatchStartMs = nil,
    stopwatchResultMph = nil,
    stopwatchError = false,

    --[[ ---- Rear Traffic Alert (manual p.5) ---- ]]
    alertActive = false,
    alertSince = 0,

    --[[ ---- PS BLANK (manual p.13) ----
         0 normal - live patrol speed
         1 blanked
         2 show the patrol speed captured by the FRONT lock
         3 show the patrol speed captured by the REAR lock ]]
    psBlankMode = 0,

    dopplerMode = 'off',         -- 'off' | 'on' | 'stationary'
    dopplerEnabled = false,      -- derived: dopplerMode ~= 'off'
    dopplerSource = Config.dopplerSource or 'strongest',  -- 'front' | 'rear' | 'strongest'

    nuiLayoutAdjust = false,
    detectionZoneDebug = Config.detectionZoneDebug == true,
}

local KVP_DISPLAY = Config.kvpDisplay
local KVP_PLATE_DISPLAY = Config.kvpPlateDisplay
local KVP_REMOTE = Config.kvpRemote
local KVP_SETTINGS = Config.kvpSettings
local MAX_DIST = Config.antennaMaxDist

local ROW_KEYS = { 'front', 'rear' }

--- Remote open state (declared early so sendToNUI can sync NUI focus for radar clicks)
local remoteOpen = false
local lastNuiFocusKey = nil

--- Seconds the radar has been powered since the last auto self-test.
--- Declared up here because the power handler resets it long before the timer thread
--- is defined; a later `local` would leave that writing to a global.
local autoTestTimer = 0

--[[ Game-timer stamp the running display test finishes at, or 0 when none is running.

     Covers both sequences the head can put up: the power-on lamp test and the full self test
     behind TEST. The NUI owns their timing, but Lua has to know about it too: a unit with a
     test on the display is not transmitting, so it must not acquire targets, sound doppler or
     raise a rear traffic alert until the test clears. Declared up here for the same reason as
     autoTestTimer - sendToNUI reads it well before either test sets it.

     Kept in step with SELF_TEST_END_AT and LAMP_TEST_MS in nui/app.js. ]]
local SELF_TEST_DURATION_MS = 8700
local LAMP_TEST_DURATION_MS = 3000
local displayTestUntil = 0

local function displayTestRunning()
    return displayTestUntil > 0 and GetGameTimer() < displayTestUntil
end

--- Forward declarations for functions the menu references before they are defined.
--- The DUAL DSR shipped `beginRadarPositionAdjust` without one, so its menu entry
--- resolved a nil global; declaring both here keeps the menu working.
local beginRadarPositionAdjust
local beginPlateReaderPositionAdjust
local openMenu

--- NUI focus only while remote is open or layout adjust is active — no cursor after closing remote.
local function forceNuiFocusOff()
    lastNuiFocusKey = nil
    if SetNuiFocusKeepInput then SetNuiFocusKeepInput(false) end
    SetNuiFocus(false, false)
end

--[[ Three focus states, not two.

     'remote'  cursor for the keypad, but the game still gets the keyboard, so you can drive
               while working the radar. That is what SetNuiFocusKeepInput buys: NUI holds the
               mouse, the game keeps WASD. remoteControlBlockThread below then takes back the
               handful of inputs that would misfire under a cursor (shooting, the pause menu).
     'adjust'  layout move/scale and window calibration. Keyboard stays captured because those
               modes are driven by arrow keys, A and R - letting them through would nudge a
               window and steer the car at the same time. You are parked to do this anyway.
     'off'     no focus at all.

     Adjust wins when both are live, since the remote can stay open behind an adjust session. ]]
local function syncNuiFocus()
    local key = 'off'
    if Radar.nuiLayoutAdjust then
        key = 'adjust'
    elseif remoteOpen then
        key = 'remote'
    end
    if key == lastNuiFocusKey then return end
    lastNuiFocusKey = key

    SetNuiFocus(key ~= 'off', key ~= 'off')
    -- After SetNuiFocus, which resets the keep-input flag.
    if SetNuiFocusKeepInput then
        SetNuiFocusKeepInput(key == 'remote' and Config.remoteKeepGameInput ~= false)
    end
end

-- Ray trace config (simplified from wk_wars2x)
local RAY_TRACES = {
    { startX = 0.0, endX = 0.0, endY = 0.0, rayType = 'same' },
    { startX = -5.0, endX = -5.0, endY = 0.0, rayType = 'same' },
    { startX = 5.0, endX = 5.0, endY = 0.0, rayType = 'same' },
    { startX = -10.0, endX = -10.0, endY = MAX_DIST * Config.oppSensitivity, rayType = 'opp' },
    { startX = -17.0, endX = -17.0, endY = MAX_DIST * Config.oppSensitivity, rayType = 'opp' },
}

--[[ ---------------------------------------------------------------------------
     Volume (manual p.14)

     The VOLUME key exposes three independent levels. Aud (the doppler tone) runs 0-4 and
     is stored twice, once per MOV/STA position; bEE P (key clicks and lock beeps) and
     UOI CE (the lock enunciator) run 0-3. Zero is off in every case.
   --------------------------------------------------------------------------- ]]

--- Current Aud level, following whichever MOV/STA position is selected.
local function audLevel()
    return Radar.stationaryMode and (Radar.audStationary or 0) or (Radar.audMoving or 0)
end

local function audVol()  return math.max(0, math.min(4, audLevel())) / 4.0 end
local function beepVol() return math.max(0, math.min(3, Radar.beepLevel  or 0)) / 3.0 end
local function voiceVol() return math.max(0, math.min(3, Radar.voiceLevel or 0)) / 3.0 end

--- Key click / confirmation beep. Silent at bEE P 0, exactly like the hardware.
local function beep()
    local v = beepVol()
    if v <= 0 then return end
    SendNUIMessage({ _type = 'audio', name = 'beep', vol = v })
end

--[[ ---------------------------------------------------------------------------
     Row helpers
   --------------------------------------------------------------------------- ]]

local function getRow(rowKey)
    return Radar.rows[rowKey == 'rear' and 'rear' or 'front']
end

--- Collapses a row's zone checkboxes into the 0/1/2/3 mode the filter understands.
local function rowZoneMode(row)
    if not row then return 0 end
    local s, o = row.zones.same, row.zones.opp
    if s and o then return 3 end
    if s then return 1 end
    if o then return 2 end
    return 0
end

--- The rear row goes dark entirely when the operator menu's Ant step is set to 1.
local function rowEnabled(rowKey)
    if rowKey == 'rear' and (Radar.antennaCount or 2) < 2 then return false end
    return true
end

--- A row only produces readings when it is powered, transmitting, not in hold,
--- and has at least one zone selected.
local function rowIsLive(row, rowKey)
    if rowKey and not rowEnabled(rowKey) then return false end
    return Radar.power and row and row.xmit and not row.hold and rowZoneMode(row) > 0
end

--[[ Range for one zone of one antenna.

     Replaces the single shared `row.range`. The manual gives the two lanes independent
     sensitivity settings (OP SEn / SL SEn, defaults 4 and 3) that apply to both antennas,
     each mapping to a range via Config.senRanges. SEn 0 is a genuinely deaf setting on
     the hardware, so it maps to zero range here. ]]
local function zoneRange(zone)
    local sen = (zone == 'opp') and (Radar.oppSen or 4) or (Radar.sameSen or 3)
    local ranges = Config.senRanges or { [0] = 0, [1] = 125, [2] = 250, [3] = 375, [4] = 500 }
    return ranges[math.max(0, math.min(4, sen))] or 0
end

--[[ Does this zone key mean "closing" for this antenna?

     Manual p.12. In stationary mode the zone keys stop meaning "which lane" and start
     meaning "which direction", and the mapping is mirrored between the two antennas
     because a car approaching the front bumper and a car approaching the rear bumper are
     travelling in opposite directions in world space:

         front OPP  = closing      front SAME = away
         rear  SAME = closing      rear  OPP  = away

     which collapses to: the zone means closing exactly when (row is front) == (zone is opp). ]]
local function zoneWantsClosing(rowKey, zone)
    return (rowKey ~= 'rear') == (zone == 'opp')
end

--- Widest range across live rows — used to bound the shared capture pass.
local function effectiveCaptureRange()
    local best = 0
    for _, key in ipairs(ROW_KEYS) do
        local row = Radar.rows[key]
        if row and rowEnabled(key) then
            for _, zone in ipairs({ 'same', 'opp' }) do
                if row.zones[zone] then
                    local r = zoneRange(zone)
                    if r > best then best = r end
                end
            end
        end
    end
    -- The Rear Traffic Alert listens even when no rear zone is selected, so the capture
    -- pass can never shrink below its (deliberately short) range.
    if Config.optTrafficAlert ~= false then
        best = math.max(best, Config.alertRangeUnits or 90)
    end
    if best <= 0 then best = Config.antennaMaxDist end
    return best
end

--[[ ---------------------------------------------------------------------------
     Detection geometry (ported unchanged from the DUAL DSR)
   --------------------------------------------------------------------------- ]]

--- Dot product for 2D vectors
local function dot2(a, b)
    return a.x * b.x + a.y * b.y
end

--- Check if sphere at pos intersects line from s to e, return relPos (1=front, -1=rear)
local function lineHitsSphere(centre, radius, s, e, minProj)
    local rs = { x = s.x, y = s.y }
    local re = { x = e.x, y = e.y }
    local c = { x = centre.x, y = centre.y }
    local ray = { x = re.x - rs.x, y = re.y - rs.y }
    local len = math.sqrt(ray.x * ray.x + ray.y * ray.y)
    if len < 0.001 then return 0 end
    local rayNorm = { x = ray.x / len, y = ray.y / len }
    local rayToCentre = { x = c.x - rs.x, y = c.y - rs.y }
    local tProj = dot2(rayToCentre, rayNorm)
    local oppLenSqr = dot2(rayToCentre, rayToCentre) - (tProj * tProj)
    local radiusSqr = radius * radius
    local mp = minProj or 8.0
    if oppLenSqr < radiusSqr then
        if tProj > mp then return 1 end
        if tProj < -mp then return -1 end
    end
    return 0
end

--- Check if target vehicle is in traffic flow (heading)
local function isVehicleInTraffic(tgtVeh, plyVeh, relPos)
    local tgtHdg = GetEntityHeading(tgtVeh)
    local plyHdg = GetEntityHeading(plyVeh)
    local hdgDiff = math.abs((plyHdg - tgtHdg + 180) % 360 - 180)
    if relPos == 1 and hdgDiff > 45 and hdgDiff < 135 then return false end
    if relPos == -1 and hdgDiff > 45 and (hdgDiff < 135 or hdgDiff > 215) then return false end
    return true
end

--- Get dynamic radius for vehicle (based on model)
local function getVehicleRadius(veh)
    local min, max = GetModelDimensions(GetEntityModel(veh))
    local size = (max.x - min.x) + (max.y - min.y) + (max.z - min.z)
    local radius = math.max(2.0, size * 0.5)
    return radius, size
end

--- Get all vehicles (FiveM GetGamePool or enum fallback)
local function getAllVehicles()
    local vehs = {}
    if GetGamePool then
        for _, v in ipairs(GetGamePool('CVehicle')) do
            if DoesEntityExist(v) then table.insert(vehs, v) end
        end
    else
        local handle, vehicle = FindFirstVehicle()
        repeat
            if DoesEntityExist(vehicle) then table.insert(vehs, vehicle) end
            local success
            success, vehicle = FindNextVehicle(handle)
        until not success
        EndFindVehicle(handle)
    end
    return vehs
end

--- Intersect flags: map + vehicles + objects (excludes peds so the ray does not stop on the driver first).
local SHAPE_TEST_FLAGS_STRICT = 1 + 2 + 8

--- Strict shape-test: first hit along the segment must be the target vehicle (blocks walls / other cars better than LOS alone).
local function isFirstHitStrictShapeTest(plyVeh, tgtVeh, s3, tgtPos)
    local h = StartShapeTestRay(
        s3.x, s3.y, s3.z,
        tgtPos.x, tgtPos.y, tgtPos.z,
        SHAPE_TEST_FLAGS_STRICT,
        plyVeh,
        7
    )
    local retval, hit, _, _, entityHit = GetShapeTestResult(h)
    local n = 0
    while retval == 0 and n < 12 do
        if n > 0 then Wait(0) end
        retval, hit, _, _, entityHit = GetShapeTestResult(h)
        n = n + 1
    end
    if retval ~= 1 then return false end
    if hit == 0 then return false end
    return entityHit == tgtVeh
end

--- Line of sight to target: default uses native LOS (reliable). Optional strict ray test for wall blocking.
local function lineOfSightToTargetVehicle(plyVeh, tgtVeh, s3, tgtPos)
    if Config.strictShapeTestLos then
        return isFirstHitStrictShapeTest(plyVeh, tgtVeh, s3, tgtPos)
    end
    return HasEntityClearLosToEntity(plyVeh, tgtVeh, 15)
end

--- Player must be physically seated in the patrol vehicle (not freecam / invalid attach).
local function isRadarPlyMountedInPatrolVehicle(plyVeh)
    if not plyVeh or plyVeh == 0 or not DoesEntityExist(plyVeh) then return false end
    return IsPedInVehicle(PlayerPedId(), plyVeh, false)
end

--- Range rate along the patrol->target line of sight (m/s): negative = closing, positive = opening.
local function getRangeRate(plyVeh, tgtVeh, tgtPos, plyPos, dist)
    if dist < 0.01 then return 0.0 end
    local pv = GetEntityVelocity(plyVeh)
    local tv = GetEntityVelocity(tgtVeh)
    local lx, ly, lz = (tgtPos.x - plyPos.x) / dist, (tgtPos.y - plyPos.y) / dist, (tgtPos.z - plyPos.z) / dist
    return (tv.x - pv.x) * lx + (tv.y - pv.y) * ly + (tv.z - pv.z) * lz
end

--- 'closing' / 'away' for the TARGET + FAST arrows, or nil inside the deadband.
local function directionFromRangeRate(rangeRate)
    local rrMph = Utils.ConvertSpeed(rangeRate or 0.0, 'mph')
    local dead = Config.closingDeadbandMph or 1.5
    if rrMph <= -dead then return 'closing' end
    if rrMph >= dead then return 'away' end
    return nil
end

--[[ ---------------------------------------------------------------------------
     Arrow indicator (manual p.11)

     The arrow is NOT "is the target coming or going" in the abstract - it is the direction
     the target is travelling relative to the patrol car, resolved onto the patrol car's own
     axis. That makes the same word produce opposite arrows on the two antennas, because a
     car closing on your front bumper is moving down the screen toward you while a car
     closing on your rear bumper is moving up it:

         ZONE            DIRECTION   ARROW
         FRONT OPPOSITE  CLOSING     down
         FRONT SAME      AWAY        up
         FRONT SAME      CLOSING     down
         REAR  OPPOSITE  AWAY        down
         REAR  SAME      CLOSING     up
         REAR  SAME      AWAY        down

     Zone drops out of the table entirely: FRONT is closing-down / away-up, REAR is
     closing-up / away-down. The old port applied the FRONT rule to both rows, so every
     rear arrow pointed the wrong way.
   --------------------------------------------------------------------------- ]]

--- Returns 'up', 'down', or nil (inside the deadband) for one row's arrow pair.
local function arrowForRow(rowKey, dir)
    if dir == nil then return nil end
    if rowKey == 'rear' then
        return dir == 'closing' and 'up' or 'down'
    end
    return dir == 'closing' and 'down' or 'up'
end

--[[ ---------------------------------------------------------------------------
     MOV / STA

     A plain two-position toggle on the real unit. Everything the DUAL DSR port packed into
     a four-way cycle (closing / away / bi-directional) lives in the ZONE keys on the 2X -
     see zoneWantsClosing above.
   --------------------------------------------------------------------------- ]]

--- In MOVING mode each antenna watches ONE zone (radio button). Switching into moving
--- therefore has to collapse any row that had both zones selected while stationary.
local function collapseZonesForMovingMode()
    for _, key in ipairs(ROW_KEYS) do
        local row = Radar.rows[key]
        if row and row.zones.same and row.zones.opp then
            -- Keep the zone the operator selected most recently.
            if row.lastZonePressed == 'same' then row.zones.opp = false else row.zones.same = false end
        end
    end
end

--- Below this the patrol car counts as parked (~2.2 mph - enough to swallow idle creep and
--- the shove you get from a kerb, not enough to call rolling traffic a stop).
local PARKED_SPEED_MS = 1.0

local function setStationaryMode(on)
    Radar.stationaryMode = on and true or false
    if not Radar.stationaryMode then collapseZonesForMovingMode() end
end

--[[ The mode has to agree with what the patrol car is doing before anything is measured.

     Stationary needs the car parked - that is the whole premise of the mode. Moving needs it
     rolling, because a moving-mode reading is taken against your own speed and there is
     nothing to take it against sat still. Either way out of agreement, the windows stay empty
     rather than showing a number the mode cannot stand behind, and nothing can be locked. It
     never lasts: the auto-switch is already on its way to the mode that does agree. ]]
local function modeAllowsMeasurement(plySpeed)
    if Radar.stationaryMode then return plySpeed <= PARKED_SPEED_MS end
    return plySpeed > PARKED_SPEED_MS
end

--- MOV/STA key: moving <-> stationary.
local function toggleMovSta()
    setStationaryMode(not Radar.stationaryMode)
end

--[[ ---------------------------------------------------------------------------
     Capture
   --------------------------------------------------------------------------- ]]

--- Shoot ray and check if vehicle is hit
local function shootRay(plyVeh, veh, startX, endX, endY, includeStationary, maxDist)
    local pos = GetEntityCoords(veh)
    local plyPos = GetEntityCoords(plyVeh)
    local dist = #(pos - plyPos)
    if not DoesEntityExist(veh) or veh == plyVeh or dist >= maxDist then return nil end
    local entSpeed = GetEntitySpeed(veh)
    if not includeStationary and entSpeed < 0.1 then return nil end
    local maxVert = Config.maxTargetVerticalDelta
    if maxVert and maxVert > 0 and math.abs(pos.z - plyPos.z) > maxVert then return nil end
    local pitch = GetEntityPitch(plyVeh)
    if pitch < -35 or pitch > 35 then return nil end
    local radius, size = getVehicleRadius(veh)
    local fy = Config.radarRayForwardOffsetM or 0.0
    local s = GetOffsetFromEntityInWorldCoords(plyVeh, startX, fy, 0.0)
    local e = GetOffsetFromEntityInWorldCoords(plyVeh, endX, endY + fy, 0.0)
    local relPos = lineHitsSphere(pos, radius, s, e, includeStationary and 2.0 or 8.0)
    if relPos == 0 then return nil end
    if not includeStationary and not isVehicleInTraffic(veh, plyVeh, relPos) then return nil end
    if not lineOfSightToTargetVehicle(plyVeh, veh, s, pos) then return nil end
    -- Lateral offset from patrol centerline (|local X|); lower = more on boresight.
    local rel = GetOffsetFromEntityGivenWorldCoords(plyVeh, pos.x, pos.y, pos.z)
    local lateralAbs = math.abs(rel.x)
    local rangeRate = getRangeRate(plyVeh, veh, pos, plyPos, dist)
    return { veh = veh, relPos = relPos, dist = dist, speed = entSpeed, size = size, lateralAbs = lateralAbs, rangeRate = rangeRate }
end

--- Capture vehicles for all rays. Both antennas share one pass; each row filters the
--- result by relPos and by its own range afterwards.
local function captureVehicles(plyVeh, includeStationary)
    if not isRadarPlyMountedInPatrolVehicle(plyVeh) then return {} end
    local captured = {}
    local vehs = getAllVehicles()
    local maxDist = effectiveCaptureRange()
    for _, ray in ipairs(RAY_TRACES) do
        local endY = ray.rayType == 'same' and (maxDist * Config.sameSensitivity) or (maxDist * Config.oppSensitivity)
        for _, v in ipairs(vehs) do
            local hit = shootRay(plyVeh, v, ray.startX, ray.endX, endY, includeStationary, maxDist)
            if hit then
                hit.rayType = ray.rayType
                hit.dir = directionFromRangeRate(hit.rangeRate)
                table.insert(captured, hit)
            end
        end
    end
    return captured
end

--- World debug: draw RAY_TRACES (same geometry as capture).
local function drawRadarDetectionDebug(plyVeh)
    local maxDist = effectiveCaptureRange()
    local sameEnds, oppEnds = {}, {}
    local fy = Config.radarRayForwardOffsetM or 0.0
    for _, ray in ipairs(RAY_TRACES) do
        local endY = ray.rayType == 'same' and (maxDist * Config.sameSensitivity) or (maxDist * Config.oppSensitivity)
        local s = GetOffsetFromEntityInWorldCoords(plyVeh, ray.startX, fy, 0.0)
        local e = GetOffsetFromEntityInWorldCoords(plyVeh, ray.endX, endY + fy, 0.0)
        local r, g, b = 0, 255, 140
        if ray.rayType == 'opp' then r, g, b = 255, 150, 40 end
        DrawLine(s.x, s.y, s.z, e.x, e.y, e.z, r, g, b, 230)
        local entry = { s = s, e = e }
        if ray.rayType == 'same' then
            sameEnds[#sameEnds + 1] = entry
        else
            oppEnds[#oppEnds + 1] = entry
        end
    end
    for i = 1, #sameEnds - 1 do
        local a, b = sameEnds[i].s, sameEnds[i + 1].s
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 0, 180, 90, 140)
        a, b = sameEnds[i].e, sameEnds[i + 1].e
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 0, 180, 90, 180)
    end
    for i = 1, #oppEnds - 1 do
        local a, b = oppEnds[i].s, oppEnds[i + 1].s
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 200, 100, 0, 140)
        a, b = oppEnds[i].e, oppEnds[i + 1].e
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 200, 100, 0, 180)
    end
end

--[[ ---------------------------------------------------------------------------
     Target selection
   --------------------------------------------------------------------------- ]]

--- Get antenna text from relPos
local function antennaFromRelPos(relPos)
    if relPos == 1 then return 'front' end
    if relPos == -1 then return 'rear' end
    return nil
end

--[[ Filter captured hits down to one row.

     Three gates, in order: the hit must be on this antenna's side of the patrol car, it
     must satisfy at least one of the row's selected zones, and it must be inside the range
     that zone's SEn setting allows.

     What "satisfy a zone" means depends on MOV/STA, which is the crux of the 2X:

       MOVING     - the zone is a LANE. OPP accepts opposite-lane hits, SAME accepts
                    same-lane hits, exactly as the ray geometry classified them.
       STATIONARY - the zone is a DIRECTION, and which direction depends on the antenna
                    (zoneWantsClosing). Lane no longer applies: parked at the roadside the
                    unit does not care which lane a car is in, only whether it is coming or
                    going, so both ray types feed both zones.

     The surviving hit is tagged with the zone that admitted it, because the lock enunciator
     and the rear same-lane difference audio both need to know. ]]
local function filterForRow(captured, rowKey, row)
    if rowZoneMode(row) == 0 then return {} end
    local stationary = Radar.stationaryMode
    local out = {}
    for _, v in ipairs(captured) do
        if antennaFromRelPos(v.relPos) == rowKey then
            for _, zone in ipairs({ 'opp', 'same' }) do
                if row.zones[zone] and v.dist <= zoneRange(zone) then
                    local admit
                    if stationary then
                        admit = (v.dir == (zoneWantsClosing(rowKey, zone) and 'closing' or 'away'))
                    else
                        admit = (v.rayType == zone)
                    end
                    if admit then
                        -- Shallow copy: one vehicle can be admitted by both zones of a
                        -- bi-directional antenna and each copy needs its own zone tag.
                        local hit = {}
                        for k, val in pairs(v) do hit[k] = val end
                        hit.zone = zone
                        table.insert(out, hit)
                        break
                    end
                end
            end
        end
    end
    return out
end

--- Sort by fastest
local sortByFastest = function(a, b) return a.speed > b.speed end
--- Sort by strongest (size)
local sortByStrongest = function(a, b) return a.size > b.size end

--- Maps Config.targetPriority to a sort mode string.
local function liveSortModeFromConfig()
    local p = Config.targetPriority or 'echo'
    if p == 'boresight' then return 'boresight' end
    if p == 'hybrid' then return 'hybrid' end
    if p == 'strongest' or p == 'size' then return 'strongest' end
    return 'echo'
end

--- Approximate received power: RCS ~ size², two-way ~ 1/R^n, antenna pattern ~ Gaussian on lateral offset (meters).
local function receivedPowerProxy(hit, beamSigmaM)
    local dist = math.max(hit.dist or 1.0, 1.0)
    local rcs = math.max(hit.size or 1.0, 0.5)
    local exp = Config.radarRangeFalloff or 4
    local rangeFall = dist ^ exp
    local lateral = hit.lateralAbs or 0
    local sigma = beamSigmaM or 14.0
    local beamW = math.exp(-0.5 * (lateral / math.max(sigma, 0.1)) ^ 2)
    return ((rcs * rcs) / rangeFall) * beamW
end

--- Higher = stronger return. Used to pick the doppler row and as a tie-break.
local function mergeScore(hit)
    local mode = liveSortModeFromConfig()
    if mode == 'boresight' then return -hit.dist end
    if mode == 'echo' then return receivedPowerProxy(hit, Config.radarBeamLateralSigmaM) end
    if mode == 'hybrid' then return receivedPowerProxy(hit, Config.radarHybridLateralSigmaM) end
    return hit.size or 0
end

--- One entry per vehicle (same car can be hit by multiple parallel rays); keep closest / most on-boresight sample.
local function dedupeHitsByVehicle(hits)
    local bestBy = {}
    for _, h in ipairs(hits) do
        local v = h.veh
        local prev = bestBy[v]
        if not prev then
            bestBy[v] = h
        elseif h.dist < prev.dist - 0.01 then
            bestBy[v] = h
        elseif math.abs(h.dist - prev.dist) <= 0.01 then
            local la, lb = h.lateralAbs or 999, prev.lateralAbs or 999
            if la < lb - 0.01 then
                bestBy[v] = h
            end
        end
    end
    local out = {}
    for _, h in pairs(bestBy) do
        table.insert(out, h)
    end
    return out
end

--- Closest in range first, then nearest to boresight, then speed (tie-break).
local function sortHitsBoresight(hits)
    table.sort(hits, function(a, b)
        if math.abs(a.dist - b.dist) > 0.01 then return a.dist < b.dist end
        local la, lb = a.lateralAbs or 999, b.lateralAbs or 999
        if math.abs(la - lb) > 0.01 then return la < lb end
        return a.speed > b.speed
    end)
end

local function sortByReceivedPower(hits, sigma)
    table.sort(hits, function(a, b)
        local sa = receivedPowerProxy(a, sigma)
        local sb = receivedPowerProxy(b, sigma)
        if math.abs(sa - sb) > 1e-9 then return sa > sb end
        if math.abs(a.dist - b.dist) > 0.01 then return a.dist < b.dist end
        local la, lb = a.lateralAbs or 999, b.lateralAbs or 999
        return la < lb
    end)
end

--[[ Low-end speed cutoff (PAt).

     PAt is the slowest number this radar will put on a window, and it governs the target
     windows as well as the patrol one. Below it there is no reading: a car crawling in a
     queue is not a speed worth reporting, and without the cutoff the beam spends its whole
     life locked onto the slowest thing in front of you instead of the traffic behind it.

     Compared in the operator's own units, the same way the patrol window compares it - the
     two halves of the display should agree on what counts as too slow to show. ]]
local function speedAboveCutoff(speedMs)
    if not speedMs or speedMs < 0.1 then return false end
    return Utils.ConvertSpeed(speedMs, Radar.speedUnit) >= (Radar.patrolCutoff or 20)
end

--- First hit in an already-sorted list that is fast enough to report.
local function firstAboveCutoff(sorted)
    for _, hit in ipairs(sorted) do
        if speedAboveCutoff(hit.speed) then return hit end
    end
    return nil
end

--- Best hit for one row. sortMode: 'echo' / 'hybrid' / 'boresight' / 'fastest' / 'strongest'
--- speedGated skips anything under the PAt cutoff, for the callers that report a speed.
---@return table|nil hit, string|nil direction
local function getBestForRow(captured, rowKey, row, sortMode, speedGated)
    local filtered = filterForRow(captured, rowKey, row)
    if #filtered == 0 then return nil, nil end
    filtered = dedupeHitsByVehicle(filtered)
    if sortMode == 'fastest' then
        table.sort(filtered, sortByFastest)
    elseif sortMode == 'strongest' then
        table.sort(filtered, sortByStrongest)
    elseif sortMode == 'echo' then
        sortByReceivedPower(filtered, Config.radarBeamLateralSigmaM or 14.0)
    elseif sortMode == 'hybrid' then
        sortByReceivedPower(filtered, Config.radarHybridLateralSigmaM or 7.0)
    else
        sortHitsBoresight(filtered)
    end
    local best = speedGated and firstAboveCutoff(filtered) or filtered[1]
    if not best then return nil, nil end
    -- relPos stays the antenna assignment (ahead/behind the patrol car); the arrows
    -- report target motion instead, so they come from range rate.
    return best, directionFromRangeRate(best.rangeRate)
end

--- FAST window for a row: fastest vehicle in THAT row's beam that is strictly faster than
--- the row's own TARGET. Each row runs this independently, so the top row can be chasing a
--- bike out front while the bottom row holds a truck behind you.
---
--- Gated twice: by the Options-menu FAS ? master (Config.optFasterEnable, factory-locked on
--- the hardware) and by the Operator Menu's FAS step, which the operator can turn off.
local function fastestFasterThanPrimary(rowHits, primaryHit)
    if Config.optFasterEnable == false then return nil end
    if not Radar.fasterDisplay then return nil end
    if not rowHits or not primaryHit or not primaryHit.veh or primaryHit.veh == 0 then return nil end
    local ps = primaryHit.speed or 0
    local requireFaster = Config.fastRequiresFasterThanTarget ~= false
    local requireStronger = Config.fastRequiresStrongerPrimary == true
    local maxBeyond = Config.fastMaxDistanceBeyondPrimaryM
    local pd = primaryHit.dist or 0
    local bestHit = nil
    local bestSp = -1.0
    for _, hit in ipairs(rowHits) do
        local ev = hit.veh
        if ev and ev ~= 0 and ev ~= primaryHit.veh and hit.speed then
            if maxBeyond and maxBeyond > 0 and pd >= 0 and hit.dist > pd + maxBeyond then
                -- skip: far beyond TARGET range, not the same cluster
            elseif requireFaster and hit.speed <= ps then
                -- skip: not faster than TARGET
            elseif requireStronger and mergeScore(primaryHit) <= mergeScore(hit) then
                -- skip: primary not the stronger echo
            elseif hit.speed > bestSp then
                bestSp = hit.speed
                bestHit = hit
            end
        end
    end
    return bestHit
end

--- Live TARGET + FAST for a row, from an already-captured hit list.
--- The fifth return is the hit the beam is actually looking at, cutoff or not - the plate
--- reader wants a plate off a parked or crawling car even though its speed is not reportable.
---@return table|nil primary, string|nil primaryDir, table|nil fast, string|nil fastDir, table|nil plateHit
local function resolveRowTargets(captured, rowKey, row)
    if not rowIsLive(row, rowKey) then return nil, nil, nil, nil end
    local liveMode = liveSortModeFromConfig()
    local rowHits = dedupeHitsByVehicle(filterForRow(captured, rowKey, row))
    if #rowHits == 0 then return nil, nil, nil, nil end

    local sorted = { table.unpack(rowHits) }
    if liveMode == 'echo' then
        sortByReceivedPower(sorted, Config.radarBeamLateralSigmaM or 14.0)
    elseif liveMode == 'hybrid' then
        sortByReceivedPower(sorted, Config.radarHybridLateralSigmaM or 7.0)
    elseif liveMode == 'strongest' then
        table.sort(sorted, sortByStrongest)
    else
        sortHitsBoresight(sorted)
    end

    local plateHit = sorted[1]

    -- Step past anything under the cutoff rather than reporting nothing: a slow car in the
    -- foreground should not blank the row for the one moving behind it.
    local primary = firstAboveCutoff(sorted)
    if not primary then return nil, nil, nil, nil, plateHit end

    local fast = fastestFasterThanPrimary(rowHits, primary)
    if fast and not speedAboveCutoff(fast.speed) then fast = nil end
    return primary, directionFromRangeRate(primary.rangeRate), fast,
           fast and directionFromRangeRate(fast.rangeRate) or nil, plateHit
end

--[[ ---------------------------------------------------------------------------
     Locks
   --------------------------------------------------------------------------- ]]

local function clearRowLock(rowKey)
    local row = getRow(rowKey)
    row.locked = false
    row.lockedSpeed = nil
    row.lockedDir = nil
    row.lockedZone = nil
    row.lockedPatrolSpeed = nil
end

--[[ Voice enunciator (manual p.4, p.15).

     Three words, not two: ANTENNA, then RADAR MODE, then TARGET DIRECTION.

         "front  stationary  closing"
         "rear   same        away"
         "front  opposite    closing"

     The middle word is the zone that produced the lock while moving, or the literal word
     "stationary" while parked - the manual lists exactly ten valid combinations and two of
     them are degenerate (moving front/opposite is always closing, moving rear/opposite is
     always away), which falls out of zoneWantsClosing on its own.

     Level 0 on the UOI CE setting silences it, as on the hardware. ]]
local function playVoiceEnunciator(antenna, lockedDir, lockedZone)
    if not Config.voiceEnunciator or Config.optVoiceEnunciator == false then return end
    local vol = voiceVol()
    if vol <= 0 then return end
    SendNUIMessage({
        _type = 'voiceEnunciator',
        antenna = antenna,
        mode = Radar.stationaryMode and 'stationary' or (lockedZone == 'opp' and 'opposite' or 'same'),
        direction = lockedDir,
        vol = vol,
    })
end

--[[ Patrol speed at the moment of a lock.

     Manual p.13: "the patrol speed is also locked and will remain locked until the patrol
     vehicle comes to a stop." Storing it per row is what lets PS BLANK cycle between the
     front lock's patrol speed and the rear lock's. ]]
local function currentPatrolSpeedMph()
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return nil end
    return Utils.ConvertSpeed(GetEntitySpeed(plyVeh), 'mph')
end

--- STRG Lk: lock the strongest target in this row.
---@return boolean
local function acquireRowLock(rowKey)
    --[[ Nothing is being measured behind a menu, so nothing can be locked. Guarded here rather
         than at the key handlers because these run their own capture pass - the standalone
         lock keybinds, the NUI shortcuts and the exports would all otherwise reach past the
         menu and lock a target the operator cannot see. Releasing a lock stays allowed. ]]
    if Radar.uiMode ~= 'radar' then return false end
    local row = getRow(rowKey)
    if not rowIsLive(row, rowKey) then return false end
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return false end
    if not modeAllowsMeasurement(GetEntitySpeed(plyVeh)) then return false end
    local captured = captureVehicles(plyVeh)
    -- Speed-gated: you can only lock a reading the radar would have shown you.
    local best, dir = getBestForRow(captured, rowKey, row, liveSortModeFromConfig(), true)
    if not best then return false end
    row.locked = true
    row.lockedSpeed = best.speed
    row.lockedDir = dir
    row.lockedZone = best.zone
    row.lockedPatrolSpeed = currentPatrolSpeedMph()
    beep()
    playVoiceEnunciator(rowKey, dir, best.zone)
    return true
end

local function clearRowFastLock(rowKey)
    local row = getRow(rowKey)
    row.fastLocked = false
    row.fastLockedSpeed = nil
    row.fastLockedDir = nil
    row.fastLockedZone = nil
end

--- FAST Lk: freeze whatever the row's FAST window is currently reading.
--- Blocked outright when the Options menu's FAS Loc is off (manual p.46): a faster target
--- can still be *displayed*, it just cannot be captured.
---@return boolean
local function acquireRowFastLock(rowKey)
    if Config.optFastLock == false then return false end
    if Radar.uiMode ~= 'radar' then return false end  -- see acquireRowLock
    local row = getRow(rowKey)
    if not rowIsLive(row, rowKey) then return false end
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return false end
    if not modeAllowsMeasurement(GetEntitySpeed(plyVeh)) then return false end
    local captured = captureVehicles(plyVeh)
    local _, _, fast, fastDir = resolveRowTargets(captured, rowKey, row)
    if not fast then return false end
    row.fastLocked = true
    row.fastLockedSpeed = fast.speed
    row.fastLockedDir = fastDir
    row.fastLockedZone = fast.zone
    row.lockedPatrolSpeed = row.lockedPatrolSpeed or currentPatrolSpeedMph()
    beep()
    playVoiceEnunciator(rowKey, fastDir, fast.zone)
    return true
end

--[[ ---------------------------------------------------------------------------
     Plates
   --------------------------------------------------------------------------- ]]

local PLACEHOLDER_PLATE_TEXT = '--------'

local function getPlateDisplayData(veh)
    if not veh or veh <= 0 or not DoesEntityExist(veh) then
        return PLACEHOLDER_PLATE_TEXT, 0
    end
    local plate = GetVehicleNumberPlateText(veh) or ''
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then plate = PLACEHOLDER_PLATE_TEXT end
    plate = string.upper(plate)

    local style = GetVehicleNumberPlateTextIndex(veh) or 0
    if style < 0 then style = 0 end
    if style > 5 then style = style % 6 end
    return plate, style
end

--- Last successfully read plate per row (live view keeps showing when no target in beam)
local lastPlate = {
    front = { text = PLACEHOLDER_PLATE_TEXT, style = 0 },
    rear  = { text = PLACEHOLDER_PLATE_TEXT, style = 0 },
}

local function storeLastPlate(rowKey, text, style)
    if text and text ~= PLACEHOLDER_PLATE_TEXT then
        lastPlate[rowKey].text = text
        lastPlate[rowKey].style = style or 0
    end
end

local function clearRowPlateLock(rowKey)
    local row = getRow(rowKey)
    row.plateLocked = false
    row.lockedPlate = nil
    row.lockedPlateStyle = nil
end

--- Assigned down in the ALPR section, which owns the scan bookkeeping this needs to touch.
--- Only ever called at runtime, long after the whole file has loaded.
local runForcedAlpr

--- Snapshot the current target plate on a row.
local function acquireRowPlateLock(rowKey)
    local row = getRow(rowKey)
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return false end
    local captured = captureVehicles(plyVeh, true)
    local best = getBestForRow(captured, rowKey, row, liveSortModeFromConfig())
    if best then
        row.lockedPlate, row.lockedPlateStyle = getPlateDisplayData(best.veh)
    elseif lastPlate[rowKey].text ~= PLACEHOLDER_PLATE_TEXT then
        -- Vehicle left the beam but the plate reader still has it — lock the last seen plate
        row.lockedPlate, row.lockedPlateStyle = lastPlate[rowKey].text, lastPlate[rowKey].style
    else
        return false
    end
    row.plateLocked = true
    beep()
    runForcedAlpr(row.lockedPlate, rowKey == 'rear' and 'Rear Lock' or 'Front Lock')
    return true
end

local NOTIFY_POLICE_VEHICLE = 'You must be in a police vehicle to use the radar.'

local function notifyPoliceVehicleError(description)
    lib.notify({ type = 'error', description = description or NOTIFY_POLICE_VEHICLE })
end

--- Clear every lock on both rows (power off, PWR toggle, menu power off, etc.)
local function clearAllRadarLocks()
    for _, key in ipairs(ROW_KEYS) do
        clearRowLock(key)
        clearRowFastLock(key)
        clearRowPlateLock(key)
        lastPlate[key].text = PLACEHOLDER_PLATE_TEXT
        lastPlate[key].style = 0
    end
end

--[[ ---------------------------------------------------------------------------
     Zone / transmitter controls
   --------------------------------------------------------------------------- ]]

--[[ Select one zone on one antenna.

     MOVING mode: the two zones are a radio button. One antenna watches one lane.

     STATIONARY mode: still a radio button on an ordinary press, but the two zones can be
     lit together as the bi-directional pair described on manual p.26 - "both the OPP mode
     key and the SAME mode key are pressed within 1 second of each other". row.lastZonePress*
     is what distinguishes a deliberate double-tap from an ordinary zone change.

     `exclusive` forces the radio-button behaviour regardless, which is how the documented
     bi-directional exit works: hold Hold, then press a zone key to choose a single zone.

     Selecting a zone always wakes the transmitter - you cannot pick a lane for a
     transmitter that is standing by. ]]
local function selectRowZone(rowKey, which, exclusive)
    local row = getRow(rowKey)
    local other = (which == 'same') and 'opp' or 'same'
    local now = GetGameTimer()

    local pairWithOther = false
    if Radar.stationaryMode and not exclusive then
        local window = Config.zonePairWindowMs or 1000
        pairWithOther = row.lastZonePressed == other
            and (now - (row.lastZonePressAt or 0)) <= window
            and row.zones[other]
    end

    row.zones[which] = true
    row.zones[other] = pairWithOther

    row.lastZonePressed = which
    row.lastZonePressAt = now
    row.hold = false
    row.xmit = true
end

--[[ Hold key held down: HOLD (standby) for that antenna (manual p.13).

     "The transmitter for that antenna will be turned off and the display will show HLd in
     the appropriate lock window. All the mode icons and directional arrows for that antenna
     will remain ON except the XMIT icon will turn OFF."

     Locks survive - the operator can stand the unit down without losing a citation speed -
     but the live TARGET/FAST readings stop, because the transmitter has. ]]
local function setRowHold(rowKey, on)
    local row = getRow(rowKey)
    row.hold = on and true or false
    if row.hold then
        row.targetSpeed, row.targetDir, row.targetZone = nil, nil, nil
        row.fastSpeed, row.fastDir, row.fastZone = nil, nil, nil
    end
end

local function toggleRowHold(rowKey)
    setRowHold(rowKey, not getRow(rowKey).hold)
end

--[[ PS BLANK (manual p.13).

     Not a simple on/off. With a lock present the key walks three positions, so a two-antenna
     unit can show you which patrol speed produced which citation:

         1  patrol window blanked
         2  the patrol speed captured by the FRONT lock
         3  the patrol speed captured by the REAR lock

     "If there is no lock speed being displayed then pressing the PS Blank key will blank the
     patrol speed window and pressing it a second time will cause the radar to re-acquire the
     patrol speed" - which is positions 1 and 0 only. ]]
local PS_BLANK_LABELS = {
    [0] = 'Normal - live patrol speed',
    [1] = 'Blanked',
    [2] = 'Front lock patrol speed',
    [3] = 'Rear lock patrol speed',
}

local function cyclePsBlank()
    local anyLocked = Radar.rows.front.locked or Radar.rows.front.fastLocked
        or Radar.rows.rear.locked or Radar.rows.rear.fastLocked
    local mode = Radar.psBlankMode or 0
    if not anyLocked then
        Radar.psBlankMode = (mode == 0) and 1 or 0
    else
        Radar.psBlankMode = (mode + 1) % 4
    end
    return Radar.psBlankMode
end

--[[ ---------------------------------------------------------------------------
     Doppler
   --------------------------------------------------------------------------- ]]

local DOPPLER_LABELS = { off = 'Off', on = 'On', stationary = 'On (Stationary Only)' }
local DOPPLER_NEXT = { off = 'on', on = 'stationary', stationary = 'off' }
local DOPPLER_SOURCE_LABELS = { front = 'Top row (front)', rear = 'Bottom row (rear)', strongest = 'Strongest target' }
local DOPPLER_SOURCE_NEXT = { strongest = 'front', front = 'rear', rear = 'strongest' }

local function setDopplerMode(mode)
    Radar.dopplerMode = DOPPLER_LABELS[mode] and mode or 'off'
    Radar.dopplerEnabled = Radar.dopplerMode ~= 'off'
end

--- /toggledoppler + menu: Off -> On -> On (Stationary Only) -> Off
local function cycleDopplerMode()
    setDopplerMode(DOPPLER_NEXT[Radar.dopplerMode] or 'on')
end

local function cycleDopplerSource()
    Radar.dopplerSource = DOPPLER_SOURCE_NEXT[Radar.dopplerSource] or 'strongest'
end

--- 'stationary' mode gates the tone on the patrol car actually being stopped.
local function dopplerAllowedAtPatrolSpeed(patrolSpeedMs)
    if Radar.dopplerMode == 'off' then return false end
    if Radar.dopplerMode ~= 'stationary' then return true end
    local maxMph = Config.dopplerStationaryMaxMph or 2.0
    return Utils.ConvertSpeed(patrolSpeedMs or 0.0, 'mph') <= maxMph
end

--[[ Doppler tone frequency (manual p.4, p.23).

     The tone is the target's TRUE speed and nothing else - the number on its own TARGET
     window, whichever antenna and whichever zone found it. Your own speed does not come into
     it: the same car reads the same and sounds the same whether you are parked or doing
     seventy, and the two rows tone alike on identical numbers. One reading, one sound, so
     the operator never has to work out what the noise is relative to before it means
     anything.

     Returns the tone speed in mph, or nil for silence. ]]
local function dopplerToneFromTarget(targetSpeedMs)
    if targetSpeedMs == nil then return nil end
    return Utils.ConvertSpeed(targetSpeedMs, 'mph')
end

--[[ ---------------------------------------------------------------------------
     Persistence

     The whole operator-facing state of the unit is written to KVP, so a restart, a
     rejoin or a fresh session brings the radar back exactly as it was left: both
     antennas' XMIT / HLd / zone selection, MOV-STA, PS BLANK, every
     Operator Menu and VOLUME value, the stopwatch distance, and the script-side
     options (speed unit, plate reader, doppler).

     Four things are deliberately NOT saved:

       * The power switch. The unit always comes up dark and has to be switched on,
         the same as walking up to a cold car. Nothing else about the radar is affected
         by this - your settings are still all there waiting behind the PWR key.
       * Locks - STRG, FAST and plate. A lock is a citation speed tied to a moment. On
         the hardware it does not survive a power cycle, and restoring one after a
         restart would put a number on the display that no longer belongs to any
         vehicle in the world.
       * Live readings - target speed, direction, zone. Stale by definition.
       * Where you were in a menu (uiMode / menuStep / volumeStep) and the stopwatch's
         run state. You come back in radar mode; the VALUES you set in those menus do
         persist, which is the part that matters.

     XMIT / zones / MOV-STA / PS BLANK are the group the hardware resets on every power-on.
     Config.rememberOperationalState (on by default) suppresses that reset entirely, so the
     saved configuration comes back on every switch-on rather than surviving only until the
     first power cycle. With it off, restoredOperationalState still protects the one
     power-on every session is obliged to begin with. See applyRadarPowerOn. ]]

--- True from a successful load until the first PWR press consumes it. Only load-bearing
--- when rememberOperationalState is off. Declared up here because applyRadarPowerOn reads
--- it a long way below where loadSettings sets it.
local restoredOperationalState = false

local function serializeRow(row)
    return {
        xmit = row.xmit,
        hold = row.hold,
        zones = { same = row.zones.same, opp = row.zones.opp },
    }
end

local function applyRowSave(row, data)
    if type(data) ~= 'table' then return end
    if data.xmit ~= nil then row.xmit = data.xmit end
    if data.hold ~= nil then row.hold = data.hold end
    if type(data.zones) == 'table' then
        row.zones.same = data.zones.same == true
        row.zones.opp = data.zones.opp == true
    end
end

--- Read `key` from `data`, falling back to `default` when it is absent or the wrong type.
--- Saved values go through this rather than `or`, so a legitimately false/0 setting is not
--- silently replaced by its default the way `data.squelch or true` would do.
local function savedValue(data, key, default, kind)
    local v = data[key]
    if v == nil then return default end
    if kind and type(v) ~= kind then return default end
    return v
end

local function savedNumber(data, key, default, min, max)
    local v = tonumber(data[key])
    if not v then return default end
    if min and v < min then return min end
    if max and v > max then return max end
    return v
end

--- Load settings from KVP
local function loadSettings()
    local raw = GetResourceKvpString(KVP_SETTINGS)
    if not raw then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then return end

    Radar.speedUnit = savedValue(data, 'speedUnit', Config.speedUnit, 'string')
    Radar.plateReaderEnabled = savedValue(data, 'plateReaderEnabled', true, 'boolean')
    Radar.detectionZoneDebug = savedValue(data, 'detectionZoneDebug', Config.detectionZoneDebug == true, 'boolean')

    -- Operator Menu values survive a power cycle on the hardware, so they persist here too.
    Radar.fasterDisplay     = savedValue(data, 'fasterDisplay', Config.defaultFasterDisplay ~= false, 'boolean')
    Radar.oppSen            = savedNumber(data, 'oppSen', Config.defaultOppSen or 4, 0, 4)
    Radar.sameSen           = savedNumber(data, 'sameSen', Config.defaultSameSen or 3, 0, 4)
    Radar.squelch           = savedValue(data, 'squelch', Config.defaultSquelch ~= false, 'boolean')
    Radar.patrolCutoff      = savedNumber(data, 'patrolCutoff', Config.defaultPatrolCutoff or 20)
    Radar.stopwatchOn       = savedValue(data, 'stopwatchOn', Config.defaultStopwatch == true, 'boolean')
    Radar.alertClosingSpeed = savedNumber(data, 'alertClosingSpeed', Config.defaultAlertClosingSpeed or 30, 1, 200)
    Radar.antennaCount      = (savedNumber(data, 'antennaCount', Config.defaultAntennaCount or 2) == 1) and 1 or 2

    Radar.audMoving     = savedNumber(data, 'audMoving', Config.defaultAudMoving or 3, 0, 4)
    Radar.audStationary = savedNumber(data, 'audStationary', Config.defaultAudStationary or 3, 0, 4)
    Radar.beepLevel     = savedNumber(data, 'beepLevel', Config.defaultBeepLevel or 2, 0, 3)
    Radar.voiceLevel    = savedNumber(data, 'voiceLevel', Config.defaultVoiceLevel or 2, 0, 3)

    Radar.stopwatchDistanceFt = savedNumber(data, 'stopwatchDistanceFt',
        Config.defaultStopwatchDistanceFt or 1320, 0, 9999)

    setDopplerMode(savedValue(data, 'dopplerMode', 'off', 'string'))
    Radar.dopplerSource = savedValue(data, 'dopplerSource', Config.dopplerSource or 'strongest', 'string')

    --[[ Operational state. Loaded here, but it does not reach the display until the operator
         presses PWR: the unit always starts dark, so this is staged and picked up by the
         first power-on. See applyRadarPowerOn. ]]
    if type(data.rows) == 'table' then
        applyRowSave(Radar.rows.front, data.rows.front)
        applyRowSave(Radar.rows.rear, data.rows.rear)
    end
    setStationaryMode(savedValue(data, 'stationaryMode', false, 'boolean'))

    --[[ PS BLANK positions 2 and 3 show a lock's captured patrol speed, and locks do not
         persist - so a saved 2 or 3 would come back pointing at nothing. Clamp to the two
         positions that stand on their own. ]]
    local psBlank = savedNumber(data, 'psBlankMode', 0, 0, 3)
    Radar.psBlankMode = (psBlank == 1) and 1 or 0

    restoredOperationalState = Config.rememberOperationalState ~= false
end

local function settingsSnapshot()
    return {
        speedUnit = Radar.speedUnit,
        plateReaderEnabled = Radar.plateReaderEnabled,
        detectionZoneDebug = Radar.detectionZoneDebug,

        rows = {
            front = serializeRow(Radar.rows.front),
            rear = serializeRow(Radar.rows.rear),
        },
        stationaryMode = Radar.stationaryMode,

        fasterDisplay     = Radar.fasterDisplay,
        oppSen            = Radar.oppSen,
        sameSen           = Radar.sameSen,
        squelch           = Radar.squelch,
        patrolCutoff      = Radar.patrolCutoff,
        stopwatchOn       = Radar.stopwatchOn,
        alertClosingSpeed = Radar.alertClosingSpeed,
        antennaCount      = Radar.antennaCount,

        audMoving     = Radar.audMoving,
        audStationary = Radar.audStationary,
        beepLevel     = Radar.beepLevel,
        voiceLevel    = Radar.voiceLevel,

        stopwatchDistanceFt = Radar.stopwatchDistanceFt,
        psBlankMode = Radar.psBlankMode,

        dopplerMode = Radar.dopplerMode,
        dopplerEnabled = Radar.dopplerEnabled,
        dopplerSource = Radar.dopplerSource,
    }
end

local settingsDirty = false

local function flushSettings()
    if not settingsDirty then return end
    settingsDirty = false
    SetResourceKvp(KVP_SETTINGS, json.encode(settingsSnapshot()))
end

--[[ Mark the settings as needing a write.

     Deferred rather than immediate because several callers fire on key repeat - holding
     up on ALE rt or the stopwatch distance walks the value several times a second, and
     each of those is a setting change worth keeping. Coalescing them into one write per
     tick keeps that honest without hammering KVP. The flush thread is right below, and
     onResourceStop flushes too, so nothing is lost on the way out. ]]
local function saveSettings()
    settingsDirty = true
end

CreateThread(function()
    while true do
        Wait(500)
        flushSettings()
    end
end)

--- Decode JSON from a KVP key (display / plate layout, etc.)
local function loadKvpJson(key)
    local raw = GetResourceKvpString(key)
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if ok and data then return data end
    return nil
end

local function saveKvpJson(key, data)
    if data and type(data) == 'table' then
        SetResourceKvp(key, json.encode(data))
    end
end

local function sendInitDisplayConfig()
    SendNUIMessage({
        _type = 'init',
        display = loadKvpJson(KVP_DISPLAY) or Config.displayDefaults,
        plateDisplay = loadKvpJson(KVP_PLATE_DISPLAY) or Config.plateReaderDefaults,
        remoteDisplay = loadKvpJson(KVP_REMOTE) or Config.remoteDefaults,
        holdThresholdMs = Config.holdThresholdMs or 500,
    })
end

--[[ ---------------------------------------------------------------------------
     OPERATOR MENU (manual pp.21-22)

     Eight steps, walked with the MENU key and edited with the two centre keys, which stop
     being Hold and become up and down for as long as a menu is open. Any Target
     Zone key drops straight back to radar mode.

     The display convention is the one the whole radar uses for text: a six-character
     message is split across the two middle (LOCK/FAST) windows, three characters each,
     and the VALUE goes in the patrol window. That is why the manual prints the labels as
     "OP  SEn" and "StO  P" - it is showing you the two windows side by side.
   --------------------------------------------------------------------------- ]]

local ON_OFF = { [true] = ' On', [false] = 'OFF' }

--- Low-end patrol cutoff shown three characters wide, since the patrol window is three
--- digits. The manual writes these as Lo5 / Lo10 / L20.
local PAT_TEXT = { [5] = 'Lo5', [10] = 'L10', [20] = 'L20' }

local MENU_STEPS = {
    {
        id = 'faster', top = 'FAS', bot = '   ',
        available = function() return Config.optFasterEnable ~= false end,
        value = function() return ON_OFF[Radar.fasterDisplay] end,
        adjust = function() Radar.fasterDisplay = not Radar.fasterDisplay end,
    },
    {
        id = 'oppSen', top = 'OP ', bot = 'SEn',
        value = function() return string.format('%3d', Radar.oppSen) end,
        adjust = function(dir) Radar.oppSen = math.max(0, math.min(4, Radar.oppSen + dir)) end,
    },
    {
        id = 'sameSen', top = 'SL ', bot = 'SEn',
        value = function() return string.format('%3d', Radar.sameSen) end,
        adjust = function(dir) Radar.sameSen = math.max(0, math.min(4, Radar.sameSen + dir)) end,
    },
    {
        id = 'squelch', top = 'SqL', bot = '   ',
        value = function() return ON_OFF[Radar.squelch] end,
        adjust = function() Radar.squelch = not Radar.squelch end,
    },
    {
        id = 'patrolCutoff', top = 'PAt', bot = '   ',
        value = function() return PAT_TEXT[Radar.patrolCutoff] or 'L20' end,
        adjust = function(dir)
            local opts = Config.patrolSpeedThresholds or { 5, 10, 20 }
            local idx = 1
            for i, v in ipairs(opts) do if v == Radar.patrolCutoff then idx = i break end end
            Radar.patrolCutoff = opts[((idx - 1 + dir) % #opts) + 1]
        end,
    },
    {
        id = 'stopwatch', top = 'StO', bot = '  P',
        available = function() return Config.optStopwatchEnable ~= false end,
        value = function() return ON_OFF[Radar.stopwatchOn] end,
        adjust = function() Radar.stopwatchOn = not Radar.stopwatchOn end,
    },
    {
        id = 'alert', top = 'ALE', bot = ' rt',
        available = function() return Config.optTrafficAlert ~= false end,
        value = function() return string.format('%3d', Radar.alertClosingSpeed) end,
        --- Manual p.22: the up/down keys accelerate after about a second of being held.
        --- `step` is supplied by the repeat handler.
        adjust = function(dir, step)
            Radar.alertClosingSpeed = math.max(1, math.min(200, Radar.alertClosingSpeed + dir * (step or 1)))
        end,
    },
    {
        id = 'antennas', top = 'Ant', bot = '   ',
        value = function() return string.format('%3d', Radar.antennaCount) end,
        adjust = function() Radar.antennaCount = (Radar.antennaCount == 2) and 1 or 2 end,
    },
}

local function menuStepAvailable(step)
    return step and (step.available == nil or step.available())
end

--- Advance to the next *available* step, wrapping past any the Options menu has hidden.
--- Returns false when the walk has gone all the way round, which exits the menu.
local function advanceMenuStep()
    for _ = 1, #MENU_STEPS do
        Radar.menuStep = Radar.menuStep + 1
        if Radar.menuStep > #MENU_STEPS then return false end
        if menuStepAvailable(MENU_STEPS[Radar.menuStep]) then return true end
    end
    return false
end

--[[ ---------------------------------------------------------------------------
     VOLUME (manual p.14)

     The VOLUME key walks Aud -> bEE P -> UOI CE and then back out to radar mode; up/down
     edit whichever is showing. Aud follows MOV/STA, so adjusting it while parked sets the
     stationary level and leaves the moving level alone.
   --------------------------------------------------------------------------- ]]

local VOLUME_STEPS = {
    {
        id = 'aud', top = 'Aud', bot = '   ', max = 4,
        get = audLevel,
        set = function(v)
            if Radar.stationaryMode then Radar.audStationary = v else Radar.audMoving = v end
        end,
    },
    { id = 'beep',  top = 'bEE', bot = ' P ', max = 3,
      get = function() return Radar.beepLevel end,  set = function(v) Radar.beepLevel = v end },
    { id = 'voice', top = 'UOI', bot = 'CE ', max = 3,
      get = function() return Radar.voiceLevel end, set = function(v) Radar.voiceLevel = v end },
}

--[[ ---------------------------------------------------------------------------
     STOPWATCH MODE (manual pp.28-29)

     A plain average-speed timer for a marked measurement zone: enter the zone length in
     feet with up/down, hit START as the target crosses the first mark and STOP as it
     crosses the second. The unit reports

         mph = 0.682 x Distance(ft) / Time(s)

     which is just ft/s -> mph (3600/5280 = 0.6818) with the manual's rounding. Any Target
     Zone key exits back to radar mode.
   --------------------------------------------------------------------------- ]]

local function stopwatchStart()
    Radar.stopwatchRunning = true
    Radar.stopwatchStartMs = GetGameTimer()
    Radar.stopwatchResultMph = nil
    Radar.stopwatchError = false
end

local function stopwatchStop()
    Radar.stopwatchRunning = false
    local startMs = Radar.stopwatchStartMs
    Radar.stopwatchStartMs = nil
    if not startMs then return end
    local seconds = (GetGameTimer() - startMs) / 1000.0
    -- The hardware reports Err when the timebase reading is nonsense; the only way to get
    -- there here is a run too short to be a real measurement.
    if seconds < 0.1 then
        Radar.stopwatchError = true
        Radar.stopwatchResultMph = nil
        return
    end
    local factor = Config.stopwatchFeetPerSecToMph or 0.682
    Radar.stopwatchResultMph = math.floor((factor * (Radar.stopwatchDistanceFt or 0) / seconds) + 0.5)
    Radar.stopwatchError = false
end

local function stopwatchToggle()
    if Radar.stopwatchRunning then stopwatchStop() else stopwatchStart() end
end

--[[ ---------------------------------------------------------------------------
     REAR TRAFFIC ALERT (manual p.5)

     "An English Horn tone will sound and ALE rt will flash in the rear antenna speed
      windows when a vehicle approaches the patrol vehicle from the rear at a speed greater
      than the Alert Closing Speed."

     Three details from the manual that are easy to miss and all change how it feels:

       * It is INDEPENDENT of the rear zone selection - the alert watches behind you even
         when the rear antenna is pointed at same-lane traffic - but it is disabled while
         the rear antenna is in HLd.
       * Sensitivity is deliberately cut to below SEn 1 "to ensure close proximity", so it
         fires on the car actually coming up on your bumper, not one a quarter mile back.
       * It only arms while the radar senses the patrol vehicle ACCELERATING, which is the
         situation it exists for: pulling away from a stop into traffic you cannot see.
   --------------------------------------------------------------------------- ]]

local lastPatrolSpeedMph = 0.0
local lastPatrolSpeedAt = 0
local patrolAccelMphPerSec = 0.0

--- Called once per update tick with the current patrol speed.
local function trackPatrolAcceleration(patrolMph)
    local now = GetGameTimer()
    local dt = (now - lastPatrolSpeedAt) / 1000.0
    if lastPatrolSpeedAt > 0 and dt >= 0.05 then
        -- Light smoothing: raw frame-to-frame deltas in GTA are noisy enough to flicker
        -- the alert on and off at a steady cruise.
        local raw = (patrolMph - lastPatrolSpeedMph) / dt
        patrolAccelMphPerSec = patrolAccelMphPerSec * 0.7 + raw * 0.3
        lastPatrolSpeedMph = patrolMph
        lastPatrolSpeedAt = now
    elseif lastPatrolSpeedAt == 0 then
        lastPatrolSpeedMph = patrolMph
        lastPatrolSpeedAt = now
    end
end

--- Is there a vehicle closing on the rear bumper fast enough to warrant the horn?
local function evaluateRearTrafficAlert(captured)
    if Config.optTrafficAlert == false then return false end
    if not Radar.power then return false end
    local rear = Radar.rows.rear
    if not rear or rear.hold or not rear.xmit then return false end
    if patrolAccelMphPerSec < (Config.alertMinAccelMphPerSec or 1.5) then return false end

    local range = Config.alertRangeUnits or 90
    local threshold = Radar.alertClosingSpeed or 30
    for _, v in ipairs(captured) do
        if antennaFromRelPos(v.relPos) == 'rear' and v.dist <= range then
            -- rangeRate is negative when closing; compare its magnitude in mph.
            local closingMph = -Utils.ConvertSpeed(v.rangeRate or 0.0, 'mph')
            if closingMph > threshold then return true end
        end
    end
    return false
end

--- Raises or clears the alert, and tells the NUI when the state changes so it can start
--- and stop the horn rather than retriggering it every tick.
local function setAlertActive(active)
    if active == Radar.alertActive then return end
    Radar.alertActive = active
    Radar.alertSince = GetGameTimer()
    SendNUIMessage({ _type = 'trafficAlert', active = active, vol = beepVol() })
end

--[[ ---------------------------------------------------------------------------
     Power
   --------------------------------------------------------------------------- ]]

--[[ Defaults when powering on.

     Both antennas come up transmitting with one zone each, which is the 2X's whole point -
     you should not have to pick an antenna. Manual Fig. 28 shows the unit in moving mode
     with the front antenna on opposite lane and the rear on same lane, which is the normal
     patrol configuration: oncoming traffic ahead, overtaking traffic behind.

     Operator Menu values are NOT reset here. They are the operator's standing preferences
     and survive a power cycle on the hardware.

     Only runs when Config.rememberOperationalState is off - by default the operator's zones
     come back on every power-on, restart or not. See applyRadarPowerOn. ]]
local function applyOperationalDefaultsWhenPoweringOn()
    for _, key in ipairs(ROW_KEYS) do
        local row = Radar.rows[key]
        local d = (Config.rowDefaults or {})[key] or {}
        row.xmit = d.xmit ~= false
        row.hold = false
        row.zones.same = (d.zones and d.zones.same) == true
        row.zones.opp = (d.zones and d.zones.opp) == true
        row.lastZonePressed = nil
        row.lastZonePressAt = 0
    end
    setStationaryMode(false)
    Radar.psBlankMode = 0
end

--- Never let a row come up deaf, whether both zones were left off by the config defaults
--- or by a save written before selectRowZone guaranteed one would always be lit.
local function ensureRowsCanHear()
    for _, key in ipairs(ROW_KEYS) do
        local row = Radar.rows[key]
        if not row.zones.same and not row.zones.opp then
            row.zones[key == 'rear' and 'same' or 'opp'] = true
        end
    end
end

--[[ State that is nobody's setting - it just has to be sane when the head lights up.
     Runs on every power-on, restored or not. ]]
local function resetTransientStateWhenPoweringOn()
    Radar.uiMode = 'radar'
    Radar.menuStep = 0
    Radar.volumeStep = 0
    Radar.stopwatchRunning = false
    Radar.stopwatchStartMs = nil
    Radar.stopwatchResultMph = nil
    Radar.stopwatchError = false
    setAlertActive(false)
end

--[[ ---------------------------------------------------------------------------
     NUI update
   --------------------------------------------------------------------------- ]]

--[[ A row with nothing lit on it: both windows blank and all eleven lamps out.

     The zone lamps, XMIT and the FRONT/REAR lamp are driven off saved row state, so without
     this they paint whatever the operator last had selected even with no power behind the
     face. ]]
local function darkRowPayload()
    local empty = Utils.FormatSpeedEmpty()
    return {
        target = empty, middle = empty,
        same = false, opp = false, xmit = false,
        front = false, rear = false, fast = false, lock = false,
        targetFrontArrow = false, targetRearArrow = false,
        fastFrontArrow = false, fastRearArrow = false,
    }
end

--- Builds the per-row half of the NUI payload.
local function buildRowPayload(rowKey, row)
    local empty = Utils.FormatSpeedEmpty()
    local unit = Radar.speedUnit

    local targetText = empty
    local middleText = empty
    local lampFast, lampLock = false, false
    local targetUp, targetDown = false, false
    local fastUp, fastDown = false, false

    -- No power: the head can still be on screen (the remote opens it, so does a layout
    -- adjust) but nothing on it is lit until the PWR key is pressed.
    -- Ant 1: the rear antenna does not exist, so the whole bottom row goes dark too.
    if not Radar.power or not rowEnabled(rowKey) then
        return darkRowPayload()
    end

    --[[ Left orange window: live strongest target for this antenna.

         Arrow direction is per-antenna (see arrowForRow). The window's "front" arrow is
         the UP arrow in the artwork and "rear" is DOWN - the names are positional
         leftovers from the single-antenna DUAL DSR. ]]
    if row.targetSpeed and row.targetSpeed >= 0.1 then
        targetText = Utils.FormatSpeed(Utils.ConvertSpeed(row.targetSpeed, unit))
        local a = arrowForRow(rowKey, row.targetDir)
        targetUp, targetDown = a == 'up', a == 'down'
    end

    -- Middle red window is dual-purpose: it holds a locked strongest-target speed with the
    -- LOCK icon lit, and otherwise shows the faster target with the FAST icon lit.
    local middleDir = nil
    if row.locked and row.lockedSpeed then
        middleText = Utils.FormatSpeed(Utils.ConvertSpeed(row.lockedSpeed, unit))
        lampLock = true
        middleDir = row.lockedDir
    elseif row.fastLocked and row.fastLockedSpeed then
        middleText = Utils.FormatSpeed(Utils.ConvertSpeed(row.fastLockedSpeed, unit))
        lampFast = true
        lampLock = true   -- a captured FAST speed lights LOCK as well; it is a lock.
        middleDir = row.fastLockedDir
    elseif row.fastSpeed and row.fastSpeed >= 0.1 then
        middleText = Utils.FormatSpeed(Utils.ConvertSpeed(row.fastSpeed, unit))
        lampFast = true
        middleDir = row.fastDir
    end
    if middleDir then
        local a = arrowForRow(rowKey, middleDir)
        fastUp, fastDown = a == 'up', a == 'down'
    end

    --[[ HOLD (manual p.13).

         "The transmitter for that antenna will be turned off and the display will show HLd
          in the appropriate lock window. All the mode icons and directional arrows for that
          antenna will remain ON except the XMIT icon will turn OFF."

         So this is deliberately NOT an early return that blanks the row: the zone lamps,
         the FRONT/REAR lamp and the arrows all stay exactly as they were. Only XMIT drops,
         the live target window empties (nothing is being transmitted), and HLd replaces the
         lock window - unless that antenna is holding a lock, which stays on display. ]]
    if row.hold then
        targetText = empty
        targetUp, targetDown = false, false
        if not (lampLock and row.lockedSpeed) and not (lampFast and row.fastLockedSpeed) then
            middleText = 'HLd'
            lampFast, lampLock = false, false
            fastUp, fastDown = false, false
        end
    end

    --[[ REAR TRAFFIC ALERT (manual p.5): "ALE rt will flash in the rear antenna speed
         windows". Six characters across the rear row's two windows, blinking. It overrides
         whatever those windows were showing for as long as it is up. ]]
    if rowKey == 'rear' and Radar.alertActive then
        local on = math.floor((GetGameTimer() - (Radar.alertSince or 0)) / (Config.alertFlashMs or 400)) % 2 == 0
        if on then
            targetText, middleText = 'ALE', ' rt'
        else
            targetText, middleText = empty, empty
        end
        targetUp, targetDown, fastUp, fastDown = false, false, false, false
    end

    -- FRONT / REAR lamp: the row's own antenna by default (that is what the hardware
    -- indicates), or the side the current target sits on when the operator prefers it.
    local iconSide = rowKey
    if Config.rowIconFollowsTargetSide and row.targetSide then
        iconSide = row.targetSide
    end

    return {
        target = targetText,
        middle = middleText,
        -- Zone lamps track the SELECTION, not the transmitter — they stay lit in HLd.
        same = row.zones.same,
        opp = row.zones.opp,
        xmit = row.xmit and not row.hold,
        front = iconSide == 'front',
        rear = iconSide == 'rear',
        fast = lampFast,
        lock = lampLock,
        targetFrontArrow = targetUp,
        targetRearArrow = targetDown,
        fastFrontArrow = fastUp,
        fastRearArrow = fastDown,
    }
end

--[[ Patrol window text.

     Four things can own this window, in priority order:

       1. A menu. Operator Menu, VOLUME and Stopwatch all put their VALUE here while their
          six-character LABEL occupies the two lock windows.
       2. PS BLANK (manual p.13). Three positions when a lock exists: blanked, the patrol
          speed captured by the front lock, the patrol speed captured by the rear lock.
       3. Stationary mode - the window is simply BLANK. There is no patrol speed to show
          when the patrol car is parked, and unlike the DUAL DSR the 2X has no legend to
          put there instead, because the direction lives in the zone lamps.
       4. Moving mode - the live patrol speed, or the [] legend when it is below the PAt
          cutoff or the car is stopped.

     Returns the three-character patrol string. ]]
local function patrolWindowText(patrolSpeedMs)
    local empty = Utils.FormatSpeedEmpty()
    if not Radar.power then return empty end

    if Radar.uiMode == 'menu' then
        local step = MENU_STEPS[Radar.menuStep]
        if step then return step.value() end
    elseif Radar.uiMode == 'volume' then
        local step = VOLUME_STEPS[Radar.volumeStep]
        if step then return string.format('%3d', step.get()) end
    elseif Radar.uiMode == 'stopwatch' then
        if Radar.stopwatchError then return 'Err' end
        if Radar.stopwatchResultMph then return Utils.FormatSpeed(Radar.stopwatchResultMph) end
        -- Distance runs up to 9999 ft but the window is three digits, so anything over
        -- 999 shows in hundreds of feet, matching how the hardware pages the value.
        local d = Radar.stopwatchDistanceFt or 0
        return d > 999 and string.format('%3d', math.floor(d / 10)) or string.format('%3d', d)
    end

    -- Stationary mode blanks the patrol window (manual p.12).
    if Radar.stationaryMode then return empty end

    local mode = Radar.psBlankMode or 0
    if mode == 1 then
        return empty
    elseif mode == 2 or mode == 3 then
        local row = Radar.rows[mode == 2 and 'front' or 'rear']
        if row.lockedPatrolSpeed then return Utils.FormatSpeed(row.lockedPatrolSpeed) end
        return empty
    end

    local patrolUnit = Utils.ConvertSpeed(patrolSpeedMs, Radar.speedUnit)
    if patrolSpeedMs < 0.01 or patrolUnit < (Radar.patrolCutoff or 20) then
        --[[ Moving mode with nothing to show: the manual's "no patrol speed" legend.

             The brackets sit on the middle and right digits, not split across the full
             window. Spread to '[ ]' the empty digit between them reads as two unrelated
             marks instead of one legend - same call seeker_dual made. ]]
        return ' []'
    end
    return Utils.FormatSpeed(patrolUnit)
end

--[[ Automatic MOV / STA.

     The newer heads pick the mode themselves, and there is nothing to pick from: the mode is
     "is the patrol car rolling", which the radar can already see. Drive off and it goes to
     moving; park and a few seconds later it goes to stationary. The MOV/STA key still works -
     it just gets overruled once the car has disagreed with it for long enough.

     Two different delays, deliberately. Moving comes back almost at once, because pulling
     away is unambiguous and the operator wants patrol speed on the window now. Stationary
     waits, because a red light, a stop sign and a queue are not the operator parking up, and
     flipping at every junction would tear the zone selection about - dropping into moving
     collapses a bi-directional row down to one zone and there is no undoing that. ]]
local AUTO_MOVING_DELAY_MS = 750
local AUTO_STATIONARY_DELAY_MS = 3000
local autoModeWanted = nil
local autoModeWantedSince = 0

local function updateAutoMovSta(plySpeed)
    local wantStationary = plySpeed <= PARKED_SPEED_MS

    -- Already where the car says it should be: nothing pending.
    if wantStationary == Radar.stationaryMode then
        autoModeWanted = nil
        return
    end

    local now = GetGameTimer()
    if autoModeWanted ~= wantStationary then
        autoModeWanted = wantStationary
        autoModeWantedSince = now
        return
    end

    local delay = wantStationary and AUTO_STATIONARY_DELAY_MS or AUTO_MOVING_DELAY_MS
    if now - autoModeWantedSince < delay then return end

    autoModeWanted = nil
    setStationaryMode(wantStationary)
    saveSettings()
end

--- Send full state to NUI
local function sendToNUI()
    local plyVeh = Player:GetVehicle()
    local patrolSpeed = Player:GetPatrolSpeed()
    local patrolMph = Utils.ConvertSpeed(patrolSpeed, 'mph')
    trackPatrolAcceleration(patrolMph)

    --[[ Manual p.13: a lock also holds the patrol speed "until the patrol vehicle comes to
         a stop". Releasing it here rather than at unlock is what makes PS BLANK positions
         2 and 3 behave - they keep showing the speed you were doing when you locked. ]]
    if patrolMph < 1.0 then
        for _, key in ipairs(ROW_KEYS) do Radar.rows[key].lockedPatrolSpeed = nil end
    end

    -- Reset live values, then refill from a single shared capture pass.
    for _, key in ipairs(ROW_KEYS) do
        local row = Radar.rows[key]
        row.targetSpeed, row.targetDir, row.targetSide, row.targetZone = nil, nil, nil, nil
        row.fastSpeed, row.fastDir, row.fastZone = nil, nil, nil
    end

    local livePlate = {
        front = { text = lastPlate.front.text, style = lastPlate.front.style },
        rear  = { text = lastPlate.rear.text,  style = lastPlate.rear.style },
    }
    local rowScore = { front = nil, rear = nil }

    local testing = displayTestRunning()

    --[[ A menu owns the whole display, so the radar stops measuring behind it.

         Operator Menu, VOLUME and Stopwatch all take both lock windows for their label and
         the patrol window for their value - there is nowhere left to report a target, and
         acquiring one you cannot see (and could not lock, since the keys are menu keys while
         you are in there) only leaves stale numbers on screen the moment you exit. Existing
         locks are untouched: this stops new acquisition, it does not release anything. ]]
    local inMenu = Radar.uiMode ~= 'radar'

    if (not testing) and (not inMenu) and Player:CanViewRadar() and Radar.power and plyVeh and plyVeh > 0 and isRadarPlyMountedInPatrolVehicle(plyVeh) then
        local plySpeed = GetEntitySpeed(plyVeh)
        updateAutoMovSta(plySpeed)

        local captured = modeAllowsMeasurement(plySpeed) and captureVehicles(plyVeh, true) or {}

        setAlertActive(evaluateRearTrafficAlert(captured))

        for _, key in ipairs(ROW_KEYS) do
            local row = Radar.rows[key]
            local primary, primaryDir, fast, fastDir, plateHit = resolveRowTargets(captured, key, row)
            if primary then
                row.targetSpeed = primary.speed
                row.targetDir = primaryDir
                row.targetZone = primary.zone
                rowScore[key] = mergeScore(primary)
            end
            if plateHit then
                row.targetSide = antennaFromRelPos(plateHit.relPos)
                local text, style = getPlateDisplayData(plateHit.veh)
                livePlate[key].text, livePlate[key].style = text, style
                storeLastPlate(key, text, style)
            end
            if fast then
                row.fastSpeed = fast.speed
                row.fastDir = fastDir
                row.fastZone = fast.zone
            end
        end
    else
        setAlertActive(false)
    end

    local frontPayload = buildRowPayload('front', Radar.rows.front)
    local rearPayload = buildRowPayload('rear', Radar.rows.rear)
    local patrolFormatted = patrolWindowText(patrolSpeed)

    --[[ A menu's six-character label takes over the two LOCK windows, three characters
         each - the split the manual uses for every text message on this radar. ]]
    local menuLabel = nil
    if Radar.uiMode == 'menu' then
        menuLabel = MENU_STEPS[Radar.menuStep]
    elseif Radar.uiMode == 'volume' then
        menuLabel = VOLUME_STEPS[Radar.volumeStep]
    elseif Radar.uiMode == 'stopwatch' then
        menuLabel = { top = 'StO', bot = '  P' }
    end
    if menuLabel then
        frontPayload.middle = menuLabel.top
        rearPayload.middle = menuLabel.bot
        frontPayload.fast, frontPayload.lock = false, false
        rearPayload.fast, rearPayload.lock = false, false
        --[[ The target windows and their arrows are already dark - nothing was captured. The
             FAST/LOCK arrows are not: they follow a held lock, which survives the menu, so
             they would sit lit under a label that has nothing to do with them. ]]
        frontPayload.fastFrontArrow, frontPayload.fastRearArrow = false, false
        rearPayload.fastFrontArrow, rearPayload.fastRearArrow = false, false
    end

    --[[ Doppler comes from the TARGET window and nowhere else.

         The tone is the received audio off the strongest echo in the beam, and the TARGET
         window is that echo's speed - the two are the same signal. Neither of the other
         windows has audio of its own to contribute:

           FAST is a weaker, faster return pulled out of the same signal the TARGET reading
                came from. It is a second number off one beam, not a second beam, so it does
                not get its own tone.
           LOCK is a frozen number. There is nothing live behind it to listen to, and letting
                it drive the tone meant a standing lock pinned the pitch and went deaf to
                everything still moving through the beam.

         Only one row may drive the tone regardless, otherwise two pitches fight each other;
         that choice is made below off rowScore, which is also the TARGET reading's score. ]]
    local function rowDoppler(row)
        -- Transmitter off, so nothing is coming back. targetSpeed is already cleared when a
        -- row goes to HLd; this is explicit so it stays true if that ever changes.
        if row.hold then return nil end
        return row.targetSpeed
    end

    local dopplerRowKey = 'front'
    if Radar.dopplerSource == 'rear' then
        dopplerRowKey = 'rear'
    elseif Radar.dopplerSource ~= 'front' then
        local fs, rs = rowScore.front, rowScore.rear
        if fs and rs then
            dopplerRowKey = (fs >= rs) and 'front' or 'rear'
        elseif rs and not fs then
            dopplerRowKey = 'rear'
        end
    end

    local dopplerSpeedMs = rowDoppler(Radar.rows[dopplerRowKey])
    if dopplerSpeedMs == nil and Radar.dopplerSource == 'strongest' then
        -- Chosen row is empty: fall back to the other one rather than going silent.
        local other = dopplerRowKey == 'front' and 'rear' or 'front'
        dopplerSpeedMs = rowDoppler(Radar.rows[other])
        if dopplerSpeedMs then dopplerRowKey = other end
    end

    --[[ Silent through the self-test and behind a menu. The capture pass above is already
         skipped for both, but squelch off leaves the tone free-running on an empty beam, which
         would still put the rushing noise over the diagnostic screens or the menu. ]]
    local dopplerSpeedMph = nil
    if (not testing) and (not inMenu) and dopplerAllowedAtPatrolSpeed(patrolSpeed) then
        --[[ Audio Squelch (manual p.22). On (the normal position) means the tone is only
             heard while a target is actually being tracked; off leaves it free-running,
             which on the hardware is the rushing noise of an empty beam - hence the 0.0,
             which is that idle noise rather than any target's speed. ]]
        if dopplerSpeedMs ~= nil or not Radar.squelch then
            dopplerSpeedMph = dopplerToneFromTarget(dopplerSpeedMs or 0.0)
        end
    end

    SendNUIMessage({
        _type = 'update',
        power = Radar.power,
        displayed = Radar.displayed and not Radar.hidden,
        patrolSpeed = patrolFormatted,
        top = frontPayload,
        bottom = rearPayload,
        dopplerSpeedMph = dopplerSpeedMph,
        dopplerPitchMin = Config.dopplerPitchMin,
        dopplerPitchMax = Config.dopplerPitchMax,
        dopplerPitchMaxSpeedMph = Config.dopplerPitchMaxSpeedMph,
        dopplerVolMin = Config.dopplerVolMin,
        dopplerVolMax = Config.dopplerVolMax,
        dopplerVolMaxSpeedMph = Config.dopplerVolMaxSpeedMph,
        dopplerVolume = audVol(),
        plateReaderVisible = Radar.plateReaderEnabled and Radar.displayed and not Radar.hidden and Radar.power,
        frontPlateText = Radar.rows.front.plateLocked and (Radar.rows.front.lockedPlate or livePlate.front.text) or livePlate.front.text,
        rearPlateText = Radar.rows.rear.plateLocked and (Radar.rows.rear.lockedPlate or livePlate.rear.text) or livePlate.rear.text,
        frontPlateStyle = Radar.rows.front.plateLocked and (Radar.rows.front.lockedPlateStyle or livePlate.front.style) or livePlate.front.style,
        rearPlateStyle = Radar.rows.rear.plateLocked and (Radar.rows.rear.lockedPlateStyle or livePlate.rear.style) or livePlate.rear.style,
        frontPlateLocked = Radar.rows.front.plateLocked or false,
        rearPlateLocked = Radar.rows.rear.plateLocked or false,
    })
    syncNuiFocus()
end

--- Exposed to client/sync.lua and client/exports.lua without making them globals.
Radar._sendToNUI = sendToNUI
Radar._saveSettings = saveSettings
Radar._rowIsLive = rowIsLive
Radar._rowZoneMode = rowZoneMode
Radar._zoneRange = zoneRange

--[[ ---------------------------------------------------------------------------
     Power / remote / layout
   --------------------------------------------------------------------------- ]]

--[[ Internal circuit test (manual pp.33-34).

     Reached by holding TEST, from the settings menu, or on the auto-test timer - power-on
     runs the short lamp test below instead. Every segment lit, then the internal checks
     (processor, memory, crystal, supply voltage, internal temperature), then the three
     reference speeds 10 / 35 / 65 that prove the display and the speed-computation path,
     then PAS S with a four-beep happy tone - or FAI L with twenty beeps. The NUI owns the
     timing; Lua only starts it.

     Tuning fork testing, which follows PASS on the real unit, is deliberately not modelled. ]]
local function runSelfTest()
    --[[ A second TEST press restarts the NUI sequence from zero, so the window restarts too
         rather than expiring early against the first run's stamp. ]]
    displayTestUntil = GetGameTimer() + SELF_TEST_DURATION_MS
    setAlertActive(false)
    SendNUIMessage({ _type = 'selfTest', vol = beepVol() })
    sendToNUI()  -- push the silenced state immediately instead of waiting for the next tick
end

--[[ Power-on lamp test.

     Only the segment-check step of the sequence above, held for three seconds: every lamp lit
     and 888 in all five windows, proving the display works, then straight into operation. The
     full self test is not run on power-up - it is nine seconds of diagnostics in front of an
     operator who just wants the radar working, and it is still one TEST hold away. ]]
local function runLampTest()
    displayTestUntil = GetGameTimer() + LAMP_TEST_DURATION_MS
    setAlertActive(false)
    SendNUIMessage({ _type = 'lampTest' })
    sendToNUI()
end

local function applyRadarPowerOn(clearLocks)
    autoTestTimer = 0
    if clearLocks then clearAllRadarLocks() end
    Radar.power = true
    Radar.displayed = true
    --[[ XMIT / zones / MOV-STA / PS BLANK are the group the real unit throws back to the
         factory positions every time you switch it on.

         Config.rememberOperationalState keeps them instead, and that is the default: the
         operator sets the radar up the way they run it and finds it that way on every
         power-on, whether or not a restart happened in between. Resetting them here also
         meant the saveSettings below wrote the factory positions over the saved ones, so a
         single power cycle permanently lost the setup - the reset has to not happen at all,
         not merely be skipped once.

         With it off this is hardware behaviour, except for the first switch-on after a
         restart: every session has to begin with a power-on, and letting that one reset
         would throw the saved configuration away before the operator ever saw it. ]]
    if Config.rememberOperationalState == false and not restoredOperationalState then
        applyOperationalDefaultsWhenPoweringOn()
    end
    restoredOperationalState = false
    ensureRowsCanHear()
    resetTransientStateWhenPoweringOn()
    saveSettings()
    sendToNUI()
    if Config.lampTestOnPowerUp ~= false then runLampTest() end
end

local function closeRemote()
    remoteOpen = false
    SendNUIMessage({ _type = 'hideRemote' })
    syncNuiFocus()
end

local function applyRadarPowerOff(alsoCloseRemote)
    autoTestTimer = 0
    Radar.power = false
    Radar.displayed = false
    clearAllRadarLocks()
    saveSettings()
    SendNUIMessage({ _type = 'audio', name = 'XmitOff', vol = beepVol() })
    sendToNUI()
    if alsoCloseRemote then closeRemote() end
end

local function openRemote()
    if not Player:CanControlRadar() then return end
    Radar.displayed = true
    remoteOpen = true
    SendNUIMessage({ _type = 'showRemote', debug = Config.remoteDebug })
    sendToNUI()
end

--- PWR / `/seeker2x_move` / remote "DSR UI": radar layout adjust (remote can stay open).
beginRadarPositionAdjust = function()
    Radar.displayed = true
    Radar.nuiLayoutAdjust = true
    sendToNUI()
    SendNUIMessage({ _type = 'adjustMode' })
end

--- `/prmove2x` / remote "PR UI": plate layout adjust (remote can stay open).
beginPlateReaderPositionAdjust = function()
    Radar.displayed = true
    Radar.plateReaderEnabled = true
    saveSettings()
    Radar.nuiLayoutAdjust = true
    sendToNUI()
    SendNUIMessage({ _type = 'plateAdjustMode' })
end

--- PWR button path: clears locks, may close remote when powering off.
local function applySeekerPowerToggle()
    if not Radar.power then
        applyRadarPowerOn(true)
    else
        applyRadarPowerOff(true)
    end
end

--[[ ---------------------------------------------------------------------------
     Settings menu
   --------------------------------------------------------------------------- ]]

local ROW_TITLES = { front = 'Top row (FRONT antenna)', rear = 'Bottom row (REAR antenna)' }

local function zoneDescription(row)
    local parts = {}
    if row.zones.same then parts[#parts + 1] = 'Same' end
    if row.zones.opp then parts[#parts + 1] = 'Opposite' end
    if #parts == 0 then return 'Off' end
    return table.concat(parts, ' + ')
end

local function rowMenuOptions(rowKey, options)
    local row = Radar.rows[rowKey]
    options[#options + 1] = {
        title = ROW_TITLES[rowKey] .. ' - XMIT',
        description = row.hold and 'Hold (standby)' or (row.xmit and 'On' or 'Off'),
        icon = 'antenna',
        onSelect = function()
            if Radar.power then
                row.hold = false
                row.xmit = not row.xmit
                saveSettings()
                SendNUIMessage({ _type = 'audio', name = row.xmit and 'XmitOn' or 'XmitOff', vol = beepVol() })
            end
            openMenu()
        end,
    }
    options[#options + 1] = {
        title = ROW_TITLES[rowKey] .. ' - Zones',
        description = zoneDescription(row) .. (Radar.stationaryMode and '  (stationary: both allowed)' or '  (moving: one only)'),
        icon = 'arrows-left-right',
        onSelect = function()
            -- Menu cycles through the legal combinations for the current MOV/STA mode.
            -- Moving allows one zone; stationary adds the bi-directional pair.
            if not Radar.stationaryMode then
                row.zones.same, row.zones.opp = not row.zones.same, row.zones.same
            else
                if row.zones.same and row.zones.opp then
                    row.zones.same, row.zones.opp = true, false
                elseif row.zones.same then
                    row.zones.same, row.zones.opp = false, true
                else
                    row.zones.same, row.zones.opp = true, true
                end
            end
            saveSettings()
            sendToNUI()
            openMenu()
        end,
    }
    options[#options + 1] = {
        title = ROW_TITLES[rowKey] .. ' - Hold (standby)',
        description = row.hold and 'On - row shows HLd' or 'Off',
        icon = 'pause',
        onSelect = function()
            toggleRowHold(rowKey)
            saveSettings()
            sendToNUI()
            openMenu()
        end,
    }
    options[#options + 1] = {
        title = ROW_TITLES[rowKey] .. ' - Release locks',
        description = (row.locked and 'STRG locked' or 'No STRG lock')
            .. ' / ' .. (row.fastLocked and 'FAST locked' or 'No FAST lock'),
        icon = 'lock-open',
        onSelect = function()
            clearRowLock(rowKey)
            clearRowFastLock(rowKey)
            sendToNUI()
            openMenu()
        end,
    }
end

openMenu = function()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError()
        return
    end

    local options = {
        {
            title = 'Power',
            description = Radar.power and 'On' or 'Off',
            icon = 'power-off',
            onSelect = function()
                if not Radar.power then
                    applyRadarPowerOn(false)
                else
                    applyRadarPowerOff(false)
                end
                openMenu()
            end,
        },
        {
            title = 'Display',
            description = Radar.displayed and 'Visible' or 'Hidden',
            icon = 'display',
            onSelect = function()
                -- Not saved: visibility rides on the power switch, and that never persists.
                Radar.displayed = not Radar.displayed
                sendToNUI()
                openMenu()
            end,
        },
        {
            title = 'Speed Unit',
            description = Radar.speedUnit == 'mph' and 'MPH' or 'KM/H',
            icon = 'gauge',
            onSelect = function()
                Radar.speedUnit = Radar.speedUnit == 'mph' and 'kmh' or 'mph'
                saveSettings()
                sendToNUI()
                openMenu()
            end,
        },
        {
            title = 'Moving / Stationary (MOV STA)',
            description = Radar.stationaryMode
                and 'Stationary - zone keys select direction, patrol window blank'
                or 'Moving - zone keys select lane',
            icon = 'car',
            onSelect = function()
                toggleMovSta()
                saveSettings()
                sendToNUI()
                openMenu()
            end,
        },
    }

    rowMenuOptions('front', options)
    rowMenuOptions('rear', options)

    local tail = {
        {
            title = 'Operator Menu',
            description = 'FAS / OP SEn ' .. Radar.oppSen .. ' / SL SEn ' .. Radar.sameSen
                .. ' / SqL / PAt / StO P / ALE rt ' .. Radar.alertClosingSpeed .. ' / Ant ' .. Radar.antennaCount,
            icon = 'list-check',
            onSelect = function()
                local input = lib.inputDialog('Operator Menu', {
                    { type = 'checkbox', label = 'FAS - Faster Target Display', checked = Radar.fasterDisplay },
                    { type = 'number', label = 'OP SEn - Opposite Lane Sensitivity (0-4)', default = Radar.oppSen, min = 0, max = 4 },
                    { type = 'number', label = 'SL SEn - Same Lane Sensitivity (0-4)', default = Radar.sameSen, min = 0, max = 4 },
                    { type = 'checkbox', label = 'SqL - Audio Squelch (tone only while tracking)', checked = Radar.squelch },
                    { type = 'select', label = 'PAt - Low-End Speed Cutoff', default = tostring(Radar.patrolCutoff),
                      options = { { value = '5', label = 'Lo5' }, { value = '10', label = 'Lo10' }, { value = '20', label = 'L20' } } },
                    { type = 'checkbox', label = 'StO P - Stopwatch Mode', checked = Radar.stopwatchOn },
                    { type = 'number', label = 'ALE rt - Alert Closing Speed (1-200)', default = Radar.alertClosingSpeed, min = 1, max = 200 },
                    { type = 'select', label = 'Ant - Number of Antennas', default = tostring(Radar.antennaCount),
                      options = { { value = '1', label = '1 (front only)' }, { value = '2', label = '2' } } },
                })
                if input then
                    Radar.fasterDisplay     = input[1] == true
                    Radar.oppSen            = math.floor(input[2] or Radar.oppSen)
                    Radar.sameSen           = math.floor(input[3] or Radar.sameSen)
                    Radar.squelch           = input[4] == true
                    Radar.patrolCutoff      = tonumber(input[5]) or Radar.patrolCutoff
                    Radar.stopwatchOn       = input[6] == true
                    Radar.alertClosingSpeed = math.floor(input[7] or Radar.alertClosingSpeed)
                    Radar.antennaCount      = tonumber(input[8]) or Radar.antennaCount
                    saveSettings()
                    sendToNUI()
                end
                openMenu()
            end,
        },
        {
            title = 'Self Test',
            description = 'Full internal circuit test (same as holding TEST)',
            icon = 'vial',
            onSelect = function()
                runSelfTest()
                openMenu()
            end,
        },
        {
            title = 'Volume (Aud / bEE P / UOI CE)',
            description = 'Aud ' .. (Radar.stationaryMode and Radar.audStationary or Radar.audMoving)
                .. (Radar.stationaryMode and ' (stationary)' or ' (moving)')
                .. ' / bEE P ' .. Radar.beepLevel .. ' / UOI CE ' .. Radar.voiceLevel,
            icon = 'volume-high',
            onSelect = function()
                local input = lib.inputDialog('Volume', {
                    { type = 'number', label = 'Aud - Doppler, moving (0-4)', default = Radar.audMoving, min = 0, max = 4 },
                    { type = 'number', label = 'Aud - Doppler, stationary (0-4)', default = Radar.audStationary, min = 0, max = 4 },
                    { type = 'number', label = 'bEE P - Beeps (0-3)', default = Radar.beepLevel, min = 0, max = 3 },
                    { type = 'number', label = 'UOI CE - Voice enunciator (0-3)', default = Radar.voiceLevel, min = 0, max = 3 },
                })
                if input then
                    Radar.audMoving     = math.floor(input[1] or Radar.audMoving)
                    Radar.audStationary = math.floor(input[2] or Radar.audStationary)
                    Radar.beepLevel     = math.floor(input[3] or Radar.beepLevel)
                    Radar.voiceLevel    = math.floor(input[4] or Radar.voiceLevel)
                    saveSettings()
                    sendToNUI()
                end
                openMenu()
            end,
        },
        {
            title = 'Doppler Sound',
            description = DOPPLER_LABELS[Radar.dopplerMode] or 'Off',
            icon = 'wave-square',
            onSelect = function()
                cycleDopplerMode()
                saveSettings()
                sendToNUI()
                openMenu()
            end,
        },
        {
            title = 'Doppler Source',
            description = DOPPLER_SOURCE_LABELS[Radar.dopplerSource] or 'Strongest target',
            icon = 'tower-broadcast',
            onSelect = function()
                cycleDopplerSource()
                saveSettings()
                sendToNUI()
                openMenu()
            end,
        },
        {
            title = 'Plate Reader',
            description = Radar.plateReaderEnabled and 'On' or 'Off',
            icon = 'id-card',
            onSelect = function()
                Radar.plateReaderEnabled = not Radar.plateReaderEnabled
                saveSettings()
                sendToNUI()
                openMenu()
            end,
        },
        {
            title = 'Patrol Speed Window (PS BLANK)',
            description = PS_BLANK_LABELS[Radar.psBlankMode or 0],
            icon = 'eye-slash',
            onSelect = function()
                cyclePsBlank()
                saveSettings()
                sendToNUI()
                openMenu()
            end,
        },
        {
            title = 'Adjust Display Position',
            description = 'Drag to move, scroll to scale',
            icon = 'arrows-up-down-left-right',
            onSelect = function()
                lib.hideMenu()
                if not Player:CanControlRadar() then
                    notifyPoliceVehicleError('You must be in a police vehicle to move the radar display.')
                    return
                end
                beginRadarPositionAdjust()
            end,
        },
        {
            title = 'Adjust Plate Reader Position',
            description = 'Drag to move, scroll to scale',
            icon = 'arrows-up-down-left-right',
            onSelect = function()
                lib.hideMenu()
                if not Player:CanControlRadar() then
                    notifyPoliceVehicleError('You must be in a police vehicle to move the plate reader.')
                    return
                end
                beginPlateReaderPositionAdjust()
            end,
        },
        {
            title = 'Reset Display Position',
            icon = 'rotate-left',
            onSelect = function()
                DeleteResourceKvp(KVP_DISPLAY)
                SendNUIMessage({ _type = 'resetDisplay', display = Config.displayDefaults })
                openMenu()
            end,
        },
        {
            title = 'Reset Remote Position',
            description = 'Re-centers the remote at default size',
            icon = 'rotate-left',
            onSelect = function()
                DeleteResourceKvp(KVP_REMOTE)
                SendNUIMessage({ _type = 'resetRemoteDisplay', remoteDisplay = Config.remoteDefaults })
                openMenu()
            end,
        },
    }
    for _, opt in ipairs(tail) do options[#options + 1] = opt end

    lib.registerContext({
        id = 'seeker_dsr2x_menu',
        title = 'SEEKER DSR 2X - Radar Settings',
        options = options,
    })
    lib.showContext('seeker_dsr2x_menu')
end

--[[ ---------------------------------------------------------------------------
     Commands / keybinds
   --------------------------------------------------------------------------- ]]

RegisterCommand('seeker_dsr2x_menu', function()
    if remoteOpen then
        closeRemote()
    else
        openRemote()
    end
end, false)
RegisterKeyMapping('seeker_dsr2x_menu', 'Open DSR 2X Remote', 'keyboard', Config.defaultKeybind)

RegisterCommand('seeker2x_settings', function()
    openMenu()
end, false)

RegisterCommand('seeker2x_power', function()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError()
        return
    end
    applySeekerPowerToggle()
end, false)

if Config.keybindPower and Config.keybindPower ~= '' then
    RegisterKeyMapping('seeker2x_power', 'Toggle radar power (PWR)', 'keyboard', Config.keybindPower)
end

RegisterCommand('seeker2x_radar_debug', function()
    Radar.detectionZoneDebug = not Radar.detectionZoneDebug
    saveSettings()
    lib.notify({
        type = 'info',
        description = 'Radar zone debug: ' .. (Radar.detectionZoneDebug and 'ON' or 'OFF')
            .. ' — green = same-dir rays, orange = opp-dir; matches capture geometry.',
    })
end, false)

RegisterCommand('toggledoppler2x', function()
    cycleDopplerMode()
    saveSettings()
    sendToNUI()
    lib.notify({ type = 'info', description = 'Doppler sound: ' .. (DOPPLER_LABELS[Radar.dopplerMode] or 'Off') })
end, false)

RegisterCommand('togglepr2x', function()
    Radar.plateReaderEnabled = not Radar.plateReaderEnabled
    saveSettings()
    sendToNUI()
    lib.notify({ type = 'info', description = 'Plate reader: ' .. (Radar.plateReaderEnabled and 'ON' or 'OFF') })
end, false)

RegisterCommand('seeker2x_move', function()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError('You must be in a police vehicle to move the radar display.')
        return
    end
    beginRadarPositionAdjust()
end, false)

RegisterCommand('prmove2x', function()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError('You must be in a police vehicle to move the plate reader.')
        return
    end
    beginPlateReaderPositionAdjust()
end, false)

--[[ Digit window calibration.

     Opens the NUI's own calibration mode: the five digit windows become draggable, scroll
     resizes the glyphs and the boxes, and "Show CSS" prints a block to paste into
     nui/style.css as the new defaults. Positions are percentages of the face, so a
     calibration done at one head size is correct at every other one. ]]
RegisterCommand('seeker2x_windows', function()
    Radar.displayed = true
    Radar.nuiLayoutAdjust = true
    sendToNUI()
    SendNUIMessage({ _type = 'windowDebug', active = true })
    lib.notify({
        type = 'info',
        description = 'Window calibration: drag to move, scroll to size, A applies size to all, ESC exits.',
    })
end, false)

--- STRG lock toggle per row
local function toggleRowStrgLock(rowKey)
    if not Player:CanControlRadar() or not Radar.power then return end
    local row = getRow(rowKey)
    if row.locked then
        clearRowLock(rowKey)
    else
        acquireRowLock(rowKey)
    end
    sendToNUI()
end

--- FAST lock toggle per row
local function toggleRowFast(rowKey)
    if not Player:CanControlRadar() or not Radar.power then return end
    local row = getRow(rowKey)
    if row.fastLocked then
        clearRowFastLock(rowKey)
    else
        acquireRowFastLock(rowKey)
    end
    sendToNUI()
end

--- Plate lock toggle per row
local function toggleRowPlateLock(rowKey)
    if not Player:CanControlRadar() or not Radar.power then return end
    local row = getRow(rowKey)
    if row.plateLocked then
        clearRowPlateLock(rowKey)
    else
        acquireRowPlateLock(rowKey)
    end
    sendToNUI()
end

RegisterCommand('seeker2x_lock_front', function() toggleRowStrgLock('front') end, false)
RegisterCommand('seeker2x_lock_rear', function() toggleRowStrgLock('rear') end, false)
RegisterCommand('seeker2x_fast_front', function() toggleRowFast('front') end, false)
RegisterCommand('seeker2x_fast_rear', function() toggleRowFast('rear') end, false)
RegisterCommand('seeker2x_plate_lock_front', function() toggleRowPlateLock('front') end, false)
RegisterCommand('seeker2x_plate_lock_rear', function() toggleRowPlateLock('rear') end, false)

if Config.keybindLockFront and Config.keybindLockFront ~= '' then
    RegisterKeyMapping('seeker2x_lock_front', 'Toggle STRG Lock - Top Row (Front)', 'keyboard', Config.keybindLockFront)
end
if Config.keybindLockRear and Config.keybindLockRear ~= '' then
    RegisterKeyMapping('seeker2x_lock_rear', 'Toggle STRG Lock - Bottom Row (Rear)', 'keyboard', Config.keybindLockRear)
end
if Config.keybindFastLockFront and Config.keybindFastLockFront ~= '' then
    RegisterKeyMapping('seeker2x_fast_front', 'Toggle FAST Lock - Top Row (Front)', 'keyboard', Config.keybindFastLockFront)
end
if Config.keybindFastLockRear and Config.keybindFastLockRear ~= '' then
    RegisterKeyMapping('seeker2x_fast_rear', 'Toggle FAST Lock - Bottom Row (Rear)', 'keyboard', Config.keybindFastLockRear)
end
if Config.keybindPlateLockFront and Config.keybindPlateLockFront ~= '' then
    RegisterKeyMapping('seeker2x_plate_lock_front', 'Toggle Plate Lock - Front', 'keyboard', Config.keybindPlateLockFront)
end
if Config.keybindPlateLockRear and Config.keybindPlateLockRear ~= '' then
    RegisterKeyMapping('seeker2x_plate_lock_rear', 'Toggle Plate Lock - Rear', 'keyboard', Config.keybindPlateLockRear)
end

--[[ ---------------------------------------------------------------------------
     NUI callbacks
   --------------------------------------------------------------------------- ]]

--- NUI POST body: table (parsed JSON) or raw string depending on client; normalize to table.
local function parseNuiJsonData(data)
    if data == nil then return nil end
    if type(data) == 'table' then return data end
    if type(data) == 'string' then
        local ok, decoded = pcall(json.decode, data)
        if ok and type(decoded) == 'table' then return decoded end
    end
    return nil
end

RegisterNUICallback('saveDisplay', function(data, cb)
    saveKvpJson(KVP_DISPLAY, parseNuiJsonData(data))
    cb('ok')
end)

RegisterNUICallback('savePlateDisplay', function(data, cb)
    saveKvpJson(KVP_PLATE_DISPLAY, parseNuiJsonData(data))
    cb('ok')
end)

RegisterNUICallback('saveRemoteDisplay', function(data, cb)
    saveKvpJson(KVP_REMOTE, parseNuiJsonData(data))
    cb('ok')
end)

RegisterNUICallback('nuiReady', function(_, cb)
    sendInitDisplayConfig()
    cb('ok')
end)

RegisterNUICallback('exitAdjustMode', function(_, cb)
    Radar.nuiLayoutAdjust = false
    syncNuiFocus()
    cb('ok')
end)

RegisterNUICallback('exitWindowDebug', function(_, cb)
    Radar.nuiLayoutAdjust = false
    syncNuiFocus()
    sendToNUI()   -- put live values back in the windows the test pattern was holding
    cb('ok')
end)

RegisterNUICallback('exitPlateAdjustMode', function(data, cb)
    local d = parseNuiJsonData(data)
    if d then saveKvpJson(KVP_PLATE_DISPLAY, d) end
    Radar.nuiLayoutAdjust = false
    syncNuiFocus()
    cb('ok')
end)

RegisterNUICallback('closeRemote', function(_, cb)
    closeRemote()
    cb('ok')
end)

--[[ ---------------------------------------------------------------------------
     REMOTE

     The Fast Lock remote (manual p.12). Two conventions govern everything below:

     1. HOLD. "An underlined word on a key indicates that the key must be held down until
        two beeps are heard for that function to operate. The first beep occurs when the key
        is initially pressed and the second beep occurs when the key actuation delay time
        expires." On this remote only Hold is underlined, so the two centre keys are the
        only keys with a genuine hold function.

     2. MODAL KEYS. The four Target Zone keys are two-function keys, but NOT short/hold -
        which function you get depends on the state the radar is already in:

           "1. Press the OPP key to turn-on the corresponding transmitter (if it is in hold)
                and directly select the Opposite lane target zone for the associated antenna.
            2. Once the Opposite lane target zone is selected, the Opp Fast Lk/Rel key now
                becomes a Lock/Release key."

        The previous port had this exactly inverted - short press was Fast Lk/Rel and a hold
        selected the zone - which meant you could never select a zone without a long press
        and could Fast-lock a zone you were not even watching.

     Layout, top to bottom:

         [Front OPP ]  [ MENU  ]  [Front SAME]
         [   Hold   ]  [MOV/STA]  [   Hold   ]     <- top Hold = up, bottom Hold = down
         [Rear  OPP ]  [VOL/TST]  [Rear  SAME]
   --------------------------------------------------------------------------- ]]

--- Repeat acceleration for the menu up/down keys (manual p.22: "the speed of the change
--- will increase after approximately one second"). Consecutive presses in the same
--- direction inside this window grow the step.
local lastAdjustDir, lastAdjustAt, adjustRepeats = 0, 0, 0

local function adjustStepFor(dir)
    local now = GetGameTimer()
    if dir == lastAdjustDir and (now - lastAdjustAt) < 400 then
        adjustRepeats = adjustRepeats + 1
    else
        adjustRepeats = 0
    end
    lastAdjustDir, lastAdjustAt = dir, now
    if adjustRepeats >= 12 then return 10 end
    if adjustRepeats >= 6 then return 5 end
    return 1
end

--[[ Menu idle timeout. See Config.menuIdleTimeoutMs for the reasoning.

     Only 'menu' and 'volume' are on the clock. Stopwatch Mode is an operating mode, not a
     menu, and sitting in it waiting for a vehicle to reach the second mark is normal use. ]]
local MENU_IDLE_TIMEOUT_MS = math.max(0, Config.menuIdleTimeoutMs or 5000)
local lastMenuInputAt = 0

local function noteMenuActivity()
    lastMenuInputAt = GetGameTimer()
end

local function menuIdleExpired()
    if MENU_IDLE_TIMEOUT_MS <= 0 then return false end
    if Radar.uiMode ~= 'menu' and Radar.uiMode ~= 'volume' then return false end
    --[[ Powering off does not clear uiMode, so without this a menu left open when the unit
         went dark would time out - and beep - on a display nobody is looking at. There is
         also nothing to hand back to: the radar is already not working. ]]
    if not Radar.power then return false end
    -- A display test owns the display and the keypad for its full run; do not talk over it.
    if displayTestRunning() then return false end
    return (GetGameTimer() - lastMenuInputAt) >= MENU_IDLE_TIMEOUT_MS
end

--- Leave any menu and go back to normal radar operation.
local function exitToRadarMode()
    Radar.uiMode = 'radar'
    Radar.menuStep = 0
    Radar.volumeStep = 0
    saveSettings()
end

--[[ MENU key.

     Steps through the Operator Menu. Walking off the end exits - and if StO P was left On,
     exits into Stopwatch Mode, which is exactly how the manual describes arming it: "If the
     Stopwatch mode is turned On then when the operator exits the Operator menu the radar
     will enter the Stopwatch mode."

     Held, it opens this resource's own ox_lib settings menu, which has no counterpart on the
     hardware but is where the FiveM-specific things live (display position, plate reader,
     speed unit). ]]
local function pressMenuKey()
    noteMenuActivity()
    if Radar.uiMode == 'volume' or Radar.uiMode == 'stopwatch' then
        Radar.uiMode = 'radar'
    end
    if Radar.uiMode ~= 'menu' then
        Radar.uiMode = 'menu'
        Radar.menuStep = 0
    end
    if not advanceMenuStep() then
        exitToRadarMode()
        if Radar.stopwatchOn and Config.optStopwatchEnable ~= false then
            Radar.uiMode = 'stopwatch'
            Radar.stopwatchResultMph = nil
            Radar.stopwatchError = false
        end
    end
    beep()
end

--- VOLUME key: Aud -> bEE P -> UOI CE -> back to radar.
local function pressVolumeKey()
    noteMenuActivity()
    if Radar.uiMode ~= 'volume' then
        Radar.uiMode = 'volume'
        Radar.volumeStep = 0
    end
    Radar.volumeStep = Radar.volumeStep + 1
    if Radar.volumeStep > #VOLUME_STEPS then exitToRadarMode() end
    beep()
end

--[[ The two centre keys.

     In radar mode they are HOLD, on a plain press - in and out of standby for that antenna.
     No long press and no lock: locking lives on the zone keys, where a second press on the
     lane you are already watching is the natural thing to reach for with a car in the window.
     Splitting one key between standby and a citation speed on press length was always the
     easy way to lose a lock you meant to take.

     In any menu they become up and down - top row up, bottom row down - which is why the
     manual calls them the up/down keys when describing the Operator Menu. ]]
local function pressCentreKey(rowKey)
    if Radar.uiMode ~= 'radar' then
        noteMenuActivity()
        local dir = (rowKey == 'front') and 1 or -1
        local step = adjustStepFor(dir)
        if Radar.uiMode == 'menu' then
            local s = MENU_STEPS[Radar.menuStep]
            if s then s.adjust(dir, step) end
        elseif Radar.uiMode == 'volume' then
            local s = VOLUME_STEPS[Radar.volumeStep]
            if s then s.set(math.max(0, math.min(s.max, s.get() + dir))) end
        elseif Radar.uiMode == 'stopwatch' then
            -- Distance entry, max 9999 ft (manual p.28). Held, it moves in bigger jumps.
            local d = (Radar.stopwatchDistanceFt or 0) + dir * step * 10
            Radar.stopwatchDistanceFt = math.max(0, math.min(9999, d))
            Radar.stopwatchResultMph = nil
        end
        --[[ Every one of those three branches edits a setting the operator expects to still
             be there tomorrow, so save on the keystroke rather than waiting for the menu to
             be walked all the way out - a disconnect halfway through a menu would otherwise
             throw the edits away. The write itself is coalesced, so a held key is one write. ]]
        saveSettings()
        beep()
        return
    end

    -- "To exit the Hold mode, momentarily press the Hold key again." Same key both ways.
    toggleRowHold(rowKey)
    saveSettings()
    beep()
end

--[[ The four Target Zone keys.

     Order matters here - each branch is a state the manual describes:

       * Any zone key exits the Operator Menu, VOLUME and Stopwatch Mode back to radar mode.
       * A zone key on an antenna that is in HLd wakes it and selects that single zone. This
         is also the documented way out of stationary bi-directional: "press and hold the
         Hold key and then press either the OPP or SAME key to select a single target zone."
       * A zone that is not yet selected gets selected.
       * A zone that IS already selected turns the key into Lk/Rel for that row - it locks
         the speed standing in that row's TARGET window, and a second press releases it.
         The lane you are watching and the key you lock with are the same key, so a car in
         the SAME window is locked by pressing SAME again with your thumb already there.
         FAST Lk/Rel is not on the remote any more; it is still on its keybinds and its
         commands. ]]
local function pressZoneKey(rowKey, zone)
    if Radar.uiMode ~= 'radar' then
        exitToRadarMode()
        beep()
        return
    end

    local row = getRow(rowKey)

    if row.hold then
        selectRowZone(rowKey, zone, true)
        saveSettings()
        beep()
        return
    end

    if not row.zones[zone] then
        selectRowZone(rowKey, zone)
        saveSettings()
        beep()
        return
    end

    -- Zone already live: Lk/Rel on that row's TARGET.
    toggleRowStrgLock(rowKey)
end

--[[ MOV/STA, which becomes START/STOP while Stopwatch Mode is running. ]]
local function pressMovStaKey()
    if Radar.uiMode == 'stopwatch' then
        stopwatchToggle()
        beep()
        return
    end
    toggleMovSta()
    saveSettings()
    beep()
end

--- Remote button dispatch.
RegisterNUICallback('remoteBtn', function(data, cb)
    local d = parseNuiJsonData(data) or {}
    local action = d.action
    local rowKey = (d.row == 'rear' or d.row == 'bottom') and 'rear' or 'front'
    local isHold = d.hold == true

    if not Player:CanControlRadar() then cb('ok') return end

    -- Power works from any state; everything else needs the unit on.
    if action ~= 'power' and action ~= 'dsrUi' and action ~= 'prUi'
        and not Radar.power then
        cb('ok')
        return
    end

    if action == 'power' then
        applySeekerPowerToggle()

    elseif action == 'menu' then
        if isHold then openMenu() else pressMenuKey() end

    elseif action == 'sameZone' or action == 'oppZone' then
        pressZoneKey(rowKey, action == 'sameZone' and 'same' or 'opp')

    elseif action == 'strgLock' then
        pressCentreKey(rowKey)

    elseif action == 'movSta' then
        pressMovStaKey()

    elseif action == 'volTest' then
        if isHold then runSelfTest() else pressVolumeKey() end

    elseif action == 'psBlank' then
        cyclePsBlank()
        saveSettings()

    elseif action == 'plateLock' then
        toggleRowPlateLock(rowKey)

    elseif action == 'dsrUi' then
        beginRadarPositionAdjust()

    elseif action == 'prUi' then
        beginPlateReaderPositionAdjust()
    end

    sendToNUI()
    cb('ok')
end)

--- Direct row lock hooks for other resources / NUI shortcuts
RegisterNUICallback('lockTop', function(_, cb)
    toggleRowStrgLock('front')
    cb('ok')
end)

RegisterNUICallback('lockBottom', function(_, cb)
    toggleRowStrgLock('rear')
    cb('ok')
end)

--[[ ---------------------------------------------------------------------------
     Threads
   --------------------------------------------------------------------------- ]]

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        -- Settings writes are deferred by up to half a second; make sure the last one lands.
        flushSettings()
        forceNuiFocusOff()
    end
end)

--[[ Inputs to take back while the remote holds the mouse but the game holds the keyboard.

     Everything not listed here still works, which is the point - WASD, horn, sirens, your
     other keybinds. These are only the ones that fire wrongly with a cursor on screen:

       attack / aim        a click on a remote key must not also be a trigger pull, on foot
                           or on a vehicle-mounted weapon.
       melee               same, for the unarmed and melee variants.
       weapon wheel        so scrolling near the remote does not swap weapons.
       look / mouse        the mouse belongs to the cursor for now; without this the camera
                           drifts with it.
       pause               so ESC closes the remote instead of closing it AND pausing. ]]
local REMOTE_BLOCKED_CONTROLS = {
    24, 25, 257, 47,              -- attack, aim, attack2, detonate
    68, 69, 70,                   -- vehicle aim / attack / attack2
    140, 141, 142, 143, 263, 264, -- melee
    14, 15, 16, 17, 37,           -- weapon wheel and next/prev weapon
    1, 2, 106,                    -- look LR/UD, vehicle mouse control override
    199, 200,                     -- pause menu
}

--[[ Only runs while the remote is open in keep-input mode; every other state parks the thread
     on a quarter-second idle rather than burning a per-frame tick for nothing. ]]
CreateThread(function()
    while true do
        local blocking = remoteOpen and not Radar.nuiLayoutAdjust
            and Config.remoteKeepGameInput ~= false
        if blocking then
            for i = 1, #REMOTE_BLOCKED_CONTROLS do
                DisableControlAction(0, REMOTE_BLOCKED_CONTROLS[i], true)
            end
        end
        Wait(blocking and 0 or 250)
    end
end)

--- Init: load settings, send display config, prime the NUI
CreateThread(function()
    loadSettings()
    sendInitDisplayConfig()
    sendToNUI()
end)

--- Pause menu / expanded map: hide radar UI (single path via sendToNUI to avoid NUI flash).
local function isRadarDisplaySuppressed()
    if IsPauseMenuActive and IsPauseMenuActive() then return true end
    if IsBigmapActive then
        local ok, active = pcall(IsBigmapActive)
        if ok and active then return true end
    end
    return false
end

--- Main update loop
CreateThread(function()
    while true do
        -- Checked here rather than on a thread of its own so the display comes back on the
        -- same tick the menu closes, via the sendToNUI below.
        if menuIdleExpired() then
            exitToRadarMode()
            beep()
        end

        local suppress = (not Player:CanViewRadar()) or isRadarDisplaySuppressed()
        if suppress and Radar.displayed and not Radar.hidden then
            Radar.hidden = true
        elseif (not suppress) and Radar.displayed and Radar.hidden then
            Radar.hidden = false
        end

        sendToNUI()
        -- Doppler pitch/volume need finer time resolution than the 7-seg display;
        -- ~30 Hz avoids stepped pitch when speed changes smoothly.
        Wait((Radar.dopplerEnabled and Radar.power) and 33 or 100)
    end
end)

local AUTO_SELF_TEST_DEFAULT_INTERVAL = 600

--- Seconds between automatic self-tests, or nil when the feature is off.
local function getAutoSelfTestInterval()
    if not Config.autoSelfTest then return nil end
    local interval = Config.autoSelfTestInterval
    if type(interval) ~= 'number' or interval <= 0 then
        interval = AUTO_SELF_TEST_DEFAULT_INTERVAL
    end
    return interval
end

--- Auto self-test timer (real STALKER runs every 10 min)
CreateThread(function()
    while true do
        local interval = getAutoSelfTestInterval()
        if interval and Radar.power then
            autoTestTimer = autoTestTimer + 1
            if autoTestTimer >= interval then
                autoTestTimer = 0
                runSelfTest()
            end
        else
            autoTestTimer = 0
        end
        Wait(1000)
    end
end)

--- World overlay: visualize parallel rays + caps (same math as shootRay / captureVehicles).
CreateThread(function()
    while true do
        local show = (Config.detectionZoneDebug or Radar.detectionZoneDebug)
        if show and Player:CanViewRadar() then
            local plyVeh = Player:GetVehicle()
            if plyVeh and plyVeh > 0 and isRadarPlyMountedInPatrolVehicle(plyVeh) then
                drawRadarDetectionDebug(plyVeh)
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

--[[ ---------------------------------------------------------------------------
     ALPR
   --------------------------------------------------------------------------- ]]

-- Continuous ALPR scan: runs independently of plate lock, mirrors real 4-camera ALPR hardware.
-- Each vehicle within radius is queried once, then ignored until Config.alpr.rescanDelay
-- expires. Which CAD answers the query is entirely server/alpr.lua's business — this side only
-- reads plates and renders whatever normalised record comes back.
local alprScanned = {}   -- [plate] = gameTimer ms when last queried
local alprLockLookups = {} -- [plate] = gameTimer ms of the last lock-driven CAD lookup
local alprHitLog  = {}   -- session hit log, newest first, max 20

RegisterCommand('alprlog2x', function()
    if #alprHitLog == 0 then
        TriggerEvent('chat:addMessage', { args = { '[ALPR]', 'No hits this session.' } })
        return
    end
    TriggerEvent('chat:addMessage', { args = { '[ALPR]', ('Last %d hit(s):'):format(#alprHitLog) } })
    for i, entry in ipairs(alprHitLog) do
        local line = ('[%s] %s  %s  %s'):format(entry.time, entry.plate, entry.direction, entry.vehicle)
        if entry.owner ~= '' then line = line .. '  Owner: ' .. entry.owner end
        line = line .. '  !! ' .. entry.flags
        TriggerEvent('chat:addMessage', { args = { tostring(i), line } })
    end
end, false)

--- Locking a plate by hand is a deliberate act — the officer is about to pull the car over on
--- what comes back — so it goes straight to the CAD instead of reading a result the scanner
--- may have cached up to Config.alpr.cacheMinutes ago. Forward-declared above; see
--- acquireRowPlateLock.
---
--- Marks the plate as scanned on the way out, so the background pass doesn't turn round and
--- deliver a second notification for the same car off the freshly written cache entry.
---
--- Config.alpr.lockCooldown keeps re-locking the same car from becoming a way to poll the CAD.
--- Inside the window the lock still runs, it just reads the cache like any other scan. The
--- server enforces the same window — this side only saves the round trip.
runForcedAlpr = function(plate, direction)
    local alprCfg = Config.alpr
    if not alprCfg or not alprCfg.provider or alprCfg.provider == 'none' then return end
    if not Radar.power or not Radar.plateReaderEnabled then return end

    plate = type(plate) == 'string' and plate:gsub('%s+', '') or ''
    if plate == '' or plate == PLACEHOLDER_PLATE_TEXT then return end

    local now      = GetGameTimer()
    local cooldown = (tonumber(alprCfg.lockCooldown) or 0) * 1000
    local force    = true
    if cooldown > 0 then
        local last = alprLockLookups[plate]
        if last and (now - last) < cooldown then
            force = false
        else
            for p, t in pairs(alprLockLookups) do
                if (now - t) >= cooldown then alprLockLookups[p] = nil end
            end
            alprLockLookups[plate] = now
        end
    end

    alprScanned[plate] = now
    TriggerServerEvent('seeker_dsr2x:runAlpr', plate, direction, force)
end

CreateThread(function()
    while true do
        local alprCfg  = Config.alpr
        local interval = (alprCfg and alprCfg.scanInterval) or 2000
        Wait(interval)

        if not alprCfg or not alprCfg.provider or alprCfg.provider == 'none' then goto continue end
        if not Radar.power then goto continue end
        if not Radar.plateReaderEnabled then goto continue end

        local plyVeh = Player:GetVehicle()
        if not plyVeh or not isRadarPlyMountedInPatrolVehicle(plyVeh) then goto continue end

        local plyPos   = GetEntityCoords(plyVeh)
        local radius   = alprCfg.radius or 50.0
        local rescanMs = (alprCfg.rescanDelay or 120) * 1000
        local now      = GetGameTimer()

        -- Expire old scanned entries to keep the table from growing forever
        for plate, ts in pairs(alprScanned) do
            if (now - ts) > rescanMs then alprScanned[plate] = nil end
        end

        local vehs = getAllVehicles()
        for _, veh in ipairs(vehs) do
            if veh == plyVeh or not DoesEntityExist(veh) then goto next end

            local vehPos = GetEntityCoords(veh)
            if #(vehPos - plyPos) > radius then goto next end

            local plate = GetVehicleNumberPlateText(veh) or ''
            plate = plate:gsub('%s+', '')
            if plate == '' or plate == PLACEHOLDER_PLATE_TEXT then goto next end

            if alprScanned[plate] then goto next end
            alprScanned[plate] = now

            -- Determine quadrant using local-space offset (real ALPR: 4 cameras, ~90° each)
            local offset = GetOffsetFromEntityGivenWorldCoords(plyVeh, vehPos.x, vehPos.y, vehPos.z)
            local dirV   = offset.y >= 0 and 'Front' or 'Rear'
            local dirH   = offset.x >= 0 and 'Right' or 'Left'
            TriggerServerEvent('seeker_dsr2x:runAlpr', plate, dirV .. ' ' .. dirH)

            ::next::
        end

        ::continue::
    end
end)

RegisterNetEvent('seeker_dsr2x:alprResult', function(result)
    if not result then return end

    -- The plate was never actually looked up (CAD unreachable, rate limited, or the server's
    -- per-player cap). Requeue it rather than holding a silence we never earned as an
    -- all-clear for the whole rescan window — but not before the backoff the server asked
    -- for, or the next pass 200 ms from now would just ask again.
    --
    -- The scan thread expires an entry once rescanDelay has passed since its timestamp, so
    -- backing a timestamp into the future is how a plate is held for less than a full window.
    if result.retry and result.plate then
        local delayMs = (result.retryAfter or 0) * 1000
        if delayMs > 0 then
            local rescanMs = ((Config.alpr and Config.alpr.rescanDelay) or 120) * 1000
            alprScanned[result.plate] = GetGameTimer() + delayMs - rescanMs
        else
            alprScanned[result.plate] = nil
        end
    end

    if result.noRecord then return end

    local regStatus = result.registrationStatus or (result.registration and 'Valid' or 'Invalid')
    local insValid  = result.insurance and (result.insuranceStatus or ''):lower() ~= 'invalid'
    local regValid  = result.registration and (regStatus:lower() == 'valid' or regStatus:lower() == 'active')

    -- Anything the CAD flagged that is not one of the four conditions above — warrants, BOLOs,
    -- a dangerous or missing owner, community-defined flags. The server passes these through
    -- verbatim, so a flag added CAD-side shows up here without a change to this file.
    local extraFlags = type(result.flags) == 'table' and result.flags or {}

    -- Only alert on flagged vehicles
    if not result.stolen and not result.impounded and insValid and regValid and #extraFlags == 0 then return end

    local parts = {}
    if result.year  then parts[#parts+1] = tostring(result.year)  end
    if result.color then parts[#parts+1] = result.color            end
    if result.make  then parts[#parts+1] = result.make             end
    if result.model then parts[#parts+1] = result.model            end

    local isSuspect = result.stolen or result.impounded or result.alertLevel == 'alert'
    local header = (isSuspect and '~r~' or '~y~') .. 'ALPR - ' .. (result.plate or '?') .. ':~s~'

    local function statusColor(val, status)
        if val == false then return '~r~' .. (status or 'Invalid') .. '~s~' end
        local s = (status or ''):lower()
        return (s == 'valid' or s == 'active' or val == true) and ('~g~' .. (status or 'Valid') .. '~s~') or ('~r~' .. (status or 'Unknown') .. '~s~')
    end

    -- Notif 1: direction + plate + vehicle
    local dir = result.direction and ('~c~' .. result.direction .. '~s~') or nil
    local notif1 = { dir and (header .. '  ' .. dir) or header }
    if #parts > 0 then notif1[#notif1+1] = table.concat(parts, ' ') end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(table.concat(notif1, '\n'))
    EndTextCommandThefeedPostTicker(false, true)

    -- Notif 2: owner + reg/ins + flags
    local notif2 = {}
    if result.owner and result.owner ~= '' then
        local owner = result.business and (result.owner .. ' ~c~(Business)~s~') or result.owner
        notif2[#notif2+1] = '~y~Owner:~s~ ' .. owner
    end
    notif2[#notif2+1] = 'Reg: ' .. statusColor(result.registration, regStatus)
    notif2[#notif2+1] = 'Ins: ' .. statusColor(result.insurance, result.insuranceStatus or (insValid and 'Valid' or 'Invalid'))
    if result.stolen    then notif2[#notif2+1] = '~r~⚠ STOLEN VEHICLE~s~'       end
    if result.impounded then notif2[#notif2+1] = '~r~⚠ IMPOUNDED VEHICLE~s~'    end
    if not regValid     then notif2[#notif2+1] = '~r~⚠ EXPIRED REGISTRATION~s~' end
    if not insValid     then notif2[#notif2+1] = '~r~⚠ NO INSURANCE~s~'         end
    for _, flag in ipairs(extraFlags) do
        notif2[#notif2+1] = '~r~⚠ ' .. tostring(flag):upper() .. '~s~'
    end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(table.concat(notif2, '\n'))
    EndTextCommandThefeedPostTicker(false, true)

    SendNUIMessage({ _type = 'audio', name = 'alpr_hit', vol = beepVol() })

    -- Store in session log (newest first, cap at 20)
    local flags = {}
    if result.stolen    then flags[#flags+1] = 'STOLEN'   end
    if result.impounded then flags[#flags+1] = 'IMPOUNDED' end
    if not regValid     then flags[#flags+1] = 'EXPIRED REG' end
    if not insValid     then flags[#flags+1] = 'NO INS'    end
    for _, flag in ipairs(extraFlags) do flags[#flags+1] = tostring(flag):upper() end
    local ms  = GetGameTimer()
    local s   = math.floor(ms / 1000)
    local ts  = ('%02d:%02d:%02d'):format(math.floor(s/3600), math.floor((s%3600)/60), s%60)
    table.insert(alprHitLog, 1, {
        time      = ts,
        plate     = result.plate or '?',
        direction = result.direction or '?',
        vehicle   = table.concat(parts, ' '),
        owner     = result.owner and (result.business and (result.owner .. ' (Business)') or result.owner) or '',
        flags     = table.concat(flags, ', '),
    })
    if #alprHitLog > 20 then alprHitLog[21] = nil end
end)
