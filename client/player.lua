--[[
    SEEKER DSR 2X - Player state tracking
    Tracks vehicle, seat, and vehicle class for radar eligibility
]]

Player = {
    ped = nil,
    vehicle = nil,
    inDriverSeat = false,
    inPassengerSeat = false,
    vehicleClassValid = false,
}

--- Returns if the current vehicle fits validity requirements
function Player:VehicleStateValid()
    return self.vehicle and DoesEntityExist(self.vehicle) and self.vehicle > 0 and self.vehicleClassValid
end

--- Returns if the player is in the driver seat
function Player:IsDriver()
    return self:VehicleStateValid() and self.inDriverSeat
end

--- Returns if the player is in the front passenger seat
function Player:IsPassenger()
    return self:VehicleStateValid() and self.inPassengerSeat
end

--- Returns if the player can control the radar (driver or passenger, valid class)
function Player:CanControlRadar()
    return self:IsDriver() or self:IsPassenger()
end

--- Returns if the player can view the radar (same eligibility as control for this resource)
function Player:CanViewRadar()
    return self:CanControlRadar()
end

--- Returns the player's vehicle
function Player:GetVehicle()
    return self.vehicle
end

--- Returns patrol vehicle speed in m/s
function Player:GetPatrolSpeed()
    if not self:VehicleStateValid() then return 0.0 end
    return GetEntitySpeed(self.vehicle)
end

--- Player state polling thread
CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)
        local inDriverSeat = false
        local inPassengerSeat = false
        local isValid = false

        if vehicle ~= 0 and DoesEntityExist(vehicle) then
            inDriverSeat = GetPedInVehicleSeat(vehicle, -1) == ped
            inPassengerSeat = GetPedInVehicleSeat(vehicle, 0) == ped
            for _, class in ipairs(Config.allowedVehicleClasses) do
                if GetVehicleClass(vehicle) == class then
                    isValid = true
                    break
                end
            end
        end

        Player.ped = ped
        Player.vehicle = (vehicle ~= 0 and DoesEntityExist(vehicle)) and vehicle or nil
        Player.inDriverSeat = inDriverSeat
        Player.inPassengerSeat = inPassengerSeat
        Player.vehicleClassValid = isValid

        Wait(500)
    end
end)
