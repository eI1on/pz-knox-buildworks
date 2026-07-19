---CatalogIndex provides the Knox Buildworks custom user-interface layer.
--
-- One immutable, lazily built index of lightweight catalogue records shared
-- by the catalogue window and Planning Mode. It is rebuilt only when the
-- registry hash changes, so opening the UI, switching categories, searching,
-- and sorting never re-derive display names, lowercase search text, filter
-- option sets, or visibility metadata per definition.
--
-- Records reference the registry definitions; they never copy them. Anything
-- player-dependent (visibility callbacks, readiness, favourites, pins) stays
-- out of the cached record and is evaluated by the callers that need it.
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local I18n = require("KnoxBuildworks/I18n")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local CatalogVisibility = require("KnoxBuildworks/UI/CatalogVisibility")
local Requirements = require("KnoxBuildworks/Validation/Requirements")
local LuaCallback = require("KnoxBuildworks/Util/LuaCallback")
local Profiler = require("KnoxBuildworks/Util/Profiler")

---@class KBW.CatalogIndexModule
---@type KBW.CatalogIndexModule
local CatalogIndex = {}

local cache = nil

---Mirrors StageConfig.recipe's onAddToMenu resolution without allocating the
---merged recipe view: an explicit stage callback wins, then the referenced
---entity script's native CraftRecipe callback.
local function stageOnAddToMenu(stage)
    local callbacks = stage.callbacks
    if callbacks and callbacks.onAddToMenu then return callbacks.onAddToMenu end
    if stage.entityCompat then
        local metadata = EntityCompat.metadata(stage)
        local native = metadata and metadata.craftRecipe
        if native then return native.onAddToMenu end
    end
    return nil
end

---A definition is unconditionally visible when any stage lacks an
---onAddToMenu callback (CatalogVisibility.stagePasses returns true for such
---stages, and definitionPasses accepts on the first passing stage). Only
---definitions where every stage carries a callback need runtime evaluation;
---for those the callback name is pre-resolved so filtering never rebuilds the
---merged recipe view.
---@return boolean alwaysVisible
---@return table|nil callbackStages
local function visibilityInfo(definition)
    local stages = definition.stages or {}
    if #stages == 0 then return true, nil end
    local callbackStages = {}
    for stageIndex = 1, #stages do
        local stage = stages[stageIndex]
        local callback = stageOnAddToMenu(stage)
        if not callback then return true, nil end
        callbackStages[#callbackStages + 1] = { stage = stage, callback = callback }
    end
    return false, callbackStages
end

local function skillsFor(definition)
    local skills = {}
    local stages = definition.stages or {}
    for stageIndex = 1, #stages do
        local requirements = stages[stageIndex].requirements or {}
        for skillName in pairs(requirements.skills or {}) do
            skills[skillName] = true
        end
    end
    return skills
end

local function buildRecord(definition, order)
    local name = I18n.definitionName(definition)
    local lowerName = string.lower(name)
    local tags = definition.tags or {}
    local searchText = lowerName .. " " .. string.lower(tostring(definition.id or ""))
    if #tags > 0 then
        searchText = searchText .. " " .. string.lower(table.concat(tags, " "))
    end
    local category = definition.category or "General"
    local subcategory = definition.subcategory or "General"
    local alwaysVisible, callbackStages = visibilityInfo(definition)
    return {
        definition = definition,
        id = definition.id,
        category = category,
        subcategory = subcategory,
        materialTags = definition.materialTags or {},
        skills = skillsFor(definition),
        name = name,
        lowerName = lowerName,
        searchText = searchText,
        searchTextExtended = searchText .. " "
            .. string.lower(I18n.category(category)) .. " "
            .. string.lower(I18n.subcategory(subcategory)),
        requirementText = nil, -- built lazily by CatalogIndex.requirementText
        alwaysVisible = alwaysVisible,
        callbackStages = callbackStages,
        order = order
    }
end

local function newFilterSets()
    return { subcategories = {}, materials = {}, skills = {} }
end

local function addToFilterSets(sets, record)
    sets.subcategories[record.subcategory] = true
    local materialTags = record.materialTags
    for tagIndex = 1, #materialTags do
        sets.materials[materialTags[tagIndex]] = true
    end
    for skillName in pairs(record.skills) do
        sets.skills[skillName] = true
    end
end

---@return table index
function CatalogIndex.get()
    local hash = Registry.hash or ""
    if cache and cache.hash == hash then return cache end
    local buildStart = Profiler.now()
    local list = Groups.groupedList(Registry:list())
    local records = {}
    local byId = {}
    local categories = {}
    local categorySeen = {}
    local filtersByCategory = {}
    local allFilters = newFilterSets()
    for listIndex = 1, #list do
        local record = buildRecord(list[listIndex], listIndex)
        records[listIndex] = record
        byId[record.id] = record
        if not categorySeen[record.category] then
            categorySeen[record.category] = true
            categories[#categories + 1] = record.category
            filtersByCategory[record.category] = newFilterSets()
        end
        addToFilterSets(filtersByCategory[record.category], record)
        addToFilterSets(allFilters, record)
    end
    local categoryLabels = {}
    for categoryIndex = 1, #categories do
        categoryLabels[categories[categoryIndex]] = I18n.category(categories[categoryIndex])
    end
    table.sort(categories, function (a, b)
        local labelA, labelB = categoryLabels[a], categoryLabels[b]
        if labelA ~= labelB then return labelA < labelB end
        return tostring(a) < tostring(b)
    end)
    local idKeys = {}
    local nameKeys = {}
    local byNameKey = {}
    for recordIndex = 1, #records do
        local record = records[recordIndex]
        idKeys[recordIndex] = record.id
        local nameKey = record.lowerName .. "\0" .. record.id
        nameKeys[recordIndex] = nameKey
        byNameKey[nameKey] = record
    end
    table.sort(idKeys)
    table.sort(nameKeys)
    local orderById = {}
    local orderByName = {}
    for keyIndex = 1, #idKeys do
        orderById[keyIndex] = byId[idKeys[keyIndex]]
        orderByName[keyIndex] = byNameKey[nameKeys[keyIndex]]
    end
    cache = {
        hash = hash,
        list = list,
        records = records,
        byId = byId,
        categories = categories,
        filtersByCategory = filtersByCategory,
        allFilters = allFilters,
        orderById = orderById,
        orderByName = orderByName
    }
    Profiler.add("catalogIndex.build", buildStart)
    Profiler.count("catalogIndex.records", #records)
    return cache
end

-- ---------------------------------------------------------------------------
-- Player-dependent visibility.
--
-- The ~270 entity-backed core definitions dispatch native onAddToMenu
-- callbacks through the BaseCraftingLogic bridge, ~1-2ms each in Kahlua —
-- running them all inside a filter pass costs hundreds of milliseconds.
-- Results are therefore memoized per record; an expired entry keeps serving
-- its cached value while a bounded background pump re-evaluates it. UIs watch
-- CatalogIndex.visibilityGeneration and rebuild only when a value actually
-- flipped (rare).
-- ---------------------------------------------------------------------------

local VISIBILITY_TTL_MS = 4000
local visibilityQueue = {}
local visibilityQueued = {}

CatalogIndex.visibilityGeneration = 0

local function nowMs()
    return getTimestampMs and getTimestampMs() or 0
end

---Runs the stage callbacks for one record and refreshes its memo entry.
local function evaluateVisibility(player, record, shouldShowAll)
    local evalStart = Profiler.now()
    Profiler.count("catalogIndex.visibilityCallbackRuns")
    local visible = false
    local stages = record.callbackStages
    for stageIndex = 1, #stages do
        local entry = stages[stageIndex]
        if entry.recipeObject == nil then
            entry.recipeObject = EntityCompat.craftRecipeObject(entry.stage) or false
        end
        if LuaCallback.callBool(entry.callback, {
                player = player,
                recipe = entry.recipeObject or nil,
                definition = record.definition,
                stage = entry.stage,
                shouldShowAll = shouldShowAll == true
            }, true) then
            visible = true
            break
        end
    end
    record.visibleCache = {
        player = player,
        showAll = shouldShowAll == true,
        rev = Requirements.inventoryRevision(),
        time = nowMs(),
        value = visible
    }
    Profiler.add("catalogIndex.visibility", evalStart)
    return visible
end

local function queueVisibility(record, player, shouldShowAll)
    if visibilityQueued[record] then return end
    visibilityQueued[record] = true
    visibilityQueue[#visibilityQueue + 1] = { record = record, player = player, showAll = shouldShowAll == true }
end

---Player-dependent visibility with the static fast path applied. Definitions
---without visibility callbacks (the overwhelming majority) return true with
---no allocation or callback dispatch. Callback-bearing definitions return
---their memoized value and re-evaluate in the background when stale, so
---filter passes stay flat.
---@param player IsoPlayer
---@param record table
---@param shouldShowAll boolean
---@return boolean
function CatalogIndex.recordVisible(player, record, shouldShowAll)
    if record.alwaysVisible then return true end
    shouldShowAll = shouldShowAll == true
    local cached = record.visibleCache
    if cached and cached.player == player then
        if cached.showAll ~= shouldShowAll
            or cached.rev ~= Requirements.inventoryRevision()
            or (nowMs() - cached.time) >= VISIBILITY_TTL_MS then
            queueVisibility(record, player, shouldShowAll)
        end
        return cached.value
    end
    return evaluateVisibility(player, record, shouldShowAll)
end

---Processes up to maxCount queued visibility re-evaluations. Call from UI
---update loops (and the post-spawn prewarm); bumps visibilityGeneration when
---any cached value changes so callers know a rebuild is worthwhile.
---@param maxCount number|nil
---@return number processed
function CatalogIndex.pumpVisibility(maxCount)
    local limit = maxCount or 8
    local processed = 0
    while processed < limit do
        local queueLength = #visibilityQueue
        if queueLength == 0 then break end
        local entry = visibilityQueue[queueLength]
        visibilityQueue[queueLength] = nil
        visibilityQueued[entry.record] = nil
        local cached = entry.record.visibleCache
        local before = cached and cached.value
        local value = evaluateVisibility(entry.player, entry.record, entry.showAll)
        if value ~= before then
            CatalogIndex.visibilityGeneration = CatalogIndex.visibilityGeneration + 1
        end
        processed = processed + 1
    end
    return processed
end

-- Post-spawn prewarm: build the index and evaluate every callback-bearing
-- record a few ticks after the player exists, spread across ticks, so the
-- first catalogue open pays neither the index build nor the callback burst.
local prewarmState = nil

local function prewarmTick()
    local state = prewarmState
    if not state then
        Events.OnTick.Remove(prewarmTick)
        return
    end
    state.ticks = state.ticks + 1
    if state.ticks < 60 then return end
    if not state.queued then
        state.queued = true
        local index = CatalogIndex.get()
        local records = index.records
        local shouldShowAll = CatalogVisibility.shouldShowAll(state.player)
        for recordIndex = 1, #records do
            local record = records[recordIndex]
            if not record.alwaysVisible and not record.visibleCache then
                queueVisibility(record, state.player, shouldShowAll)
            end
        end
        return
    end
    CatalogIndex.pumpVisibility(6)
    if #visibilityQueue == 0 then
        prewarmState = nil
        Events.OnTick.Remove(prewarmTick)
        Profiler.report("catalog prewarm complete")
    end
end

---@param player IsoPlayer
function CatalogIndex.prewarm(player)
    if not player or prewarmState then return end
    if not Events or not Events.OnTick then return end
    prewarmState = { player = player, ticks = 0, queued = false }
    Events.OnTick.Add(prewarmTick)
end

local function appendLower(pieces, value)
    if value ~= nil and value ~= "" then
        pieces[#pieces + 1] = string.lower(tostring(value))
    end
end

local function appendInput(pieces, input)
    appendLower(pieces, input.id)
    appendLower(pieces, input.label)
    appendLower(pieces, input.role)
    local items = input.items or {}
    for itemIndex = 1, #items do
        local fullType = items[itemIndex]
        appendLower(pieces, fullType)
        if type(fullType) == "string" and string.find(fullType, ".", 1, true) and getItemNameFromFullType then
            appendLower(pieces, getItemNameFromFullType(fullType))
        end
    end
    local tags = input.tags or {}
    for tagIndex = 1, #tags do
        appendLower(pieces, tags[tagIndex])
    end
    local flags = input.flags or {}
    for flagIndex = 1, #flags do
        appendLower(pieces, flags[flagIndex])
    end
end

---Lazily builds and caches the lowercase requirement-search text for a
---record. Covers the same fields the previous per-keystroke walk matched:
---tools, stage inputs/materials/tools, skill names and their translations,
---and required recipes.
---@param record table
---@return string
function CatalogIndex.requirementText(record)
    if record.requirementText then return record.requirementText end
    local buildStart = Profiler.now()
    local pieces = {}
    local definition = record.definition
    local definitionTools = definition.tools or {}
    for toolIndex = 1, #definitionTools do
        appendInput(pieces, definitionTools[toolIndex])
    end
    local stages = definition.stages or {}
    for stageIndex = 1, #stages do
        local requirements = stages[stageIndex].requirements or {}
        local inputs = requirements.inputs or {}
        for inputIndex = 1, #inputs do
            appendInput(pieces, inputs[inputIndex])
        end
        local materials = requirements.materials or {}
        for materialIndex = 1, #materials do
            appendInput(pieces, materials[materialIndex])
        end
        local tools = requirements.tools or {}
        for toolIndex = 1, #tools do
            appendInput(pieces, tools[toolIndex])
        end
        for skillName in pairs(requirements.skills or {}) do
            appendLower(pieces, skillName)
            appendLower(pieces, getText("IGUI_perks_" .. tostring(skillName)))
        end
        local recipes = requirements.recipes or {}
        for recipeIndex = 1, #recipes do
            local recipe = recipes[recipeIndex]
            if type(recipe) == "table" then
                appendLower(pieces, recipe.id or recipe.name)
            else
                appendLower(pieces, recipe)
            end
        end
    end
    record.requirementText = table.concat(pieces, " ")
    Profiler.add("catalogIndex.requirementText", buildStart)
    return record.requirementText
end

function CatalogIndex.invalidate()
    cache = nil
end

return CatalogIndex
