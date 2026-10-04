--- Requirements provides the Knox Buildworks construction validation layer.
local Log = require("KnoxBuildworks/Log")
local KBW = require("KnoxBuildworks/Core")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local RecipeData = require("KnoxBuildworks/Crafting/RecipeData")
local Profiler = require("KnoxBuildworks/Util/Profiler")
local SupplyAllocation = require("KnoxBuildworks/Validation/SupplyAllocation")

---@class KBW.RequirementsModule
---@type KBW.RequirementsModule
local Requirements = {}

-- Revision counter for player inventory/container state. UI readiness caches
-- key off this instead of re-walking containers on a timer: any container
-- change bumps it, and stale statuses re-evaluate lazily.
local inventoryRev = 1

local function bumpInventoryRev()
    inventoryRev = inventoryRev + 1
end

Events.OnContainerUpdate.Add(bumpInventoryRev)

---@return number
function Requirements.inventoryRevision()
    return inventoryRev
end

local activeInput = nil

local function hasFlag(input, flag)
    local flags = input and input.flags or {}
    for flagIndex = 1, #flags do
        local value = flags[flagIndex]
        if value == flag then return true end
    end
    return false
end

local function recipeHasTag(recipe, wanted)
    local tags = recipe and recipe.tags or {}
    for tagIndex = 1, #tags do
        if tags[tagIndex] == wanted then return true end
    end
    return false
end

local function recipeDisplayName(recipeName)
    local internalName = tostring(recipeName or "")
    if internalName == "" then return "?" end
    if getRecipeDisplayName then
        local displayName = getRecipeDisplayName(internalName)
        if displayName and displayName ~= "" then return tostring(displayName) end
    end
    return internalName
end

local function predicateNotBroken(item)
    local input = activeInput
    if not item then return false end
    -- An exhausted drainable has nothing left to give. Skipping it here matters
    -- twice over: it keeps the availability count honest, and it stops
    -- consumption re-picking the same empty item until its uses go negative.
    -- KeepOnDeplete items (the blowtorch) never leave the container, so without
    -- this the first torch is drained past empty while a full one sits beside
    -- it, and DrainableComboItem.Use decrements with no floor at zero.
    if input and (input.uses ~= nil or input.mode == "drain") and not hasFlag(input, "IsEmpty")
        and not hasFlag(input, "HasNoUses") and item.getCurrentUses and instanceof(item, "DrainableComboItem")
        and item:getCurrentUses() <= 0 then
        return false
    end
    if hasFlag(input, "NoBrokenItems") and item.isBroken and item:isBroken() then return false end
    if not hasFlag(input, "AllowDestroyedItem") and item.isDestroyed and item:isDestroyed() then return false end
    if hasFlag(input, "IsEmptyContainer") and instanceof(item, "InventoryContainer") and not item
            :getInventory()
            :getItems()
            :isEmpty() then
        return false
    end
    if hasFlag(input, "IsFull") and item.getCurrentUses
        and item.getMaxUses and item:getCurrentUses() < item:getMaxUses() then
        return false
    end
    if hasFlag(input, "NotFull") and item.getCurrentUses
        and item.getMaxUses and item:getCurrentUses() >= item:getMaxUses() then
        return false
    end
    if hasFlag(input, "IsEmpty") and item.getCurrentUses and item:getCurrentUses() > 0 then return false end
    if hasFlag(input, "NotEmpty") and item.getCurrentUses and item:getCurrentUses() <= 0 then return false end
    if hasFlag(input, "HasOneUse") and item.getCurrentUses and item:getCurrentUses() ~= 1 then return false end
    if hasFlag(input, "HasNoUses") and item.getCurrentUses and item:getCurrentUses() > 0 then return false end
    if not hasFlag(input, "AllowFavorite") and input and input.mode ~= "keep" and item.isFavorite and item:isFavorite() then
        return false
    end
    return true
end

local function normalizeTagName(name)
    if not name then return nil end
    local value = tostring(name)
    if not string.find(value, ":", 1, true) then
        local dotIndex = string.find(value, ".", 1, true)
        if dotIndex then
            local namespace = string.sub(value, 1, dotIndex - 1)
            local path = string.sub(value, dotIndex + 1)
            if namespace ~= "" and path ~= "" and not string.find(path, ".", 1, true) then
                value = namespace .. ":" .. path
            end
        end
    end
    return value
end

local warnedTags = {}

local function tagValue(name)
    local normalized = normalizeTagName(name)
    local tag = nil
    if normalized and ItemTag and ResourceLocation then tag = ItemTag.get(ResourceLocation.of(normalized)) end
    if not tag and ItemTag and normalized then
        local key = string.upper(string.gsub(normalized, "(%l)(%u)", "%1_%2"))
        key = string.gsub(key, "[^A-Z0-9]", "_")
        tag = ItemTag[key] or ItemTag[string.upper(normalized)]
    end
    if not tag and normalized and not warnedTags[normalized] then
        warnedTags[normalized] = true
        Log:warning("Unresolved item tag '%s' in requirements", tostring(name))
    end
    return tag
end

local function addUniquePossible(result, seen, fullType)
    if not fullType or seen[fullType] then return end
    seen[fullType] = true
    result[#result + 1] = fullType
end

local function addScriptItemFullType(result, seen, scriptItem)
    if not scriptItem then return end
    local fullType = nil
    if scriptItem.getFullName then
        fullType = scriptItem:getFullName()
    elseif scriptItem.getFullType then
        fullType = scriptItem:getFullType()
    elseif scriptItem.getName then
        fullType = scriptItem:getName()
    end
    addUniquePossible(result, seen, fullType)
end

local function possibleItemsForInput(input)
    local result = {}
    local seen = {}
    local items = input.items or {}
    for itemIndex = 1, #items do
        addUniquePossible(result, seen, items[itemIndex])
    end
    if not getScriptManager then return result end
    local manager = getScriptManager()
    if not manager or not manager.getItemsTag then return result end
    local tags = input.tags or {}
    for tagIndex = 1, #tags do
        local tag = tagValue(tags[tagIndex])
        if tag then
            local scriptItems = manager:getItemsTag(tag)
            if scriptItems then
                for scriptIndex = 0, scriptItems:size() - 1 do
                    addScriptItemFullType(result, seen, scriptItems:get(scriptIndex))
                end
            end
        end
    end
    return result
end

local function findTag(inventory, tags, input)
    local oldInput = activeInput
    activeInput = input
    tags = tags or {}
    for tagIndex = 1, #tags do
        local name = tags[tagIndex]
        local tag = tagValue(name)
        if tag then
            local item = inventory:getFirstTagEvalRecurse(tag, predicateNotBroken)
            if item then
                activeInput = oldInput
                return item
            end
        end
    end
    activeInput = oldInput
end

local function amountForItem(item, countUses)
    -- max(0): a drainable that an older build drove below empty still counts as
    -- nothing, never as negative stock.
    if countUses and instanceof(item, "DrainableComboItem") then
        return math.max(item:getCurrentUses(), 0)
    end
    return 1
end

local function addMatchedItem(result, seenItems, item)
    if not item then return end
    local key = tostring(item)
    if seenItems[key] then return end
    seenItems[key] = true
    result[#result + 1] = item
end

local function matchedInventoryItems(inventory, input, choices)
    local result = {}
    local seenItems = {}
    if not inventory then return result end
    local oldInput = activeInput
    activeInput = input
    local selectedFullType = choices and choices[input.id] or nil
    if selectedFullType then
        local items = inventory:getAllTypeEvalRecurse(selectedFullType, predicateNotBroken)
        if items then
            for i = 0, items:size() - 1 do
                addMatchedItem(result, seenItems, items:get(i))
            end
        end
        activeInput = oldInput
        return result
    end
    local inputItems = input.items or {}
    for itemIndex = 1, #inputItems do
        local fullType = inputItems[itemIndex]
        if fullType ~= selectedFullType then
            local items = inventory:getAllTypeEvalRecurse(fullType, predicateNotBroken)
            if items then
                for i = 0, items:size() - 1 do
                    addMatchedItem(result, seenItems, items:get(i))
                end
            end
        end
    end
    local inputTags = input.tags or {}
    for tagIndex = 1, #inputTags do
        local tag = tagValue(inputTags[tagIndex])
        if tag then
            local items = inventory:getAllTagEvalRecurse(tag, predicateNotBroken, ArrayList.new())
            if items then
                for i = 0, items:size() - 1 do
                    addMatchedItem(result, seenItems, items:get(i))
                end
            end
        end
    end
    activeInput = oldInput
    return result
end

local function addAvailable(result, seen, seenItems, item, countUses)
    if not item then return 0 end
    local itemKey = tostring(item)
    if seenItems[itemKey] then return 0 end
    seenItems[itemKey] = true
    local fullType = item:getFullType()
    local amount = amountForItem(item, countUses)
    local entry = seen[fullType]
    if not entry then
        entry = { fullType = fullType, count = 0, uses = 0, available = 0, item = item, items = {} }
        seen[fullType] = entry
        result[#result + 1] = entry
    end
    entry.items[#entry.items + 1] = item
    entry.count = entry.count + 1
    entry.uses = entry.uses + (instanceof(item, "DrainableComboItem") and item:getCurrentUses() or 1)
    entry.available = entry.available + amount
    return amount
end

local function availableTypes(inventory, types, tags, countUses, square, input)
    local result, total = {}, 0
    local seen = {}
    local seenItems = {}
    local ground = square and buildUtil.getMaterialOnGround(square) or {}
    local oldInput = activeInput
    activeInput = input
    types = types or {}
    for typeIndex = 1, #types do
        local fullType = types[typeIndex]
        local items = inventory:getAllTypeEvalRecurse(fullType, predicateNotBroken)
        if items then
            for i = 0, items:size() - 1 do
                total = total + addAvailable(result, seen, seenItems, items:get(i), countUses)
            end
        end
        local groundItems = ground[fullType] or {}
        for groundIndex = 1, #groundItems do
            if predicateNotBroken(groundItems[groundIndex]) then
                total = total + addAvailable(result, seen, seenItems, groundItems[groundIndex], countUses)
            end
        end
    end
    tags = tags or {}
    for tagIndex = 1, #tags do
        local tagName = tags[tagIndex]
        local tag = tagValue(tagName)
        if tag then
            local items = inventory:getAllTagEvalRecurse(tag, predicateNotBroken, ArrayList.new())
            if items then
                for i = 0, items:size() - 1 do
                    total = total + addAvailable(result, seen, seenItems, items:get(i), countUses)
                end
            end
            for _, itemsOnGround in pairs(ground) do
                itemsOnGround = itemsOnGround or {}
                for groundIndex = 1, #itemsOnGround do
                    local item = itemsOnGround[groundIndex]
                    if item:hasTag(tag) and predicateNotBroken(item) then
                        total = total + addAvailable(result, seen, seenItems, item, countUses)
                    end
                end
            end
        end
    end
    activeInput = oldInput
    return result, total
end

local function degradeChance(input)
    if hasFlag(input, "MayDegradeHeavy") then return 1.0 end
    if hasFlag(input, "MayDegrade") then return 2.0 end
    if hasFlag(input, "MayDegradeLight") then return 3.0 end
    if hasFlag(input, "MayDegradeVeryLight") then return 6.0 end
    return nil
end

local function highestRelevantSkill(player, stage, item)
    local highest = 0
    local skills = ((stage or {}).requirements or {}).skills or {}
    for perkName in pairs(skills) do
        local perk = Perks[perkName]
        if perk and player and player.getPerkLevel then highest = math.max(highest, player:getPerkLevel(perk)) end
    end
    if item and item.getMaintenanceMod and player then highest = highest + (item:getMaintenanceMod(player) or 0) end
    return highest
end

local function maybeDegradeKeptItem(player, stage, input, item)
    local chance = degradeChance(input)
    if not chance or not item or not item.damageCheck then return end
    item:damageCheck(highestRelevantSkill(player, stage, item), chance, false)
end

local function normalizedInputs(definition, stage)
    local req = stage.requirements or {}
    local rows = {}
    local inputs = req.inputs or {}
    for index = 1, #inputs do
        local input = inputs[index]
        local copy = copyTable(input)
        copy.id = copy.id or ("input-" .. index)
        copy.role = copy.role or "material"
        copy.mode = copy.mode or (copy.role == "tool" and "keep" or "consume")
        copy.resourceType = copy.resourceType or "Item"
        rows[#rows + 1] = copy
    end
    local materials = req.materials or {}
    for index = 1, #materials do
        local material = materials[index]
        rows[#rows + 1] = {
            id = material.id or ("material-" .. index),
            role = material.role or "material",
            mode = material.mode or (material.uses and "drain" or "consume"),
            items = material.items,
            tags = material.tags,
            amount = material.amount,
            uses = material.uses,
            resourceType = material.resourceType,
            label = material.label,
            icon = material.icon,
            flags = material.flags,
            materialTags = material.materialTags
        }
    end
    local definitionTools = definition.tools or {}
    for index = 1, #definitionTools do
        local tool = definitionTools[index]
        rows[#rows + 1] = {
            id = tool.id or ("base-tool-" .. index),
            role = "tool",
            mode = tool.mode or "keep",
            tags = tool.tags,
            items = tool.items,
            amount = tool.amount,
            uses = tool.uses,
            resourceType = tool.resourceType,
            label = tool.label,
            icon = tool.icon,
            flags = tool.flags
        }
    end
    local tools = req.tools or {}
    for index = 1, #tools do
        local tool = tools[index]
        rows[#rows + 1] = {
            id = tool.id or ("tool-" .. index),
            role = "tool",
            mode = tool.mode or "keep",
            tags = tool.tags,
            items = tool.items,
            amount = tool.amount,
            uses = tool.uses,
            resourceType = tool.resourceType,
            label = tool.label,
            icon = tool.icon,
            flags = tool.flags
        }
    end
    -- Keep input IDs valid for blueprints saved while paint was required.
    -- Zero-cost rows are still accepted by ingredient-choice validation.
    if KBW.sandboxValue("KnoxBuildworks.RequireConstructionPaint", true) == false then
        local hasConstructionPaint = false
        for index = 1, #rows do
            if rows[index].id == "finish_paint" then
                rows[index].amount, rows[index].uses = 0, 0
                hasConstructionPaint = true
            end
        end
        if hasConstructionPaint then
            for index = 1, #rows do
                if rows[index].id == "tool_paintbrush" then rows[index].amount = 0 end
            end
        end
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Inventory snapshot + readiness-only evaluation.
--
-- Requirements.evaluate below walks the player's containers recursively per
-- input (several Java-side recursions per buildable). That is correct and
-- detailed, but far too heavy to run for every visible catalogue card. The
-- snapshot walks the inventory ONCE per (revision, square) and readiness
-- checks count against it in Lua with the exact same item predicates.
-- ---------------------------------------------------------------------------

local function acceptAll()
    return true
end

local snapshotCache = nil

--- One recursive walk of the player's inventory plus the on-ground material
--- map for the given square, cached until a container changes or the square
--- differs. Shared by every readiness check in a refresh cycle.
---@param player IsoPlayer
---@param square IsoGridSquare | nil
---@return table snapshot
function Requirements.snapshot(player, square)
    local squareKey = square and (square:getX() .. ":" .. square:getY() .. ":" .. square:getZ()) or ""
    local cached = snapshotCache
    if cached and cached.player == player and cached.rev == inventoryRev and cached.squareKey == squareKey then
        return cached
    end
    local snapshotStart = Profiler.now()
    local snapshot = {
        player = player,
        rev = inventoryRev,
        squareKey = squareKey,
        byType = {},
        allItems = {},
        tagCache = {},
        ground = (square and buildUtil and buildUtil.getMaterialOnGround) and buildUtil.getMaterialOnGround(square)
            or {}
    }
    local inventory = player and player.getInventory and player:getInventory() or nil
    local items = inventory and inventory:getAllEvalRecurse(acceptAll, ArrayList.new()) or nil
    if items then
        local byType = snapshot.byType
        local allItems = snapshot.allItems
        for itemIndex = 0, items:size() - 1 do
            local item = items:get(itemIndex)
            local fullType = item:getFullType()
            local list = byType[fullType]
            if not list then
                list = {}
                byType[fullType] = list
            end
            list[#list + 1] = item
            allItems[#allItems + 1] = item
        end
    end
    snapshotCache = snapshot
    Profiler.add("requirements.snapshot", snapshotStart)
    Profiler.count("requirements.snapshotBuilds")
    return snapshot
end

--- Items carrying the tag, filtered lazily from the snapshot and cached per
--- tag name so hundreds of cards sharing common tool tags scan once.
local function snapshotTagItems(snapshot, tagName)
    local cached = snapshot.tagCache[tagName]
    if cached then return cached end
    local result = {}
    local tag = tagValue(tagName)
    if tag then
        local allItems = snapshot.allItems
        for itemIndex = 1, #allItems do
            local item = allItems[itemIndex]
            if item:hasTag(tag) then result[#result + 1] = item end
        end
    end
    snapshot.tagCache[tagName] = result
    return result
end

--- Counts available units for one input against the snapshot, honouring the
--- same predicate flags and ground-item rules as the detailed evaluation
--- (carried items pass predicateNotBroken; ground items are counted as-is).
local function countAvailable(snapshot, input, countUses, includeGround)
    local total = 0
    local seenItems = {}
    local oldInput = activeInput
    activeInput = input
    local types = input.items or {}
    for typeIndex = 1, #types do
        local fullType = types[typeIndex]
        local list = snapshot.byType[fullType]
        if list then
            for itemIndex = 1, #list do
                local item = list[itemIndex]
                if not seenItems[item] and predicateNotBroken(item) then
                    seenItems[item] = true
                    total = total + amountForItem(item, countUses)
                end
            end
        end
        if includeGround then
            local groundItems = snapshot.ground[fullType] or {}
            for groundIndex = 1, #groundItems do
                local item = groundItems[groundIndex]
                if not seenItems[item] and predicateNotBroken(item) then
                    seenItems[item] = true
                    total = total + amountForItem(item, countUses)
                end
            end
        end
    end
    local tags = input.tags or {}
    for tagIndex = 1, #tags do
        local tagName = tags[tagIndex]
        local tagged = snapshotTagItems(snapshot, tagName)
        for itemIndex = 1, #tagged do
            local item = tagged[itemIndex]
            if not seenItems[item] and predicateNotBroken(item) then
                seenItems[item] = true
                total = total + amountForItem(item, countUses)
            end
        end
        if includeGround then
            local tag = tagValue(tagName)
            if tag then
                for _, itemsOnGround in pairs(snapshot.ground) do
                    itemsOnGround = itemsOnGround or {}
                    for groundIndex = 1, #itemsOnGround do
                        local item = itemsOnGround[groundIndex]
                        if not seenItems[item] and item:hasTag(tag) and predicateNotBroken(item) then
                            seenItems[item] = true
                            total = total + amountForItem(item, countUses)
                        end
                    end
                end
            end
        end
    end
    activeInput = oldInput
    return total
end

--- Normalized inputs cached per stage. The normalized rows derive only from
--- the immutable definition/stage data and are treated as read-only by the
--- readiness path; the detailed evaluate/consume paths keep building fresh
--- copies.
local function readinessInputs(definition, stage)
    local requirePaint = KBW.sandboxValue("KnoxBuildworks.RequireConstructionPaint", true)
    local cached = stage.__kbwReadinessInputs
    if not cached or stage.__kbwReadinessPaint ~= requirePaint then
        cached = normalizedInputs(definition, stage)
        stage.__kbwReadinessInputs = cached
        stage.__kbwReadinessPaint = requirePaint
    end
    return cached
end

--- Whether the stage recipe carries CanBeDoneInDark, resolved once per stage.
local function stageCanBeDoneInDark(definition, stage)
    local cached = stage.__kbwCanBeDoneInDark
    if cached == nil then
        cached = recipeHasTag(StageConfig.recipe(definition, stage), "CanBeDoneInDark")
        stage.__kbwCanBeDoneInDark = cached
    end
    return cached
end

---@param player    IsoPlayer
---@param knowledge KBW.KnowledgeRequirement
---@return boolean, string
local function knowledgeAlternativeStatus(player, knowledge)
    local groups = knowledge and knowledge.skillAlternatives or {}
    local labels = {}
    for groupIndex = 1, #groups do
        local group = groups[groupIndex] or {}
        local mode = group.mode == "any" and "any" or "all"
        local groupOk = mode == "all"
        local foundSkill = false
        local groupLabels = {}
        for perkName, needed in pairs(group.skills or {}) do
            foundSkill = true
            local perk = Perks[perkName]
            local available = perk and player:getPerkLevel(perk) or 0
            local skillOk = perk ~= nil and available >= (tonumber(needed) or 0)
            if mode == "any" then
                groupOk = groupOk or skillOk
            else
                groupOk = groupOk and skillOk
            end
            groupLabels[#groupLabels + 1] = getText("IGUI_perks_" .. tostring(perkName)) .. " " .. tostring(needed)
        end
        table.sort(groupLabels)
        if foundSkill then
            labels[#labels + 1] = table.concat(groupLabels, mode == "any" and " / " or " + ")
            if groupOk then return true, table.concat(labels, " / ") end
        end
    end
    return false, table.concat(labels, " / ")
end

--- Readiness-only evaluation for catalogue cards: same pass/fail logic as
--- Requirements.evaluate, but counts against the shared snapshot, skips the
--- Available Ingredients / Possible Items detail rows, and exits early.
---@param player     IsoPlayer
---@param definition KBW.BuildableDefinition
---@param stage      KBW.BuildStage
---@param snapshot   table
---@return { ok: boolean }
function Requirements.evaluateReadiness(player, definition, stage, snapshot)
    if not player or not definition or not stage then return { ok = false } end
    Profiler.count("requirements.readinessEvals")
    local cheat = player:isBuildCheat()
    local req = stage.requirements or {}
    if req.debugOnly and not isDebugEnabled() then return { ok = false } end
    if not cheat and player.tooDarkToRead and player:tooDarkToRead() and not stageCanBeDoneInDark(definition, stage) then
        return { ok = false }
    end
    if not cheat then
        local inputs = readinessInputs(definition, stage)
        for inputIndex = 1, #inputs do
            local input = inputs[inputIndex]
            local needed = input.uses or input.amount or 1
            local countUses = input.uses ~= nil or input.mode == "drain"
            local includeGround = input.mode ~= "keep"
            if countAvailable(snapshot, input, countUses, includeGround) < needed then
                return { ok = false }
            end
        end
        for perkName, needed in pairs(req.skills or {}) do
            local perk = Perks[perkName]
            local available = perk and player:getPerkLevel(perk) or 0
            if perk == nil or available < needed then return { ok = false } end
        end
    end
    local knowledge = req.knowledge or {}
    if knowledge.needToBeLearned ~= false then
        local alternativeMet = knowledgeAlternativeStatus(player, knowledge)
        local requiredRecipes = req.recipes or {}
        for recipeIndex = 1, #requiredRecipes do
            if not player:isRecipeActuallyKnown(requiredRecipes[recipeIndex]) and not alternativeMet then
                return { ok = false }
            end
        end
        local knowledgeRecipes = knowledge.recipes or {}
        for recipeIndex = 1, #knowledgeRecipes do
            if not player:isRecipeActuallyKnown(knowledgeRecipes[recipeIndex]) and not alternativeMet then
                return { ok = false }
            end
        end
    end
    return { ok = true }
end

---@param player     IsoPlayer
---@param definition KBW.BuildableDefinition
---@param stage      KBW.BuildStage
---@param square     IsoGridSquare | nil
---@param choices    table<string, string> | nil
---@return KBW.RequirementStatus
function Requirements.evaluate(player, definition, stage, square, choices)
    Profiler.count("requirements.fullEvals")
    local status = { ok = true, materials = {}, tools = {}, skills = {}, recipes = {}, rows = {} }
    if not player or not definition or not stage then
        status.ok = false
        status.reason = "invalid selection"
        return status
    end
    local cheat = player:isBuildCheat()
    local req, inventory = stage.requirements or {}, player:getInventory()
    local recipe = StageConfig.recipe(definition, stage)
    if not cheat and player.tooDarkToRead and player:tooDarkToRead() and not recipeHasTag(recipe, "CanBeDoneInDark") then
        status.ok = false
        status.reason = "requires light"
    end
    if req.debugOnly and not isDebugEnabled() then
        status.ok = false
        status.reason = "debug only"
    end
    if square == nil and player.getSquare then square = player:getSquare() end
    local inputs = normalizedInputs(definition, stage)
    for inputIndex = 1, #inputs do
        local input = inputs[inputIndex]
        local needed = input.uses or input.amount or 1
        local countUses = input.uses ~= nil or input.mode == "drain"
        local groundSquare = input.mode ~= "keep" and square or nil
        local selectedFullType = choices and choices[input.id] or nil
        local selectedTypes = selectedFullType and { selectedFullType } or input.items
        local selectedTags = selectedFullType and {} or input.tags
        local availableItems, available = availableTypes(
            inventory, selectedTypes, selectedTags, countUses, groundSquare, input
        )
        -- A manual choice narrows the row used for construction, but it must
        -- not erase the stock preview for the other legal aliases. Keep a
        -- second, unfiltered snapshot for Possible Items so changing from a
        -- Smithing Hammer to another hammer still shows the Smithing Hammer
        -- as available in the player's inventory.
        local possibleAvailableItems, possibleAvailable = availableItems, available
        if selectedFullType then
            possibleAvailableItems, possibleAvailable = availableTypes(
                inventory, input.items, input.tags, countUses, groundSquare, input
            )
        end
        local foundTool = nil
        if selectedFullType then
            local oldInput = activeInput
            activeInput = input
            foundTool = inventory:getFirstTypeEvalRecurse(selectedFullType, predicateNotBroken)
            activeInput = oldInput
        elseif input.tags and #input.tags > 0 then
            foundTool = findTag(inventory, input.tags, input)
        end
        local row = {
            id = input.id,
            kind = "input",
            role = input.role,
            mode = input.mode,
            uses = input.uses,
            resourceType = input
                .resourceType or "Item",
            label = input.label,
            labelKey = input.labelKey,
            icon = input.icon,
            flags = input.flags or {},
            materialTags = input
                .materialTags
                or {},
            possibleItems = possibleItemsForInput(input),
            possibleTags = input.tags or {},
            availableItems = availableItems,
            possibleAvailableItems = possibleAvailableItems,
            possibleAvailable = possibleAvailable,
            needed = needed,
            neededMax = input.amountMax,
            available = available,
            ok = cheat or available >= needed,
            item = foundTool,
            selectedFullType = selectedFullType
        }
        status.rows[#status.rows + 1] = row
        if input.role == "tool" then
            status.tools[#status.tools + 1] = {
                tags = input.tags or {},
                items = input.items or {},
                item = foundTool,
                ok = row
                    .ok,
                row = row
            }
        else
            status.materials[#status.materials + 1] = {
                items = input.items or {},
                tags = input.tags or {},
                needed = needed,
                available = available,
                ok = row.ok,
                row = row
            }
        end
        if not row.ok then status.ok = false end
    end
    for perkName, needed in pairs(req.skills or {}) do
        local perk = Perks[perkName]
        local available = perk and player:getPerkLevel(perk) or 0
        local row = {
            kind = "skill",
            role = "skill",
            name = perkName,
            needed = needed,
            available = available,
            ok = cheat or (perk ~= nil and available >= needed)
        }
        status.skills[#status.skills + 1] = row
        status.rows[#status.rows + 1] = row
        if not row.ok then status.ok = false end
    end
    local knowledge = req.knowledge or {}
    local alternativeMet, alternativeLabel = knowledgeAlternativeStatus(player, knowledge)
    local recipes = {}
    local requiredRecipes = req.recipes or {}
    for recipeIndex = 1, #requiredRecipes do
        recipes[#recipes + 1] = requiredRecipes[recipeIndex]
    end
    local knowledgeRecipes = knowledge.recipes or {}
    for recipeIndex = 1, #knowledgeRecipes do
        recipes[#recipes + 1] = knowledgeRecipes[recipeIndex]
    end
    for recipeIndex = 1, #recipes do
        local recipe = recipes[recipeIndex]
        local known = player:isRecipeActuallyKnown(recipe)
        local row = {
            id = "knowledge:" .. tostring(recipe),
            kind = "knowledge",
            role = "knowledge",
            name = recipeDisplayName(recipe),
            recipeName = recipe,
            needed = 1,
            available = known and 1 or 0,
            ok = cheat or known or alternativeMet,
            sources = knowledge.sources or {},
            needToBeLearned = knowledge.needToBeLearned ~= false,
            alternativeMet = alternativeMet,
            alternativeLabel = alternativeLabel
        }
        status.recipes[#status.recipes + 1] = row
        status.rows[#status.rows + 1] = row
        if row.needToBeLearned and not row.ok then status.ok = false end
    end
    if not cheat then
        local allocation = SupplyAllocation.rows(status.rows)
        status.allocation = allocation
        for index = 1, #allocation.rows do
            local entry = allocation.rows[index]
            entry.row.totalAvailable = entry.row.available
            entry.row.available = entry.available
            entry.row.ok = entry.ok
        end
        if not allocation.ok then status.ok = false end
    end
    return status
end

---@param player     IsoPlayer
---@param stage      KBW.BuildStage
---@param square     IsoGridSquare | nil
---@param definition KBW.BuildableDefinition
---@param choices    table<string, string> | nil
---@return boolean consumed
---@return KBW.CraftRecipeData recipeData
function Requirements.consume(player, stage, square, definition, choices)
    local recipeData = RecipeData.new(EntityCompat.craftRecipeObject(stage), player)
    if player:isBuildCheat() then return true, recipeData end
    definition = definition or {}
    local status = Requirements.evaluate(player, definition, stage, square, choices)
    if not status.ok then return false, recipeData end
    local inventory = player:getInventory()
    local inputs = normalizedInputs(definition, stage)
    for inputIndex = 1, #inputs do
        local input = inputs[inputIndex]
        local allocation = status.allocation.rows[inputIndex]
        for matchIndex = 1, #allocation.items do
            local match = allocation.items[matchIndex]
            local item = match.item
            if input.mode == "keep" then
                recipeData:record(input, item, inputIndex)
                maybeDegradeKeptItem(player, stage, input, item)
            elseif input.uses ~= nil or input.mode == "drain" then
                for useIndex = 1, match.amount do
                    recipeData:record(input, item, inputIndex)
                    item:UseAndSync()
                end
            else
                recipeData:record(input, item, inputIndex)
                local world = item:getWorldItem()
                if world then
                    world:getSquare():transmitRemoveItemFromSquare(world)
                else
                    player:removeFromHands(item)
                    local container = item:getContainer() or inventory
                    sendRemoveItemFromContainer(container, item)
                    container:Remove(item)
                end
            end
        end
    end
    return true, recipeData
end

---@param definition KBW.BuildableDefinition
---@param stage      KBW.BuildStage
---@return KBW.BuildInput[]
function Requirements.getInputs(definition, stage)
    return normalizedInputs(definition, stage)
end

-- Shared by gather previews and transfer selection, so broken/empty/favorite
-- item flags are interpreted exactly as they are during construction.
function Requirements.matchesInput(item, input, selectedFullType)
    if not item then return false end
    local previous = activeInput
    activeInput = input
    local accepted = predicateNotBroken(item)
    activeInput = previous
    if not accepted then return false end
    local fullType = item:getFullType()
    if selectedFullType and selectedFullType ~= "" and fullType ~= selectedFullType then return false end
    if input.matchTag and item:hasTag(input.matchTag) then return true end
    local types, tags = input.items or input.possibleItems or {}, input.tags or input.possibleTags or {}
    for index = 1, #types do if types[index] == fullType then return true end end
    for index = 1, #tags do
        local tag = tagValue(tags[index])
        if tag and item:hasTag(tag) then return true end
    end
    return false
end

---@param player     IsoPlayer
---@param definition KBW.BuildableDefinition
---@param stage      KBW.BuildStage
---@param square     IsoGridSquare | nil
---@param choices    table<string, string> | nil
---@return string | nil primaryModel
---@return string | nil secondaryModel
function Requirements.handModels(player, definition, stage, square, choices)
    local prop1 = nil
    local prop2 = nil
    local inputs = normalizedInputs(definition or {}, stage or {})
    local inventory = player and player.getInventory and player:getInventory() or nil
    for inputIndex = 1, #inputs do
        local input = inputs[inputIndex]
        if (prop1 == nil and hasFlag(input, "Prop1")) or (prop2 == nil and hasFlag(input, "Prop2")) then
            local matches = matchedInventoryItems(inventory, input, choices)
            local item = matches[1]
            local model = item
            if item and item.getStaticModel then model = item:getStaticModel() or item end
            if prop1 == nil and hasFlag(input, "Prop1") then prop1 = model end
            if prop2 == nil and hasFlag(input, "Prop2") then prop2 = model end
        end
        if prop1 ~= nil and prop2 ~= nil then break end
    end
    return prop1, prop2
end

-- Exposed so Resolver.validateChoices can verify manual ingredient selections
-- against the same accepted-item resolution the requirement rows use.
---@param input KBW.BuildInput
---@return string[]
function Requirements.possibleItems(input)
    return possibleItemsForInput(input)
end

return Requirements
