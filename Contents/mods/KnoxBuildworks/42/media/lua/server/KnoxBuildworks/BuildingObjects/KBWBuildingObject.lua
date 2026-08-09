--- KBWBuildingObject provides the Knox Buildworks building-object layer.
require "BuildingObjects/ISBuildingObject"

local KBW = require("KnoxBuildworks/Core")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local Resolver = require("KnoxBuildworks/Definitions/Resolver")
local Requirements = require("KnoxBuildworks/Validation/Requirements")
local Placement = require("KnoxBuildworks/Validation/Placement")
local FinishActions = require("KnoxBuildworks/Validation/FinishActions")
local Log = require("KnoxBuildworks/Log")
local Integrity = require("KnoxBuildworks/Network/Integrity")
local LuaCallback = require("KnoxBuildworks/Util/LuaCallback")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local Properties = require("KnoxBuildworks/Definitions/Properties")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local NativeObjectFactory = require("KnoxBuildworks/BuildingObjects/NativeObjectFactory")

---@class KBWBuildingObject: ISBuildingObject
KBWBuildingObject = ISBuildingObject:derive("KBWBuildingObject")

local function faceName(nSprite)
    return ({ "W", "N", "E", "S" })[nSprite or 1] or "W"
end

local function wallEdgeDirection(direction)
    direction = tonumber(direction) or 1
    return (direction == 2 or direction == 4) and 2 or 1
end

-- A north/west wall edge belongs to its anchor square, but a character can
-- work on it from the square directly across that edge or from the adjacent
-- approach square on the anchor side. Vanilla's generic wall finder may choose
-- the anchor square and then try to path through the frame being replaced.
-- Accept the character's current usable side first instead.
---@param character IsoGameCharacter|nil
---@param square IsoGridSquare|nil
---@param north boolean
local function isStandingAtWallEdge(character, square, north)
    local current = character and character:getCurrentSquare() or nil
    if not current or not square or current:getZ() ~= square:getZ() then return false end
    if current == square then return true end
    local acrossEdge = square:getAdjacentSquare(north and IsoDirections.N or IsoDirections.W)
    if acrossEdge ~= nil and current == acrossEdge then return true end
    local approach = square:getAdjacentSquare(north and IsoDirections.S or IsoDirections.E)
    return approach ~= nil and current == approach and current:canReachTo(square)
end

local function configuredBoolean(value, default)
    if value == nil then return default == true end
    return value == true
end

local CONNECTION_IDENTITY_FIELDS = { "buildableId", "stageId", "variantId", "materialId" }

local function connectionData(object)
    local data = object and object.getModData and object:getModData() or nil
    return data and data.KBW or nil
end

local function sameConnectionIdentity(left, right)
    if not left or not right or left.connectionRole ~= nil or right.connectionRole ~= nil then return false end
    for fieldIndex = 1, #CONNECTION_IDENTITY_FIELDS do
        local field = CONNECTION_IDENTITY_FIELDS[fieldIndex]
        if tostring(left[field] or "") ~= tostring(right[field] or "") then return false end
    end
    return true
end

local function findMatchingWallEdge(square, identity, north, excluded)
    if not square or not identity then return nil end
    for objectIndex = 0, square:getSpecialObjects():size() - 1 do
        local object = square:getSpecialObjects():get(objectIndex)
        if object ~= excluded and instanceof(object, "IsoThumpable") and object:getNorth() == (north == true)
            and sameConnectionIdentity(identity, connectionData(object)) then
            return object
        end
    end
    return nil
end

local function squareHasSprite(square, spriteName)
    if not square or not spriteName then return false end
    for objectIndex = 0, square:getObjects():size() - 1 do
        local object = square:getObjects():get(objectIndex)
        local sprite = object and object:getSprite() or nil
        if sprite and sprite:getName() == spriteName then return true end
    end
    return false
end

local function isGarageDoorSprite(spriteName)
    if not spriteName then return false end
    local sprite = getSprite(spriteName)
    local properties = sprite and sprite:getProperties() or nil
    return properties and properties:has(IsoPropertyType.GARAGE_DOOR) == true
end

local function isFloorAttachmentSprite(spriteName)
    if not spriteName then return false end
    local sprite = getSprite(spriteName)
    local properties = sprite and sprite:getProperties() or nil
    if not properties then return false end
    return (properties:has("MoveType") and properties:get("MoveType") == "FloorRug") or properties:has(
            IsoFlagType.attachedFloor
        ) or properties:has(IsoFlagType.FloorOverlay)
end

local function isRoofObjectSprite(spriteName)
    if not spriteName then return false end
    local sprite = getSprite(spriteName)
    local properties = sprite and sprite:getProperties() or nil
    if not properties or properties:has(IsoFlagType.solidfloor) then return false end
    if properties:has(IsoFlagType.WallN) or properties:has(IsoFlagType.WallNTrans) or properties:has(IsoFlagType.WallW)
        or properties:has(IsoFlagType.WallWTrans) or properties:has(IsoFlagType.WallNW) then
        return false
    end
    return properties:has("RoofGroup") or properties:has("WestRoofB")
        or properties:has("WestRoofM") or properties:has("WestRoofT")
        or properties:has("isEave")
end

local function isPassableWallOpeningSprite(spriteName, north)
    local sprite = spriteName and getSprite(spriteName) or nil
    local props = sprite and sprite:getProperties() or nil
    if not props then return false end
    if north then
        return props:has(IsoFlagType.cutN) and not (
            props:has(IsoFlagType.collideN) or props:has(IsoFlagType.WallN)
                or props:has(IsoFlagType.WallNW) or props:has(IsoFlagType.WindowN)
                or props:has(IsoFlagType.DoorWallN) or props:has(IsoFlagType.HoppableN)
        )
    end
    return props:has(IsoFlagType.cutW) and not (
        props:has(IsoFlagType.collideW) or props:has(IsoFlagType.WallW)
            or props:has(IsoFlagType.WallNW) or props:has(IsoFlagType.WindowW)
            or props:has(IsoFlagType.DoorWallW) or props:has(IsoFlagType.HoppableW)
    )
end

local function isPassableWallOpening(stage)
    local sprites = (stage and stage.sprites) or {}
    local found = false
    if sprites.W then
        found = true
        if not isPassableWallOpeningSprite(sprites.W, false) then return false end
    end
    if sprites.N then
        found = true
        if not isPassableWallOpeningSprite(sprites.N, true) then return false end
    end
    return found
end

local function nativeContainerType(spriteName)
    if not spriteName then return nil end
    local sprite = getSprite(spriteName)
    local properties = sprite and sprite:getProperties() or nil
    local containerType = properties and properties:get("container") or nil
    if containerType == "" then return nil end
    return containerType
end

local function listedBuildContainers(character)
    if ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.getContainers then
        local containers = ISInventoryPaneContextMenu.getContainers(character)
        if containers then return containers end
    end
    local containers = ArrayList.new()
    if character and character.getInventory then containers:add(character:getInventory()) end
    return containers
end

local function accessibleBuildContainers(character, containers)
    local accessible = ArrayList.new()
    if not character then return accessible end
    local checker = BuildLogic and BuildLogic.new(character, nil, nil) or nil
    local candidate = ArrayList.new()
    local seen = {}

    local function add(container)
        if not container then return end
        local key = tostring(container)
        if seen[key] then return end
        seen[key] = true
        if checker then
            candidate:clear()
            candidate:add(container)
            if not checker:isContainersAccessible(candidate) then return end
        end
        accessible:add(container)
    end

    add(character:getInventory())
    if containers then
        for containerIndex = 0, containers:size() - 1 do
            add(containers:get(containerIndex))
        end
    end
    return accessible
end

local function currentBuildContainers(character)
    return accessibleBuildContainers(character, listedBuildContainers(character))
end

local function applyNativeInputChoices(logic, recipe, choices, containers)
    if not logic or not recipe or not choices then return end
    local inputs = recipe:getInputs()
    local hasSelection = false
    for inputIndex = 0, inputs:size() - 1 do
        if choices["input_" .. tostring(inputIndex + 1)] then
            hasSelection = true
            break
        end
    end
    if not hasSelection then return end
    logic:setManualSelectInputs(true)
    for inputIndex = 0, inputs:size() - 1 do
        local fullType = choices["input_" .. tostring(inputIndex + 1)]
        if fullType then
            local selected = ArrayList.new()
            local seen = {}
            for containerIndex = 0, containers:size() - 1 do
                local container = containers:get(containerIndex)
                if container then
                    local items = container:getAllTypeRecurse(fullType)
                    for itemIndex = 0, items:size() - 1 do
                        local item = items:get(itemIndex)
                        local key = tostring(item)
                        if not seen[key] then
                            seen[key] = true
                            selected:add(item)
                        end
                    end
                end
            end
            logic:setManualInputsFor(inputs:get(inputIndex), selected)
        end
    end
    logic:autoPopulateInputs()
end

local function newNativeBuildLogic(character, recipe, choices, containers)
    if not BuildLogic or not character or not recipe or not containers then return nil end
    local logic = BuildLogic.new(character, nil, nil)
    logic:setContainers(containers)
    logic:setRecipe(recipe)
    applyNativeInputChoices(logic, recipe, choices, containers)
    return logic
end

local function nativeInputFailure(logic, recipe, containers)
    if not logic then return "native build logic unavailable" end
    if not containers or containers:size() == 0 then return "no construction containers available" end
    if not logic:isContainersAccessible(containers) then return "construction container is no longer accessible" end
    local missing = {}
    local inputs = recipe and recipe:getInputs() or nil
    if inputs then
        for inputIndex = 0, inputs:size() - 1 do
            local input = inputs:get(inputIndex)
            if not logic:isInputSatisfied(input) then
                local label = input:getOriginalLine()
                if not label or label == "" then label = "input_" .. tostring(inputIndex + 1) end
                missing[#missing + 1] = label
            end
        end
    end
    if #missing > 0 then return "native recipe inputs unavailable: " .. table.concat(missing, "; ") end
    return "native recipe rejected the current items or character state"
end

local function snapshotXp(character, awards)
    local xp = character and character:getXp() or nil
    for awardIndex = 1, #awards do
        local award = awards[awardIndex]
        award.before = xp and xp:getXP(award.perk) or 0
    end
end

local function nativeXpWasGranted(character, awards)
    local xp = character and character:getXp() or nil
    if not xp or #awards == 0 then return #awards == 0 end
    for awardIndex = 1, #awards do
        local award = awards[awardIndex]
        if xp:getXP(award.perk) > (tonumber(award.before) or 0) then return true end
    end
    return false
end

local function showConfiguredXpHalo(character, perk, gained)
    if not character or not perk or not gained or gained <= 0 then return end
    if getCore():getOptionShowCraftingXP() ~= true then return end
    if not HaloTextHelper or not HaloTextHelper.addGoodText then return end
    local rounded = math.floor(gained * 10 + 0.5) / 10
    local amountText = rounded == math.floor(rounded) and tostring(math.floor(rounded)) or tostring(rounded)
    HaloTextHelper.addGoodText(character, getText(perk:getName()) .. " XP: " .. amountText, "[br/]")
end

local function awardConfiguredXp(character, perk, amount)
    if not character or not perk or not amount or amount <= 0 then return 0 end
    local xp = character:getXp()
    local before = xp:getXP(perk)
    addXp(character, perk, amount)
    local gained = xp:getXP(perk) - before
    showConfiguredXpHalo(character, perk, gained)
    return gained
end

---@class KBW.FACE_KEYSModule
---@type KBW.FACE_KEYSModule
local FACE_KEYS = {
    "W",
    "N",
    "E",
    "S"
}

local function explicitDirections(stage)
    local directions = {}
    local cells = stage and stage.cellsByFace or {}
    local sprites = stage and stage.sprites or {}
    for direction = 1, #FACE_KEYS do
        local key = FACE_KEYS[direction]
        if cells[key] ~= nil or sprites[key] ~= nil then directions[#directions + 1] = direction end
    end
    if #directions == 0 then directions[1] = 1 end
    return directions
end

local function normalizedDirection(stage, direction)
    direction = tonumber(direction) or 1
    local directions = explicitDirections(stage)
    for index = 1, #directions do
        if directions[index] == direction then return direction end
    end
    local _, resolvedFace = Matrix.getFaceCells(stage, direction)
    for index = 1, #FACE_KEYS do
        if FACE_KEYS[index] == resolvedFace then return index end
    end
    return directions[1]
end

local function nextDirection(stage, direction)
    local directions = explicitDirections(stage)
    direction = normalizedDirection(stage, direction)
    for index = 1, #directions do
        if directions[index] == direction then return directions[(index % #directions) + 1] end
    end
    return directions[1]
end

local function applySprites(object, sprites)
    object:setSprite(sprites.W or sprites.S or sprites.N or sprites.E)
    object:setNorthSprite(sprites.N or sprites.S or object.sprite)
    object:setEastSprite(sprites.E or sprites.W)
    object:setSouthSprite(sprites.S or sprites.N)
end

---@param player       IsoPlayer
---@param buildableId  string
---@param stageId      string | nil
---@param variantId    string | nil
---@param materialId   string | nil
---@param direction    KBW.Direction
---@param inputChoices table<string, string> | nil
---@param containers   ArrayList<ItemContainer> | nil
---@return KBWBuildingObject
function KBWBuildingObject:new(player, buildableId, stageId, variantId, materialId, direction, inputChoices, containers)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    o.player = type(player) == "number" and player or player:getPlayerNum()
    if type(player) == "number" then
        o.character = getSpecificPlayer(player)
    else
        o.character = player
    end
    o.buildableId, o.stageId, o.variantId, o.materialId = buildableId, stageId, variantId or "", materialId or ""
    o.inputChoices = inputChoices or {}
    o.nSprite = tonumber(direction) or 1
    o.direction = o.nSprite
    o.definition, o.stage = Resolver.resolveStage(buildableId, o.variantId, o.materialId, stageId)
    if not o.definition or not o.stage then
        o.blockBuild = true
        return o
    end
    applySprites(o, o.stage.sprites)
    local placement = StageConfig.placement(o.definition, o.stage)
    local kind = placement.kind
    if kind == "wall" or placement.needWindowFrame == true then
        o.nSprite = wallEdgeDirection(o.nSprite)
        o.direction = o.nSprite
    else
        o.nSprite = normalizedDirection(o.stage, o.nSprite)
        o.direction = o.nSprite
    end
    local entityMetadata = EntityCompat.metadata(o.stage)
    local spriteConfig = StageConfig.sprite(o.definition, o.stage)
    local construction = StageConfig.construction(o.definition, o.stage)
    local objectConfig = o.stage.object or {}
    -- Built thumpables carry the vanilla entity name so previousStage checks
    -- (vanilla ISBuildIsoEntity and Knox Placement.findPrevious) recognise
    -- Knox-built frames and vice versa.
    o.name = entityMetadata.entity or (o.definition.id .. ":" .. o.stage.id)
    o.dragNilAfterPlace = false
    -- blockAfterPlace is cleared by vanilla buildPanelLogic callbacks. Knox's
    -- independent cursor does not own that panel logic, so enabling the flag
    -- leaves the preview permanently red after its first queued action.
    o.blockAfterPlace = false
    -- Knox requirements are authoritative for every tool type. Leaving the
    -- legacy ISBuildingObject hammer path enabled would silently require a
    -- hammer even for welding, masonry or JSON-only tool recipes.
    o.noNeedHammer = true
    o.isWallLike = kind == "wall" or kind == "wallCovering" or placement.needWindowFrame == true
    o.isFloor = kind == "floor"
    o.canBeAlwaysPlaced = kind == "overlay"
    local passableWallOpening = kind == "wall" and isPassableWallOpening(o.stage)
    o.canPassThrough = configuredBoolean(objectConfig.canPassThrough, kind == "overlay" or passableWallOpening)
    o.isDoorFrame = objectConfig.isDoorFrame == true
    o.isCorner = objectConfig.isCorner == true
    o.isProp = objectConfig.isProp == true or spriteConfig.isProp == true
        or (objectConfig.canPassThrough == true and kind ~= "overlay" and kind ~= "floor")
    o.isThumpable = configuredBoolean(objectConfig.isThumpable, spriteConfig.isThumpable ~= false and kind ~= "overlay")
    o.dismantable = objectConfig.dismantable ~= false
    o.blockAllTheSquare = configuredBoolean(objectConfig.blockAllSquare, kind == "object")
    o.hoppable = not passableWallOpening and (objectConfig.hoppable == true or o.stage.hoppable == true)
    o.dontNeedFrame = spriteConfig.dontNeedFrame == true
    o.needWindowFrame = spriteConfig.needWindowFrame == true
    o.needToBeAgainstWall = spriteConfig.needToBeAgainstWall == true
    o.isPole = spriteConfig.isPole == true
    o.canBeLockedByPadlock = spriteConfig.canBePadlocked == true
    o.corner = spriteConfig.corner
    o.pillar = spriteConfig.pillar
    o.bonusHealth = spriteConfig.bonusHealth or 0
    o.baseHealth = spriteConfig.health or 100
    o.skillBaseHealth = spriteConfig.skillBaseHealth or 0
    o.breakSound = spriteConfig.breakSound
    o.thumpDmg = objectConfig.thumpDamage or o.thumpDmg
    o.canBarricade = not passableWallOpening and objectConfig.canBarricade == true
    o.buildLow = objectConfig.buildLow == true
    o.drawFloorGrid = objectConfig.drawFloorGrid ~= false
    o.objectConfig = objectConfig
    o.spriteCache = {}
    -- This must be set before buildUtil.setInfo creates the thumpable. Vanilla
    -- entity scripts commonly declare plasterability through SpriteConfig's
    -- OnCreate callback instead of a top-level stage flag.
    o.canBePlastered = WallFinishes.isPlasterable(o.definition, o.stage)
    local craftRecipe = StageConfig.recipe(o.definition, o.stage)
    o.craftRecipe = EntityCompat.craftRecipeObject(o.stage)
    if o.craftRecipe and EntityCompat.usesNativeRecipeInputs(o.stage) and BuildLogic then
        o.containers = containers or currentBuildContainers(o.character)
        o.buildPanelLogic = newNativeBuildLogic(o.character, o.craftRecipe, o.inputChoices, o.containers)
    end
    o.maxTime = craftRecipe.time or 200
    o.xpAward = craftRecipe.xpAward
    o.useNativeXpAward = o.craftRecipe ~= nil and (o.stage.xp == nil and construction.xp == nil)
    local actionScript = craftRecipe.timedAction and getScriptManager()
        and getScriptManager():getTimedActionScript(craftRecipe.timedAction) or nil
    if actionScript then
        if actionScript:getSound() then o.craftingBank = actionScript:getSound() end
        if actionScript:getCompletionSound() then o.completionSound = actionScript:getCompletionSound() end
    end
    o.craftingBank = construction.sound or o.craftingBank
    o.completionSound = construction.completionSound or o.completionSound
    o.actionAnim = construction.actionAnim or o.actionAnim
    o.modData = {
        KBW = {
            buildableId = buildableId,
            stageId = o.stage.id,
            variantId = o.variantId,
            materialId = o.materialId,
            entity = entityMetadata.entity,
            schemaVersion = KBW.SCHEMA_VERSION,
            providesWindowFrame = placement.providesWindowFrame == true and true or nil,
            wallType = ((o.stage.finishes or o.definition.finishes) and WallFinishes.wallType(o.definition, o.stage))
                or nil
        }
    }
    -- Registered stage-property handlers derive their cursor fields last so
    -- they can build on (or override) the built-in flags above.
    Properties.applyToCursor(o)
    return o
end

---@param key string | number
function KBWBuildingObject:rotateKey(key)
    if getCore():isKey("Rotate building", key) then
        if self.isWallLike then
            self.nSprite = wallEdgeDirection(self.nSprite) == 1 and 2 or 1
        else
            self.nSprite = nextDirection(self.stage, self.nSprite)
        end
        self.direction = self.nSprite
        self:getSprite()
        return
    end
    ISBuildingObject.rotateKey(self, key)
    self.direction = self.nSprite
end

---@param x number
---@param y number
function KBWBuildingObject:rotateMouse(x, y)
    ISBuildingObject.rotateMouse(self, x, y)
    if self.isWallLike then
        self.nSprite = wallEdgeDirection(self.nSprite)
    else
        self.nSprite = normalizedDirection(self.stage, self.nSprite)
    end
    self.direction = self.nSprite
    self:getSprite()
end

---@param x number
---@param y number
---@param z number
function KBWBuildingObject:tryBuild(x, y, z)
    if self.isWallLike then
        self.nSprite = wallEdgeDirection(self.nSprite)
    else
        self.nSprite = normalizedDirection(self.stage, self.nSprite)
    end
    self.direction = self.nSprite
    self:getSprite()
    if self.modData and self.modData.KBW then self.modData.KBW.direction = self.nSprite end
    if self.buildPanelLogic and EntityCompat.usesNativeRecipeInputs(self.stage) then
        self.containers = currentBuildContainers(self.character)
        self.buildPanelLogic:setContainers(self.containers)
        applyNativeInputChoices(self.buildPanelLogic, self.craftRecipe, self.inputChoices, self.containers)
    end
    local buildAction = ISBuildingObject.tryBuild(self, x, y, z)
    local construction = StageConfig.construction(self.definition, self.stage)
    local timedActionOnIsValid = StageConfig.sprite(self.definition, self.stage).timedActionOnIsValid
    if buildAction and timedActionOnIsValid then buildAction.onIsValid = timedActionOnIsValid end
    if buildAction and construction.canWalk == true then
        buildAction.stopOnWalk = false
        buildAction.stopOnRun = false
    end
    -- Chain the plaster/paint/wallpaper actions once the wall exists in the
    -- world; the watcher is client-side (the timed actions are vanilla and
    -- multiplayer-safe on their own).
    if not isServer() and WallFinishes.isWallFinish(self.finish) then
        local FinishQueue = require("KnoxBuildworks/Planning/FinishQueue")
        FinishQueue.watch(
            self.character, self.buildableId, x, y, z, self.north == true, self.finish, self.definition, self.stage
        )
    end
    return buildAction
end

function KBWBuildingObject:onActionComplete()
    ISBuildingObject.onActionComplete(self)
    self.blockBuild = false
end

---@param action string
function KBWBuildingObject:onTimedActionStart(action)
    ISBuildingObject.onTimedActionStart(self, action)
    local construction = StageConfig.construction(self.definition, self.stage)
    local craftRecipe = StageConfig.recipe(self.definition, self.stage)
    local actionScript = craftRecipe.timedAction and getScriptManager()
        and getScriptManager():getTimedActionScript(craftRecipe.timedAction) or nil
    if actionScript then
        if actionScript:getActionAnim() then action:setActionAnim(actionScript:getActionAnim()) end
        if actionScript:getAnimVarKey() then
            action:setAnimVariable(actionScript:getAnimVarKey(), actionScript:getAnimVarVal())
        end
    end
    if construction.actionAnim then action:setActionAnim(construction.actionAnim) end
    local animVariable = construction.animVariable or {}
    if animVariable.key and animVariable.value then action:setAnimVariable(animVariable.key, animVariable.value) end
    local square = self.square
    local prop1, prop2 = Requirements.handModels(self.character, self.definition, self.stage, square, self.inputChoices)
    if prop1 ~= nil or prop2 ~= nil then
        action:setOverrideHandModels(prop1, prop2)
    elseif actionScript and (actionScript:getProp1() or actionScript:getProp2()) then
        action:setOverrideHandModels(actionScript:getProp1(), actionScript:getProp2())
    end
end

---@param square IsoGridSquare | nil
function KBWBuildingObject:haveMaterial(square)
    if not self.character then
        self.character = type(self.player) == "number" and getSpecificPlayer(self.player) or self.player
    end
    return Requirements.evaluate(self.character, self.definition, self.stage, square, self.inputChoices).ok
end

function KBWBuildingObject:getFootprint()
    local direction = faceName(self.nSprite)
    return Matrix.getFaceCells(self.stage, direction)
end

--- ISBuildAction's TimedActionOnIsValid bridge expects the vanilla entity
--- cursor's getFace():getFaceName() shape. JSON-only cursors provide the same
--- minimal adapter without creating a native FaceScript.
function KBWBuildingObject:getFace()
    local name = string.lower(faceName(self.nSprite))
    return { getFaceName = function () return name end }
end

---@param x number
---@param y number
---@param z number
function KBWBuildingObject:ensureSquareExists(x, y, z)
    if not getWorld():isValidSquare(x, y, z) then return nil end
    local square = getCell():getGridSquare(x, y, z)
    if not square then
        square = IsoGridSquare.new(getCell(), nil, x, y, z)
        getCell():ConnectNewSquare(square, false)
    end
    square:EnsureSurroundNotNull()
    return square
end

---@param x number
---@param y number
---@param z number
function KBWBuildingObject:ensureSquaresExist(x, y, z)
    local footprint = self:getFootprint()
    if footprint then
        for tileIndex = 1, #footprint do
            local tile = footprint[tileIndex]
            if tile.sprite or tile.blocks then
                self:ensureSquareExists(x + (tile.dx or 0), y + (tile.dy or 0), z + (tile.dz or 0))
            end
        end
    else
        self:ensureSquareExists(x, y, z)
    end
end

---@param spriteName string | nil
function KBWBuildingObject:getCachedSprite(spriteName)
    if not spriteName then return nil end
    local sprite = self.spriteCache and self.spriteCache[spriteName]
    if sprite then return sprite end
    sprite = getSprite(spriteName)
    if not sprite then
        sprite = IsoSprite.new()
        sprite:LoadSingleTexture(spriteName)
    end
    self.spriteCache[spriteName] = sprite
    return sprite
end

---@param x number
---@param y number
---@param z number
function KBWBuildingObject:walkTo(x, y, z)
    local square = getCell():getGridSquare(x, y, z)
    local occupied = {}
    local footprint = self:getFootprint() or {}
    for cellIndex = 1, #footprint do
        local cell = footprint[cellIndex]
        local target = getCell():getGridSquare(x + cell.dx, y + cell.dy, z + (cell.dz or 0))
        if target and (cell.blocks or cell.sprite) then
            occupied[#occupied + 1] = target
        end
    end
    local isStairs = (self.definition.placement or {}).kind == "stairs"
        or string.find(string.lower(tostring(self.buildableId or "")), "stairs", 1, true) ~= nil
    if isStairs then
        local bottom
        if self.north then
            bottom = getCell():getGridSquare(x + 2, y, z)
        else
            bottom = getCell():getGridSquare(x, y + 2, z)
        end
        if bottom then return luautils.walkAdj(self.character, bottom, false, occupied) end
    end
    if #occupied > 1 then return luautils.walkAdjSquares(self.character, occupied, true, true) end
    if self.isWallLike then
        local previousStage = Placement.previousStageOf(self.stage)
        local frame = square and previousStage
            and Placement.findPrevious(square, self.definition.id, previousStage, self.north == true) or nil
        if frame and isStandingAtWallEdge(self.character, square, self.north == true) then
            ISTimedActionQueue.clear(self.character)
            return true
        end
        return luautils.walkAdjWall(self.character, square, self.north)
    end
    return ISBuildingObject.walkTo(self, x, y, z)
end

---@param square IsoGridSquare | nil
function KBWBuildingObject:isValid(square)
    if not self.character then
        self.character = type(self.player) == "number" and getSpecificPlayer(self.player) or self.player
    end
    if self.blockBuild or not self.definition or not self.stage then return false end
    if not Integrity.isAllowed(self.character) then
        self.validationReason = "definition integrity mismatch"
        return false
    end
    self:getSprite()
    local ok, reason, previous = Placement.validate(self, square)
    if not ok then
        self.validationReason = reason
        return false
    end
    if not self:haveMaterial(square) then
        self.validationReason = "requirements not met"
        return false
    end
    if WallFinishes.isWallFinish(self.finish) then
        local finishOk, finishReason = FinishActions.validate(
            self.character, self.definition, self.stage, self.finish, true
        )
        if not finishOk then
            self.validationReason = finishReason or "finish materials missing"
            return false
        end
    end
    if previous then return true end
    local footprint = self:getFootprint()
    if footprint then return true end
    if (self.definition.placement or {}).kind == "floor" then
        if square:getZ() > 0 then
            local below = getCell():getGridSquare(square:getX(), square:getY(), square:getZ() - 1)
            if below and below:HasStairs() then return false end
        end
        for i = 0, square:getObjects():size() - 1 do
            local object = square:getObjects():get(i)
            if object:getTextureName() == self:getSprite() or object:getSpriteName() == self:getSprite() then
                return false
            end
        end
        return square:connectedWithFloor()
    end
    if (self.definition.placement or {}).kind == "overlay" then return true end
    return ISBuildingObject.isValid(self, square)
end

-- Stackable furniture and table-top fixtures render with the same vertical
-- surface offset as vanilla moveables.
---@param spriteName string | nil
---@param square     IsoGridSquare | nil
function KBWBuildingObject:getStackRenderOffset(spriteName, square)
    if not spriteName or not square then return 0 end
    local sharedSprite = getSprite(spriteName)
    if not sharedSprite then return 0 end
    local properties = sharedSprite:getProperties()
    if not properties:has("IsStackable") and not properties:has("IsTableTop") then return 0 end
    local props = ISMoveableSpriteProps.new(sharedSprite)
    local offset = props:getTotalTableHeight(square)
    if properties:has("IsTableTop") and props.surface and props.surfaceIsOffset then
        offset = offset - props.surface
    end
    return offset
end

---@param x      number
---@param y      number
---@param z      number
---@param square IsoGridSquare | nil
function KBWBuildingObject:render(x, y, z, square)
    self:ensureSquaresExist(x, y, z)
    local footprint = self:getFootprint()
    if not footprint then
        ISBuildingObject.render(self, x, y, z, square)
        return
    end
    local valid = self:isValid(square)
    local floorSprite = self:getFloorCursorSprite()
    for tileIndex = 1, #footprint do
        local tile = footprint[tileIndex]
        local tileX, tileY, tileZ = x + (tile.dx or 0), y + (tile.dy or 0), z + (tile.dz or 0)
        if tile.blocks and floorSprite then
            floorSprite:RenderGhostTileColor(
                tileX, tileY, tileZ, valid and 0.25 or 0.8, valid and 0.9 or 0.15, valid and 0.9 or 0.15, 0.35
            )
        end
        local spriteName = tile.sprite
        -- Preview the final finished face (plastered/painted/papered).
        if spriteName and WallFinishes.isWallFinish(self.finish) then
            spriteName = WallFinishes.previewSprite(
                self.finish, self.north == true, self.definition, self.stage, tile.sprite
            ) or spriteName
        end
        local sprite = self:getCachedSprite(spriteName)
        if sprite then
            local tileSquare = getCell():getGridSquare(tileX, tileY, tileZ)
            local offsetY = self:getStackRenderOffset(tile.sprite, tileSquare)
            if offsetY ~= 0 then
                sprite:RenderGhostTileColor(
                    tileX, tileY, tileZ, 0, offsetY * Core.getTileScale(), valid and 1.0 or 0.65, valid and 1.0 or 0.2,
                    valid and 1.0 or 0.2, 0.6
                )
            else
                sprite:RenderGhostTileColor(
                    tileX, tileY, tileZ, valid and 1.0 or 0.65, valid and 1.0 or 0.2, valid and 1.0 or 0.2, 0.6
                )
            end
        end
    end
end

function KBWBuildingObject:getBuildHealth()
    local base = self.baseHealth or self.stage.health or 100
    local req = (self.stage.requirements or {}).skills or {}
    local highest = 0
    for perkName in pairs(req) do
        if Perks[perkName] then highest = math.max(highest, self.character:getPerkLevel(Perks[perkName])) end
    end
    local bonus = self.bonusHealth or 0
    local option = getSandboxOptions() and getSandboxOptions():getOptionByName("ConstructionBonusPoints")
    if option then
        local value = option:getValue()
        if value == 1 then
            bonus = bonus * .5
        elseif value == 2 then
            bonus = bonus * .7
        elseif value == 4 then
            bonus = bonus * 1.3
        elseif value == 5 then
            bonus = bonus * 1.5
        end
    end
    return base + bonus + (highest * (self.skillBaseHealth or 0))
end

function KBWBuildingObject:runOnCreate(part, context)
    local onCreate = StageConfig.sprite(self.definition, self.stage).onCreate
    if not onCreate or not part then return nil end
    local square = part:getSquare()
    return LuaCallback.callObject(onCreate, {
        thumpable = part,
        craftRecipeData = self.craftRecipeData,
        character = self.character,
        facing = string.lower(faceName(self.nSprite)),
        north = self.north == true,
        square = square,
        definition = self.definition,
        stage = self.stage,
        buildObject = self,
        buildableId = self.buildableId,
        stageId = self.stage and self.stage.id or nil,
        tile = context and context.tile or nil,
        tileIndex = context and context.tileIndex or nil,
        x = square and square:getX() or nil,
        y = square and square:getY() or nil,
        z = square and square:getZ() or nil
    })
end

function KBWBuildingObject:consumeConstructionRequirements(square)
    local usesNativeInputs = EntityCompat.usesNativeRecipeInputs(self.stage)
    if usesNativeInputs and not self.craftRecipe then
        self.craftRecipe = EntityCompat.craftRecipeObject(self.stage)
    end
    if not usesNativeInputs or not self.craftRecipe or not BuildLogic then
        local consumed, recipeData = Requirements.consume(
            self.character, self.stage, square, self.definition, self.inputChoices
        )
        self.craftRecipeData = recipeData
        return consumed, consumed and nil or "Knox recipe inputs changed before consumption"
    end

    local containers = accessibleBuildContainers(
        self.character, self.containers or listedBuildContainers(self.character)
    )
    self.containers = containers
    local logic = newNativeBuildLogic(self.character, self.craftRecipe, self.inputChoices, containers)
    if not logic then return false, "native build logic unavailable" end
    local nativeAwards = self.stage._kbwAdminXpOverride and {} or EntityCompat.xpAwards(self.stage)
    Log:info(
        "Entity XP check for %s uses recipe %s with %d award(s)", tostring(self.buildableId),
        tostring(self.craftRecipe:getName()), #nativeAwards
    )
    snapshotXp(self.character, nativeAwards)
    logic:startCraftAction(nil)
    self.craftRecipeData = logic:getRecipeData()
    self.nativeRecipeHandled = true
    if self.character:isBuildCheat() then return true end
    if not logic:performCurrentRecipe() then
        return false, nativeInputFailure(logic, self.craftRecipe, containers)
    end
    local inProgress = logic:getRecipeDataInProgress()
    inProgress:luaCallOnCreate(self.character)
    inProgress:processDestroyAndUsedItems(self.character)
    self.nativeXpPending = #nativeAwards > 0 and not nativeXpWasGranted(self.character, nativeAwards)
    if #nativeAwards > 0 and not self.nativeXpPending then
        Log:info("Entity recipe XP credited during native completion for %s", tostring(self.buildableId))
    elseif #nativeAwards == 0 then
        Log:info(
            "Entity recipe %s has no configured XP award for %s", tostring(self.craftRecipe:getName()),
            tostring(self.buildableId)
        )
    end
    return true
end

function KBWBuildingObject:transmitPart(part, result)
    if result ~= nil then
        if result.objectAlreadyTransmitted then return end
        if result.replaceObject and result.object ~= nil then
            local sourceModData = part and part.getModData and part:getModData() or nil
            local replacementModData = result.object.getModData and result.object:getModData() or nil
            if sourceModData and sourceModData.KBW and replacementModData then
                replacementModData.KBW = sourceModData.KBW
            end
            result.object:transmitCompleteItemToClients()
            return
        end
    end
    if part and part.transmitCompleteItemToClients then part:transmitCompleteItemToClients() end
end

---@param x number
---@param y number
---@param z number
function KBWBuildingObject:verifyAuthoritative(x, y, z)
    if not Integrity.isAllowed(self.character) then return false, "definition integrity mismatch" end
    -- Builds launched from a plan re-check blueprint access here; the client
    -- stamps blueprintId on the cursor (free builds carry none).
    if self.blueprintId then
        local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
        local blueprint = Blueprints.get(self.character, self.blueprintId)
        if not blueprint then return false, "unknown blueprint" end
        if not Blueprints.canBuild(self.character, blueprint) then
            return false, "no build access on blueprint"
        end
    end
    local definition, stage, reason = Resolver.resolveStage(
        self.buildableId, self.variantId, self.materialId, self.stageId or (self.stage and self.stage.id)
    )
    if not definition or not stage then return false, reason or "unknown buildable" end
    self.definition, self.stage = definition, stage
    local spriteConfig = StageConfig.sprite(definition, stage)
    if spriteConfig.onIsValid and not LuaCallback.resolve(spriteConfig.onIsValid) then
        return false, "OnIsValid callback is unavailable: " .. tostring(spriteConfig.onIsValid)
    end
    if spriteConfig.onCreate and not LuaCallback.resolve(spriteConfig.onCreate) then
        return false, "OnCreate callback is unavailable: " .. tostring(spriteConfig.onCreate)
    end
    if self.nativeObject and self.nativeObject.type == "generator" then
        local itemType = self.nativeObject.item
        if not getScriptManager() or not getScriptManager():getItem(itemType) then
            return false, "native generator item is unavailable: " .. tostring(itemType)
        end
    end
    if LuaCallback.requiresNativeRecipe(spriteConfig.onCreate) and not EntityCompat.usesNativeRecipeInputs(stage) then
        return false,
            "OnCreate callback requires an entity-backed native CraftRecipe: " .. tostring(spriteConfig.onCreate)
    end
    local finishOk, finishReason = FinishActions.validate(self.character, definition, stage, self.finish, true)
    if not finishOk then return false, finishReason or "invalid finish" end
    local choicesOk, choicesReason = Resolver.validateChoices(definition, stage, self.inputChoices)
    if not choicesOk then return false, choicesReason or "invalid ingredient choices" end
    if self.character and self.character.isBuildCheat and self.character:isBuildCheat() then return true end
    local bounds = Matrix.getBounds(self:getFootprint() or {})
    local slack = math.max(bounds.width or 1, bounds.height or 1) + 2
    local dx = self.character:getX() - (x + 0.5)
    local dy = self.character:getY() - (y + 0.5)
    if dx * dx + dy * dy > slack * slack then return false, "too far from build site" end
    local dz = math.abs(math.floor(self.character:getZ()) - z)
    if dz > math.max(1, (bounds.depth or 1)) then return false, "wrong level for build site" end
    return true
end

local function alwaysTrue(item)
    return item ~= nil
end

-- Vanilla lamp-on-pillar behaviour: the consumed torch/flashlight becomes the
-- thumpable's light source and keeps its battery charge.
function KBWBuildingObject:findLightSourceItem(spriteConfig)
    if not spriteConfig.lightRadius or not self.character then return nil end
    local inventory = self.character:getInventory()
    if not inventory then return nil end
    if spriteConfig.lightsourceItem then
        local item = inventory:getFirstTypeRecurse(spriteConfig.lightsourceItem)
        if item then return item end
    end
    local tags = spriteConfig.lightsourceTags or {}
    for tagIndex = 1, #tags do
        if ItemTag and ResourceLocation then
            local tag = ItemTag.get(ResourceLocation.of(tags[tagIndex]))
            if tag then
                local item = inventory:getFirstTagEvalRecurse(tag, alwaysTrue)
                if item then return item end
            end
        end
    end
    if self.character:isBuildCheat() and spriteConfig.debugItem then
        return instanceItem(spriteConfig.debugItem)
    end
    return nil
end

function KBWBuildingObject:attachLightSource(part, spriteConfig, torchItem)
    if not spriteConfig.lightRadius or not torchItem then return end
    local offsets = (spriteConfig.lightOffsets or {})[faceName(self.nSprite)] or {}
    part:createLightSource(
        spriteConfig.lightRadius, offsets.x or 0, offsets.y or 0, offsets.z or 0, 0, spriteConfig.lightsourceFuel,
        torchItem, self.character
    )
end

function KBWBuildingObject:applyPartFlags(part)
    local props = part:getProperties()
    if not props then return end
    local spriteType = part:getType()
    self.blockAllTheSquare = props:has(IsoPropertyType.BLOCKS_PLACEMENT) == true
    self.canPassThrough = not (props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans)
        or props:has(IsoFlagType.doorN) or props:has(IsoFlagType.doorW)
        or props:has(IsoFlagType.collideN) or props:has(IsoFlagType.collideW)
        or props:has(IsoFlagType.WindowN) or props:has(IsoFlagType.WindowW)
        or props:has(IsoFlagType.windowN) or props:has(IsoFlagType.windowW)
        or props:has(IsoFlagType.DoorWallN) or props:has(IsoFlagType.DoorWallW)
        or props:has(IsoFlagType.HoppableN) or props:has(IsoFlagType.HoppableW)
        or props:has(IsoFlagType.WallN) or props:has(IsoFlagType.WallNTrans)
        or props:has(IsoFlagType.WallW) or props:has(IsoFlagType.WallWTrans)
        or props:has(IsoFlagType.WallNW))
    self.hoppable = (props:has(IsoFlagType.HoppableN) or props:has(IsoFlagType.HoppableW)
        or props:has(IsoFlagType.TallHoppableN) or props:has(IsoFlagType.TallHoppableW)) == true
    self.isStairs = spriteType ~= nil
        and (spriteType == IsoObjectType.stairsTW or spriteType == IsoObjectType.stairsTN
            or spriteType == IsoObjectType.stairsMW or spriteType == IsoObjectType.stairsMN
            or spriteType == IsoObjectType.stairsBW or spriteType == IsoObjectType.stairsBN)
    self.isDoorFrame = spriteType ~= nil
        and (spriteType == IsoObjectType.doorFrN or spriteType == IsoObjectType.doorFrW)
    self.isDoor = spriteType ~= nil and (spriteType == IsoObjectType.doorN or spriteType == IsoObjectType.doorW)
    self.isFloor = props:has(IsoFlagType.solidfloor) == true
    if self.isDoor then self.thumpDmg = 5 end
    self.canBarricade = (self.isDoor or props:has(IsoFlagType.WindowN)
        or props:has(IsoFlagType.WindowW) or props:has(IsoFlagType.windowN)
        or props:has(IsoFlagType.windowW))
        and not (props:has(IsoPropertyType.DOUBLE_DOOR) or props:has(IsoPropertyType.GARAGE_DOOR))
    self.canBarricade = self.canBarricade == true
    local objectConfig = self.objectConfig or {}
    if objectConfig.blockAllSquare ~= nil then self.blockAllTheSquare = objectConfig.blockAllSquare == true end
    if objectConfig.canPassThrough ~= nil then self.canPassThrough = objectConfig.canPassThrough == true end
    if objectConfig.isDoorFrame ~= nil then self.isDoorFrame = objectConfig.isDoorFrame == true end
    if objectConfig.isCorner ~= nil then self.isCorner = objectConfig.isCorner == true end
    if objectConfig.hoppable ~= nil then self.hoppable = objectConfig.hoppable == true end
    if objectConfig.thumpDamage ~= nil then self.thumpDmg = objectConfig.thumpDamage end
    if objectConfig.canBarricade ~= nil then self.canBarricade = objectConfig.canBarricade == true end
    local sprite = part:getSprite()
    if isPassableWallOpeningSprite(sprite and sprite:getName() or nil, self.north == true) then
        -- Cut-only arches are openings, not windows: they remain walkable and
        -- cannot inherit old window-frame interaction flags from definitions.
        self.canPassThrough = true
        self.hoppable = false
        self.canBarricade = false
    end
end

-- Two matching orientations on the SAME anchor square become one corner.
-- Matching offset ends keep both edges and receive the optional pillar sprite
-- in the gap between them.
---@param square IsoGridSquare
---@param part IsoThumpable
---@param north boolean
function KBWBuildingObject:connectWallParts(square, part, north)
    local identity = connectionData(part)
    if not identity or (not self.corner and not self.pillar) then return part end
    local matchIdentity = copyTable(identity)
    matchIdentity.connectionRole = nil

    if self.corner then
        local perpendicular = findMatchingWallEdge(square, matchIdentity, not north, part)
        if perpendicular then
            local cornerMaxHealth = math.max(
                tonumber(part:getMaxHealth()) or 0,
                tonumber(perpendicular:getMaxHealth()) or 0
            )
            local cornerHealth = math.max(
                tonumber(part:getHealth()) or 0,
                tonumber(perpendicular:getHealth()) or 0
            )
            square:transmitRemoveItemFromSquare(perpendicular)
            square:RemoveTileObject(part)

            local corner = IsoThumpable.new(getCell(), square, self.corner, false, self)
            self:applyPartFlags(corner)
            buildUtil.setInfo(corner, self)
            corner:setMaxHealth(cornerMaxHealth)
            corner:setHealth(cornerHealth)
            corner:setBreakSound(self.breakSound or IsoThumpable.GetBreakFurnitureSound(self.corner))
            corner:setCanBePlastered(self.canBePlastered == true)
            corner:setCorner(true)
            corner:setCanBarricade(false)
            corner:getModData().KBW = copyTable(matchIdentity)
            corner:getModData().KBW.direction = 1
            corner:getModData().KBW.connectionRole = "corner"
            EntityCompat.attach(corner, self.stage, true)
            square:AddSpecialObject(corner)
            square:RecalcAllWithNeighbours(true)
            return corner
        end
    end

    if not self.pillar then return part end
    local otherX, otherY = square:getX() + 1, square:getY() - 1
    local pillarX, pillarY = square:getX() + 1, square:getY()
    if not north then
        otherX, otherY = square:getX() - 1, square:getY() + 1
        pillarX, pillarY = square:getX(), square:getY() + 1
    end
    local otherSquare = getCell():getGridSquare(otherX, otherY, square:getZ())
    if not findMatchingWallEdge(otherSquare, matchIdentity, not north, nil) then return part end

    local pillarSquare = self:ensureSquareExists(pillarX, pillarY, square:getZ())
    if not pillarSquare or pillarSquare:getWallFull() or squareHasSprite(pillarSquare, self.pillar) then return part end
    local pillar = IsoThumpable.new(getCell(), pillarSquare, self.pillar, false, self)
    buildUtil.setInfo(pillar, self)
    pillar:setName(self.name)
    pillar:setMaxHealth(part:getMaxHealth())
    pillar:setHealth(part:getHealth())
    pillar:setCorner(true)
    pillar:setCanPassThrough(true)
    pillar:setCanBarricade(false)
    pillar:setCanBePlastered(self.canBePlastered == true)
    pillar:getModData().KBW = copyTable(matchIdentity)
    pillar:getModData().KBW.connectionRole = "pillar"
    pillarSquare:AddSpecialObject(pillar)
    pillarSquare:RecalcAllWithNeighbours(true)
    pillar:transmitCompleteItemToClients()
    buildUtil.setHaveConstruction(pillarSquare, true)
    return part
end

---@param x      number
---@param y      number
---@param z      number
---@param north  boolean
---@param sprite IsoSprite | string | nil
function KBWBuildingObject:create(x, y, z, north, sprite)
    if not self.character then
        self.character = type(self.player) == "number" and getSpecificPlayer(self.player) or self.player
    end
    if self.isWallLike then
        self.nSprite = north == true and 2 or 1
        self.direction = self.nSprite
    end
    self:getSprite()
    north = self.north == true
    if self.modData and self.modData.KBW then self.modData.KBW.direction = self.nSprite end
    local verified, verifyReason = self:verifyAuthoritative(x, y, z)
    if not verified then
        Log:warning(
            "Server rejected build %s at %d,%d,%d: %s", tostring(self.buildableId), x, y, z, tostring(verifyReason)
        )
        return false
    end
    -- The rules document may have changed after the client opened its cursor.
    -- Rebuild every recipe/XP field from the stage the server just resolved.
    self.craftRecipe = EntityCompat.craftRecipeObject(self.stage)
    local craftRecipeConfig = StageConfig.recipe(self.definition, self.stage)
    local construction = StageConfig.construction(self.definition, self.stage)
    self.xpAward = craftRecipeConfig.xpAward
    self.useNativeXpAward = self.craftRecipe ~= nil and (self.stage.xp == nil and construction.xp == nil)
    self:ensureSquaresExist(x, y, z)
    local square = getCell():getGridSquare(x, y, z)
    local ok, reason, previous = Placement.validate(self, square)
    if not ok or not Requirements.evaluate(self.character, self.definition, self.stage, square, self.inputChoices).ok then
        Log:warning("Server rejected build %s at %d,%d,%d: %s", self.buildableId, x, y, z, reason or "requirements")
        return false
    end
    local spriteConfig = StageConfig.sprite(self.definition, self.stage)
    local torchItem = self:findLightSourceItem(spriteConfig)
    local consumed, consumptionReason = self:consumeConstructionRequirements(square)
    if not consumed then
        Log:warning(
            "Server rejected build %s at %d,%d,%d during consumption: %s", tostring(self.buildableId), x, y, z,
            tostring(consumptionReason or "requirements changed")
        )
        return false
    end
    local replacedIndex = -1
    if previous then replacedIndex = square:transmitRemoveItemFromSquare(previous) or -1 end
    local footprint = self:getFootprint() or { { dx = 0, dy = 0, dz = 0, sprite = sprite } }
    local groupId = string.format("%s:%d:%d:%d:%d", self.buildableId, x, y, z, getTimestampMs())
    local placement = StageConfig.placement(self.definition, self.stage)
    for index = 1, #footprint do
        local tile = footprint[index]
        if tile.sprite then
            local target = self:ensureSquareExists(x + (tile.dx or 0), y + (tile.dy or 0), z + (tile.dz or 0))
            local nativeObjectType = NativeObjectFactory.resolve(self.nativeObject, tile.sprite)
            self.modData.KBW.groupId, self.modData.KBW.partIndex, self.modData.KBW.partCount = groupId,
                index, #footprint
            if placement.kind == "floor" then
                local part = target:addFloor(tile.sprite)
                part:getModData().KBW = copyTable(self.modData.KBW)
                EntityCompat.attach(part, self.stage, true)
                target:disableErosion()
                sendServerCommand(
                    "erosion", "disableForSquare", { x = target:getX(), y = target:getY(), z = target:getZ() }
                )
                Properties.applyToObject(
                    part, self, { square = target, spriteConfig = spriteConfig, tileIndex = index, isFloor = true }
                )
                self:transmitPart(part, self:runOnCreate(part, { tile = tile, tileIndex = index }))
            elseif nativeObjectType then
                local part, nativeState, nativeError = NativeObjectFactory.create(
                    nativeObjectType, self.nativeObject, target, tile.sprite
                )
                if not part then
                    Log:error(
                        "Failed to create native %s for %s: %s", tostring(nativeObjectType), tostring(self.buildableId),
                        tostring(nativeError)
                    )
                    return false
                end
                part:getModData().KBW = copyTable(self.modData.KBW)
                EntityCompat.attach(part, self.stage, true)
                local nativeInsertIndex = previous and target == square and replacedIndex >= 0 and replacedIndex or nil
                NativeObjectFactory.insert(part, nativeState, target, nativeInsertIndex)
                Properties.applyToObject(
                    part, self, { square = target, spriteConfig = spriteConfig, tileIndex = index, isFloor = false }
                )
                if part.setExplored then part:setExplored(true) end
                local callbackResult = self:runOnCreate(part, { tile = tile, tileIndex = index })
                NativeObjectFactory.finalize(part, nativeState, target)
                if callbackResult and callbackResult.replaceObject then
                    self:transmitPart(part, callbackResult)
                elseif nativeState.alreadyTransmitted then
                    if part.transmitModData then part:transmitModData() end
                else
                    self:transmitPart(part, callbackResult)
                end
                buildUtil.setHaveConstruction(target, true)
            elseif self.isProp or isFloorAttachmentSprite(tile.sprite) or isRoofObjectSprite(tile.sprite) then
                -- Vanilla isProp scripts place a moveable world prop instead
                -- of an IsoThumpable (ISBuildIsoEntity:setInfo). Floor rugs
                -- and non-floor roof pieces must follow this path as well.
                -- IsoThumpable's pathfinding collision remains north/west
                -- oriented even when the object is marked passable.
                local props = ISMoveableSpriteProps.new(IsoObject.new(target, tile.sprite):getSprite())
                props.rawWeight = 10
                local part = props:placeMoveableInternal(target, instanceItem("Base.Plank"), tile.sprite)
                local plainProp = false
                if not part then
                    part = IsoObject.new(target, tile.sprite)
                    target:AddTileObject(part)
                    plainProp = true
                end
                if part then
                    part:getModData().KBW = copyTable(self.modData.KBW)
                    EntityCompat.attach(part, self.stage, true)
                    Properties.applyToObject(part, self, {
                        square = target,
                        spriteConfig = spriteConfig,
                        tileIndex = index,
                        isFloor = isFloorAttachmentSprite(tile.sprite)
                    })
                    self:runOnCreate(part, { tile = tile, tileIndex = index })
                    if plainProp and part.transmitCompleteItemToClients then
                        part:transmitCompleteItemToClients()
                    elseif part.transmitModData then
                        part:transmitModData()
                    end
                end
            elseif isGarageDoorSprite(tile.sprite) then
                -- Garage-door behavior is owned by IsoDoor. Its sprite-name
                -- constructor reads GarageDoor=1..6 and derives the open part
                -- at the engine's +8/-8 offset. A generic IsoThumpable has no
                -- open sprite and becomes a null-sprite object when toggled.
                local part = IsoDoor.new(getCell(), target, tile.sprite, north)
                local health = math.max(tonumber(self:getBuildHealth()) or 0, tonumber(part:getHealth()) or 0)
                part:setHealth(health)
                part:getModData().KBW = copyTable(self.modData.KBW)
                EntityCompat.attach(part, self.stage, true)
                if previous and target == square and replacedIndex >= 0 then
                    target:AddSpecialObject(part, replacedIndex)
                else
                    target:AddSpecialObject(part)
                end
                Properties.applyToObject(
                    part, self, { square = target, spriteConfig = spriteConfig, tileIndex = index, isFloor = false }
                )
                part:setExplored(true)
                target:RecalcAllWithNeighbours(true)
                self:transmitPart(part, self:runOnCreate(part, { tile = tile, tileIndex = index }))
                buildUtil.setHaveConstruction(target, true)
            else
                local faceKey = faceName(self.nSprite)
                local openSprite = (self.stage.sprites and self.stage.sprites[faceKey .. "_open"])
                    or spriteConfig.openSprite
                local part = openSprite and IsoThumpable.new(getCell(), target, tile.sprite, openSprite, north, self)
                    or IsoThumpable.new(getCell(), target, tile.sprite, north, self)
                self:applyPartFlags(part)
                local configuredIsContainer = self.isContainer
                local configuredContainerType = self.containerType
                local tileContainerType = nativeContainerType(tile.sprite)
                if tileContainerType then
                    self.isContainer = true
                    self.containerType = tileContainerType
                elseif self.stage.container == nil then
                    self.isContainer = false
                    self.containerType = nil
                end
                buildUtil.setInfo(part, self)
                self.isContainer = configuredIsContainer
                self.containerType = configuredContainerType
                part:setCanBePlastered(self.canBePlastered == true)
                local health = self:getBuildHealth()
                part:setMaxHealth(health)
                part:setHealth(health)
                part:setBreakSound(self.breakSound or IsoThumpable.GetBreakFurnitureSound(tile.sprite))
                if self.canBeLockedByPadlock then part:setCanBeLockByPadlock(true) end
                -- Stackable furniture (crates) sits on top of the stack below it.
                local stackOffset = self:getStackRenderOffset(tile.sprite, target)
                if stackOffset ~= 0 then part:setRenderYOffset(stackOffset) end
                -- Match ISBuildIsoEntity:setInfo: native entity components are
                -- instanced before the object enters the square. This makes
                -- Resources, CraftBench/DryingCraftLogic, CraftBenchSounds,
                -- SpriteConfig and SpriteOverlayConfig engine-managed.
                part:getModData().KBW = copyTable(self.modData.KBW)
                EntityCompat.attach(part, self.stage, true)
                if previous and target == square and replacedIndex >= 0 then
                    target:AddSpecialObject(part, replacedIndex)
                else
                    target:AddSpecialObject(part)
                end
                part = self:connectWallParts(target, part, north)
                -- Registered stage-property handlers (container capacity etc.)
                -- apply their behavior to the finished part.
                Properties.applyToObject(
                    part, self, { square = target, spriteConfig = spriteConfig, tileIndex = index, isFloor = false }
                )
                -- Player-built containers must never roll world loot
                part:setExplored(true)
                self:attachLightSource(part, spriteConfig, torchItem)
                target:RecalcAllWithNeighbours(true)
                self:transmitPart(part, self:runOnCreate(part, { tile = tile, tileIndex = index }))
                buildUtil.setHaveConstruction(target, true)
            end
        end
    end
    if self.character and self.nativeXpPending and self.craftRecipe then
        Log:warning(
            "Native recipe XP was not credited during %s; applying the B42.20 CraftRecipe fallback",
            tostring(self.buildableId)
        )
        self.craftRecipe:addXP(self.character, true)
        self.nativeXpPending = false
    elseif self.character and self.craftRecipe and self.useNativeXpAward and not self.nativeRecipeHandled then
        local nativeAwards = EntityCompat.xpAwards(self.stage)
        Log:info(
            "Entity XP completion for %s uses recipe %s with %d award(s) outside BuildLogic", tostring(self.buildableId),
            tostring(self.craftRecipe:getName()), #nativeAwards
        )
        if #nativeAwards > 0 then
            self.craftRecipe:addXP(self.character, true)
        else
            Log:info(
                "Entity recipe %s has no configured XP award for %s", tostring(self.craftRecipe:getName()),
                tostring(self.buildableId)
            )
        end
    elseif self.character and self.xpAward and (not self.nativeRecipeHandled or self.stage._kbwAdminXpOverride) then
        local multiplier = tonumber(KBW.sandboxValue("KnoxBuildworks.BuildXPMultiplier", 1.0)) or 1.0
        for perkName, amount in pairs(self.xpAward) do
            local perk = Perks[perkName]
            local xp = tonumber(amount)
            if perk and xp then
                local requested = xp * multiplier
                local gained = awardConfiguredXp(self.character, perk, requested)
                Log:info(
                    "Awarded %s/%s %s XP (requested %s) for %s", tostring(perkName), tostring(perk:getId()),
                    tostring(gained), tostring(requested), tostring(self.buildableId)
                )
            end
        end
    end
    Log:info("Built %s:%s at %d,%d,%d", self.buildableId, self.stage.id, x, y, z)
    return true
end

return KBWBuildingObject
