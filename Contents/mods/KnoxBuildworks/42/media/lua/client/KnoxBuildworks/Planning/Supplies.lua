local Requirements = require("KnoxBuildworks/Validation/Requirements")
local Allocation = require("KnoxBuildworks/Validation/SupplyAllocation")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local Queue = require("KnoxBuildworks/Planning/BuildQueue")
local I18n = require("KnoxBuildworks/I18n")
local Icons = require("KnoxBuildworks/UI/IconResolver")
local Rules = require("KnoxBuildworks/Admin/BuildableRules")
local Supplies = { FRAME_BUDGET_MS = 3, MAX_RECIPES_PER_STEP = 32 }

local function contextKey(player)
    local square = player and player:getSquare()
    local position = square and (tostring(square:getX()) .. ":" .. tostring(square:getY()) .. ":" .. tostring(square:getZ())) or ""
    local dark = player and player.tooDarkToRead and player:tooDarkToRead() or false
    local cheat = player and player:isBuildCheat() or false
    return position .. ":" .. tostring(dark) .. ":" .. tostring(cheat) .. ":" .. tostring(Rules.revision or 0)
end

local function addItems(state, items)
    for index = 1, #items do
        local item = items[index]
        local key = tostring(item)
        if not state.seen[key] then
            state.seen[key] = true
            state.items[#state.items + 1] = item
            local fullType = item:getFullType()
            state.byType[fullType] = state.byType[fullType] or {}
            local typed = state.byType[fullType]
            typed[#typed + 1] = item
        end
    end
end

function Supplies.new(player, blueprint)
    local state = {player = player, blueprint = blueprint, revision = Requirements.inventoryRevision(),
        rulesRevision = Rules.revision or 0,
        placements = blueprint.placements, updated = blueprint.updated, area = blueprint.gatherArea,
        items = {}, seen = {}, cursor = 1, phase = "scan", incomplete = false,
        allocation = Allocation.new(), materials = {}, tools = {}, skills = {}, recipes = {},
        singleReady = {}, allReady = true, allAccess = true, anyReady = false, count = #(blueprint.placements or {}),
        context = contextKey(player), matches = {}, matchStocks = {}, statuses = {}, ground = {}, byType = {}, selections = {}}
    state.scan = Queue.newSupplyScan(player, state.area)
    return state
end

function Supplies.current(state, blueprint)
    if not state or state.blueprint ~= blueprint or state.placements ~= blueprint.placements then return false end
    if state.updated ~= blueprint.updated or state.area ~= blueprint.gatherArea then return false end
    if state.rulesRevision ~= (Rules.revision or 0) then return false end
    -- A busy server can emit container updates throughout a gather scan. Keep
    -- that scan moving; execution rechecks materials against the live world.
    if state.phase ~= "done" then return true end
    local age = getTimestampMs() - (state.checkedAt or 0)
    if state.revision ~= Requirements.inventoryRevision() or state.context ~= contextKey(state.player) then
        return age < 5000
    end
    return age < 30000
end

local function inputKey(row)
    local types = row.selectedFullType and {row.selectedFullType} or row.possibleItems or row.items or {}
    local tags = row.selectedFullType and {} or row.possibleTags or row.tags or {}
    return tostring(row.mode) .. "|" .. tostring(row.uses ~= nil) .. "|" .. table.concat(types, ",") .. "|" .. table.concat(tags, ",")
        .. "|" .. table.concat(row.flags or {}, ",") .. "|" .. tostring(row.matchTag or "")
end

local function supplyRow(state, input, square, choices)
    local row = {}
    for key, value in pairs(input) do row[key] = value end
    row.selectedFullType = choices and choices[row.id] or row.selectedFullType
    row.needed = row.needed or row.uses or row.amount or 1
    row.kind = "input"
    local key = inputKey(row)
    local matches = state.matches[key]
    if not matches then
        matches = {}
        local types = row.selectedFullType and {row.selectedFullType} or row.items or row.possibleItems or {}
        local tags = row.selectedFullType and {} or row.tags or row.possibleTags or {}
        local scanAll = #tags > 0 or row.matchTag ~= nil
        local lists = scanAll and {state.items} or {}
        if not scanAll then
            for index = 1, #types do lists[#lists + 1] = state.byType[types[index]] or {} end
        end
        local seen = {}
        for listIndex = 1, #lists do
            local items = lists[listIndex]
            for index = 1, #items do
                local item = items[index]
                if not seen[item] and Requirements.matchesInput(item, row, row.selectedFullType) then
                    seen[item] = true; matches[#matches + 1] = item
                end
            end
        end
        state.matches[key] = matches
    end
    local stock = state.matchStocks[key]
    if stock == nil then
        stock = Allocation.row({ needed = 0, mode = row.mode, uses = row.uses,
            availableItems = {{items = matches}} }).available
        state.matchStocks[key] = stock
    end
    row.availableItems = {{items = matches}}
    -- Include materials beside this placement even when the gather area is
    -- elsewhere. Scan only that small ground map: the detailed status row also
    -- repeats every carried match, which would make a full stockpile cost
    -- O(placements * inventory size) to enumerate again.
    local extra = {}
    local extraSeen = {}
    if row.mode ~= "keep" and square and buildUtil and buildUtil.getMaterialOnGround then
        local ground = state.ground[square]
        if not ground then
            ground = buildUtil.getMaterialOnGround(square) or {}
            state.ground[square] = ground
        end
        for _, items in pairs(ground) do
            for itemIndex = 1, #items do
                local item = items[itemIndex]
                local itemKey = tostring(item)
                if not state.seen[itemKey] and not extraSeen[itemKey]
                    and Requirements.matchesInput(item, row, row.selectedFullType) then
                    extraSeen[itemKey] = true
                    extra[#extra + 1] = item
                end
            end
        end
    end
    if #extra > 0 then
        row.availableItems[#row.availableItems + 1] = {items = extra}
        stock = stock + Allocation.row({ needed = 0, mode = row.mode, uses = row.uses,
            availableItems = {{items = extra}} }).available
    end
    row.stock = stock
    return row
end

local function describe(row)
    local labels = {}
    local types = row.selectedFullType and {row.selectedFullType} or row.possibleItems or row.items or {}
    local tags = row.selectedFullType and {} or row.possibleTags or row.tags or {}
    if #tags > 0 then
        for index = 1, #tags do labels[#labels + 1] = Icons.displayNameForTag(tags[index]) end
    else
        for index = 1, #types do labels[#labels + 1] = getItemNameFromFullType(types[index]) end
    end
    local label = row.labelKey and getText(row.labelKey) or row.label
    if not label or label == "" then label = table.concat(labels, " / ") end
    return label ~= "" and label or row.id,
        types[1] or (#tags > 0 and ("#" .. tags[1])) or row.id,
        inputKey(row)
end

local function addTotal(state, row, allocated)
    if allocated.needed == 0 then return end
    local key = inputKey(row)
    local kept = row.mode == "keep"
    local totals = (row.role == "tool" or kept) and state.tools or state.materials
    local total = totals[key]
    if not total then
        local label, iconKey = describe(row)
        total = {key = key, iconKey = iconKey, label = label, amount = 0, available = 0, stock = 0, uses = row.mode == "drain" or row.uses ~= nil}
        totals[key] = total
    end
    local stock = row.stock or 0
    total.stock = math.max(total.stock, stock)
    local assigned = math.min(allocated.available, allocated.needed)
    if kept then
        total.amount = math.max(total.amount, allocated.needed)
        total.available = math.max(total.available, assigned)
    else
        total.amount = total.amount + allocated.needed
        total.available = total.available + assigned
    end
end

local function inspectPlacement(state, placement)
    local key = placement.buildableId and table.concat({placement.buildableId, placement.stageId or "",
        placement.variantId or "", placement.materialId or ""}, "|") or placement.stage
    local selection = state.selections[key]
    if not selection then
        local definition, stage = Blueprints.resolvePlacement(placement)
        selection = {definition=definition, stage=stage}
        state.selections[key] = selection
    end
    local definition, stage = selection.definition, selection.stage
    if not definition or not stage then state.allReady = false; state.unknown = true; return end
    local square = getCell and getCell():getGridSquare(placement.x, placement.y, placement.z) or nil
    local status = state.statuses[stage]
    if not status then
        status = Requirements.describe(state.player, definition, stage)
        state.statuses[stage] = status
    end
    local rows, access = {}, status.reason == nil
    for index = 1, #status.rows do
        local row = status.rows[index]
        if row.kind == "input" then
            rows[#rows + 1] = supplyRow(state, row, square, placement.inputChoices)
        else
            if not row.ok and row.needToBeLearned ~= false then access = false end
            local target = row.kind == "skill" and state.skills or state.recipes
            local key = row.name or row.id
            local previous = target[key]
            local required = row.kind ~= "knowledge" or row.needToBeLearned ~= false
            local available = row.kind == "knowledge" and (row.ok and 1 or 0) or (row.available or 0)
            if required and (not previous or (row.needed or 1) > previous.amount) then
                target[key] = {name = row.name, label = row.kind == "skill" and I18n.skill(row.name) or row.name,
                    amount = row.needed or 1, stock = available, available = available}
            end
        end
    end
    local finishes = WallFinishes.fetchRows(state.player, placement.finish, definition, stage)
    for index = 1, #finishes do rows[#rows + 1] = supplyRow(state, finishes[index], square) end
    local own = Allocation.rows(rows, nil, true)
    state.singleReady[placement.id] = access and (own.ok or state.player:isBuildCheat())
    if state.singleReady[placement.id] then state.anyReady = true end
    local allocation = Allocation.rows(rows, state.allocation, true)
    if not access then state.allAccess = false end
    if not access or not allocation.ok then state.allReady = false end
    for index = 1, #allocation.rows do
        local entry = allocation.rows[index]
        addTotal(state, entry.row, entry)
    end
end

function Supplies.step(state)
    if state.phase == "done" then return false end
    if state.phase == "scan" then
        local items, done, incomplete = Queue.stepSupplyScan(state.scan, Supplies.FRAME_BUDGET_MS)
        addItems(state, items)
        state.incomplete = state.incomplete or incomplete
        if done then
            state.scan = nil
            state.phase = "recipes"
            state.ordered = Queue.supplyOrder(state.placements or {})
        end
        return true
    end
    local started, processed = getTimestampMs(), 0
    repeat
        if state.cursor > #state.ordered then break end
        inspectPlacement(state, state.ordered[state.cursor])
        state.cursor = state.cursor + 1
        processed = processed + 1
    until processed >= Supplies.MAX_RECIPES_PER_STEP or getTimestampMs() - started >= Supplies.FRAME_BUDGET_MS
    if state.cursor > #state.ordered then
        state.phase = "done"
        state.checkedAt = getTimestampMs()
        if state.incomplete then
            state.allReady = false
        elseif state.player:isBuildCheat() and state.allAccess and not state.unknown then
            state.allReady = true
        end
    end
    return true
end

return Supplies
