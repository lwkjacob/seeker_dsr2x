--[[
    SEEKER DSR 2X - Client exports for external resources

    Both antennas run at once, so the state shape is per-row rather than the DUAL DSR's
    single activeAntenna. `rows.front` is the top row, `rows.rear` is the bottom row.
]]

local function buildRowState(rowKey)
    local row = Radar.rows[rowKey]
    if not row then return nil end
    return {
        xmit = row.xmit,
        hold = row.hold,
        zones = { same = row.zones.same, opp = row.zones.opp },
        zoneMode = Radar._rowZoneMode(row),   -- 0=off 1=same 2=opp 3=both
        live = Radar._rowIsLive(row, rowKey),
        -- Range is no longer per-row: both antennas share the OP SEn / SL SEn settings, so
        -- a row's reach depends on which zone the reading came through.
        oppRange = Radar._zoneRange('opp'),
        sameRange = Radar._zoneRange('same'),
        locked = row.locked,
        lockedSpeed = row.lockedSpeed,        -- m/s
        lockedDir = row.lockedDir,            -- 'closing' | 'away' | nil
        lockedZone = row.lockedZone,          -- 'same' | 'opp' | nil
        lockedPatrolSpeed = row.lockedPatrolSpeed,  -- mph, frozen at lock
        fastLocked = row.fastLocked,
        fastLockedSpeed = row.fastLockedSpeed,
        fastLockedDir = row.fastLockedDir,
        fastLockedZone = row.fastLockedZone,
        targetSpeed = row.targetSpeed,        -- m/s, live
        targetDir = row.targetDir,
        targetZone = row.targetZone,
        fastSpeed = row.fastSpeed,
        fastDir = row.fastDir,
        fastZone = row.fastZone,
        plateLocked = row.plateLocked,
        lockedPlate = row.lockedPlate,
    }
end

local function buildRadarState()
    return {
        power = Radar.power,
        displayed = Radar.displayed,
        hidden = Radar.hidden,
        rows = {
            front = buildRowState('front'),
            rear = buildRowState('rear'),
        },
        stationaryMode = Radar.stationaryMode,

        -- Operator Menu (manual pp.21-22)
        fasterDisplay = Radar.fasterDisplay,
        oppSen = Radar.oppSen,
        sameSen = Radar.sameSen,
        squelch = Radar.squelch,
        patrolCutoff = Radar.patrolCutoff,
        stopwatchOn = Radar.stopwatchOn,
        alertClosingSpeed = Radar.alertClosingSpeed,
        antennaCount = Radar.antennaCount,

        -- VOLUME key levels
        audMoving = Radar.audMoving,
        audStationary = Radar.audStationary,
        beepLevel = Radar.beepLevel,
        voiceLevel = Radar.voiceLevel,

        -- Remote UI state: 'radar' | 'menu' | 'volume' | 'stopwatch'
        uiMode = Radar.uiMode,
        stopwatchRunning = Radar.stopwatchRunning,
        stopwatchDistanceFt = Radar.stopwatchDistanceFt,
        stopwatchResultMph = Radar.stopwatchResultMph,
        alertActive = Radar.alertActive,

        psBlankMode = Radar.psBlankMode,   -- 0 normal | 1 blank | 2 front lock PS | 3 rear lock PS
        dopplerMode = Radar.dopplerMode,
        dopplerEnabled = Radar.dopplerEnabled,
        dopplerSource = Radar.dopplerSource,
        plateReaderEnabled = Radar.plateReaderEnabled,
        speedUnit = Radar.speedUnit,
    }
end

exports('GetRadarState', buildRadarState)
exports('GetRadarDetailedState', buildRadarState)

--- True when the unit is on and at least one row is actually transmitting.
exports('IsRadarActive', function()
    return Radar.power
        and (Radar._rowIsLive(Radar.rows.front, 'front') or Radar._rowIsLive(Radar.rows.rear, 'rear'))
        or false
end)

exports('IsRadarDisplayed', function()
    return Radar.displayed and not Radar.hidden
end)

exports('CanControlRadar', function()
    return Player and Player:CanControlRadar() or false
end)

exports('CanViewRadar', function()
    return Player and Player:CanViewRadar() or false
end)
