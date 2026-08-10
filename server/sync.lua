--[[
    SEEKER DSR 2X - Server helpers for reading replicated radar state bags
    See client/sync.lua for the writer.
]]

function GetPlayerRadarState(source)
    local ply = source and Player(source)
    if not ply then return nil end

    return {
        power = ply.state.seekerDsr2xPower == true,
        frontXmit = ply.state.seekerDsr2xFrontXmit == true,
        rearXmit = ply.state.seekerDsr2xRearXmit == true,
        frontLocked = ply.state.seekerDsr2xFrontLocked == true,
        rearLocked = ply.state.seekerDsr2xRearLocked == true,
    }
end
