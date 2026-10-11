-- A room is a union of edge-connected rectangles. Offsets are relative to
-- room.x/y so moving and exporting a blueprint only changes its anchor.
local RoomShape = { MAX_RECTS = 32, MAX_CELLS = 4096 }

local function integer(value)
    return type(value) == "number" and value == math.floor(value) and math.abs(value) < 10000000
end

local function key(x, y)
    return tostring(x) .. ":" .. tostring(y)
end

function RoomShape.rects(room)
    if type(room.rects) == "table" and #room.rects > 0 then return room.rects end
    return {{ dx = 0, dy = 0, w = room.w or room.width or 1, h = room.h or room.height or 1 }}
end

function RoomShape.cells(room)
    if type(room) ~= "table" or not integer(room.x) or not integer(room.y) then return nil end
    local rects = RoomShape.rects(room)
    if #rects < 1 or #rects > RoomShape.MAX_RECTS then return nil end
    local cells, list, area = {}, {}, 0
    for index = 1, #rects do
        local rect = rects[index]
        local dx, dy = rect.dx, rect.dy
        local w, h = rect.w, rect.h
        if not integer(dx) or not integer(dy) or not integer(w) or not integer(h)
            or w < 1 or h < 1 or w * h > RoomShape.MAX_CELLS then return nil end
        area = area + w * h
        if area > RoomShape.MAX_CELLS then return nil end
        for y = room.y + dy, room.y + dy + h - 1 do
            for x = room.x + dx, room.x + dx + w - 1 do
                local id = key(x, y)
                if not cells[id] then
                    local cell = {x = x, y = y}
                    cells[id] = cell
                    list[#list + 1] = cell
                end
            end
        end
    end
    return cells, list
end

function RoomShape.contains(room, x, y)
    local rects = RoomShape.rects(room)
    for index = 1, #rects do
        local rect = rects[index]
        local left, top = room.x + rect.dx, room.y + rect.dy
        if x >= left and x < left + rect.w and y >= top and y < top + rect.h then return true end
    end
    return false
end

function RoomShape.bounds(room)
    local rects = RoomShape.rects(room)
    local left, top, right, bottom
    for index = 1, #rects do
        local rect = rects[index]
        local x, y = room.x + rect.dx, room.y + rect.dy
        left, top = math.min(left or x, x), math.min(top or y, y)
        right, bottom = math.max(right or x + rect.w, x + rect.w), math.max(bottom or y + rect.h, y + rect.h)
    end
    return left, top, right, bottom
end

function RoomShape.extend(room, rectangle)
    local cells, list = RoomShape.cells(room)
    if not cells or not rectangle or not integer(rectangle.x) or not integer(rectangle.y)
        or not integer(rectangle.w) or not integer(rectangle.h) or rectangle.w < 1 or rectangle.h < 1
        or rectangle.w * rectangle.h > RoomShape.MAX_CELLS then return nil, "invalid_room" end
    local rects = RoomShape.rects(room)
    if #rects >= RoomShape.MAX_RECTS then return nil, "invalid_room" end
    local connects, added = false, 0
    for y = rectangle.y, rectangle.y + rectangle.h - 1 do
        for x = rectangle.x, rectangle.x + rectangle.w - 1 do
            if cells[key(x, y)] then
                connects = true
            else
                added = added + 1
                if cells[key(x - 1, y)] or cells[key(x + 1, y)]
                    or cells[key(x, y - 1)] or cells[key(x, y + 1)] then connects = true end
            end
        end
    end
    if not connects or added == 0 or #list + added > RoomShape.MAX_CELLS then
        return nil, "invalid_room"
    end
    local result = {}
    for index = 1, #rects do
        local rect = rects[index]
        result[index] = {dx = rect.dx, dy = rect.dy, w = rect.w, h = rect.h}
    end
    result[#result + 1] = {
        dx = rectangle.x - room.x, dy = rectangle.y - room.y, w = rectangle.w, h = rectangle.h
    }
    return result
end

-- Rebuild a room's rectangles from a cell set: runs per row, merged with the
-- row below while the runs match. Returns nil when it needs more rectangles
-- than a room may hold.
local function rectsFromCells(room, cells)
    local rows, ys = {}, {}
    for _, cell in pairs(cells) do
        if not rows[cell.y] then rows[cell.y] = {}; ys[#ys + 1] = cell.y end
        rows[cell.y][#rows[cell.y] + 1] = cell.x
    end
    table.sort(ys)
    local open, result = {}, {}
    local function close(entry)
        result[#result + 1] = { dx = entry.x - room.x, dy = entry.y - room.y, w = entry.w, h = entry.h }
    end
    local previousY
    for index = 1, #ys do
        local y = ys[index]
        local xs = rows[y]
        table.sort(xs)
        local runs, start = {}, xs[1]
        for i = 2, #xs + 1 do
            if xs[i] ~= xs[i - 1] + 1 then
                runs[#runs + 1] = { x = start, w = xs[i - 1] - start + 1 }
                start = xs[i]
            end
        end
        local nextOpen = {}
        for r = 1, #runs do
            local run = runs[r]
            local id = run.x .. ":" .. run.w
            local entry = previousY == y - 1 and open[id] or nil
            if entry then
                entry.h = entry.h + 1
                open[id] = nil
            else
                entry = { x = run.x, y = y, w = run.w, h = 1 }
            end
            nextOpen[id] = entry
        end
        for _, entry in pairs(open) do close(entry) end
        open, previousY = nextOpen, y
    end
    for _, entry in pairs(open) do close(entry) end
    if #result > RoomShape.MAX_RECTS then return nil end
    table.sort(result, function(a, b) if a.dy ~= b.dy then return a.dy < b.dy end return a.dx < b.dx end)
    return result
end

-- The reverse of extend: clear a rectangle out of a room. Returns the new
-- rectangles, or an empty table when nothing of the room is left.
function RoomShape.subtract(room, rectangle)
    local cells = RoomShape.cells(room)
    if not cells or not rectangle or not integer(rectangle.x) or not integer(rectangle.y)
        or not integer(rectangle.w) or not integer(rectangle.h) or rectangle.w < 1 or rectangle.h < 1
        or rectangle.w * rectangle.h > RoomShape.MAX_CELLS * 4 then return nil, "invalid_room" end
    local removed, left = 0, {}
    for id, cell in pairs(cells) do
        if cell.x >= rectangle.x and cell.x < rectangle.x + rectangle.w
            and cell.y >= rectangle.y and cell.y < rectangle.y + rectangle.h then
            removed = removed + 1
        else
            left[id] = cell
        end
    end
    if removed == 0 then return nil, "nothing_to_cut" end
    local empty = true
    for _ in pairs(left) do empty = false; break end
    if empty then return {} end
    local rects = rectsFromCells(room, left)
    if not rects then return nil, "room_too_complex" end
    return rects
end

-- Only exposed edges are emitted. Sorting and merging collinear unit edges
-- makes outlines stable for concavities, holes and overlapping rectangles.
function RoomShape.perimeterCells(cells, list)
    if not cells or not list then return {} end
    local horizontal, vertical = {}, {}
    local function edge(rows, fixed, start)
        rows[fixed] = rows[fixed] or {}
        rows[fixed][start] = true
    end
    for index = 1, #list do
        local cell = list[index]
        local x, y = cell.x, cell.y
        if not cells[key(x, y - 1)] then edge(horizontal, y, x) end
        if not cells[key(x, y + 1)] then edge(horizontal, y + 1, x) end
        if not cells[key(x - 1, y)] then edge(vertical, x, y) end
        if not cells[key(x + 1, y)] then edge(vertical, x + 1, y) end
    end
    local segments = {}
    local function collect(rows, isHorizontal)
        local fixedValues = {}
        for fixed in pairs(rows) do fixedValues[#fixedValues + 1] = fixed end
        table.sort(fixedValues)
        for fixedIndex = 1, #fixedValues do
            local fixed = fixedValues[fixedIndex]
            local starts = rows[fixed]
            local values = {}
            for start in pairs(starts) do values[#values + 1] = start end
            table.sort(values)
            local first, last
            for index = 1, #values do
                local value = values[index]
                if first ~= nil and value ~= last + 1 then
                    if isHorizontal then segments[#segments + 1] = {first, fixed, last + 1, fixed}
                    else segments[#segments + 1] = {fixed, first, fixed, last + 1} end
                    first = nil
                end
                first = first or value
                last = value
            end
            if first ~= nil then
                if isHorizontal then segments[#segments + 1] = {first, fixed, last + 1, fixed}
                else segments[#segments + 1] = {fixed, first, fixed, last + 1} end
            end
        end
    end
    collect(horizontal, true)
    collect(vertical, false)
    return segments
end

function RoomShape.perimeter(room)
    local rects = RoomShape.rects(room)
    if #rects == 1 then
        local rect = rects[1]
        if not integer(room.x) or not integer(room.y) or not integer(rect.dx) or not integer(rect.dy)
            or not integer(rect.w) or not integer(rect.h) or rect.w < 1 or rect.h < 1 then return {} end
        local x, y = room.x + rect.dx, room.y + rect.dy
        local right, bottom = x + rect.w, y + rect.h
        return {{x, y, right, y}, {right, y, right, bottom},
            {x, bottom, right, bottom}, {x, y, x, bottom}}
    end
    local cells, list = RoomShape.cells(room)
    return RoomShape.perimeterCells(cells, list)
end

return RoomShape
