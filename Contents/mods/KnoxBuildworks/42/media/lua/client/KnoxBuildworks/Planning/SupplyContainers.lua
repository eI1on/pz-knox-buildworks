-- Discover actual source containers, including bags inside storage or on the floor.
-- Walking uses the outer container; transfers always use the item's own container.
local Containers = {}

function Containers.add(result, seen, container)
    if not container or seen[container] then return end
    seen[container] = true
    result[#result + 1] = container
    local items = container:getItems()
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        if instanceof(item, "InventoryContainer") then
            Containers.add(result, seen, item:getInventory())
        end
    end
end

function Containers.addBag(result, seen, item)
    if item and instanceof(item, "InventoryContainer") then
        Containers.add(result, seen, item:getInventory())
    end
end

function Containers.root(container)
    return container and container.getOutermostContainer and container:getOutermostContainer() or container
end

function Containers.walk(player, container)
    local root = Containers.root(container)
    if not root then return false end
    local current, seen = container, {}
    while current and not seen[current] do
        seen[current] = true
        local bag = current.getContainingItem and current:getContainingItem()
        local world = bag and bag:getWorldItem()
        if world then
            local square = world:getSquare()
            return square ~= nil and luautils.walkAdj(player, square, true)
        end
        current = bag and bag:getContainer() or nil
    end
    -- Some container kinds expose their world parent only at the root.
    local bag = root.getContainingItem and root:getContainingItem()
    local world = bag and bag:getWorldItem()
    if world then return world:getSquare() ~= nil and luautils.walkAdj(player, world:getSquare(), true) end
    return luautils.walkToContainer(root, player:getPlayerNum())
end

-- Reserve capacity for the entire fetch, not each item against the same empty
-- space. Native transfers still perform their own live permission/capacity checks.
function Containers.carryPlan(player, items, mainOnly)
    if #items == 0 then return {} end
    local main = player:getInventory()
    local bagItem = not mainOnly and player:getClothingItem_Back() or nil
    local bag = bagItem and instanceof(bagItem, "InventoryContainer") and bagItem:getInventory() or nil
    local mainLoad, mainLimit = main:getCapacityWeight(), main:getEffectiveCapacity(player)
    local bagLoad = bag and bag:getCapacityWeight() or 0
    local bagLimit = bag and bag:getEffectiveCapacity(player) or 0
    local reduction = bagItem and bag and math.max(0, 1 - bagItem:getWeightReduction() / 100) or 1
    local result, seen = {}, {}
    for index = 1, #items do
        local item = items[index]
        local weight = item:getUnequippedWeight()
        local source = item:getContainer()
        local carried = source and source:isInCharacterInventory(player)
        local allowed = not carried and (not source or source:isRemoveItemAllowed(item))
        if not seen[item] and allowed and mainLoad + weight <= mainLimit then
            local destination
            if bag and bagLoad + weight <= bagLimit and bag:hasRoomFor(player, item)
                and not bag:isInside(item) then
                destination = bag
                bagLoad = bagLoad + weight
                mainLoad = mainLoad + weight * reduction
            elseif main:hasRoomFor(player, item) then
                destination = main
                mainLoad = mainLoad + weight
            end
            if destination then
                result[#result + 1] = { item = item, destination = destination }
                seen[item] = true
            end
        end
    end
    return result
end

function Containers.nearest(player, containers)
    local ordered = {}
    for index = 1, #containers do
        local container = containers[index]
        local square = container:getSquare()
        local distance = math.huge
        if square then
            local dx, dy, dz = square:getX() - player:getX(), square:getY() - player:getY(), square:getZ() - player:getZ()
            distance = dx * dx + dy * dy + dz * dz * 400
        end
        ordered[#ordered + 1] = { container = container, distance = distance, order = index }
    end
    table.sort(ordered, function(a, b)
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.order < b.order
    end)
    local result = {}
    for index = 1, #ordered do result[index] = ordered[index].container end
    return result
end

return Containers
