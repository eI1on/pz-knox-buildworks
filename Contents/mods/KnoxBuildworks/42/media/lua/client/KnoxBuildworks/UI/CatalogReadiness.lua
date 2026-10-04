local Requirements = require("KnoxBuildworks/Validation/Requirements")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local Visibility = require("KnoxBuildworks/UI/CatalogVisibility")
local Rules = require("KnoxBuildworks/Admin/BuildableRules")
local TableUtil = require("KnoxBuildworks/Util/Table")
local Readiness = {}

local function environmentKey(owner)
    local square = owner.player:getSquare()
    if not square or not square.getX then return "" end
    return tostring(square:getX()) .. ":" .. tostring(square:getY()) .. ":" .. tostring(square:getZ())
        .. ":" .. tostring(owner.player:isBuildCheat()) .. ":" .. tostring(owner.player:tooDarkToRead())
end

function Readiness.reset(owner)
    owner.readyResults = {}
    owner.readyWork = nil
    owner.readyRevision = Requirements.inventoryRevision()
    owner.readyRules = Rules.revision
    owner.readyEnvironment = environmentKey(owner)
end

function Readiness.filter(owner, definitions)
    if not owner.readyOnly then return definitions end
    if not owner.readyResults then Readiness.reset(owner) end
    owner.readySource = definitions
    local result = {}
    for index = 1, #definitions do
        local definition = definitions[index]
        if owner.readyResults[definition.id] then result[#result + 1] = definition end
    end
    return result
end

local function candidates(owner, group)
    local result = {}
    local stages = Visibility.filteredStages(owner.player, group)
    for stageIndex = 1, #stages do
        local raw = stages[stageIndex]
        local base = Groups.resolveDefinition(group, raw)
        local variants, materials = base.variants or {}, base.materialOptions or {}
        for variantIndex = 0, #variants do
            local variant = variants[variantIndex]
            local varied = variant and TableUtil.merge(base, variant) or base
            for materialIndex = base.materialRequired and 1 or 0, #materials do
                local material = materials[materialIndex]
                local definition = material and TableUtil.merge(varied, material) or varied
                definition.id = base.id
                local stage = raw
                if variant or material then
                    for index = 1, #(definition.stages or {}) do
                        if definition.stages[index].id == Groups.resolveStageId(raw) then stage = definition.stages[index]; break end
                    end
                end
                stage = Rules.effectiveStage(base, stage)
                if stage and Visibility.stagePasses(owner.player, base, stage) then
                    result[#result + 1] = {definition = definition, stage = stage,
                        state = {scope = owner.scope, selectedCategories = owner.selectedCategories,
                            search = owner.search:getInternalText(), selectedId = group.id,
                            buildableId = base.id, stageId = Groups.resolveStageId(raw),
                            variantIndex = variantIndex + 1,
                            materialIndex = materialIndex + (base.materialRequired and 0 or 1)}}
                end
            end
        end
    end
    return result
end

-- Work is bounded per frame, including recipes outside the visible rows.
-- The fast check rejects obvious shortages; the full allocator verifies
-- overlapping ingredients before a recipe is advertised as ready.
function Readiness.update(owner)
    if not owner.readyOnly then return end
    if owner.readyRevision ~= Requirements.inventoryRevision() or owner.readyRules ~= Rules.revision
        or owner.readyEnvironment ~= environmentKey(owner) then
        Readiness.reset(owner)
        owner:refreshGrid()
    end
    local source = owner.readySource or {}
    local dirty, checked = false, 0
    local snapshot
    for index = 1, #source do
        if checked >= 4 then break end
        local group = source[index]
        if owner.readyResults[group.id] == nil then
            local work = owner.readyWork
            if not work or work.id ~= group.id then
                work = {id = group.id, list = candidates(owner, group), cursor = 1}
                owner.readyWork = work
            end
            while work.cursor <= #work.list and checked < 4 do
                local candidate = work.list[work.cursor]
                work.cursor, checked = work.cursor + 1, checked + 1
                snapshot = snapshot or Requirements.snapshot(owner.player, owner.player:getSquare())
                if Requirements.evaluateReadiness(owner.player, candidate.definition, candidate.stage, snapshot).ok
                    and Requirements.evaluate(owner.player, candidate.definition, candidate.stage).ok then
                    owner.readyResults[group.id] = candidate.state
                    dirty = true
                    break
                end
            end
            if owner.readyResults[group.id] or work.cursor > #work.list then
                owner.readyResults[group.id] = owner.readyResults[group.id] or false
                owner.readyWork = nil
                checked = checked + 1
            end
        end
    end
    if dirty then owner.readyDirty = true end
    local now = getTimestampMs()
    local pending = false
    for index = 1, #source do
        if owner.readyResults[source[index].id] == nil then pending = true; break end
    end
    if owner.readyButton then
        owner.readyButton:setTitle(getText(pending and "IGUI_KBW_CheckingRecipes" or "IGUI_KBW_ReadyToBuild"))
    end
    if owner.readyDirty and now - (owner.readyRefreshAt or 0) > 300 then
        owner.readyDirty, owner.readyRefreshAt = false, now
        owner:refreshGrid(true)
    end
end

function Readiness.select(owner)
    local hint = owner.readyOnly and owner.selected and owner.readyResults[owner.selected.id]
    if not hint then return end
    local state = TableUtil.merge(hint, {
        scope = owner.scope, selectedCategories = owner.selectedCategories,
        search = owner.search:getInternalText()
    })
    state.subcategory = owner.subcategoryValues and owner.subcategoryValues[owner.subcategoryFilter.selected]
    state.material = owner.materialFilterValues and owner.materialFilterValues[owner.materialFilter.selected]
    state.skill = owner.skillFilterValues and owner.skillFilterValues[owner.skillFilter.selected]
    owner:restoreState(state)
end

return Readiness
