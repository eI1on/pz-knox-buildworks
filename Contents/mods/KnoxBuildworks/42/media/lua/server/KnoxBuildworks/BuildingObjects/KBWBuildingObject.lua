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

---@class KBWBuildingObject: ISBuildingObject
KBWBuildingObject = ISBuildingObject:derive("KBWBuildingObject")

local function faceName(nSprite)
    return ({ "W", "N", "E", "S" })[nSprite or 1] or "W"
end

local function wallEdgeDirection(direction)
    direction = tonumber(direction) or 1
    return (direction == 2 or direction == 4) and 2 or 1
end

local function configuredBoolean(value, default)
    if value == nil then return default == true end
    return value == true
end

local function currentBuildContainers(character)
    if ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.getContainers then
        local containers = ISInventoryPaneContextMenu.getContainers(character)
        if containers then return containers end
    end
    local containers = ArrayList.new()
    if character and character.getInventory then containers:add(character:getInventory()) end
    return containers
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

---@param player      IsoPlayer
---@param buildableId string
---@param stageId     string | nil
---@param variantId   string | nil
---@param materialId  string | nil
---@param direction   KBW.Direction
---@return KBWBuildingObject
function KBWBuildingObject:new(player, buildableId, stageId, variantId, materialId, direction, inputChoices)
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
    if kind == "wall" then
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
    o.isWallLike = kind == "wall" or kind == "wallCovering"
    o.isFloor = kind == "floor"
    o.canBeAlwaysPlaced = kind == "overlay"
    o.canPassThrough = configuredBoolean(objectConfig.canPassThrough, kind == "overlay")
    o.isThumpable = spriteConfig.isThumpable ~= false and kind ~= "overlay"
    o.dismantable = objectConfig.dismantable ~= false
    o.blockAllTheSquare = configuredBoolean(objectConfig.blockAllSquare, kind == "object")
    o.hoppable = objectConfig.hoppable == true or o.stage.hoppable == true
    o.dontNeedFrame = spriteConfig.dontNeedFrame == true
    o.needWindowFrame = spriteConfig.needWindowFrame == true
    o.needToBeAgainstWall = spriteConfig.needToBeAgainstWall == true
    o.isPole = spriteConfig.isPole == true
    o.canBeLockedByPadlock = spriteConfig.canBePadlocked == true
    o.corner = spriteConfig.corner
    o.bonusHealth = spriteConfig.bonusHealth or 0
    o.baseHealth = spriteConfig.health or 100
    o.skillBaseHealth = spriteConfig.skillBaseHealth or 0
    o.breakSound = spriteConfig.breakSound
    o.thumpDmg = objectConfig.thumpDamage or o.thumpDmg
    o.canBarricade = objectConfig.canBarricade == true
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
        o.containers = currentBuildContainers(o.character)
        o.buildPanelLogic = BuildLogic.new(o.character, nil, nil)
        o.buildPanelLogic:setContainers(o.containers)
        o.buildPanelLogic:setRecipe(o.craftRecipe)
        applyNativeInputChoices(o.buildPanelLogic, o.craftRecipe, o.inputChoices, o.containers)
    end
    o.maxTime = craftRecipe.time or 200
    o.xpAward = craftRecipe.xpAward
    -- Build sounds and completion sounds come from the recipe's timed-action
    -- script, matching vanilla ISBuildIsoEntity:new.
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
            wallType = kind == "wall" and WallFinishes.wallType(o.definition, o.stage) or nil
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

---ISBuildAction's TimedActionOnIsValid bridge expects the vanilla entity
---cursor's getFace():getFaceName() shape. JSON-only cursors provide the same
---minimal adapter without creating a native FaceScript.
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
    if self.isWallLike then return luautils.walkAdjWall(self.character, square, self.north) end
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

-- Stackable furniture (crates) renders and builds with a vertical offset on
-- top of the existing stack, exactly like vanilla ISBuildIsoEntity.
---@param spriteName string | nil
---@param square     IsoGridSquare | nil
function KBWBuildingObject:getStackRenderOffset(spriteName, square)
    if not spriteName or not square then return 0 end
    local sharedSprite = getSprite(spriteName)
    if not sharedSprite or not sharedSprite:getProperties():has("IsStackable") then return 0 end
    local props = ISMoveableSpriteProps.new(sharedSprite)
    return props:getTotalTableHeight(square)
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
    if not self.buildPanelLogic or not EntityCompat.usesNativeRecipeInputs(self.stage) then
        local consumed, recipeData = Requirements.consume(
            self.character, self.stage, square, self.definition, self.inputChoices
        )
        self.craftRecipeData = recipeData
        return consumed
    end

    -- Vanilla starts a fresh in-progress recipe on the authoritative server;
    -- in SP/client placement ISBuildingObject:tryBuild already did this.
    if isServer() then
        local containers = self.containers or currentBuildContainers(self.character)
        self.containers = containers
        self.buildPanelLogic:setContainers(containers)
        applyNativeInputChoices(self.buildPanelLogic, self.craftRecipe, self.inputChoices, containers)
        self.buildPanelLogic:startCraftAction(nil)
    end
    self.craftRecipeData = self.buildPanelLogic:getRecipeData()
    self.nativeRecipeHandled = true
    if self.character:isBuildCheat() then return true end
    if not self.buildPanelLogic:performCurrentRecipe() then return false end
    local inProgress = self.buildPanelLogic:getRecipeDataInProgress()
    inProgress:luaCallOnCreate(self.character)
    inProgress:processDestroyAndUsedItems(self.character)
    return true
end

function KBWBuildingObject:transmitPart(part, result)
    if result ~= nil then
        if result.objectAlreadyTransmitted then return end
        if result.replaceObject and result.object ~= nil then
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
    if LuaCallback.requiresNativeRecipe(spriteConfig.onCreate)
        and not EntityCompat.usesNativeRecipeInputs(stage) then
        return false, "OnCreate callback requires an entity-backed native CraftRecipe: "
            .. tostring(spriteConfig.onCreate)
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

-- Derives the built part's behaviour flags from its sprite properties before
-- buildUtil.setInfo persists them on the Java object, exactly like vanilla
-- ISBuildIsoEntity:setInfo - this is what makes built fences hoppable, doors
-- barricadable, and so on.
function KBWBuildingObject:applyPartFlags(part)
    local props = part:getProperties()
    if not props then return end
    local spriteType = part:getType()
    self.blockAllTheSquare = props:has(IsoPropertyType.BLOCKS_PLACEMENT) == true
    self.canPassThrough = not (props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans)
        or props:has(IsoFlagType.doorN) or props:has(IsoFlagType.doorW)
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
    if objectConfig.hoppable ~= nil then self.hoppable = objectConfig.hoppable == true end
    if objectConfig.thumpDamage ~= nil then self.thumpDmg = objectConfig.thumpDamage end
    if objectConfig.canBarricade ~= nil then self.canBarricade = objectConfig.canBarricade == true end
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
    -- The timed action's north argument is the authoritative wall edge. A
    -- serialized cursor can otherwise arrive with a stale/default nSprite,
    -- which used to make an auto-snapped planned wall build on the wrong edge.
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
    self:ensureSquaresExist(x, y, z)
    local square = getCell():getGridSquare(x, y, z)
    local ok, reason, previous = Placement.validate(self, square)
    if not ok or not Requirements.evaluate(self.character, self.definition, self.stage, square, self.inputChoices).ok then
        Log:warning("Server rejected build %s at %d,%d,%d: %s", self.buildableId, x, y, z, reason or "requirements")
        return false
    end
    local spriteConfig = StageConfig.sprite(self.definition, self.stage)
    local torchItem = self:findLightSourceItem(spriteConfig)
    if not self:consumeConstructionRequirements(square) then
        Log:error("Consumption race rejected %s", self.buildableId)
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
            self.modData.KBW.groupId, self.modData.KBW.partIndex, self.modData.KBW.partCount = groupId,
                index, #footprint
            if placement.kind == "floor" then
                local part = target:addFloor(tile.sprite)
                EntityCompat.attach(part, self.stage, true)
                target:disableErosion()
                sendServerCommand(
                    "erosion", "disableForSquare", { x = target:getX(), y = target:getY(), z = target:getZ() }
                )
                Properties.applyToObject(
                    part, self, { square = target, spriteConfig = spriteConfig, tileIndex = index, isFloor = true }
                )
                self:transmitPart(part, self:runOnCreate(part, { tile = tile, tileIndex = index }))
            elseif self.isProp then
                -- Vanilla isProp scripts place a moveable world prop instead
                -- of an IsoThumpable (ISBuildIsoEntity:setInfo).
                local props = ISMoveableSpriteProps.new(IsoObject.new(target, tile.sprite):getSprite())
                props.rawWeight = 10
                props:placeMoveableInternal(target, instanceItem("Base.Plank"), tile.sprite)
            else
                local faceKey = faceName(self.nSprite)
                local openSprite = (self.stage.sprites and self.stage.sprites[faceKey .. "_open"])
                    or spriteConfig.openSprite
                local part = openSprite and IsoThumpable.new(getCell(), target, tile.sprite, openSprite, north, self)
                    or IsoThumpable.new(getCell(), target, tile.sprite, north, self)
                self:applyPartFlags(part)
                buildUtil.setInfo(part, self)
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
                buildUtil.checkCorner(target:getX(), target:getY(), target:getZ(), north, part, self)
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
    if self.character and self.xpAward and not self.nativeRecipeHandled then
        local multiplier = tonumber(KBW.sandboxValue("KnoxBuildworks.BuildXPMultiplier", 1.0)) or 1.0
        for perkName, amount in pairs(self.xpAward) do
            if Perks[perkName] and tonumber(amount) then
                self.character:getXp():AddXP(Perks[perkName], tonumber(amount) * multiplier)
            end
        end
    end
    Log:info("Built %s:%s at %d,%d,%d", self.buildableId, self.stage.id, x, y, z)
    return true
end

return KBWBuildingObject
