local Requirements = require("KnoxBuildworks/Validation/Requirements")
local Allocation = require("KnoxBuildworks/Validation/SupplyAllocation")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local Queue = require("KnoxBuildworks/Planning/BuildQueue")
local I18n = require("KnoxBuildworks/I18n")
local Icons = require("KnoxBuildworks/UI/IconResolver")
local Rules = require("KnoxBuildworks/Admin/BuildableRules")
local Supplies = {}

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
        end
    end
end

function Supplies.new(player, blueprint)
    local snapshot = Requirements.snapshot(player, player:getSquare())
    local state = {player = player, blueprint = blueprint, revision = Requirements.inventoryRevision(),
        placements = blueprint.placements, updated = blueprint.updated, area = blueprint.gatherArea,
        items = {}, seen = {}, cursor = 1, phase = "scan", incomplete = false,
        allocation = Allocation.new(), materials = {}, tools = {}, skills = {}, recipes = {},
        singleReady = {}, allReady = true, allAccess = true, anyReady = false, count = #(blueprint.placements or {}),
        context = contextKey(player), matches = {}}
    addItems(state, snapshot.allItems)
    for _, items in pairs(snapshot.ground or {}) do addItems(state, items) end
    if state.area then
        state.x, state.y = state.area.x1, state.area.y1
    else
        addItems(state, Queue.inspectSupplies(player, nil))
        state.phase = "recipes"
    end
    state.ordered = Queue.supplyOrder(blueprint.placements or {})
    return state
end

function Supplies.current(state, blueprint)
    if not state or state.blueprint ~= blueprint or state.placements ~= blueprint.placements then return false end
    if state.updated ~= blueprint.updated or state.area ~= blueprint.gatherArea
        or state.revision ~= Requirements.inventoryRevision() or state.context ~= contextKey(state.player) then return false end
    return state.phase ~= "done" or getTimestampMs() - (state.checkedAt or 0) < 4000
end

local function inputKey(row)
    local types = row.selectedFullType and {row.selectedFullType} or row.possibleItems or row.items or {}
    local tags = row.selectedFullType and {} or row.possibleTags or row.tags or {}
    return tostring(row.mode) .. "|" .. table.concat(types, ",") .. "|" .. table.concat(tags, ",")
        .. "|" .. table.concat(row.flags or {}, ",")
end

local function supplyRow(state, input)
    local row = {}
    for key, value in pairs(input) do row[key] = value end
    row.needed = row.needed or row.uses or row.amount or 1
    row.kind = "input"
    local key = inputKey(row)
    local matches = state.matches[key]
    if not matches then
        matches = {}
        for index = 1, #state.items do
            local item = state.items[index]
            if Requirements.matchesInput(item, row, row.selectedFullType) then matches[#matches + 1] = item end
        end
        state.matches[key] = matches
    end
    row.availableItems = {{items = matches}}
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
    local label, iconKey, key = describe(row)
    local kept = row.mode == "keep"
    local totals = (row.role == "tool" or kept) and state.tools or state.materials
    local total = totals[key]
    if not total then
        total = {key = key, iconKey = iconKey, label = label, amount = 0, available = 0, stock = 0, uses = row.mode == "drain" or row.uses ~= nil}
        totals[key] = total
    end
    local stock = Allocation.row(row).available
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
    local definition, stage = Blueprints.resolvePlacement(placement)
    if not definition or not stage then state.allReady = false; state.unknown = true; return end
    local status = Requirements.evaluate(state.player, definition, stage, nil, placement.inputChoices)
    local rows, access = {}, status.reason == nil
    for index = 1, #status.rows do
        local row = status.rows[index]
        if row.kind == "input" then
            rows[#rows + 1] = supplyRow(state, row)
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
    for index = 1, #finishes do rows[#rows + 1] = supplyRow(state, finishes[index]) end
    local own = Allocation.rows(rows)
    state.singleReady[placement.id] = access and (own.ok or state.player:isBuildCheat())
    if state.singleReady[placement.id] then state.anyReady = true end
    local allocation = Allocation.rows(rows, state.allocation)
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
        local area = state.area
        local lastY = math.min(area.y2, state.y + 23)
        local items, incomplete = Queue.inspectSupplies(state.player,
            {x1 = state.x, x2 = state.x, y1 = state.y, y2 = lastY, z = area.z})
        addItems(state, items)
        state.incomplete = state.incomplete or incomplete
        state.y = lastY + 1
        if state.y > area.y2 then state.x, state.y = state.x + 1, area.y1 end
        if state.x > area.x2 then state.phase = "recipes" end
        return true
    end
    local limit = math.min(#state.ordered, state.cursor + 2)
    for index = state.cursor, limit do inspectPlacement(state, state.ordered[index]) end
    state.cursor = limit + 1
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
