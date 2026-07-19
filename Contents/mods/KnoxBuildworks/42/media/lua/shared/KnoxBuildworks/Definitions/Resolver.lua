---Resolver provides the Knox Buildworks data-driven definition layer.
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Requirements = require("KnoxBuildworks/Validation/Requirements")
local TableUtil = require("KnoxBuildworks/Util/Table")

-- Single source of truth for turning (buildableId, variantId, materialId) into a
-- merged definition. KBWBuildingObject, Blueprints, Planner and Server all resolve
-- through here so client previews, plan ghosts and server validation cannot drift.
---@class KBW.ResolverModule
---@type KBW.ResolverModule
local Resolver = {}

local function findOption(options, optionId)
    options = options or {}
    for optionIndex = 1, #options do
        local option = options[optionIndex]
        if option.id == optionId then return option end
    end
    return nil
end

-- Returns merged definition or nil + reason. variantId/materialId may be nil or "".
---@param buildableId string
---@param variantId string|nil
---@param materialId string|nil
---@param buildableId string
---@param variantId string|nil
---@param materialId string|nil
---@return KBW.BuildableDefinition|nil definition
---@return string|nil reason
function Resolver.resolve(buildableId, variantId, materialId)
    local base = Registry:get(buildableId)
    if not base then return nil, "unknown buildable" end
    if base.materialRequired == true and (materialId == nil or materialId == "") then
        return nil, "material selection required"
    end
    local definition = base
    if variantId and variantId ~= "" then
        local variant = findOption(base.variants, variantId)
        if not variant then return nil, "unknown variant" end
        definition = TableUtil.merge(definition, variant)
    end
    if materialId and materialId ~= "" then
        local material = findOption(base.materialOptions, materialId)
        if not material then return nil, "unknown material" end
        definition = TableUtil.merge(definition, material)
    end
    if definition == base then definition = TableUtil.copy(base) end
    definition.id = buildableId
    return definition
end

-- Convenience: resolve definition and stage in one call.
---@param buildableId string
---@param variantId string|nil
---@param materialId string|nil
---@param stageId string|nil
---@param buildableId string
---@param variantId string|nil
---@param materialId string|nil
---@param stageId string|nil
---@return KBW.BuildableDefinition|nil definition
---@return KBW.BuildStage|nil stage
---@return string|nil reason
function Resolver.resolveStage(buildableId, variantId, materialId, stageId)
    local definition, reason = Resolver.resolve(buildableId, variantId, materialId)
    if not definition then return nil, nil, reason end
    local stage = Registry:getStage(definition, stageId)
    if not stage then return definition, nil, "unknown stage" end
    return definition, stage
end

-- Validates manual ingredient selections against what each input actually accepts.
-- choices is a map of input.id -> fullType. Unknown input ids or item types that are
-- not in the input's accepted set are rejected (server must never trust them).
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param choices table<string, string>|nil
---@return boolean valid
---@return string|nil reason
function Resolver.validateChoices(definition, stage, choices)
    if choices == nil then return true end
    if type(choices) ~= "table" then return false, "invalid ingredient choices" end
    local inputs = Requirements.getInputs(definition, stage)
    local byId = {}
    for inputIndex = 1, #inputs do
        local input = inputs[inputIndex]
        byId[input.id] = input
    end
    for inputId, fullType in pairs(choices) do
        local input = byId[inputId]
        if not input then return false, "unknown input id " .. tostring(inputId) end
        if type(fullType) ~= "string" then return false, "invalid choice for " .. tostring(inputId) end
        local accepted = Requirements.possibleItems(input)
        if not TableUtil.contains(accepted, fullType) then
            return false, "item " .. fullType .. " not accepted by " .. tostring(inputId)
        end
    end
    return true
end

return Resolver
