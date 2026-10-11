-- Reserve actual item instances across input rows, in recipe order. Keep-mode
-- tools can be reused; drained units and consumed objects cannot be counted twice.
-- This is a deterministic construction preview, not an alternative-item optimizer.
local Allocation = {}

function Allocation.new()
    return {used = {}, removed = {}, heads = {}}
end

function Allocation.row(row, state, stopAtNeeded)
    state = state or Allocation.new()
    local result = {row = row, needed = math.max(0, row.needed or row.uses or row.amount or 1), available = 0, items = {}}
    local remaining = result.needed
    local seen = {}
    local drain = row.mode == "drain" or row.uses ~= nil
    local keep = row.mode == "keep"
    local groups = row.availableItems or {}
    for groupIndex = 1, #groups do
        if stopAtNeeded and remaining <= 0 then break end
        local group = groups[groupIndex]
        local items = group.items or (group.item and {group.item}) or {}
        -- Matching lists are shared across repeated recipes. Fully reserved
        -- items never become available again within this allocation, so skip
        -- their prefix instead of rescanning an ever longer consumed pile.
        local mode = keep and "keep" or drain and "drain" or "consume"
        state.heads = state.heads or {}
        local heads = state.heads[items]
        if not heads then heads = {}; state.heads[items] = heads end
        local first = stopAtNeeded and (heads[mode] or 1) or 1
        for itemIndex = first, #items do
            if stopAtNeeded and remaining <= 0 then break end
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
            if stopAtNeeded and itemIndex == (heads[mode] or 1) then
                local used = state.used[key] or 0
                local exhausted = state.removed[key]
                if not exhausted and used > 0 then
                    local uses = instanceof(item, "DrainableComboItem") and math.max(0, item:getCurrentUses()) or 1
                    exhausted = mode == "consume" or used >= uses
                end
                if exhausted then heads[mode] = itemIndex + 1 end
            end
        end
    end
    result.ok = remaining <= 0
    return result
end

function Allocation.rows(rows, state, stopAtNeeded)
    state = state or Allocation.new()
    local result = {ok = true, rows = {}, state = state}
    local inputs = {}
    for index = 1, #rows do
        local row = rows[index]
        if row.kind == "input" or row.kind == nil then
            inputs[#inputs + 1] = row
        end
    end
    -- Claim consumed/drained resources first. A kept tool cannot also be the
    -- sole item consumed by another input, regardless of recipe row order.
    for pass = 1, 2 do
        for index = 1, #inputs do
            local row = inputs[index]
            if (row.mode == "keep") == (pass == 2) then
                local allocated = Allocation.row(row, state, stopAtNeeded)
                result.rows[index] = allocated
                if not allocated.ok then result.ok = false end
            end
        end
    end
    return result
end

return Allocation
