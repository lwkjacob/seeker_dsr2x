--[[
    SEEKER DSR 2X - State bag replication

    Publishes a minimal view of the radar to the server (and to any other resource that
    watches player state bags, e.g. a detector script). Only pushed when a value actually
    changes, so idle patrols cost nothing.

    Keys are deliberately distinct from seeker_dual's `seekerRadar*` so both resources can
    run side by side without one clobbering the other's bags.
]]

local last = {}

--- Writes a bag only when the value changed.
local function push(key, value)
    if last[key] == value then return end
    last[key] = value
    LocalPlayer.state:set(key, value, true)
end

CreateThread(function()
    while true do
        local frontLive = Radar._rowIsLive(Radar.rows.front) or false
        local rearLive = Radar._rowIsLive(Radar.rows.rear) or false

        push('seekerDsr2xPower', Radar.power or false)
        push('seekerDsr2xFrontXmit', frontLive)
        push('seekerDsr2xRearXmit', rearLive)
        push('seekerDsr2xFrontLocked', Radar.rows.front.locked or false)
        push('seekerDsr2xRearLocked', Radar.rows.rear.locked or false)

        Wait(250)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    LocalPlayer.state:set('seekerDsr2xPower', false, true)
    LocalPlayer.state:set('seekerDsr2xFrontXmit', false, true)
    LocalPlayer.state:set('seekerDsr2xRearXmit', false, true)
    LocalPlayer.state:set('seekerDsr2xFrontLocked', false, true)
    LocalPlayer.state:set('seekerDsr2xRearLocked', false, true)
end)
