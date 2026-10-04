-- Reserve actual item instances across input rows, in recipe order. Keep-mode
-- tools can be reused; drained units and consumed objects cannot be counted twice.
-- This is a deterministic construction preview, not an alternative-item optimizer.
local Allocation = {}

function Allocation.new()
    return {used = {}, removed = {}}
end

function Allocation.row(row, state)
    state = state or Allocation.new()
    local result = {row = row, needed = math.max(0, row.needed or row.uses or row.amount or 1), available = 0, items = {}}
    local remaining = result.needed
    local seen = {}
    local drain = row.mode == "drain" or row.uses ~= nil
    local keep = row.mode == "keep"
    local groups = row.availableItems or {}
    for groupIndex = 1, #groups do
        local group = groups[groupIndex]
        local items = group.items or (group.item and {group.item}) or {}
        for itemIndex = 1, #items do
            local item = items[itemIndex]
            local key = tostring(item)
            if not seen[key] and not state.removed[key] then
                seen[key] = true
                local used = state.used[key] or 0
                local uses = instanceof(item, "DrainableComboItem") and math.max(0, item:getCurrentUses()) or 1
                local amount = 0
                if keep then
                    if used < uses or used == 0 then amount = 1 end
                elseif drain then
                    amount = math.max(0, uses - used)
                elseif used == 0 then
                    amount = 1
                end
                local take = math.min(remaining, amount)
                result.available = result.available + amount
                if take > 0 then
                    result.items[#result.items + 1] = {item = item, amount = take}
                    remaining = remaining - take
                    if not keep then
                        if drain then state.used[key] = used + take else state.removed[key] = true end
                    end
                end
            end
        end
    end
    result.ok = remaining <= 0
    return result
end

function Allocation.rows(rows, state)
    state = state or Allocation.new()
    local result = {ok = true, rows = {}, state = state}
    for index = 1, #rows do
        local row = rows[index]
        if row.kind == "input" or row.kind == nil then
            local allocated = Allocation.row(row, state)
            result.rows[#result.rows + 1] = allocated
            if not allocated.ok then result.ok = false end
        end
    end
    return result
end

return Allocation
