local Log = require("KnoxBuildworks/Log")

---@class KBW.FluidContainersModule
---@type KBW.FluidContainersModule
local FluidContainers = {}

local tracked = {}

local DEFAULT_CAPACITY = 400
local DEFAULT_RAIN_FACTOR = 0.3

-- B42 removed the Lua rain-collector objects entirely. Rain is applied by the
-- engine's FluidContainerUpdateSystem, which walks every entity carrying a
-- FluidContainer component and fills the ones whose rain catcher is above zero
-- (zombie.entity.components.fluids.FluidContainerUpdateSystem.updateEntity).
--
-- Entity scripts are the usual source of that component, but EntityCompat
-- refuses to instance a script whose SpriteConfig does not list the sprite being
-- built, so referencing Base.RainCollector from a drum sprite silently attaches
-- nothing. Knox therefore creates the component directly, the same way
-- IsoObject.syncFluidContainerReceive does when a container arrives over the
-- wire: allocate from ComponentType and hand it to GameEntityFactory, which
-- reconnects the entity so the update system picks it up.
---@param object IsoObject
local function ensureContainer(object)
    local existing = object.getFluidContainer and object:getFluidContainer() or nil
    if existing then return existing end
    if not ComponentType or not ComponentType.FluidContainer or not GameEntityFactory then return nil end
    local component = ComponentType.FluidContainer:CreateComponent()
    if not component then return nil end
    GameEntityFactory.AddComponent(object, component)
    return object:getFluidContainer()
end

--- Creates and configures the rain-collecting FluidContainer for a built object.
---@param object IsoObject
---@param config table | nil
---@return boolean
function FluidContainers.configureObject(object, config)
    if not object then return false end
    config = type(config) == "table" and config or {}
    local container = ensureContainer(object)
    if not container then
        Log:error(
            "Buildable at %s,%s,%s could not create a FluidContainer component", tostring(object:getX()),
            tostring(object:getY()), tostring(object:getZ())
        )
        return false
    end

    local capacity = math.max(1, tonumber(config.capacity) or DEFAULT_CAPACITY)
    container:setCapacity(capacity)

    -- Rain collection and meta storage are both gated on this single value:
    -- isQualifiesForMetaStorage() is literally getRainCatcher() > 0, which is
    -- what keeps the drum filling while its chunk is unloaded.
    local rainFactor = math.max(0, tonumber(config.rainFactor) or DEFAULT_RAIN_FACTOR)
    container:setRainCatcher(rainFactor)

    if config.containerName ~= nil then container:setContainerName(tostring(config.containerName)) end

    -- canPlayerEmpty gates the rain branch as well as the drain interaction, and
    -- a freshly allocated component already defaults it to true. It is set here
    -- anyway because the component comes from a pool.
    if container.setCanPlayerEmpty then container:setCanPlayerEmpty(true) end

    local modData = object:getModData()
    -- Sprite states live in mod data so the level swap keeps working after a
    -- chunk reload, when the definition is no longer at hand.
    if config.emptySprite and config.filledSprite then
        modData.KBWFluidSprites = {
            empty = tostring(config.emptySprite),
            filled = tostring(config.filledSprite),
            percent = math.max(0, math.min(100, tonumber(config.filledPercent) or 1)),
            fire = config.fireSprite and tostring(config.fireSprite) or nil
        }
    end
    -- Remembered so switching back out of fire mode restores the original rate
    -- rather than a module default.
    modData.KBWFluidRain = rainFactor
    if modData.KBWFluidSprites and modData.KBWFluidSprites.fire and modData.KBWDrumMode == nil then
        modData.KBWDrumMode = "water"
    end
    if modData.KBWFluidInitialized ~= true then
        container:Empty()
        local initialPercent = math.max(0, math.min(100, tonumber(config.initialPercent) or 0))
        if initialPercent > 0 and FluidType then
            container:addFluid(FluidType.TaintedWater, capacity * initialPercent / 100)
        end
        modData.KBWFluidInitialized = true
    end
    modData.KBWFluidCapacity = capacity
    FluidContainers.track(object)
    FluidContainers.refreshSprite(object)
    return true
end

---@param object IsoObject
function FluidContainers.track(object)
    if not object or not object.hasModData or not object:hasModData() then return end
    if object:getModData().KBWFluidSprites ~= nil then tracked[object] = true end
end

--- Swaps between the empty and filled sprite for the current fluid level.
---@param object IsoObject
---@return boolean
function FluidContainers.refreshSprite(object)
    if not object or not object.hasModData or not object:hasModData() then return false end
    local modData = object:getModData()
    local sprites = modData.KBWFluidSprites
    if not sprites or not sprites.empty or not sprites.filled then return false end
    local container = object.getFluidContainer and object:getFluidContainer() or nil
    if not container then return false end
    local wanted
    if modData.KBWDrumMode == "fire" and sprites.fire then
        wanted = sprites.fire
    else
        local capacity = tonumber(container:getCapacity()) or 0
        local amount = tonumber(container:getAmount()) or 0
        local percent = capacity > 0 and amount / capacity * 100 or 0
        wanted = percent >= (tonumber(sprites.percent) or 1) and sprites.filled or sprites.empty
    end
    if object:getSpriteName() == wanted then return false end
    if not getSprite(wanted) then return false end
    object:setSprite(wanted)
    object:transmitUpdatedSpriteToClients()
    return true
end

--- Whether the object is a Knox drum that can be switched between collecting
--- rain and burning fuel.
---@param object IsoObject
function FluidContainers.isDualMode(object)
    if not object or not object.hasModData or not object:hasModData() then return false end
    local sprites = object:getModData().KBWFluidSprites
    return sprites ~= nil and sprites.fire ~= nil
end

---@param object IsoObject
function FluidContainers.getMode(object)
    if not FluidContainers.isDualMode(object) then return nil end
    return object:getModData().KBWDrumMode or "water"
end

--- Switches a dual-mode drum between rain collection and burning.
---
--- The two modes need different object classes, and that is the whole point:
--- isFireInteractionObject() is true for every IsoFireplace, so a fireplace can
--- never hide the vanilla fuel and light options, and anything carrying a
--- FluidContainer can never hide the vanilla fluid options. Keeping one object
--- that is both left the player with both sets of options at once. Swapping the
--- object -- the same thing vanilla does for the rain barrel lid -- gives each
--- mode exactly the menu that belongs to it.
---
--- Refuses while the drum still holds the other mode's contents, so nothing is
--- silently destroyed.
---@param object IsoObject
---@param mode   string
---@return boolean, string | nil
function FluidContainers.setMode(object, mode)
    if not FluidContainers.isDualMode(object) then return false, "not a drum" end
    mode = mode == "fire" and "fire" or "water"
    local modData = object:getModData()
    if (modData.KBWDrumMode or "water") == mode then return true end
    local square = object:getSquare()
    if not square then return false, "no square" end

    local container = object.getFluidContainer and object:getFluidContainer() or nil
    local isFireplace = instanceof(object, "IsoFireplace")
    if mode == "fire" then
        if container and (tonumber(container:getAmount()) or 0) > 0 then return false, "drain first" end
    else
        -- Vanilla stores fireplace fuel as an abstract minute count, not items,
        -- so no menu anywhere takes logs back out. Refusing on leftover fuel
        -- would strand the drum in fire mode; a live fire still has to be out.
        if isFireplace and (object:isLit() or object:isSmouldering()) then
            return false, "put out first"
        end
    end

    local sprites = modData.KBWFluidSprites
    local spriteName = mode == "fire" and sprites.fire or sprites.empty
    if not getSprite(spriteName) then return false, "missing sprite" end

    local carried = copyTable(modData)
    carried.KBWDrumMode = mode
    carried.KBWFluidInitialized = nil
    -- getHealth/getMaxHealth live on IsoThumpable only: IsoObject and therefore
    -- IsoFireplace have no health at all. Reading them off the burn-barrel form
    -- would call nil, so health rides along in mod data instead and survives
    -- however many times the drum is switched.
    if object.getMaxHealth then
        carried.KBWDrumMaxHealth = tonumber(object:getMaxHealth())
        carried.KBWDrumHealth = tonumber(object:getHealth())
    end

    local replacement
    if mode == "fire" then
        replacement = IsoFireplace.new(getCell(), square, getSprite(spriteName))
    else
        replacement = IsoThumpable.new(getCell(), square, spriteName, false, nil)
        local maxHealth = math.max(1, tonumber(carried.KBWDrumMaxHealth) or 100)
        replacement:setMaxHealth(maxHealth)
        replacement:setHealth(math.min(maxHealth, tonumber(carried.KBWDrumHealth) or maxHealth))
        replacement:setIsThumpable(true)
        replacement:setIsDismantable(true)
        replacement:setBlockAllTheSquare(true)
    end
    if not replacement then return false, "replace failed" end

    local index = square:transmitRemoveItemFromSquare(object) or -1
    tracked[object] = nil
    local newModData = replacement:getModData()
    for key, value in pairs(carried) do
        newModData[key] = value
    end
    if index >= 0 then
        square:AddSpecialObject(replacement, index)
    else
        square:AddSpecialObject(replacement)
    end

    if mode == "water" then
        FluidContainers.configureObject(replacement, {
            capacity = tonumber(carried.KBWFluidCapacity),
            rainFactor = tonumber(carried.KBWFluidRain),
            emptySprite = sprites.empty,
            filledSprite = sprites.filled,
            filledPercent = sprites.percent,
            fireSprite = sprites.fire
        })
    end
    FluidContainers.track(replacement)
    square:RecalcAllWithNeighbours(true)
    if replacement.transmitCompleteItemToClients then replacement:transmitCompleteItemToClients() end
    return true
end

--- Empties unburnt fuel out of a drum without changing its mode.
---@param object IsoObject
---@return boolean, string | nil
function FluidContainers.dumpFuel(object)
    if not instanceof(object, "IsoFireplace") then return false, "not a drum" end
    if object:isLit() or object:isSmouldering() then return false, "put out first" end
    if (tonumber(object:getFuelAmount()) or 0) <= 0 then return false, "no fuel" end
    object:setFuelAmount(0)
    if object.sync then object:sync() end
    return true
end

-- The vanilla fuel and light options appear on any IsoFireplace, so a drum left
-- in water mode can still be fuelled and lit behind Knox's back. Rather than
-- fight that, the stored mode follows reality: a drum holding fuel or burning
-- IS a burn barrel, which also stops it collecting rain while alight.
---@param object IsoObject
local function reconcileMode(object)
    if not FluidContainers.isDualMode(object) then return end
    if not instanceof(object, "IsoFireplace") then return end
    local burning = object:isLit() or object:isSmouldering() or (tonumber(object:getFuelAmount()) or 0) > 0
    if not burning then return end
    local modData = object:getModData()
    if modData.KBWDrumMode == "fire" then return end
    modData.KBWDrumMode = "fire"
    local container = object.getFluidContainer and object:getFluidContainer() or nil
    if container then container:setRainCatcher(0) end
    if object.transmitModData then object:transmitModData() end
end

local function refreshTracked()
    if isClient() then return end
    for object in pairs(tracked) do
        local square = object and object:getSquare() or nil
        if not square or object:getObjectIndex() < 0 then
            tracked[object] = nil
        else
            reconcileMode(object)
            FluidContainers.refreshSprite(object)
        end
    end
end

-- Mirrors WellSystem: hasModData() is checked before getModData() so streaming a
-- square does not allocate a mod-data table for every unrelated object on it.
local function onLoadGridsquare(square)
    if not square then return end
    local objects = square:getObjects()
    for objectIndex = 0, objects:size() - 1 do
        FluidContainers.track(objects:get(objectIndex))
    end
end

Events.LoadGridsquare.Add(onLoadGridsquare)
Events.OnObjectAdded.Add(FluidContainers.track)
Events.EveryOneMinute.Add(refreshTracked)

return FluidContainers
