---Keeps catalogue visibility consistent with Build 42's OnAddToMenu contract.
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local LuaCallback = require("KnoxBuildworks/Util/LuaCallback")
local BuildableRules = require("KnoxBuildworks/Admin/BuildableRules")

---@class KBW.CatalogVisibilityModule
---@type KBW.CatalogVisibilityModule
local CatalogVisibility = {}
local Requirements = require("KnoxBuildworks/Validation/Requirements")

local function uiData(player)
    local root = player:getModData()
    root.KBW_UI = root.KBW_UI or { favorites = {}, recent = {}, compact = false }
    return root.KBW_UI
end

---@param player IsoPlayer
---@return boolean
function CatalogVisibility.shouldShowAll(player)
    return player ~= nil and uiData(player).showAllVersions == true
end

---@param player IsoPlayer
---@param enabled boolean
function CatalogVisibility.setShowAll(player, enabled)
    if player then uiData(player).showAllVersions = enabled == true end
end

-- Recipes taught by a magazine (hideUntilLearned) stay listed, locked, with
-- the magazine or skill that unlocks them: hidden, most Vanilla Expanded
-- pieces never appeared at all and players could not tell what to look for.
-- The requirement itself is unchanged. The "Show unlearned recipes" option
-- turns the old hiding back on.
CatalogVisibility.showUnlearned = true

---@param enabled boolean
function CatalogVisibility.setShowUnlearned(enabled)
    CatalogVisibility.showUnlearned = enabled ~= false
end

---True when the stage is hidden because its knowledge is not learned yet.
---@param player IsoPlayer
---@param stage KBW.BuildStage
---@param shouldShowAll boolean
---@return boolean
function CatalogVisibility.hiddenUntilLearned(player, stage, shouldShowAll)
    local knowledge = (stage.requirements or {}).knowledge or {}
    if not knowledge.hideUntilLearned or shouldShowAll or CatalogVisibility.showUnlearned then return false end
    return not Requirements.meetsKnowledge(player, stage)
end

---@param player IsoPlayer
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param shouldShowAll boolean|nil
---@return boolean
function CatalogVisibility.stagePasses(player, definition, stage, shouldShowAll)
    if not stage then return false end
    stage = BuildableRules.effectiveStage(definition, stage)
    if not stage then return false end
    if shouldShowAll == nil then shouldShowAll = CatalogVisibility.shouldShowAll(player) end
    if CatalogVisibility.hiddenUntilLearned(player, stage, shouldShowAll) then return false end
    local recipe = StageConfig.recipe(definition, stage)
    if not recipe.onAddToMenu then return true end
    if shouldShowAll == nil then shouldShowAll = CatalogVisibility.shouldShowAll(player) end
    return LuaCallback.callBool(recipe.onAddToMenu, {
        player = player,
        recipe = EntityCompat.craftRecipeObject(stage),
        definition = definition,
        stage = stage,
        shouldShowAll = shouldShowAll == true
    }, true)
end

---@param player IsoPlayer
---@param definition KBW.BuildableDefinition
---@param shouldShowAll boolean|nil
---@return boolean
function CatalogVisibility.definitionPasses(player, definition, shouldShowAll)
    if not BuildableRules.isEnabled(definition) then return false end
    local stages = definition and definition.stages or {}
    for stageIndex = 1, #stages do
        if CatalogVisibility.stagePasses(player, definition, stages[stageIndex], shouldShowAll) then return true end
    end
    return #stages == 0
end

---@param player IsoPlayer
---@param definition KBW.BuildableDefinition
---@param shouldShowAll boolean|nil
---@return KBW.BuildStage[]
function CatalogVisibility.filteredStages(player, definition, shouldShowAll)
    local result = {}
    local stages = definition and definition.stages or {}
    for stageIndex = 1, #stages do
        local stage = stages[stageIndex]
        if CatalogVisibility.stagePasses(player, definition, stage, shouldShowAll) then
            result[#result + 1] = BuildableRules.effectiveStage(definition, stage)
        end
    end
    return result
end

function CatalogVisibility.definitionEnabled(definition)
    return BuildableRules.isEnabled(definition)
end

return CatalogVisibility
