--[[
    SEEKER DSR 2X - Utility functions
]]

Utils = {}

local SPEED_CONVERSIONS = {
    mph = 2.236936,
    kmh = 3.6,
}

--- Converts speed from m/s to the specified unit
---@param speedMs number Speed in meters per second
---@param unit string 'mph' or 'kmh'
---@return number
function Utils.ConvertSpeed(speedMs, unit)
    local mult = SPEED_CONVERSIONS[unit] or SPEED_CONVERSIONS.mph
    return speedMs * mult
end

--- Formats speed for 7-segment display (right-aligned, 3 digits)
---@param speed number
---@return string
function Utils.FormatSpeed(speed)
    local value = math.floor(speed + 0.5)
    if value < 0 then value = 0 end
    if value > 999 then value = 999 end
    return string.format('%3d', value)
end

--- Returns empty display string when no speed
function Utils.FormatSpeedEmpty()
    return '   '
end

--- Shallow-copies a table one level deep, recursing into nested tables.
--- Used to seed each row's runtime state from Config.rowDefaults without
--- the two rows sharing the same zones table.
---@param src table
---@return table
function Utils.DeepCopy(src)
    if type(src) ~= 'table' then return src end
    local out = {}
    for k, v in pairs(src) do
        out[k] = type(v) == 'table' and Utils.DeepCopy(v) or v
    end
    return out
end
