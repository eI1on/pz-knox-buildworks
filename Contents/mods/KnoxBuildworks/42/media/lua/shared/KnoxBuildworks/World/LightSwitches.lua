---Knox-built wall light switches outside the map's own rooms.
---
---A wall-switch tile (lighting_indoor_01_0..7) has no lightR property, so the
---engine makes it a room switch (IsoLightSwitch.lightRoom). Room switches only
---work inside a map IsoRoom: IsoLightSwitch.setActive returns early when the
---square has no room and the object cannot be modified, so a switch built in a
---player-made house showed "Turn off" and then did nothing.
---
---Every vanilla toggle path (context menu, click, joypad) ends in
---ISToggleLightAction:complete, which runs on the server (or in single
---player). For a Knox-built room switch on a square without a map room, this
---module toggles the switch through the engine's own setActive (so the
---SyncIsoObject packet reaches every client) and switches the light fixtures
---wired into the same enclosed area. Everything else keeps vanilla behaviour.
require "TimedActions/ISToggleLightAction"

local LightSwitches = {}

-- Area searched for fixtures: the enclosed space around the switch, bounded
-- by walls, doors and windows, at most this far and this large.
local MAX_DISTANCE = 12
local MAX_SQUARES = 300

local function isRoomStyleSwitch(object)
    local sprite = object and object:getSprite() or nil
    local properties = sprite and sprite:getProperties() or nil
    return properties ~= nil and not properties:has("lightR")
end

---True for a Knox-built wall switch the engine cannot toggle on its own.
function LightSwitches.isDetachedSwitch(object)
    if not object or not instanceof(object, "IsoLightSwitch") then return false end
    local square = object:getSquare()
    if not square or square:getRoom() ~= nil then return false end
    if object:getCanBeModified() or not isRoomStyleSwitch(object) then return false end
    local modData = object:hasModData() and object:getModData() or nil
    return modData ~= nil and modData.KBW ~= nil
end

local function isWiredFixture(object)
    if not instanceof(object, "IsoLightSwitch") or isRoomStyleSwitch(object) then return false end
    if object:getUseBattery() then return false end
    local properties = object:getSprite():getProperties()
    return not properties:has("streetlight")
end

local function separated(from, to)
    return from:isWallTo(to) or from:isDoorTo(to) or from:isWindowTo(to)
end

---Light fixtures (lamps, ceiling lights) in the enclosed area of a switch.
function LightSwitches.fixturesFor(switch)
    local start = switch:getSquare()
    local fixtures = {}
    if not start then return fixtures end
    local cell = getCell()
    local sx, sy, z = start:getX(), start:getY(), start:getZ()
    local seen = { [sx .. "," .. sy] = true }
    local queue, head = { start }, 1
    local steps = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    while head <= #queue do
        local square = queue[head]
        head = head + 1
        local objects = square:getObjects()
        for index = 0, objects:size() - 1 do
            local object = objects:get(index)
            if object ~= switch and isWiredFixture(object) then fixtures[#fixtures + 1] = object end
        end
        for s = 1, 4 do
            local x, y = square:getX() + steps[s][1], square:getY() + steps[s][2]
            local key = x .. "," .. y
            if not seen[key] and math.abs(x - sx) <= MAX_DISTANCE and math.abs(y - sy) <= MAX_DISTANCE
                and #queue < MAX_SQUARES then
                seen[key] = true
                local neighbour = cell:getGridSquare(x, y, z)
                if neighbour and not separated(square, neighbour) then queue[#queue + 1] = neighbour end
            end
        end
    end
    return fixtures
end

-- IsoLightSwitch.setActive refuses any light on a square without a map room
-- unless the object is modifiable (moveable lamps are; wall switches and a few
-- lit signs are not). Lift that for this one call so the engine's own switch,
-- power check, lighting invalidation and SyncIsoObject broadcast run unchanged.
local function setActive(light, state)
    if light:getCanBeModified() then return light:setActive(state) end
    light:setCanBeModified(true)
    local result = light:setActive(state)
    light:setCanBeModified(false)
    return result
end

---Toggle a detached switch and its fixtures. Returns the new state.
function LightSwitches.toggle(switch)
    local state = not switch:isActivated()
    local result = setActive(switch, state)
    if result ~= state then return result end
    local fixtures = LightSwitches.fixturesFor(switch)
    for index = 1, #fixtures do
        local fixture = fixtures[index]
        if fixture:isActivated() ~= state then setActive(fixture, state) end
    end
    return state
end

-- One small, reversible wrapper: only detached Knox switches take the new
-- path; every other light keeps the vanilla complete().
if ISToggleLightAction and not LightSwitches.originalComplete then
    LightSwitches.originalComplete = ISToggleLightAction.complete
    function ISToggleLightAction:complete()
        if LightSwitches.isDetachedSwitch(self.object) then
            LightSwitches.toggle(self.object)
            return true
        end
        return LightSwitches.originalComplete(self)
    end
end

return LightSwitches
