local KBW = require("KnoxBuildworks/Core")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local Log = require("KnoxBuildworks/Log")

---@class KBW.WellSystemModule
---@type KBW.WellSystemModule
local WellSystem = {}

local WELL_STAGE = { entityCompat = { module = "Base", entity = "Well" } }
local VANILLA_WELL_SPRITE = "camping_01_16"
local tracked = {}

local function optionNumber(name, default)
    return tonumber(KBW.sandboxValue(name, default)) or default
end

local function finiteMode()
    return optionNumber("KnoxBuildworks.WellWaterMode", 1) == 2
end

local function configTable(config)
    return type(config) == "table" and config or {}
end

local function capacityFor(config)
    return math.max(1, tonumber(configTable(config).capacity) or optionNumber("KnoxBuildworks.WellCapacity", 1500))
end

local function initialPercentFor(config)
    return math.max(
        0,
        math.min(
            100, tonumber(configTable(config).initialPercent) or optionNumber("KnoxBuildworks.WellInitialPercent", 25)
        )
    )
end

local function refillFor(config)
    return math.max(
        0, tonumber(configTable(config).refillPerHour) or optionNumber("KnoxBuildworks.WellHourlyRefill", 3)
    )
end

local function rainFactorFor(config)
    local base = math.max(0, tonumber(configTable(config).rainFactor) or 0.1)
    local multiplier = math.max(0, optionNumber("KnoxBuildworks.WellRainRefillMultiplier", 1.5))
    return base * multiplier
end

local function copyConfig(config)
    if type(config) ~= "table" then return nil end
    return {
        capacity = tonumber(config.capacity),
        initialPercent = tonumber(config.initialPercent),
        refillPerHour = tonumber(config.refillPerHour),
        rainFactor = tonumber(config.rainFactor)
    }
end

local function patchSprite(sprite, isFinite)
    if not sprite then return end
    local properties = sprite:getProperties()
    if not properties then return end
    if isFinite then
        properties:set("waterAmount", "0")
        properties:set("waterMaxAmount", tostring(capacityFor(nil)))
    else
        properties:set("waterAmount", "999999")
        properties:set("waterMaxAmount", "999999")
    end
end

local function patchVanillaSprite()
    patchSprite(getSprite(VANILLA_WELL_SPRITE), finiteMode())
end

local function isWellObject(object)
    if not object then return false end
    -- Almost every streamed object is not a well. Check the one vanilla
    -- sprite first, then avoid getModData() entirely when the object has no
    -- existing table; getModData() would otherwise allocate one while merely
    -- scanning every object on every loaded square.
    if object:getSpriteName() == VANILLA_WELL_SPRITE then return true end
    if not object:hasModData() then return false end
    return object:getModData().KBWWell == true
end

local function track(object)
    if object then tracked[object] = true end
end

local function ensureFluidContainer(object)
    local fluidContainer = object:getFluidContainer()
    if fluidContainer then return fluidContainer end
    EntityCompat.attach(object, WELL_STAGE, false)
    return object:getFluidContainer()
end

local function syncObject(object)
    if object.transmitModData then object:transmitModData() end
    if object.sync then object:sync() end
end

---@param object IsoObject
---@param config boolean | table | nil
---@param isNew  boolean | nil
function WellSystem.configureObject(object, config, isNew)
    if not object then return false end
    local isFinite = finiteMode()
    patchSprite(object:getSprite(), isFinite)

    local modData = object:getModData()
    modData.KBWWell = true
    if isNew == true then modData.KBWWellOptions = copyConfig(config) end
    local effectiveConfig = modData.KBWWellOptions or config

    if not isFinite then
        if isNew ~= true then syncObject(object) end
        return true
    end

    local fluidContainer = ensureFluidContainer(object)
    if not fluidContainer then
        Log:error(
            "Water well at %s,%s,%s has no FluidContainer component", tostring(object:getX()), tostring(object:getY()),
            tostring(object:getZ())
        )
        return false
    end

    local capacity = capacityFor(effectiveConfig)
    fluidContainer:setCapacity(capacity)
    fluidContainer:setRainCatcher(rainFactorFor(effectiveConfig))
    if modData.KBWWellFiniteInitialized ~= true then
        fluidContainer:Empty()
        local initialAmount = capacity * initialPercentFor(effectiveConfig) / 100
        if initialAmount > 0 then fluidContainer:addFluid(FluidType.Water, initialAmount) end
        modData.KBWWellFiniteInitialized = true
    end
    modData.KBWWellCapacity = capacity
    track(object)
    if isNew ~= true then syncObject(object) end
    return true
end

local function configureSquare(square)
    if not square then return end
    local objects = square:getObjects()
    for objectIndex = 0, objects:size() - 1 do
        local object = objects:get(objectIndex)
        if isWellObject(object) then
            if isClient() then
                patchSprite(object:getSprite(), finiteMode())
            else
                WellSystem.configureObject(object, object:getModData().KBWWellOptions, false)
            end
        end
    end
end

local function onObjectAdded(object)
    if not isWellObject(object) then return end
    if isClient() then
        patchSprite(object:getSprite(), finiteMode())
    else
        WellSystem.configureObject(object, object:getModData().KBWWellOptions, false)
    end
end

local function refillWells()
    if isClient() or not finiteMode() then return end
    for object in pairs(tracked) do
        local square = object and object:getSquare() or nil
        if not square or object:getObjectIndex() < 0 then
            tracked[object] = nil
        else
            local modData = object:getModData()
            local config = modData.KBWWellOptions
            local fluidContainer = object:getFluidContainer()
            local amount = refillFor(config)
            if fluidContainer and amount > 0 and fluidContainer:getFreeCapacity() > 0 then
                fluidContainer:addFluid(FluidType.Water, math.min(amount, fluidContainer:getFreeCapacity()))
                object:sync()
            end
        end
    end
end

Events.OnGameStart.Add(patchVanillaSprite)
Events.OnServerStarted.Add(patchVanillaSprite)
Events.LoadGridsquare.Add(configureSquare)
Events.OnObjectAdded.Add(onObjectAdded)
Events.EveryHours.Add(refillWells)

KBW.WellSystem = WellSystem

return WellSystem
