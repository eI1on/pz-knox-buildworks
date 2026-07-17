---Resolves a Knox stage's registered Build 42 entity script.
---
---JSON stores identity only (`module` + `entity`). Component metadata is read
---from the parsed GameEntityScript so the entity script remains the sole
---source of truth for native behavior.
local Log = require("KnoxBuildworks/Log")
local TableUtil = require("KnoxBuildworks/Util/Table")

---@class KBW.EntityCompatModule
---@type KBW.EntityCompatModule
local EntityCompat = {}

local metadataCache = {}
local missingLogged = {}

local FACE_SCRIPTS = {
    { id = 0, name = "N" },
    { id = 1, name = "W" },
    { id = 2, name = "S" },
    { id = 3, name = "E" },
    { id = 4, name = "N_open" },
    { id = 5, name = "W_open" }
}

-- InputScript exposes hasFlag(), but not its EnumSet as a Lua-friendly list.
-- Keep this list aligned with B42's InputFlag enum so Knox preserves native
-- tool props, degradation and item-state filters when deriving requirements.
local INPUT_FLAGS = {
    "HandcraftOnly", "AutomationOnly", "IsFull", "NotFull", "ItemIsUses", "ItemIsFluid",
    "ItemIsEnergy", "IsEmpty", "NotEmpty", "Prop1", "Prop2", "ToolLeft", "ToolRight",
    "IsDamaged", "IsUndamaged", "IsWholeFoodItem", "IsEmptyContainer", "IsUncookedFoodItem",
    "IsCookedFoodItem", "IsNotDull", "IsHeadPart", "IsSharpenable", "DontPutBack", "InheritColor",
    "InheritCondition", "InheritEquipped", "InheritSharpness", "InheritHeadCondition", "MayDegrade",
    "MayDegradeLight", "MayDegradeVeryLight", "MayDegradeHeavy", "SharpnessCheck", "InheritUses",
    "InheritUsesAndEmpty", "InheritFood", "InheritFoodAge", "InheritCooked", "InheritModelVariation",
    "InheritWeight", "InheritName", "InheritFreezingTime", "DontInheritCondition", "AllowFrozenItem",
    "AllowRottenItem", "NoBrokenItems", "AllowDestroyedItem", "IsWorn", "IsNotWorn",
    "InheritAmmunition", "CopyClothing", "AllowFavorite", "InheritFavorite", "FakeOutput",
    "DontReplace", "CanBeDoneFromFloor", "ItemCount", "IsExclusive", "RecordInput",
    "DontRecordInput", "ResearchInput", "IsBlunt", "HasOneUse", "HasNoUses", "IsSealed",
    "IsNotSealed", "Unseal", "EquipSecondary", "SetActivated"
}

local function referenceFor(stage)
    return (stage and stage.entityCompat) or {}
end

local function copyJavaStrings(values)
    local result = {}
    if not values then return result end
    for valueIndex = 0, values:size() - 1 do
        result[#result + 1] = tostring(values:get(valueIndex))
    end
    return result
end

local function splitSemicolonList(value)
    local result = {}
    value = tostring(value or "")
    for entry in string.gmatch(value .. ";", "([^;]*);") do
        local trimmed = string.gsub(entry, "^%s*(.-)%s*$", "%1")
        if trimmed ~= "" then result[#result + 1] = trimmed end
    end
    return result
end

local function tagsFromInput(input)
    local line = tostring(input:getOriginalLine() or "")
    local tagBlock = string.match(line, "tags%s*%[([^%]]*)%]")
    return splitSemicolonList(tagBlock)
end

local function flagsFromInput(input)
    local result = {}
    if not InputFlag then return result end
    for flagIndex = 1, #INPUT_FLAGS do
        local name = INPUT_FLAGS[flagIndex]
        local flag = InputFlag[name]
        if flag and input:hasFlag(flag) then result[#result + 1] = name end
    end
    return result
end

local function explicitItemsFromInput(input)
    local result = {}
    local values = input:getItems()
    local manager = getScriptManager and getScriptManager() or nil
    for valueIndex = 0, values:size() - 1 do
        local value = tostring(values:get(valueIndex))
        local scriptItem = manager and manager:getItem(value) or nil
        result[#result + 1] = scriptItem and tostring(scriptItem:getFullName()) or value
    end
    return result
end

local function inputUsesUnits(input)
    local resourceType = tostring(input:getResourceType())
    if resourceType ~= "Item" then return true end
    if input:isItemCount() then return false end
    local items = input:getPossibleInputItems()
    for itemIndex = 0, items:size() - 1 do
        local item = items:get(itemIndex)
        if item and ItemType and item:isItemType(ItemType.DRAINABLE) then return true end
    end
    return false
end

local function requirementFromInput(input, inputIndex)
    local resourceType = tostring(input:getResourceType())
    local keep = input:isKeep()
    local usesUnits = inputUsesUnits(input)
    local mode = "consume"
    if input:isDestroy() then
        mode = "destroy"
    elseif keep then
        mode = "keep"
    elseif usesUnits then
        mode = "drain"
    end
    local row = {
        id = "input_" .. tostring(inputIndex),
        role = (keep or input:isTool()) and "tool" or (usesUnits and "consumable" or "material"),
        mode = mode,
        resourceType = resourceType,
        items = explicitItemsFromInput(input),
        tags = tagsFromInput(input),
        flags = flagsFromInput(input)
    }
    local amount = input:getAmount()
    if usesUnits then
        row.uses = amount
    else
        row.amount = input:getIntAmount()
    end
    if input:isVariableAmount() then row.amountMax = input:getMaxAmount() end
    return row
end

local function requirementsFromRecipe(recipe)
    if not recipe then return nil end
    local result = { inputs = {}, skills = {} }
    local inputs = recipe:getInputs()
    for inputIndex = 0, inputs:size() - 1 do
        result.inputs[#result.inputs + 1] = requirementFromInput(inputs:get(inputIndex), inputIndex + 1)
    end
    for skillIndex = 0, recipe:getRequiredSkillCount() - 1 do
        local required = recipe:getRequiredSkill(skillIndex)
        local perk = required and required:getPerk() or nil
        if perk then result.skills[tostring(perk:getId())] = required:getLevel() end
    end
    if recipe:needToBeLearn() then
        result.knowledge = {
            needToBeLearned = true,
            recipes = { tostring(recipe:getName()) }
        }
    end
    if #result.inputs == 0 then result.inputs = nil end
    local hasSkills = false
    for _ in pairs(result.skills) do
        hasSkills = true
        break
    end
    if not hasSkills then result.skills = nil end
    if not result.inputs and not result.skills and not result.knowledge then return nil end
    return result
end

local function tokenFromTile(tile)
    if not tile then return false end
    if tile:isEmptySpace() then return tile:isBlocksSquare() end
    return tostring(tile:getTileName())
end

local function faceGeometry(face)
    local layers = {}
    for layerIndex = 0, face:getZLayers() - 1 do
        local layer = face:getLayer(layerIndex)
        local rows = {}
        for rowIndex = 0, layer:getHeight() - 1 do
            local sourceRow = layer:getRow(rowIndex)
            local row = {}
            for columnIndex = 0, sourceRow:getWidth() - 1 do
                row[#row + 1] = tokenFromTile(sourceRow:getTile(columnIndex))
            end
            rows[#rows + 1] = row
        end
        layers[#layers + 1] = { rows = rows }
    end
    return { layers = layers }
end

local function firstFaceSprite(face)
    if not face then return nil end
    for layerIndex = 0, face:getZLayers() - 1 do
        local layer = face:getLayer(layerIndex)
        for rowIndex = 0, layer:getHeight() - 1 do
            local row = layer:getRow(rowIndex)
            for columnIndex = 0, row:getWidth() - 1 do
                local tile = row:getTile(columnIndex)
                if tile and not tile:isEmptySpace() then return tostring(tile:getTileName()) end
            end
        end
    end
end

local function geometryFromSpriteConfig(component)
    if not component then return nil, nil end
    local geometry = { faces = {} }
    local sprites = {}
    for faceIndex = 1, #FACE_SCRIPTS do
        local descriptor = FACE_SCRIPTS[faceIndex]
        local face = component:getFace(descriptor.id)
        if face then
            local faceName = tostring(face:getFaceName())
            local sprite = firstFaceSprite(face)
            if faceName == "single" then
                local cardinal = { "N", "E", "S", "W" }
                for directionIndex = 1, #cardinal do
                    local direction = cardinal[directionIndex]
                    geometry.faces[direction] = faceGeometry(face)
                    if sprite then sprites[direction] = sprite end
                end
            elseif descriptor.id < 4 then
                geometry.faces[descriptor.name] = faceGeometry(face)
                if sprite then sprites[descriptor.name] = sprite end
            elseif sprite then
                sprites[descriptor.name] = sprite
            end
        end
    end
    local hasGeometry = false
    for _ in pairs(geometry.faces) do
        hasGeometry = true
        break
    end
    if not hasGeometry then geometry = nil end
    return geometry, sprites
end

---@param stage KBW.BuildStage
---@return string|nil
function EntityCompat.scriptName(stage)
    local reference = referenceFor(stage)
    local entity = tostring(reference.entity or "")
    if entity == "" then return nil end
    if string.find(entity, ".", 1, true) then return entity end
    local module = tostring(reference.module or "Base")
    if module == "" then module = "Base" end
    return module .. "." .. entity
end

---@param stage KBW.BuildStage
---@return GameEntityScript|nil, string|nil
function EntityCompat.resolveScript(stage)
    local name = EntityCompat.scriptName(stage)
    if not name or not getScriptManager then return nil, name end
    return getScriptManager():getGameEntityScript(name), name
end

---@param stage KBW.BuildStage
---@param componentType ComponentType
---@return ComponentScript|nil
function EntityCompat.component(stage, componentType)
    local script = EntityCompat.resolveScript(stage)
    if not script or not componentType then return nil end
    return script:getComponentScriptFor(componentType)
end

---@param stage KBW.BuildStage
---@return CraftRecipe|nil
function EntityCompat.craftRecipeObject(stage)
    local component = EntityCompat.component(stage, ComponentType.CraftRecipe)
    return component and component:getCraftRecipe() or nil
end

local function spriteMetadata(script)
    local component = script:getComponentScriptFor(ComponentType.SpriteConfig)
    if not component then return nil end
    local previousStages = copyJavaStrings(component:getPreviousStages())
    local geometry, sprites = geometryFromSpriteConfig(component)
    local result = {
        isThumpable = component:getIsThumpable(),
        dontNeedFrame = component:getDontNeedFrame(),
        needWindowFrame = component:getNeedWindowFrame(),
        needToBeAgainstWall = component:getNeedToBeAgainstWall(),
        isPole = component:isPole(),
        isProp = component:isProp(),
        canBePadlocked = component:getCanBePadlocked(),
        skillBaseHealth = component:getSkillBaseHealth(),
        bonusHealth = component:getBonusHealth(),
        breakSound = component:getBreakSound(),
        corner = component:getCornerSprite(),
        onCreate = component:getOnCreate(),
        onIsValid = component:getOnIsValid(),
        timedActionOnIsValid = component:getTimedActionOnIsValid(),
        geometry = geometry,
        sprites = sprites
    }
    local health = component:getHealth()
    if health and health >= 0 then result.health = health end
    if #previousStages > 0 then result.previousStage = previousStages end
    local lightRadius = component:getLightRadius()
    if lightRadius and lightRadius > 0 then
        result.lightRadius = lightRadius
        result.lightsourceItem = component:getLightsourceItem()
        result.lightsourceFuel = component:getLightsourceFuel()
        result.debugItem = component:getDebugItem()
        result.lightsourceTags = copyJavaStrings(component:getLightsourceTagItem())
        result.lightOffsets = {}
        local faces = { { "N", 0 }, { "W", 1 }, { "S", 2 }, { "E", 3 } }
        for faceIndex = 1, #faces do
            local face = component:getFace(faces[faceIndex][2])
            if face then
                result.lightOffsets[faces[faceIndex][1]] = {
                    x = face:getLightsourceOffsetX(),
                    y = face:getLightsourceOffsetY(),
                    z = face:getLightsourceOffsetZ()
                }
            end
        end
    end
    return result
end

local function recipeMetadata(script)
    local component = script:getComponentScriptFor(ComponentType.CraftRecipe)
    local recipe = component and component:getCraftRecipe() or nil
    if not recipe then return nil end
    local result = {
        time = recipe:getTime(),
        category = recipe:getCategory(),
        tooltip = recipe:getTooltip(),
        needToBeLearn = recipe:needToBeLearn(),
        canWalk = recipe:isCanWalk(),
        onAddToMenu = recipe:getOnAddToMenu(),
        icon = recipe:getIconName(),
        tags = copyJavaStrings(recipe:getModTags()),
        requirements = requirementsFromRecipe(recipe)
    }
    local timedAction = recipe:getTimedActionScript()
    if timedAction then result.timedAction = timedAction:getName() end
    -- CraftRecipe:getXPAward() returns CraftRecipe$xp_Award, a private nested
    -- Java type that is not exposed as indexable userdata in Kahlua. Native
    -- BuildLogic awards entity-recipe XP during performCurrentRecipe(); Knox
    -- therefore must not mirror or award it a second time.
    return result
end

local function wallCoveringMetadata(script)
    local component = script:getComponentScriptFor(ComponentType.WallCoveringConfig)
    if not component then return nil end
    local action = component:getTypeString()
    local result = { type = action, name = component:getName() }
    if action == "paintSign" then result.sign = component:getSignIndex() end
    return result
end

local function buildMetadata(script, scriptName)
    return {
        module = tostring(script:getModuleName() or "Base"),
        entity = tostring(script:getName()),
        scriptName = scriptName,
        spriteConfig = spriteMetadata(script),
        craftRecipe = recipeMetadata(script),
        wallCoveringConfig = wallCoveringMetadata(script)
    }
end

---Returns a runtime-only metadata view derived from the entity
---script. It is never serialized into the definition registry or its hash.
---@param stage KBW.BuildStage
---@return KBW.EntityMetadata
function EntityCompat.metadata(stage)
    local script, scriptName = EntityCompat.resolveScript(stage)
    local reference = referenceFor(stage)
    if not script then
        if scriptName and not missingLogged[scriptName] then
            missingLogged[scriptName] = true
            Log:error("Entity script not found: %s", tostring(scriptName))
        end
        return { module = reference.module or "Base", entity = reference.entity, scriptName = scriptName }
    end
    local cached = metadataCache[scriptName]
    if not cached then
        cached = buildMetadata(script, scriptName)
        metadataCache[scriptName] = cached
    end
    return cached
end

EntityCompat.config = EntityCompat.metadata

local function copyMissing(target, source)
    target = target or {}
    for key, value in pairs(source or {}) do
        if target[key] == nil then target[key] = value end
    end
    return target
end

---Populates omitted Knox stage fields from the referenced entity script.
---Explicit JSON values win, so add-ons can override only the Knox-facing
---parts that differ from their native SpriteConfig or CraftRecipe.
---@param stage KBW.BuildStage
---@return KBW.BuildStage
function EntityCompat.hydrateStage(stage)
    if not stage or not stage.entityCompat then return stage end
    if stage._kbwNativeRecipeInputs == nil then
        stage._kbwNativeRecipeInputs = stage.requirements == nil or stage.requirements.inputs == nil
    end
    local metadata = EntityCompat.metadata(stage)
    local spriteConfig = metadata.spriteConfig
    if spriteConfig then
        if stage.geometry == nil then stage.geometry = TableUtil.copy(spriteConfig.geometry) end
        stage.sprites = copyMissing(stage.sprites, spriteConfig.sprites)
        if stage.health == nil then stage.health = spriteConfig.health end
        if stage.skillBaseHealth == nil then stage.skillBaseHealth = spriteConfig.skillBaseHealth end
    end
    local nativeRequirements = metadata.craftRecipe and metadata.craftRecipe.requirements or nil
    if nativeRequirements then
        stage.requirements = stage.requirements or {}
        if stage.requirements.inputs == nil then
            stage.requirements.inputs = TableUtil.copy(nativeRequirements.inputs)
        end
        if stage.requirements.skills == nil then
            stage.requirements.skills = TableUtil.copy(nativeRequirements.skills)
        end
        if stage.requirements.knowledge == nil then
            stage.requirements.knowledge = TableUtil.copy(nativeRequirements.knowledge)
        end
    end
    return stage
end

---True when the stage did not override the referenced entity recipe's inputs.
---Those stages can use BuildLogic for native selection, consumption and
---CraftRecipeData instead of reproducing the recipe lifecycle in Lua.
---@param stage KBW.BuildStage
---@return boolean
function EntityCompat.usesNativeRecipeInputs(stage)
    return stage ~= nil and stage._kbwNativeRecipeInputs == true and EntityCompat.craftRecipeObject(stage) ~= nil
end

function EntityCompat.clearCache()
    metadataCache = {}
    missingLogged = {}
end

local function verifyScriptComponents(object, script, scriptName)
    local spriteConfig = object:getComponent(ComponentType.SpriteConfig)
    local isMaster = spriteConfig == nil or not spriteConfig:isValidMultiSquare()
        or spriteConfig:isMultiSquareMaster()
    local componentScripts = script:getComponentScripts()
    local valid = true
    for componentIndex = 0, componentScripts:size() - 1 do
        local componentScript = componentScripts:get(componentIndex)
        if (isMaster or not componentScript:isoMasterOnly())
            and not object:hasComponent(componentScript.type) then
            valid = false
            Log:error(
                "Entity script %s did not create native %s component",
                tostring(scriptName), tostring(componentScript.type)
            )
        end
    end
    return valid
end

---Instances every native component declared by the referenced entity. The
---engine handles resources, crafting logic, sounds, overlays and multi-tile
---master-only behavior; Knox does not reproduce those systems in Lua.
---@param object IsoObject
---@param stage KBW.BuildStage
---@param isFirstTimeCreated boolean|nil
---@return boolean, string|nil
function EntityCompat.attach(object, stage, isFirstTimeCreated)
    if not object then return false, "missing object" end
    local script, scriptName = EntityCompat.resolveScript(stage)
    if not script then
        if scriptName then Log:error("Entity script not found: %s", tostring(scriptName)) end
        return false, "entity script not found"
    end
    if object:hasComponents() then
        local current = object:getEntityScript()
        if current == script then return verifyScriptComponents(object, script, scriptName) end
        Log:warning(
            "Skipped entity script %s because the object already has components from another script",
            tostring(scriptName)
        )
        return false, "object already has components"
    end
    GameEntityFactory.CreateIsoObjectEntity(object, script, isFirstTimeCreated == true)
    if object:getEntityScript() ~= script then
        Log:error("Failed to instance entity script %s", tostring(scriptName))
        return false, "entity factory failed"
    end
    return verifyScriptComponents(object, script, scriptName)
end

return EntityCompat
