---Schema provides the Knox Buildworks data-driven definition layer.
local KBW = require("KnoxBuildworks/Core")
local TableUtil = require("KnoxBuildworks/Util/Table")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local Properties = require("KnoxBuildworks/Definitions/Properties")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local LuaCallback = require("KnoxBuildworks/Util/LuaCallback")

---@class KBW.SchemaModule
---@type KBW.SchemaModule
local Schema = {}
local DIRECTIONS = { W = true, N = true, E = true, S = true }
local ENTITY_REFERENCE_FIELDS = { module = true, entity = true }
local PLACEMENT_KINDS = { object = true, wall = true, floor = true, stairs = true, overlay = true,
    wallCovering = true }

local function add(errors, value)
    errors[#errors + 1] = value
end

local function validateRequirementRows(errors, stageId, rows, label)
    rows = rows or {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) ~= "table" then
            add(errors, "stage " .. stageId .. " has an invalid " .. label)
        else
            local resourceType = row.resourceType or "Item"
            local items = row.items or {}
            local tags = row.tags or {}
            if resourceType == "Item" and #items == 0 and #tags == 0 then
                add(errors, "stage " .. stageId .. " has a " .. label .. " without item or tag alternatives")
            end
            for j = 1, #items do
                local fullType = items[j]
                if ScriptManager and not ScriptManager.instance:FindItem(fullType) then
                    add(errors, "stage " .. stageId .. " references missing item " .. tostring(fullType))
                end
            end
        end
    end
end

local function normalizeRequirements(errors, stage, materialGroups, definitionTools)
    stage.requirements = stage.requirements or {}
    stage.requirements.knowledge = stage.requirements.knowledge or {}
    stage.requirements.inputs = stage.requirements.inputs or {}
    if type(stage.requirements.materials) == "string" then
        local group = materialGroups[stage.requirements.materials]
        if not group then
            add(errors, "stage " .. stage.id .. " references unknown material group")
        else
            stage.requirements.materials = TableUtil.copy(group)
        end
    end
    validateRequirementRows(errors, stage.id, stage.requirements.inputs, "requirement input")
    validateRequirementRows(errors, stage.id, stage.requirements.materials, "material")
    validateRequirementRows(errors, stage.id, stage.requirements.tools, "tool")
    validateRequirementRows(errors, stage.id, definitionTools, "definition tool")
    for perkName in pairs(stage.requirements.skills or {}) do
        if not Perks[perkName] then
            add(errors, "stage " .. stage.id .. " references missing skill " .. perkName)
        end
    end
end

local function validateEntityReference(errors, stage)
    local reference = stage and stage.entityCompat
    if reference == nil then return end
    local stageId = tostring(stage.id or "<unknown>")
    if type(reference) ~= "table" then
        add(errors, "stage " .. stageId .. " entityCompat must be an object")
        return
    end
    for field in pairs(reference) do
        if not ENTITY_REFERENCE_FIELDS[field] then
            add(errors, "stage " .. stageId .. " entityCompat only accepts module and entity; remove " .. tostring(field))
        end
    end
    if type(reference.entity) ~= "string" or reference.entity == "" then
        add(errors, "stage " .. stageId .. " entityCompat.entity is required")
        return
    end
    if reference.module ~= nil and (type(reference.module) ~= "string" or reference.module == "") then
        add(errors, "stage " .. stageId .. " entityCompat.module must be a non-empty string")
    end
    local script, scriptName = EntityCompat.resolveScript(stage)
    if not script then
        add(errors, "stage " .. stageId .. " references missing entity script " .. tostring(scriptName))
    end
end

local function validatePlacementConfiguration(errors, owner, placement)
    if placement == nil then return end
    if type(placement) ~= "table" then
        add(errors, owner .. " placement must be an object")
        return
    end
    if placement.kind ~= nil and not PLACEMENT_KINDS[placement.kind] then
        add(errors, owner .. " has invalid placement kind " .. tostring(placement.kind))
    end
    if placement.maxDistance ~= nil
        and (type(placement.maxDistance) ~= "number" or placement.maxDistance <= 0) then
        add(errors, owner .. " placement.maxDistance must be greater than zero")
    end
end

local function validateConstructionConfiguration(errors, owner, construction)
    if construction == nil then return end
    if type(construction) ~= "table" then
        add(errors, owner .. " construction must be an object")
        return
    end
    if construction.time ~= nil and (type(construction.time) ~= "number" or construction.time < 0) then
        add(errors, owner .. " construction.time must be zero or greater")
    end
    if construction.timedAction ~= nil then
        if type(construction.timedAction) ~= "string" or construction.timedAction == "" then
            add(errors, owner .. " construction.timedAction must be a non-empty string")
        elseif getScriptManager and not getScriptManager():getTimedActionScript(construction.timedAction) then
            add(errors, owner .. " references missing timed action " .. construction.timedAction)
        end
    end
    if construction.animVariable ~= nil and (type(construction.animVariable) ~= "table"
        or type(construction.animVariable.key) ~= "string" or type(construction.animVariable.value) ~= "string") then
        add(errors, owner .. " construction.animVariable requires string key and value")
    end
end

local function validateStageConfiguration(errors, stage)
    local owner = "stage " .. tostring(stage.id or "<unknown>")
    validatePlacementConfiguration(errors, owner, stage.placement)
    validateConstructionConfiguration(errors, owner, stage.construction)
    if stage.object ~= nil and type(stage.object) ~= "table" then
        add(errors, owner .. " object must be an object")
    end
    if stage.callbacks ~= nil then
        if type(stage.callbacks) ~= "table" then
            add(errors, owner .. " callbacks must be an object")
        else
            local callbackNames = { "onAddToMenu", "onCreate", "onIsValid", "timedActionOnIsValid" }
            for callbackIndex = 1, #callbackNames do
                local name = callbackNames[callbackIndex]
                local value = stage.callbacks[name]
                if value ~= nil and not LuaCallback.isValidName(value) then
                    add(errors, owner .. " callbacks." .. name .. " must be a namespaced Lua function path")
                end
            end
        end
    end
    if stage.lightSource ~= nil then
        local light = stage.lightSource
        if type(light) ~= "table" then
            add(errors, owner .. " lightSource must be an object")
        elseif type(light.radius) ~= "number" or light.radius < 1 then
            add(errors, owner .. " lightSource.radius must be at least one")
        elseif light.item == nil and type(light.tags) ~= "table" and light.debugItem == nil then
            add(errors, owner .. " lightSource requires item, tags or debugItem")
        end
    end
end

local function validateCallbackCompatibility(errors, stage)
    local onCreate = stage.callbacks and stage.callbacks.onCreate
    if LuaCallback.requiresNativeRecipe(onCreate) and not EntityCompat.usesNativeRecipeInputs(stage) then
        add(errors, "stage " .. stage.id .. " callback " .. onCreate
            .. " requires an entity-backed native CraftRecipe")
    end
end

---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
function Schema.expandSprites(definition, stage)
    if stage.sprites then return end
    local directional = stage.directionalSprites or definition.directionalSprites
    if directional then
        stage.sprites = TableUtil.copy(directional)
        return
    end
    local pattern = stage.spritePattern or definition.spritePattern
    if not pattern then return end
    stage.sprites = {}
    local prefix, suffix = pattern.prefix or definition.spritePrefix or "",
        pattern.suffix or definition.spriteSuffix or ""
    for direction, token in pairs(pattern.directions or {}) do
        stage.sprites[direction] = prefix .. tostring(token) .. suffix
    end
    if pattern.start then
        local rotations = stage.rotations or definition.rotations or { "W", "N", "E", "S" }
        for index = 1, #rotations do
            local direction = rotations[index]
            stage.sprites[direction] = prefix .. tostring(pattern.start + (index - 1) * (pattern.step or 1)) .. suffix
        end
    end
end

---@param bundle KBW.DefinitionBundle
function Schema.validateBundle(bundle)
    local errors = {}
    if type(bundle) ~= "table" then
        add(errors, "root must be an object")
        return errors
    end
    if bundle.schemaVersion ~= KBW.SCHEMA_VERSION then
        add(errors, "unsupported schemaVersion " .. tostring(bundle.schemaVersion))
    end
    if type(bundle.buildables) ~= "table" then add(errors, "buildables must be an array") end
    return errors
end

---@param definition KBW.BuildableDefinition
---@param templates table<string, table>
---@param materialGroups table<string, table>
function Schema.normalize(definition, templates, materialGroups)
    local errors = {}
    local resolved = definition
    if definition.extends then
        local function resolveTemplate(name, seen)
            seen = seen or {}
            if seen[name] then
                add(errors, "template inheritance cycle at " .. name)
                return nil
            end
            local value = templates[name]
            if not value then return nil end
            if not value.extends then return value end
            seen[name] = true
            local parent = resolveTemplate(value.extends, seen)
            seen[name] = nil
            return parent and TableUtil.merge(parent, value) or value
        end
        local template = resolveTemplate(definition.extends)
        if not template then
            add(errors, "unknown template " .. tostring(definition.extends))
        else
            resolved = TableUtil.merge(template, definition)
        end
    else
        resolved = TableUtil.copy(definition)
    end
    if type(resolved.id) ~= "string" or not string.match(resolved.id, "^[%w_.%-]+$") then
        add(errors, "invalid or missing id")
    end
    if type(resolved.category) ~= "string" then add(errors, "category is required") end
    if type(resolved.stages) ~= "table" or #resolved.stages == 0 then
        add(errors, "at least one stage is required")
    end
    -- getText routes keys strictly by prefix (IGUI_ -> IG_UI.json, Tooltip_ ->
    -- Tooltip.json in Translate/<LANG>/); keys without a routed prefix can
    -- never resolve, so defaults and explicit keys must carry one.
    resolved.translationKey = resolved.translationKey
        or ("IGUI_KBW_Buildable_" .. string.gsub(resolved.id or "Invalid", "[^%w]", "_"))
    resolved.tooltipKey = resolved.tooltipKey
        or ("Tooltip_KBW_Buildable_" .. string.gsub(resolved.id or "Invalid", "[^%w]", "_"))
    if resolved.materialRequired ~= nil and type(resolved.materialRequired) ~= "boolean" then
        add(errors, "materialRequired must be a boolean")
    end
    if resolved.materialRequired == true and #(resolved.materialOptions or {}) == 0 then
        add(errors, "materialRequired needs at least one materialOptions entry")
    end
    resolved.aliases = resolved.aliases or {}
    resolved.tags = resolved.tags or {}
    resolved.subcategory = resolved.subcategory or "General"
    resolved.materialTags = resolved.materialTags or (resolved.material and { resolved.material } or {})
    resolved.styleTags = resolved.styleTags or {}
    validatePlacementConfiguration(errors, "buildable " .. tostring(resolved.id), resolved.placement)
    validateConstructionConfiguration(errors, "buildable " .. tostring(resolved.id), resolved.construction)
    local stages = resolved.stages or {}
    for index = 1, #stages do
        local stage = stages[index]
        stage.id = stage.id or tostring(index)
        stage.level = stage.level or index
        validateStageConfiguration(errors, stage)
        validateEntityReference(errors, stage)
        EntityCompat.hydrateStage(stage)
        validateCallbackCompatibility(errors, stage)
        Schema.expandSprites(resolved, stage)
        Matrix.normalizeStage(stage)
        if type(stage.sprites) ~= "table" then
            add(errors, "stage " .. stage.id .. " has no sprites")
        else
            for direction, sprite in pairs(stage.sprites) do
                -- "W_open"/"N_open" keys carry door/gate open-state sprites.
                local baseDirection = string.match(tostring(direction), "^([WNES])_open$") or direction
                if not DIRECTIONS[baseDirection] then
                    add(errors, "stage " .. stage.id .. " has invalid direction " .. tostring(direction))
                end
                if type(sprite) ~= "string" or sprite == "" then
                    add(errors, "stage " .. stage.id .. " has invalid sprite")
                end
            end
        end
        for direction, tiles in pairs(stage.footprints or {}) do
            if not DIRECTIONS[direction] or type(tiles) ~= "table" then
                add(errors, "stage " .. stage.id .. " has invalid footprint")
            else
                for i = 1, #tiles do
                    local tile = tiles[i]
                    if (tile.sprite ~= nil and type(tile.sprite) ~= "string") or type(tile.dx) ~= "number"
                        or type(tile.dy) ~= "number" or type(tile.dz or 0) ~= "number" then
                        add(errors, "stage " .. stage.id .. " has invalid footprint tile")
                    end
                end
            end
        end
        normalizeRequirements(errors, stage, materialGroups, resolved.tools)
        Properties.normalizeStage(stage, resolved, errors)
    end
    -- Variants and material options may replace the complete stage list. Normalize
    -- those matrices now as well so every consumer sees the same canonical cells.
    local optionSets = { resolved.variants or {}, resolved.materialOptions or {} }
    for setIndex = 1, #optionSets do
        local options = optionSets[setIndex]
        for optionIndex = 1, #options do
            local option = options[optionIndex]
            local optionStages = option.stages or {}
            for stageIndex = 1, #optionStages do
                local stage = optionStages[stageIndex]
                stage.id = stage.id or tostring(stageIndex)
                stage.level = stage.level or stageIndex
                validateStageConfiguration(errors, stage)
                validateEntityReference(errors, stage)
                EntityCompat.hydrateStage(stage)
                validateCallbackCompatibility(errors, stage)
                Schema.expandSprites(TableUtil.merge(resolved, option), stage)
                Matrix.normalizeStage(stage)
                normalizeRequirements(errors, stage, materialGroups, resolved.tools)
                Properties.normalizeStage(stage, resolved, errors)
            end
        end
    end
    return resolved, errors
end

return Schema
