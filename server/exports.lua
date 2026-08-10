--- SEEKER DSR 2X - Server exports for other resources

exports('GetPlayerRadarState', function(source)
    return GetPlayerRadarState(source)
end)

--- True when the unit is on and at least one antenna is transmitting.
exports('IsPlayerRadarActive', function(source)
    local state = GetPlayerRadarState(source)
    return state and state.power and (state.frontXmit or state.rearXmit) or false
end)
