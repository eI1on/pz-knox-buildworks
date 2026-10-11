--- Definitions suite: per-buildable checks only the running engine can make.
if not isDebugEnabled() then return end

local Harness = require("KnoxBuildworks/Debug/TestHarness")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Resolver = require("KnoxBuildworks/Definitions/Resolver")
local Requirements = require("KnoxBuildworks/Validation/Requirements")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local Durability = require("KnoxBuildworks/Definitions/Durability")
local IconResolver = require("KnoxBuildworks/UI/IconResolver")
local I18n = require("KnoxBuildworks/I18n")

local FACES = { "W", "N", "E", "S" }
local KINDS = { object = true, wall = true, floor = true, overlay = true, stairs = true, wallCovering = true }

local function optionIds(options, required)
    local ids = {}
    if required ~= true then ids[1] = "" end
    options = options or {}
    for index = 1, #options do
        ids[#ids + 1] = tostring(options[index].id)
    end
    return ids
end

local function checkStage(t, label, definition, stage)
    local placement = StageConfig.placement(definition, stage)
    t:check(KINDS[placement.kind or ""] == true, label .. ": unknown placement kind " .. tostring(placement.kind))
    local spriteCount = 0
    for faceIndex = 1, #FACES do
        local cells = Matrix.getFaceCells(stage, FACES[faceIndex]) or {}
        for cellIndex = 1, #cells do
            local sprite = cells[cellIndex].sprite
            if sprite then
                spriteCount = spriteCount + 1
                t:check(
                    getSprite(sprite) ~= nil,
                    label .. ": missing sprite "
                        .. tostring(sprite) .. " (face "
                        .. FACES[faceIndex] .. ")"
                )
            end
        end
    end
    if placement.kind ~= "wallCovering" then
        t:check(spriteCount > 0, label .. ": no face places a sprite")
    end
    if stage.entityCompat then
        local script, scriptName = EntityCompat.resolveScript(stage)
        t:check(script ~= nil, label .. ": entity script " .. tostring(scriptName) .. " not found")
        if script and EntityCompat.usesNativeRecipeInputs(stage) then
            t:check(EntityCompat.craftRecipeObject(stage) ~= nil, label .. ": entity has no CraftRecipe component")
        end
    end
    local inputs = Requirements.getInputs(definition, stage)
    for inputIndex = 1, #inputs do
        local input = inputs[inputIndex]
        local needed = tonumber(input.uses or input.amount) or 1
        if needed > 0 and tostring(input.resourceType or "Item") == "Item" then
            t:check(
                #Requirements.possibleItems(input) > 0,
                label .. ": input " .. tostring(input.id) .. " resolves to no installed item"
            )
            local items = input.items or {}
            for itemIndex = 1, #items do
                t:check(
                    ScriptManager.instance:FindItem(items[itemIndex]) ~= nil,
                    label .. ": input " .. tostring(input.id) .. " names missing item " .. tostring(items[itemIndex])
                )
            end
        end
    end
    for perkName in pairs((stage.requirements or {}).skills or {}) do
        t:check(Perks[perkName] ~= nil, label .. ": unknown skill " .. tostring(perkName))
    end
    -- Vanilla scripts may carry all durability in skillBaseHealth (base 0).
    local base, _, skill = Durability.resolve(definition, stage, StageConfig.sprite(definition, stage))
    t:check(
        type(base) == "number" and type(skill) == "number" and base + skill > 0,
        label .. ": durability resolves to nothing"
    )
    t:check(IconResolver.textureForDefinition(definition, stage) ~= nil, label .. ": no catalogue icon resolves")
end

local function definitionTest(definition)
    return {
        id = "definition:" .. definition.id,
        name = I18n.definitionName(definition),
        group = tostring(definition.category or "Other"),
        run = function (t)
            local label = definition.id
            t:check(
                getTextOrNull(definition.translationKey) ~= nil,
                label .. ": name key " .. tostring(definition.translationKey) .. " has no translation"
            )
            if definition.tooltipKey and definition.tooltipKey ~= "" then
                t:check(
                    getTextOrNull(definition.tooltipKey) ~= nil,
                    label .. ": tooltip key " .. tostring(definition.tooltipKey) .. " has no translation"
                )
            end
            local categoryKey = "IGUI_KBW_Category_" .. I18n.keyPart(definition.category)
            t:check(getTextOrNull(categoryKey) ~= nil, label .. ": missing " .. categoryKey)
            local variants = optionIds(definition.variants, false)
            local materials = optionIds(definition.materialOptions, definition.materialRequired == true)
            local cases = 0
            for variantIndex = 1, #variants do
                for materialIndex = 1, #materials do
                    local variantId, materialId = variants[variantIndex], materials[materialIndex]
                    local resolved, reason = Resolver.resolve(definition.id, variantId, materialId)
                    if not resolved then
                        t:check(false, label .. " v=" .. variantId .. " m=" .. materialId .. ": " .. tostring(reason))
                    else
                        local stages = resolved.stages or {}
                        for stageIndex = 1, #stages do
                            local effective, stage, why = Resolver.resolveStage(
                                definition.id, variantId, materialId, stages[stageIndex].id
                            )
                            local stageLabel = label .. ":"
                                .. tostring(stages[stageIndex].id) .. (variantId ~= "" and (" v=" .. variantId) or "")
                                .. (materialId ~= "" and (" m=" .. materialId) or "")
                            if not stage then
                                if why ~= "buildable disabled by server" then t:check(false, stageLabel .. ": " .. tostring(why)) end
                            else
                                cases = cases + 1
                                checkStage(t, stageLabel, effective, stage)
                            end
                        end
                    end
                end
            end
            t:note(tostring(cases) .. " case(s)")
        end
    }
end

Harness.registerSuite({
    id = "definitions",
    order = 10,
    titleKey = "IGUI_KBW_TestSuite_Definitions",
    descriptionKey = "IGUI_KBW_TestSuite_DefinitionsDesc",
    collect = function (ctx)
        local tests = {}
        local definitions = Registry:list()
        for index = 1, #definitions do
            local definition = definitions[index]
            if ctx.matchesScope(definition.category, definition.subcategory) then
                tests[#tests + 1] = definitionTest(definition)
            end
        end
        return tests
    end
})

return true
