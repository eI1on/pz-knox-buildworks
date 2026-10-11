-- Roof layouts for any rectilinear footprint.
--
-- The roof surface is a height field sampled every half tile. Height is the
-- L-infinity distance from the nearest eave edge, which for orthogonal
-- footprints is exactly the straight-skeleton roof: hips run at 45 degrees in
-- plan from convex corners, valleys from re-entrant ones, and ridges settle
-- where opposite eaves meet. Gable edges do not seed the field, so a slope runs
-- past them and the edge receives an end wall shaped by the same heights.
--
-- Each roof cell is then matched to a tile by its corner heights (see
-- RoofAtlas). Pieces are named by their real Facing (downhill direction); the
-- buildable face that carries a sprite is looked up, never assumed.
local RoomShape = require("KnoxBuildworks/Planning/RoomShape")
local RoofAtlas = require("KnoxBuildworks/Planning/RoofAtlas")

local RoofPlanner = { MAX_CELLS = 576, MAX_WINGS = 4, MAX_Z = 31 }

local FACES = { W = 1, N = 2, E = 3, S = 4 }
local FACE_NAMES = { "W", "N", "E", "S" }
local OPPOSITE = { W = "E", E = "W", N = "S", S = "N" }
local DIRECTIONS = { W = { -1, 0 }, N = { 0, -1 }, E = { 1, 0 }, S = { 0, 1 } }
local DIRECTION_ORDER = { "W", "N", "E", "S" }
RoofPlanner.FACES = FACES

local function integer(v)
    return type(v) == "number" and v == v and math.abs(v) < 10000000 and v == math.floor(v)
end

local function cellKey(x, y)
    return tostring(x) .. ":" .. tostring(y)
end
RoofPlanner.cellKey = cellKey

local function boundaryKey(x, y, direction)
    return cellKey(x, y) .. ":" .. direction
end
RoofPlanner.boundaryKey = boundaryKey

local function sortCells(list)
    table.sort(list, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)
end

-- ---------------------------------------------------------------------------
-- Profiles: what each roof family can draw.
-- ---------------------------------------------------------------------------

local function stageFaces(stage)
    return stage.cellsByFace or stage.footprints or (stage.geometry or {}).faces or stage.sprites or {}
end

local function faceExists(stage, face)
    return stageFaces(stage)[face] ~= nil
end

-- First sprite of a face: geometry layers when authored, else the plain map.
local function faceSprite(stage, face)
    local geometry = (stage.geometry or {}).faces
    local entry = geometry and geometry[face]
    if type(entry) == "table" then
        local layers = entry.layers or {}
        local layer = layers[1]
        local rows = layer and layer.rows or nil
        local row = rows and rows[1] or nil
        if row and type(row[1]) == "string" then return row[1] end
    end
    local sprites = stage.sprites
    if type(sprites) == "table" and type(sprites[face]) == "string" then return sprites[face] end
    return nil
end
RoofPlanner.faceSprite = faceSprite

local function entry(definition, stage, face, piece)
    -- `layer` mirrors the placement kind Blueprints uses for collisions: a
    -- roof tile authored as a floor shares the floor slot with the deck.
    local kind = (definition.placement or {}).kind
    return { buildableId = definition.id, stageId = stage.id, stage = stage, face = face, piece = piece,
        layer = kind == "floor" and "floor" or nil,
        label = definition.displayName or definition.subcategory or definition.id }
end

-- Authored part names from older definitions, used only for sprites that the
-- atlas does not know (custom tile packs).
local LEGACY_PARTS = {
    hipSE = "outer:SE", hipSW = "outer:SW", hipNE = "outer:NE", hipNW = "outer:NW",
    valleySE = "valley:SE", valleySW = "valley:SW", valleyNE = "valley:NE", valleyNW = "valley:NW",
    ridgeEW = "ridge:EW", ridgeNS = "ridge:NS",
    eaveS = "eave:S", eaveE = "eave:E", eaveSE = "eave:SE", eaveSW = "eave:SW", eaveNE = "eave:NE",
}

local function legacyKey(part)
    local name, step = string.match(part, "^(%a+):?(%d*)$")
    local mapped = name and LEGACY_PARTS[name]
    if not mapped then return nil end
    if step ~= "" then return mapped .. ":" .. step end
    return mapped
end

local function setPiece(profile, key, value)
    local current = profile.pieces[key]
    -- Prefer the plain art over alternates (for example capped ridge tiles).
    if current and not (current.piece and current.piece.alternate) then return end
    profile.pieces[key] = value
end

function RoofPlanner.profiles(definitions, stageFilter)
    local profiles, flats, order = {}, {}, {}
    local function profileFor(family, pitch, label)
        local key = tostring(family) .. ":" .. tostring(pitch)
        local profile = profiles[key]
        if not profile then
            profile = { id = key, family = family, pitch = pitch, label = label or family,
                pieces = {}, details = {}, hidden = {} }
            profiles[key] = profile
            order[#order + 1] = profile
        end
        return profile
    end
    for i = 1, #(definitions or {}) do
        local definition = definitions[i]
        for j = 1, #(definition.stages or {}) do
            local stage = definition.stages[j]
            local roof = stage.roof
            if roof and roof.role ~= "gable" and roof.role ~= "accent"
                and (not stageFilter or stageFilter(definition, stage)) then
                local label = definition.subcategory or roof.family
                if roof.role == "flat" then
                    flats[roof.family] = flats[roof.family] or entry(definition, stage)
                else
                    -- The sheet decides the pitch; authored labels are only a
                    -- fallback for tiles the atlas does not know.
                    local profile
                    for f = 1, 4 do
                        local face = FACE_NAMES[f]
                        local sprite = faceExists(stage, face) and faceSprite(stage, face) or nil
                        local piece = sprite and RoofAtlas.roofPiece(sprite) or nil
                        if piece then
                            profile = profileFor(roof.family, piece.pitch, label)
                            profile.stepsPerLevel = piece.steps
                            profile.maxStep = piece.maxStep
                            if piece.kind == "flat" then
                                flats[roof.family] = flats[roof.family] or entry(definition, stage, face)
                            else
                                setPiece(profile, RoofAtlas.key(piece), entry(definition, stage, face, piece))
                            end
                        end
                    end
                    if not profile then
                        profile = profileFor(roof.family, roof.pitch, label)
                        if roof.role == "slope" and integer(roof.step) then
                            profile.stepsPerLevel = roof.stepsPerLevel or profile.stepsPerLevel
                            for edge, face in pairs(roof.faceByEdge or {}) do
                                if faceExists(stage, face) then
                                    setPiece(profile, "slope:" .. edge .. ":" .. roof.step, entry(definition, stage, face))
                                end
                            end
                        end
                        for face, part in pairs(roof.partsByFace or {}) do
                            local key = legacyKey(part)
                            if key and faceExists(stage, face) then setPiece(profile, key, entry(definition, stage, face)) end
                        end
                    end
                    profile.details[#profile.details + 1] = entry(definition, stage)
                end
            end
        end
    end
    local result = {}
    for i = 1, #order do
        local profile = order[i]
        profile.flat = flats[profile.family]
        local anyPiece = false
        for _ in pairs(profile.pieces) do anyPiece = true; break end
        if anyPiece or #profile.details > 0 then
            -- Shallow sets only have their first rows.
            local steps = profile.stepsPerLevel and (profile.maxStep or profile.stepsPerLevel)
            if steps then
                -- A face is hidden when the set has no tile for it at all:
                -- the isometric camera never sees a steep north or west slope.
                for f = 1, 4 do
                    local face = FACE_NAMES[f]
                    local any = false
                    for step = 1, steps do
                        if profile.pieces["slope:" .. face .. ":" .. step] then any = true; break end
                    end
                    if not any then profile.hidden[face] = true end
                end
                local complete = true
                for step = 1, steps do
                    if not profile.pieces["slope:S:" .. step] or not profile.pieces["slope:E:" .. step] then
                        complete = false
                    end
                end
                profile.complete = complete
            end
            result[#result + 1] = profile
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function RoofPlanner.gables(definitions, stageFilter)
    -- A 45 degree gable run is an 18-tile block: find each family's first tile.
    local bases = {}
    for i = 1, #(definitions or {}) do
        local definition = definitions[i]
        for j = 1, #(definition.stages or {}) do
            local stage = definition.stages[j]
            local roof = stage.roof
            if roof and roof.role == "gable" and roof.pitch == 45 then
                for f = 1, 4 do
                    local sprite = faceSprite(stage, FACE_NAMES[f])
                    local sheet, index = RoofAtlas.split(sprite)
                    if sheet then
                        local key = tostring(roof.family) .. "|" .. sheet
                        if not bases[key] or index < bases[key] then bases[key] = index end
                    end
                end
            end
        end
    end
    local profiles, fills, order = {}, {}, {}
    for i = 1, #(definitions or {}) do
        local d = definitions[i]
        for j = 1, #(d.stages or {}) do
            local s = d.stages[j]
            local roof = s.roof
            if roof and roof.role == "gable" and (not stageFilter or stageFilter(d, s)) then
                if roof.pitch == 0 then
                    fills[roof.family] = fills[roof.family] or {}
                    for face in pairs(roof.partsByFace or {}) do
                        if faceExists(s, face) then fills[roof.family][face] = entry(d, s, face) end
                    end
                else
                    local key = tostring(roof.family) .. ":" .. tostring(roof.pitch)
                    local p = profiles[key]
                    if not p then
                        p = { id = key, family = roof.family, pitch = roof.pitch, label = d.subcategory or roof.family, parts = {} }
                        profiles[key] = p
                        order[#order + 1] = p
                    end
                    for f = 1, 4 do
                        local face = FACE_NAMES[f]
                        if faceExists(s, face) then
                            local sprite = faceSprite(s, face)
                            local sheet = RoofAtlas.split(sprite)
                            local piece = sprite and RoofAtlas.gablePiece(sprite, roof.pitch,
                                sheet and bases[tostring(roof.family) .. "|" .. sheet] or nil) or nil
                            local partKey
                            if piece then
                                partKey = RoofAtlas.gableKey(piece)
                            else
                                local part = (roof.partsByFace or {})[face]
                                local wall = (face == "W" or face == "E") and "W" or "N"
                                if type(part) == "string" then
                                    local lowEnd, step = string.match(part, "^rise(%u):(%d+)$")
                                    local peak = string.match(part, "^peak:(%d+)$")
                                    if lowEnd then partKey = wall .. ":low" .. lowEnd .. ":" .. step
                                    elseif peak then partKey = wall .. ":peak:" .. peak end
                                end
                            end
                            if partKey and not p.parts[partKey] then p.parts[partKey] = entry(d, s, face, piece) end
                        end
                    end
                end
            end
        end
    end
    local result = {}
    for i = 1, #order do
        local p = order[i]
        p.fills = fills[p.family] or {}
        result[#result + 1] = p
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

---Accent trim sets by family: rakes keyed like gable parts per pitch
---("rake:45:W:lowS:1"), eave boards, corners, returns and corner blocks.
function RoofPlanner.accents(definitions, stageFilter)
    local sets, order = {}, {}
    for i = 1, #(definitions or {}) do
        local definition = definitions[i]
        for j = 1, #(definition.stages or {}) do
            local stage = definition.stages[j]
            local roof = stage.roof
            if roof and roof.role == "accent" and (not stageFilter or stageFilter(definition, stage)) then
                local set = sets[roof.family]
                if not set then
                    set = { id = roof.family, family = roof.family, label = definition.subcategory or roof.family, parts = {} }
                    sets[roof.family] = set
                    order[#order + 1] = set
                end
                for f = 1, 4 do
                    local face = FACE_NAMES[f]
                    local sprite = faceExists(stage, face) and faceSprite(stage, face) or nil
                    local piece = sprite and RoofAtlas.accentPiece(sprite) or nil
                    local key = piece and RoofAtlas.accentKey(piece) or nil
                    if key and not set.parts[key] then set.parts[key] = entry(definition, stage, face, piece) end
                end
            end
        end
    end
    local result = {}
    for i = 1, #order do
        result[#result + 1] = order[i]
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

local function placement(e, x, y, z)
    if not e then return nil end
    local face = e.face
    if not face or not faceExists(e.stage, face) then return nil end
    return { buildableId = e.buildableId, stageId = e.stageId, direction = FACES[face], x = x, y = y, z = z }
end

-- ---------------------------------------------------------------------------
-- Footprints
-- ---------------------------------------------------------------------------

local function finishRegion(region)
    sortCells(region.list)
    local first = region.list[1]
    region.minX, region.minY, region.maxX, region.maxY = first.x, first.y, first.x, first.y
    for i = 2, #region.list do
        local c = region.list[i]
        if c.x < region.minX then region.minX = c.x end
        if c.x > region.maxX then region.maxX = c.x end
        if c.y < region.minY then region.minY = c.y end
        if c.y > region.maxY then region.maxY = c.y end
    end
    region.w, region.h = region.maxX - region.minX + 1, region.maxY - region.minY + 1
    region.rectangle = #region.list == region.w * region.h
    return region
end

local function regionFromRect(rect)
    local w, h = rect.w or rect.width, rect.h or rect.height
    local region = { cells = {}, list = {}, roomIds = {}, abut = {}, blocked = {}, z = rect.z or 0 }
    for y = rect.y, rect.y + h - 1 do
        for x = rect.x, rect.x + w - 1 do
            region.cells[cellKey(x, y)] = true
            region.list[#region.list + 1] = { x = x, y = y }
        end
    end
    return finishRegion(region)
end
RoofPlanner.regionFromRect = regionFromRect

-- Merge adjacent rooms on each storey, then remove the squares occupied by
-- the storey directly above. Edges against that upper storey are "abut"
-- edges: the roof leans on its wall instead of ending in an eave.
function RoofPlanner.regionsFromRooms(rooms)
    local levels, levelKeys = {}, {}
    for index = 1, #(rooms or {}) do
        local room = rooms[index]
        local z = room.z or 0
        local _, roomCells = RoomShape.cells(room)
        if integer(z) and roomCells and #roomCells <= RoofPlanner.MAX_CELLS then
            if not levels[z] then levels[z] = {}; levelKeys[#levelKeys + 1] = z end
            for cellIndex = 1, #roomCells do
                local x, y = roomCells[cellIndex].x, roomCells[cellIndex].y
                local key = cellKey(x, y)
                local cell = levels[z][key]
                if not cell then cell = { x = x, y = y, roomIds = {} }; levels[z][key] = cell end
                if room.id then cell.roomIds[room.id] = true end
            end
        end
    end
    table.sort(levelKeys)
    -- Highest storey stacked continuously on each column, for roof ceilings.
    local function topOf(key, z)
        local top = z
        while levels[top + 1] and levels[top + 1][key] do top = top + 1 end
        return top
    end
    local result = {}
    for levelIndex = 1, #levelKeys do
        local z = levelKeys[levelIndex]
        local here, above = levels[z], levels[z + 1] or {}
        local visited = {}
        local sorted = {}
        for _, cell in pairs(here) do
            if not above[cellKey(cell.x, cell.y)] then sorted[#sorted + 1] = cell end
        end
        sortCells(sorted)
        for index = 1, #sorted do
            local start = sorted[index]
            local startKey = cellKey(start.x, start.y)
            if not visited[startKey] then
                local region = { cells = {}, list = {}, roomIds = {}, abut = {}, blocked = above, z = z }
                local queue = { start }
                visited[startKey] = true
                local head = 1
                local ceiling
                while head <= #queue do
                    local cell = queue[head]; head = head + 1
                    region.cells[cellKey(cell.x, cell.y)] = true
                    region.list[#region.list + 1] = { x = cell.x, y = cell.y }
                    for id in pairs(cell.roomIds) do region.roomIds[id] = true end
                    for d = 1, 4 do
                        local direction = DIRECTION_ORDER[d]
                        local delta = DIRECTIONS[direction]
                        local nx, ny = cell.x + delta[1], cell.y + delta[2]
                        local key = cellKey(nx, ny)
                        if here[key] and not above[key] and not visited[key] then
                            visited[key] = true; queue[#queue + 1] = here[key]
                        end
                        if here[key] and above[key] then
                            region.abut[boundaryKey(cell.x, cell.y, direction)] = true
                            local levelsAbove = topOf(key, z) - z
                            if not ceiling or levelsAbove < ceiling then ceiling = levelsAbove end
                        end
                    end
                end
                region.ceiling = ceiling
                result[#result + 1] = finishRegion(region)
            end
        end
    end
    table.sort(result, function(a, b)
        if a.z ~= b.z then return a.z < b.z end
        if a.minY ~= b.minY then return a.minY < b.minY end
        return a.minX < b.minX
    end)
    return result
end

function RoofPlanner.findRegion(rooms, roomId)
    local regions = RoofPlanner.regionsFromRooms(rooms)
    local best
    for index = 1, #regions do
        local region = regions[index]
        if region.roomIds[roomId] and (not best or #region.list > #best.list) then best = region end
    end
    return best, regions
end

local function expandRegion(region, overhang)
    if overhang == 0 then return region end
    -- Regions belong to one immutable room snapshot; reuse their dilation.
    region.expansions = region.expansions or {}
    if region.expansions[overhang] then return region.expansions[overhang] end
    local blocked = region.blocked or {}
    local expanded = { cells = {}, list = {}, roomIds = region.roomIds, blocked = blocked, abut = {},
        z = region.z, ceiling = region.ceiling, source = region, overhang = overhang }
    for index = 1, #region.list do
        local cell = region.list[index]
        for dy = -overhang, overhang do
            for dx = -overhang, overhang do
                local x, y = cell.x + dx, cell.y + dy
                local key = cellKey(x, y)
                if not expanded.cells[key] and not blocked[key] then
                    expanded.cells[key] = true; expanded.list[#expanded.list + 1] = { x = x, y = y }
                    if #expanded.list > RoofPlanner.MAX_CELLS then return nil, "too_large" end
                end
            end
        end
    end
    finishRegion(expanded)
    for index = 1, #expanded.list do
        local cell = expanded.list[index]
        for d = 1, 4 do
            local direction = DIRECTION_ORDER[d]
            local delta = DIRECTIONS[direction]
            if blocked[cellKey(cell.x + delta[1], cell.y + delta[2])] then
                expanded.abut[boundaryKey(cell.x, cell.y, direction)] = true
            end
        end
    end
    region.expansions[overhang] = expanded
    return expanded
end

local function asRegion(footprint)
    if not footprint then return nil end
    if footprint.cells then return footprint end
    local w, h = footprint.w or footprint.width, footprint.h or footprint.height
    if not integer(w) or not integer(h) or not integer(footprint.x) or not integer(footprint.y)
        or w < 1 or h < 1 then
        return nil
    end
    if w * h > RoofPlanner.MAX_CELLS then return nil, "too_large" end
    footprint.regionCache = footprint.regionCache
    if not footprint.regionCache or footprint.regionCache.sig ~= footprint.x .. ":" .. footprint.y .. ":" .. w .. ":" .. h then
        local region = regionFromRect(footprint)
        footprint.regionCache = { sig = footprint.x .. ":" .. footprint.y .. ":" .. w .. ":" .. h, region = region }
    end
    return footprint.regionCache.region
end

-- The world preview outline follows the roof footprint, including overhang.
function RoofPlanner.previewFootprint(footprint, overhang)
    if not footprint or not integer(overhang) or overhang < 0 or overhang > 2 then return nil end
    if footprint.cells then return expandRegion(footprint, overhang) end
    local w, h = footprint.w or footprint.width, footprint.h or footprint.height
    if not integer(w) or not integer(h) or not integer(footprint.x) or not integer(footprint.y) then return nil end
    return { x = footprint.x - overhang, y = footprint.y - overhang, w = w + 2 * overhang, h = h + 2 * overhang }
end

-- Rectangular wings covering the footprint, largest first. Each later run is
-- the maximal rectangle adding the most uncovered tiles.
local function regionRuns(region)
    if region.roofRuns then return region.roofRuns end
    if #region.list > RoofPlanner.MAX_CELLS then return nil, "too_large" end
    -- Maximal rectangles from run lengths on a numeric grid (no string keys).
    local W, H = region.w, region.h
    local inside, spans, candidates = {}, {}, {}
    for index = 1, #region.list do
        local c = region.list[index]
        inside[(c.y - region.minY) * W + (c.x - region.minX)] = true
    end
    for y = 0, H - 1 do
        local run = 0
        for x = W - 1, 0, -1 do
            if inside[y * W + x] then run = run + 1 else run = 0 end
            spans[y * W + x] = run
        end
    end
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            local width = spans[y * W + x]
            local height = 0
            while width > 0 do
                height = height + 1
                local below = y + height < H and spans[(y + height) * W + x] or 0
                if below < width then
                    -- Keep only rectangles that cannot grow left or up either.
                    local growsLeft = x > 0
                    if growsLeft then
                        for row = 0, height - 1 do
                            if spans[(y + row) * W + x - 1] < width + 1 then growsLeft = false; break end
                        end
                    end
                    local growsUp = y > 0
                    if growsUp then
                        for col = 0, width - 1 do
                            if not inside[(y - 1) * W + x + col] then growsUp = false; break end
                        end
                    end
                    if not growsLeft and not growsUp then
                        candidates[#candidates + 1] = { x = region.minX + x, y = region.minY + y, w = width, h = height }
                    end
                end
                width = math.min(width, below)
            end
        end
    end
    -- Greedy cover: each pass takes the candidate adding the most uncovered
    -- tiles. A summed-area table makes every candidate's gain O(1).
    local covered, runs = {}, {}
    local left = #region.list
    while left > 0 do
        local prefix = {}
        for y = 0, region.h do prefix[y * (W + 1)] = 0 end
        for x = 0, W do prefix[x] = 0 end
        for y = 1, region.h do
            local across = 0
            local row, above = y * (W + 1), (y - 1) * (W + 1)
            for x = 1, W do
                if covered[(y - 1) * W + x - 1] then across = across + 1 end
                prefix[row + x] = across + prefix[above + x]
            end
        end
        local best, bestGain
        for index = 1, #candidates do
            local c = candidates[index]
            local x1, y1 = c.x - region.minX, c.y - region.minY
            local x2, y2 = x1 + c.w, y1 + c.h
            local done = prefix[y2 * (W + 1) + x2] - prefix[y1 * (W + 1) + x2]
                - prefix[y2 * (W + 1) + x1] + prefix[y1 * (W + 1) + x1]
            local area = c.w * c.h
            local gain = area - done
            if gain > 0 and (not bestGain or gain > bestGain
                or gain == bestGain and area > best.w * best.h) then
                best = c; bestGain = gain
            end
        end
        if not best then break end
        runs[#runs + 1] = best
        for y = best.y - region.minY, best.y - region.minY + best.h - 1 do
            for x = best.x - region.minX, best.x - region.minX + best.w - 1 do
                local key = y * W + x
                if not covered[key] then covered[key] = true; left = left - 1 end
            end
        end
        if #runs > 16 then return nil, "too_complex" end
    end
    region.roofRuns = runs
    return runs
end

function RoofPlanner.regionRuns(region)
    if not region or not region.cells then return nil, "dimensions" end
    return regionRuns(region)
end

-- ---------------------------------------------------------------------------
-- Edge labels: which boundary edges are eaves, gables or tall walls.
-- ---------------------------------------------------------------------------

-- Exposed edges of a footprint, computed once per region (regions are
-- immutable snapshots) and reused by every labelling and building pass.
local function boundaryOf(region)
    local edges = region.boundaryEdges
    if edges then return edges end
    edges = {}
    for index = 1, #region.list do
        local cell = region.list[index]
        for d = 1, 4 do
            local direction = DIRECTION_ORDER[d]
            local delta = DIRECTIONS[direction]
            if not region.cells[cellKey(cell.x + delta[1], cell.y + delta[2])] then
                edges[#edges + 1] = { cell = cell, direction = direction, key = boundaryKey(cell.x, cell.y, direction) }
            end
        end
    end
    region.boundaryEdges = edges
    return edges
end

local function eachBoundary(region, fn)
    local edges = boundaryOf(region)
    for index = 1, #edges do
        local edge = edges[index]
        fn(edge.cell, edge.direction, edge.key)
    end
end

local function wholeRun(region)
    return { x = region.minX, y = region.minY, w = region.w, h = region.h }
end

local function ridgeAlongX(run, main)
    if run.w ~= run.h then return run.w > run.h end
    if not main then return true end
    local dx = math.abs(run.x + run.w / 2 - main.x - main.w / 2)
    local dy = math.abs(run.y + run.h / 2 - main.y - main.h / 2)
    return dx >= dy
end

-- Owner wing of every cell and each wing's ridge axis. A square wing has no
-- long axis, so its ridge leaves the wing it is attached to.
local function wingAxes(region, runs)
    if region.wingAxesCache and region.wingAxesCache.runs == runs then
        return region.wingAxesCache.owners, region.wingAxesCache.axes
    end
    local owners = {}
    for index = 1, #runs do
        local run = runs[index]
        for y = run.y, run.y + run.h - 1 do
            for x = run.x, run.x + run.w - 1 do
                local key = cellKey(x, y)
                if not owners[key] then owners[key] = index end
            end
        end
    end
    local seams = {}
    for index = 1, #region.list do
        local cell = region.list[index]
        local owner = owners[cellKey(cell.x, cell.y)]
        if owner and owner > 1 then
            local seam = seams[owner] or { x = 0, y = 0 }
            seams[owner] = seam
            for d = 1, 4 do
                local direction = DIRECTION_ORDER[d]
                local delta = DIRECTIONS[direction]
                local neighbour = owners[cellKey(cell.x + delta[1], cell.y + delta[2])]
                if neighbour and neighbour < owner then
                    -- Joined across a west/east edge: the ridge runs along x.
                    local axis = (direction == "W" or direction == "E") and "x" or "y"
                    seam[axis] = seam[axis] + 1
                end
            end
        end
    end
    local axes = {}
    for index = 1, #runs do
        local run, seam = runs[index], seams[index]
        if run.w == run.h and seam and seam.x ~= seam.y then axes[index] = seam.x > seam.y
        else axes[index] = ridgeAlongX(run, index > 1 and runs[1] or nil) end
    end
    region.wingAxesCache = { runs = runs, owners = owners, axes = axes }
    return owners, axes
end

-- styles[i] is "gable" or "hip" for wing i; flip[i] turns that wing's ridge.
local function wingLabels(region, runs, styles, flip)
    local owners, axes = wingAxes(region, runs)
    local labels = {}
    eachBoundary(region, function(cell, direction, key)
        if (region.abut or {})[key] then return end
        local owner = owners[cellKey(cell.x, cell.y)] or 1
        local alongX = axes[owner]
        if flip and flip[owner] then alongX = not alongX end
        local isEnd = alongX and (direction == "W" or direction == "E")
            or not alongX and (direction == "N" or direction == "S")
        if isEnd and styles[owner] == "gable" then labels[key] = "gable" end
    end)
    return labels, axes
end

-- Single-slope roof: low edges face `face`, the opposite side is a tall wall.
-- Only footprints whose low boundary is one straight line qualify.
local function shedLabels(region, face)
    local labels = {}
    local ok = true
    eachBoundary(region, function(cell, direction, key)
        if direction == face then
            local extreme = (face == "W" and cell.x == region.minX) or (face == "E" and cell.x == region.maxX)
                or (face == "N" and cell.y == region.minY) or (face == "S" and cell.y == region.maxY)
            if not extreme then ok = false end
            if (region.abut or {})[key] then ok = false end
        elseif not (region.abut or {})[key] then
            labels[key] = direction == OPPOSITE[face] and "wall" or "gable"
        end
    end)
    if not ok then return nil end
    return labels
end

-- ---------------------------------------------------------------------------
-- Height field on a half-tile grid.
-- ---------------------------------------------------------------------------

local function newGrid(roof)
    if roof.fieldGrid then return roof.fieldGrid end
    local cw, ch = roof.w, roof.h
    local W, H = cw * 2 + 1, ch * 2 + 1
    -- Quarter-tile squares between half-grid points; a move is allowed only
    -- across quarters that belong to a roof cell.
    local quarter = {}
    for index = 1, #roof.list do
        local c = roof.list[index]
        local qu, qv = (c.x - roof.minX) * 2, (c.y - roof.minY) * 2
        local i = qv * W + qu
        quarter[i] = true; quarter[i + 1] = true; quarter[i + W] = true; quarter[i + W + 1] = true
    end
    local grid = { minX = roof.minX, minY = roof.minY, cw = cw, ch = ch, W = W, H = H, roof = roof,
        quarter = quarter }
    roof.fieldGrid = grid
    return grid
end

local function idx(grid, u, v)
    return v * grid.W + u
end

-- Distance (in half steps) from the eave edges, walking only over the roof.
-- Seeding is immediate; the flood runs in slices through `fieldStep`.
local function fieldStart(grid, labels)
    local roof = grid.roof
    local W = grid.W
    local field = { dist = {}, queue = {}, head = 1, tail = 0, grid = grid }
    local dist, queue = field.dist, field.queue
    local function seed(u, v)
        local i = v * W + u
        if dist[i] == nil then dist[i] = 0; field.tail = field.tail + 1; queue[field.tail] = i end
    end
    local seeded = false
    local abut = roof.abut or {}
    eachBoundary(roof, function(cell, direction, key)
        if abut[key] or labels[key] then return end
        seeded = true
        local u, v = (cell.x - grid.minX) * 2, (cell.y - grid.minY) * 2
        if direction == "N" then seed(u, v); seed(u + 1, v); seed(u + 2, v)
        elseif direction == "S" then seed(u, v + 2); seed(u + 1, v + 2); seed(u + 2, v + 2)
        elseif direction == "W" then seed(u, v); seed(u, v + 1); seed(u, v + 2)
        else seed(u + 2, v); seed(u + 2, v + 1); seed(u + 2, v + 2) end
    end)
    if not seeded then return nil end
    return field
end

-- Advance the flood by at most `budget` points; true when finished.
local function fieldStep(field, budget)
    local grid = field.grid
    local W, H, quarter = grid.W, grid.H, grid.quarter
    local dist, queue = field.dist, field.queue
    local head, tail = field.head, field.tail
    local stop = head + budget
    while head <= tail and head < stop do
        local i = queue[head]; head = head + 1
        local u = i % W
        local v = (i - u) / W
        local nd = dist[i] + 1
        local left, right, up, down = u > 0, u < W - 1, v > 0, v < H - 1
        -- quarters around the point: a = NW, b = NE, c = SW, d = SE
        local a = left and up and quarter[(v - 1) * W + u - 1]
        local b = right and up and quarter[(v - 1) * W + u]
        local c = left and down and quarter[v * W + u - 1]
        local d = right and down and quarter[v * W + u]
        local n
        if right and (b or d) then n = i + 1; if dist[n] == nil or dist[n] > nd then dist[n] = nd; tail = tail + 1; queue[tail] = n end end
        if left and (a or c) then n = i - 1; if dist[n] == nil or dist[n] > nd then dist[n] = nd; tail = tail + 1; queue[tail] = n end end
        if down and (c or d) then n = i + W; if dist[n] == nil or dist[n] > nd then dist[n] = nd; tail = tail + 1; queue[tail] = n end end
        if up and (a or b) then n = i - W; if dist[n] == nil or dist[n] > nd then dist[n] = nd; tail = tail + 1; queue[tail] = n end end
        if d then n = i + W + 1; if dist[n] == nil or dist[n] > nd then dist[n] = nd; tail = tail + 1; queue[tail] = n end end
        if b then n = i - W + 1; if dist[n] == nil or dist[n] > nd then dist[n] = nd; tail = tail + 1; queue[tail] = n end end
        if c then n = i + W - 1; if dist[n] == nil or dist[n] > nd then dist[n] = nd; tail = tail + 1; queue[tail] = n end end
        if a then n = i - W - 1; if dist[n] == nil or dist[n] > nd then dist[n] = nd; tail = tail + 1; queue[tail] = n end end
    end
    field.head, field.tail = head, tail
    -- The queue only grows; drop the processed prefix now and then.
    return head > tail
end

-- A single plane rising away from the `face` edge, filled `rows` at a time.
local function planarRows(grid, face, dist, fromRow, rows)
    local W, H = grid.W, grid.H
    local stop = math.min(H - 1, fromRow + rows - 1)
    for v = fromRow, stop do
        local base = v * W
        for u = 0, W - 1 do
            local d
            if face == "S" then d = H - 1 - v
            elseif face == "N" then d = v
            elseif face == "E" then d = W - 1 - u
            else d = u end
            dist[base + u] = d
        end
    end
    return stop + 1
end

-- Heights in steps at a cell's corners, edge midpoints and centre, written
-- into `h` (reused for every cell of a layout).
local function sample(grid, dist, cx, cy, cap, h)
    local W = grid.W
    local base = cy * 2 * W + cx * 2
    local function at(offset)
        local d = dist[base + offset]
        if d == nil then return nil end
        local value = d / 2
        if cap and value > cap then value = cap end
        return value
    end
    h.nw, h.ne, h.se, h.sw, h.c = at(0), at(2), at(2 * W + 2), at(2 * W), at(W + 1)
    h.n, h.s, h.w, h.e = at(1), at(2 * W + 1), at(W), at(W + 2)
    return h
end

-- Classify a cell by its sampled heights. Returns a piece description:
-- { kind, facing|corner|axis, step (global, from 1), base (steps) }
local function classify(h)
    if not h.nw or not h.ne or not h.se or not h.sw or not h.c then return nil end
    local b = math.min(h.nw, h.ne, h.se, h.sw)
    local NW, NE, SE, SW = h.nw > b, h.ne > b, h.se > b, h.sw > b
    local count = (NW and 1 or 0) + (NE and 1 or 0) + (SE and 1 or 0) + (SW and 1 or 0)
    local step = math.floor(b) + 1
    if count == 0 then
        if h.c > b then
            local wHigh, eHigh = h.w > b, h.e > b
            local nHigh, sHigh = h.n > b, h.s > b
            local alongX = (wHigh or eHigh) and not (nHigh or sHigh)
            local alongY = (nHigh or sHigh) and not (wHigh or eHigh)
            if not alongX and not alongY and (wHigh and eHigh) then alongX = true end
            if not alongX and not alongY and (nHigh and sHigh) then alongY = true end
            -- Two odd-span ridges meeting over a valley (an L of ridges).
            if not alongX and not alongY and not (wHigh and eHigh) and not (nHigh and sHigh)
                and (wHigh or eHigh) and (nHigh or sHigh) then
                local corner = (sHigh and "S" or "N") .. (eHigh and "E" or "W")
                return { kind = "junction", corner = corner, step = step, base = b }
            end
            if alongX then return { kind = "ridge", axis = "EW", step = step, base = b } end
            if alongY then return { kind = "ridge", axis = "NS", step = step, base = b } end
            return { kind = "peak", step = step, base = b }
        end
        return { kind = "flat", base = b, step = step }
    end
    if count == 2 then
        if NW and NE then return { kind = "slope", facing = "S", step = step, base = b } end
        if NW and SW then return { kind = "slope", facing = "E", step = step, base = b } end
        if SW and SE then return { kind = "slope", facing = "N", step = step, base = b } end
        if NE and SE then return { kind = "slope", facing = "W", step = step, base = b } end
        -- Two hips crossing in one tile: follow the lowest edge midpoint.
        local low, facing = h.s, "S"
        if h.e < low then low, facing = h.e, "E" end
        if h.n < low then low, facing = h.n, "N" end
        if h.w < low then facing = "W" end
        return { kind = "slope", facing = facing, step = step, base = b, saddle = true }
    end
    if count == 1 then
        local corner = NW and "SE" or NE and "SW" or SE and "NW" or "NE"
        return { kind = "outer", corner = corner, step = step, base = b }
    end
    local corner = not SE and "SE" or not SW and "SW" or not NE and "NE" or "NW"
    return { kind = "valley", corner = corner, step = step, base = b }
end

-- Tiles that can stand in for a missing piece. Every substitute draws the
-- same visible surface (a 45 degree south-west valley shows only its south
-- slope), or at least never a surface that is not there.
local SUBSTITUTES = {
    ["valley:SW"] = { "slope:S" }, ["valley:NE"] = { "slope:E" },
    ["valley:NW"] = {}, ["outer:NW"] = {},
    ["outer:SW"] = { "slope:S" }, ["outer:NE"] = { "slope:E" },
    ["valley:SE"] = { "slope:S" },
}

-- ---------------------------------------------------------------------------
-- Building one layout
-- ---------------------------------------------------------------------------

local idHashes = {}
local function idHash(id)
    local h = idHashes[id]
    if h then return h end
    h = 0
    for i = 1, #id do h = (h * 31 + string.byte(id, i)) % 1000003 end
    idHashes[id] = h
    return h
end

local function newOutput()
    local out = { list = {}, used = {}, info = {}, metrics = { pieces = 0, roof = 0, hidden = 0, approx = 0,
        missing = 0, gables = 0, fills = 0, eaves = 0, deck = 0, levels = 0, ridges = 0, shifted = 0 },
        hashA = 0, hashB = 0 }
    function out.put(e, x, y, z, layer)
        if z < -32 or z > RoofPlanner.MAX_Z then return "height_limit" end
        local item = placement(e, x, y, z)
        if not item then return "missing_face" end
        if e.layer == "floor" then layer = "floor" end
        local key = cellKey(x, y) .. ":" .. z .. ":" .. (layer or "roof")
        if out.used[key] then return "plan_overlap" end
        out.used[key] = true
        out.list[#out.list + 1] = item
        out.metrics.pieces = out.metrics.pieces + 1
        -- Order-independent fingerprint, so identical roofs are listed once.
        local h = (idHash(item.buildableId) * 7 + item.direction * 131 + x * 8191 + y * 127 + z * 524287)
            % 2147483647
        out.hashA = (out.hashA + h) % 2147483647
        out.hashB = (out.hashB + (h * h) % 2147483647) % 2147483647
        return nil
    end
    function out.free(x, y, z, layer)
        return not out.used[cellKey(x, y) .. ":" .. z .. ":" .. (layer or "roof")]
    end
    return out
end

local function lookup(profile, kind, key, step)
    local pieces = profile.pieces or {}
    local direct = pieces[kind .. ":" .. key .. ":" .. step]
    if direct then return direct, false end
    local subs = SUBSTITUTES[kind .. ":" .. key]
    for i = 1, #(subs or {}) do
        local e = pieces[subs[i] .. ":" .. step]
        if e then return e, true end
    end
    return nil, false
end

local function placeRidge(profile, out, cell, piece, baseZ, steps)
    local pieces = profile.pieces or {}
    -- Sets with a ridge tile for every step (30 degree) draw it in place.
    local level = math.floor((piece.step - 1) / steps)
    local exact = pieces["ridge:" .. piece.axis .. ":" .. (piece.step - level * steps)]
    if exact then return out.put(exact, cell.x, cell.y, baseZ + level, "roof"), "exact" end
    local native = pieces["ridge:" .. piece.axis]
    if not native then return nil, "none" end
    local nativeStep = (native.piece and native.piece.step) or 2
    -- A tile placed one square south-east draws one step lower, and one
    -- storey up draws `steps` higher, so (+d, +d, +storeys) lands on the same
    -- screen spot. Forward-and-up shifts come first: the game draws a higher
    -- storey after this one, so end walls and slopes in between can never
    -- cover the ridge (a shift back by one square is hidden by the gable).
    -- Squares on the roof are preferred over ones beyond its edge.
    local need = piece.step - nativeStep
    local order = { 0, 1, 2, 3, 4, 5, -1, -2, -3 }
    for pass = 1, 2 do
        for i = 1, #order do
            local d = order[i]
            local lift = need + d
            if lift >= 0 and lift % steps == 0 then
                local z = baseZ + lift / steps
                local x, y = cell.x + d, cell.y + d
                local onRoof = out.roof.cells[cellKey(x, y)] == true
                if (pass == 2 or onRoof) and z <= RoofPlanner.MAX_Z and out.free(x, y, z, "roof")
                    and (d == 0 or not out.reserved[cellKey(x, y) .. ":" .. z]) then
                    local error = out.put(native, x, y, z, "roof")
                    if not error then
                        if d ~= 0 then out.metrics.shifted = out.metrics.shifted + 1 end
                        if lift >= steps and baseZ + lift / steps > out.top then out.top = baseZ + lift / steps end
                        return nil, "shifted"
                    end
                end
            end
        end
    end
    return nil, "none"
end

local function placePeak(profile, out, cell, piece, baseZ, steps)
    local level = math.floor((piece.step - 1) / steps)
    local localStep = piece.step - level * steps
    local e = (profile.pieces or {})["peak:" .. localStep]
    if e then return out.put(e, cell.x, cell.y, baseZ + level, "roof"), true end
    return nil, false
end

-- Roof heights (in steps) at the north/west end, middle and south/east end
-- of one cell edge.
local function edgeHeights(grid, dist, cap, cell, direction)
    local function heightAt(u, v)
        local d = dist[idx(grid, u, v)]
        if d == nil then return nil end
        local h = d / 2
        if cap and h > cap then h = cap end
        return h
    end
    local u, v = (cell.x - grid.minX) * 2, (cell.y - grid.minY) * 2
    if direction == "W" then return heightAt(u, v), heightAt(u, v + 1), heightAt(u, v + 2) end
    if direction == "E" then return heightAt(u + 2, v), heightAt(u + 2, v + 1), heightAt(u + 2, v + 2) end
    if direction == "N" then return heightAt(u, v), heightAt(u + 1, v), heightAt(u + 2, v) end
    return heightAt(u, v + 2), heightAt(u + 1, v + 2), heightAt(u + 2, v + 2)
end

-- Gable piece for an edge with heights a (north/west end), m, b: the part key
-- ("W:lowS:2", "N:peak:1", nil for a level top) and the full storeys below it.
local function edgeShape(wall, a, m, b, steps)
    local lo = math.min(a, b)
    if a ~= b then
        local lowEnd
        if wall == "W" then lowEnd = a < b and "N" or "S" else lowEnd = a < b and "W" or "E" end
        local levels = math.floor(lo / steps)
        return wall .. ":low" .. lowEnd .. ":" .. (math.floor(lo) - levels * steps + 1), levels
    elseif m > a then
        local levels = math.floor(lo / steps)
        return wall .. ":peak:" .. (math.floor(lo) - levels * steps + 1), levels
    end
    -- Level top (a capped crown or the high side of a lean-to).
    return nil, math.ceil(lo / steps)
end

-- Gable end walls along the building's own wall line. With an overhang the
-- roof edge is further out, so heights come from the roof field at the wall.
local function placeGables(gable, out, region, roof, grid, dist, labels, cap, baseZ, steps, options)
    -- The helper may dress each end-wall piece (variant, paint, plaster).
    local decorate = options and options.decorateGable
    if not gable then return nil end
    local overhang = roof.overhang or 0
    local function roofLabel(cell, direction)
        local delta = DIRECTIONS[direction]
        local x, y = cell.x + delta[1] * overhang, cell.y + delta[2] * overhang
        return labels[boundaryKey(x, y, direction)]
    end
    local failure
    eachBoundary(region, function(cell, direction, key)
        if failure or (region.abut or {})[key] then return end
        local label = roofLabel(cell, direction)
        if label ~= "gable" and label ~= "wall" then return end
        local wall = (direction == "W" or direction == "E") and "W" or "N"
        local a, m, b = edgeHeights(grid, dist, cap, cell, direction)
        if not a or not b or not m then return end
        local wx = cell.x + (direction == "E" and 1 or 0)
        local wy = cell.y + (direction == "S" and 1 or 0)
        local part, levels = edgeShape(wall, a, m, b, steps)
        local fill = gable.fills and gable.fills[wall]
        for level = 0, levels - 1 do
            if not fill then failure = "missing_gable"; return end
            local error = out.put(fill, wx, wy, baseZ + level, "wall" .. wall)
            if error then failure = error; return end
            if decorate then decorate(out.list[#out.list], fill) end
            out.metrics.fills = out.metrics.fills + 1
        end
        if part then
            local e = gable.parts and gable.parts[part]
            if not e then failure = "missing_gable"; return end
            local error = out.put(e, wx, wy, baseZ + levels, "wall" .. wall)
            if error then failure = error; return end
            if decorate then decorate(out.list[#out.list], e) end
            out.metrics.gables = out.metrics.gables + 1
        end
    end)
    return failure
end

-- Roof accent trim, placed as the vanilla map does (measured from the shipped
-- lotpacks): only what the camera sees. Rakes go on the gable edges facing
-- east or south, at roof height on the gable wall's square; everything along
-- the eave hangs one level below the roof on the square just outside it:
-- fascia under the south and east eaves, a corner piece in inner corners, a
-- corner block on south-east outside corners, under the front end of each
-- rake an end return (45 degree) or a corner block (30 degree), and for 30
-- degree sets a rake foot under each eave end.
-- Accents are decoration: a missing piece or an occupied slot is skipped.
local function placeAccents(accent, out, roof, grid, dist, labels, cap, baseZ, steps, pitch)
    local parts = accent.parts or {}
    local function put(key, x, y, z, layer)
        local e = parts[key]
        if not e then
            out.metrics.accentMissing = (out.metrics.accentMissing or 0) + 1
            return
        end
        if not out.put(e, x, y, z, layer) then out.metrics.accents = (out.metrics.accents or 0) + 1 end
    end
    local abut = roof.abut or {}
    -- Shallow rows start 1/6 storey up: their eave board is the low one, on
    -- the roof's own level (the vanilla map always pairs them).
    local shallow = pitch == "shallow"
    local below = shallow and baseZ or baseZ - 1
    local height = shallow and "low" or "top"
    if grid and dist then
        eachBoundary(roof, function(cell, direction, key)
            if (direction ~= "E" and direction ~= "S") or abut[key] or labels[key] ~= "gable" then return end
            local wall = direction == "E" and "W" or "N"
            local a, m, b = edgeHeights(grid, dist, cap, cell, direction)
            if not a or not b or not m then return end
            local wx = cell.x + (direction == "E" and 1 or 0)
            local wy = cell.y + (direction == "S" and 1 or 0)
            local part, levels = edgeShape(wall, a, m, b, steps)
            if part then put("rake:" .. pitch .. ":" .. part, wx, wy, baseZ + levels, "rake" .. wall) end
            local footA = "foot:" .. pitch .. ":" .. wall .. ":low" .. (wall == "W" and "N" or "W")
            local footB = "foot:" .. pitch .. ":" .. wall .. ":low" .. (wall == "W" and "S" or "E")
            if shallow then return end
            if a == 0 and parts[footA] then put(footA, wx, wy, below, "foot" .. wall .. "A") end
            if b == 0 then
                if parts[footB] then put(footB, wx, wy, below, "foot" .. wall .. "B") end
                local cx, cy = wx + (wall == "N" and 1 or 0), wy + (wall == "W" and 1 or 0)
                if pitch == 30 then put("block:top", cx, cy, below, "fasciaBlock")
                else put("return:" .. wall .. ":top", cx, cy, below, "fasciaReturn" .. wall) end
            end
        end)
    end
    local boards, order, blocks = {}, {}, {}
    local function mark(x, y, bit)
        local key = cellKey(x, y)
        local target = boards[key]
        if not target then target = { x = x, y = y }; boards[key] = target; order[#order + 1] = target end
        target[bit] = true
    end
    local function eave(cell, direction)
        local delta = DIRECTIONS[direction]
        if roof.cells[cellKey(cell.x + delta[1], cell.y + delta[2])] then return false end
        local key = boundaryKey(cell.x, cell.y, direction)
        return not abut[key] and not labels[key]
    end
    for index = 1, #roof.list do
        local cell = roof.list[index]
        local s, e = eave(cell, "S"), eave(cell, "E")
        if s then mark(cell.x, cell.y + 1, "n") end
        if e then mark(cell.x + 1, cell.y, "w") end
        if s and e then blocks[#blocks + 1] = { x = cell.x + 1, y = cell.y + 1 } end
    end
    sortCells(order)
    for index = 1, #order do
        local c = order[index]
        if c.n and c.w then put("fasciaCorner:" .. height, c.x, c.y, below, "fasciaNW")
        elseif c.n then put("fascia:N:" .. height, c.x, c.y, below, "fasciaN")
        else put("fascia:W:" .. height, c.x, c.y, below, "fasciaW") end
    end
    if shallow then return end
    sortCells(blocks)
    for index = 1, #blocks do put("block:top", blocks[index].x, blocks[index].y, below, "fasciaBlock") end
end

-- Trim hung one level below the visible south and east roof edges.
local function placeEaves(profile, out, roof, labels, baseZ)
    local pieces = profile.pieces or {}
    if not pieces["eave:S"] or not pieces["eave:E"] then return "missing_eaves" end
    local claims, order = {}, {}
    local function claim(x, y, bit)
        local key = cellKey(x, y)
        if roof.cells[key] then return end
        local target = claims[key]
        if not target then target = { x = x, y = y }; claims[key] = target; order[#order + 1] = target end
        target[bit] = true
    end
    local function eave(x, y, direction)
        local delta = DIRECTIONS[direction]
        if roof.cells[cellKey(x + delta[1], y + delta[2])] then return false end
        local key = boundaryKey(x, y, direction)
        return not (roof.abut or {})[key] and not labels[key]
    end
    for index = 1, #roof.list do
        local cell = roof.list[index]
        local x, y = cell.x, cell.y
        local s, e, w, n = eave(x, y, "S"), eave(x, y, "E"), eave(x, y, "W"), eave(x, y, "N")
        if s then claim(x, y + 1, "s") end
        if e then claim(x + 1, y, "e") end
        if s and e then claim(x + 1, y + 1, "se") end
        if s and w then claim(x - 1, y + 1, "sw") end
        if e and n then claim(x + 1, y - 1, "ne") end
    end
    sortCells(order)
    for index = 1, #order do
        local c = order[index]
        local part
        if c.s and c.e then part = pieces["eave:valley"] or pieces["eave:SE"]
        elseif c.s then part = pieces["eave:S"]
        elseif c.e then part = pieces["eave:E"]
        elseif c.se then part = pieces["eave:SE"]
        elseif c.sw then part = pieces["eave:SW"]
        elseif c.ne then part = pieces["eave:NE"] end
        if part then
            local error = out.put(part, c.x, c.y, baseZ - 1, "eave")
            if error then return error end
            out.metrics.eaves = out.metrics.eaves + 1
        end
    end
    return nil
end

local function placeFlat(profile, out, x, y, z, layer)
    if not profile.flat then return "missing_flat" end
    local e = profile.flat
    if not e.face then
        e = { buildableId = e.buildableId, stageId = e.stageId, stage = e.stage,
            face = faceExists(e.stage, "W") and "W" or "N" }
        profile.flat = e
    end
    return out.put(e, x, y, z, layer or "floor")
end

-- One layout is built as a resumable job so the game never waits on a large
-- footprint: phases run in slices of `budget` work units (about one cell, or
-- a few flood points, per unit).
local function newJob(profile, region, roof, spec, options)
    local out = newOutput()
    out.roof, out.top = roof, options.z
    return { profile = profile, region = region, roof = roof, spec = spec, options = options,
        baseZ = options.z, steps = profile.stepsPerLevel, out = out, phase = "start", index = 0,
        deferred = {}, needsDeck = false, top = 0, h = {} }
end

local function fail(job, reason)
    job.phase, job.reason = "failed", reason
    return true, 0
end

local function cellPhase(job, cell)
    local profile, out, steps, baseZ, cap = job.profile, job.out, job.steps, job.baseZ, job.cap
    local grid = job.grid
    local h = sample(grid, job.dist, cell.x - grid.minX, cell.y - grid.minY, cap, job.h)
    local piece = classify(h)
    if not piece then return "unsupported_shape" end
    local info = { kind = piece.kind, facing = piece.facing, corner = piece.corner, axis = piece.axis,
        h = h.c, base = piece.base, nw = h.nw, ne = h.ne, se = h.se, sw = h.sw }
    out.info[cellKey(cell.x, cell.y)] = info
    if h.c > job.top then job.top = h.c end
    local level = math.floor((piece.step - 1) / steps)
    local localStep = piece.step - level * steps
    if piece.kind == "junction" then
        local e = (profile.pieces or {})["innerHalf:" .. piece.corner .. ":" .. localStep]
        if e then
            job.needsDeck = true
            out.metrics.roof = out.metrics.roof + 1
            return out.put(e, cell.x, cell.y, baseZ + level, "roof")
        end
        -- No junction tile in this set: stand in as before.
        piece.kind = "peak"
    end
    if piece.kind == "flat" then
        local rise = piece.base - math.floor(piece.base / steps) * steps
        local raisedFlat = rise > 0 and math.abs(rise - math.floor(rise + 0.5)) < 0.01
            and (profile.pieces or {})["raisedFlat:" .. math.floor(rise + 0.5)] or nil
        if raisedFlat then
            job.needsDeck = true
            return out.put(raisedFlat, cell.x, cell.y, baseZ + math.floor(piece.base / steps), "floor")
        end
        if piece.base > 0 or cap == 0 then
            local flatLevel = math.floor(piece.base / steps + 0.5)
            if math.abs(piece.base - flatLevel * steps) > 0.01 then out.metrics.approx = out.metrics.approx + 1 end
            if flatLevel > 0 then
                local error = placeFlat(profile, out, cell.x, cell.y, baseZ + flatLevel, "floor")
                if error then return error end
            else
                job.needsDeck = true
            end
        else
            job.needsDeck = true
        end
    elseif piece.kind == "ridge" or piece.kind == "peak" then
        job.deferred[#job.deferred + 1] = { cell = cell, piece = piece }
    else
        local key = piece.kind == "slope" and piece.facing or piece.corner
        local hiddenFace = piece.kind == "slope" and (profile.hidden or {})[piece.facing]
        local e, approx = lookup(profile, piece.kind, key, localStep)
        if e then
            local error = out.put(e, cell.x, cell.y, baseZ + level, "roof")
            if error then return error end
            out.metrics.roof = out.metrics.roof + 1
            if approx then out.metrics.approx = out.metrics.approx + 1; info.approx = true end
            if piece.saddle then out.metrics.approx = out.metrics.approx + 1 end
        else
            job.needsDeck = true
            local visible = piece.kind == "slope" and not hiddenFace
                or piece.kind == "outer" and piece.corner == "SE"
                or piece.kind == "valley" and piece.corner == "SE"
            if visible then out.metrics.missing = out.metrics.missing + 1; info.missing = true
            else out.metrics.hidden = out.metrics.hidden + 1; info.hidden = true end
        end
    end
    return nil
end

local function ridgePhase(job, item)
    local profile, out, steps, baseZ = job.profile, job.out, job.steps, job.baseZ
    local error, how
    if item.piece.kind == "peak" then
        local ok
        error, ok = placePeak(profile, out, item.cell, item.piece, baseZ, steps)
        if not ok then
            -- No pyramid top in this set: a ridge half stands in.
            error, how = placeRidge(profile, out, item.cell,
                { kind = "ridge", axis = "EW", step = item.piece.step }, baseZ, steps)
            if how ~= "none" then
                out.metrics.apexStandIn = true
                out.metrics.approx = out.metrics.approx + 1
                out.info[cellKey(item.cell.x, item.cell.y)].approx = true
            end
        end
    else
        error, how = placeRidge(profile, out, item.cell, item.piece, baseZ, steps)
    end
    if error then return error end
    out.metrics.ridges = out.metrics.ridges + 1
    if how == "none" then
        out.metrics.ridgeGaps = (out.metrics.ridgeGaps or 0) + 1
        out.metrics.approx = out.metrics.approx + 1
        out.info[cellKey(item.cell.x, item.cell.y)].approx = true
    end
    -- Steep ridge halves let rain through; a deck below keeps it dry.
    job.needsDeck = true
    return nil
end

---Advance a layout job; returns true when it finished (job.out or job.reason).
local function runJob(job, budget)
    local profile, roof, spec, out = job.profile, job.roof, job.spec, job.out
    local list = roof.list
    while budget > 0 do
        local phase = job.phase
        if phase == "start" then
            if spec.kind == "flat" then
                job.phase = "flat"
            else
                if not integer(job.steps) or job.steps < 1 then return fail(job, "missing_slope") end
                job.grid = newGrid(roof)
                job.cap = spec.cap and spec.cap * job.steps or nil
                if spec.field == "planar" then
                    job.dist, job.row = {}, 0
                    job.phase = "planar"
                else
                    job.field = fieldStart(job.grid, spec.labels)
                    if not job.field then return fail(job, "unsupported_shape") end
                    job.dist = job.field.dist
                    job.phase = "field"
                end
                budget = budget - 8
            end
        elseif phase == "planar" then
            local rows = math.max(1, math.floor(budget * 2 / job.grid.W))
            job.row = planarRows(job.grid, spec.face, job.dist, job.row, rows)
            budget = budget - rows * job.grid.W / 2
            if job.row >= job.grid.H then job.phase, job.index = "cells", 0 end
        elseif phase == "flat" then
            local stop = math.min(#list, job.index + math.max(1, math.floor(budget)))
            for index = job.index + 1, stop do
                local c = list[index]
                local error = placeFlat(profile, out, c.x, c.y, job.baseZ, "floor")
                if error then return fail(job, error) end
                out.info[cellKey(c.x, c.y)] = { kind = "flat", h = 0, base = 0, nw = 0, ne = 0, se = 0, sw = 0 }
            end
            budget = budget - (stop - job.index)
            job.index = stop
            if stop >= #list then
                out.metrics.levels = 1
                if job.options.accents then
                    placeAccents(job.options.accents, out, roof, nil, nil, spec.labels or {}, nil, job.baseZ, 1, profile.pitch)
                end
                job.phase = "done"
            end
        elseif phase == "field" then
            local points = math.max(1, math.floor(budget * 4))
            if fieldStep(job.field, points) then job.phase = "cells"; job.index = 0; job.field = nil end
            budget = budget - points / 4
        elseif phase == "cells" then
            local stop = math.min(#list, job.index + math.max(1, math.floor(budget)))
            for index = job.index + 1, stop do
                local error = cellPhase(job, list[index])
                if error then return fail(job, error) end
            end
            budget = budget - (stop - job.index)
            job.index = stop
            if stop >= #list then
                -- Ridge cells keep their own square; shifted halves may not land on one.
                out.reserved = {}
                for i = 1, #job.deferred do
                    local item = job.deferred[i]
                    local level = math.floor((item.piece.step - 1) / job.steps)
                    out.reserved[cellKey(item.cell.x, item.cell.y) .. ":" .. (job.baseZ + level)] = true
                end
                job.phase, job.index = "ridges", 0
            end
        elseif phase == "ridges" then
            local stop = math.min(#job.deferred, job.index + math.max(1, math.floor(budget)))
            for index = job.index + 1, stop do
                local error = ridgePhase(job, job.deferred[index])
                if error then return fail(job, error) end
            end
            budget = budget - (stop - job.index) - 1
            job.index = stop
            if stop >= #job.deferred then
                out.metrics.levels = math.max(1, math.ceil(job.top / job.steps))
                if profile.maxStep and job.top > profile.maxStep then return fail(job, "shallow_span") end
                if (out.metrics.ridgeGaps or 0) > 0 and (not profile.flat or profile.maxStep) then
                    return fail(job, "odd_gable")
                end
                -- Ceiling deck: rain-proof floor on the roof's first level.
                local deck = job.options.ceiling
                if deck == nil then deck = job.needsDeck or (profile.hidden or {}).N == true end
                if not deck and job.needsDeck then out.metrics.leaks = true end
                job.phase, job.index = deck and "deck" or "walls", 0
            end
        elseif phase == "deck" then
            local stop = math.min(#list, job.index + math.max(1, math.floor(budget)))
            for index = job.index + 1, stop do
                local c = list[index]
                if out.free(c.x, c.y, job.baseZ, "floor") then
                    local error = placeFlat(profile, out, c.x, c.y, job.baseZ, "floor")
                    if error then return fail(job, error) end
                    out.metrics.deck = out.metrics.deck + 1
                end
            end
            budget = budget - (stop - job.index)
            job.index = stop
            if stop >= #list then job.phase = "walls" end
        elseif phase == "walls" then
            local options = job.options
            if options.gable then
                if options.gable.pitch ~= profile.pitch then return fail(job, "missing_gable") end
                local error = placeGables(options.gable, out, job.region, roof, job.grid, job.dist,
                    spec.labels or {}, job.cap, job.baseZ, job.steps, options)
                if error then return fail(job, error) end
            end
            if options.eaves then
                local error = placeEaves(profile, out, roof, spec.labels or {}, job.baseZ)
                if error then return fail(job, error) end
            end
            if options.accents then
                placeAccents(options.accents, out, roof, job.grid, job.dist, spec.labels or {}, job.cap,
                    job.baseZ, job.steps, profile.pitch)
            end
            budget = budget - 40
            job.phase = "done"
        else
            return true, budget
        end
    end
    return job.phase == "done" or job.phase == "failed", budget
end

---Build one layout in one go. `spec` = { kind, labels, field = "skeleton"|"planar",
---face, cap (levels) }. Returns output table or nil, reason.
local function build(profile, region, roof, spec, options)
    local job = newJob(profile, region, roof, spec, options)
    while not runJob(job, 100000) do end
    if job.phase == "failed" then return nil, job.reason end
    return job.out
end

-- ---------------------------------------------------------------------------
-- Layout candidates and ranking
-- ---------------------------------------------------------------------------

local KIND_NAMES = {
    flat = "Flat", shed = "Shed", gable = "Gable", hip = "Hip", crossGable = "CrossGable",
    hipWings = "HipWings", gableHipWings = "GableHipWings", mixed = "MixedWings",
}
RoofPlanner.KIND_NAMES = KIND_NAMES

local function signature(roof, labels, extra)
    local parts = {}
    eachBoundary(roof, function(_, _, key)
        local label = labels and labels[key]
        parts[#parts + 1] = label and string.sub(label, 1, 1) or "e"
    end)
    return table.concat(parts) .. "|" .. tostring(extra)
end

-- Shape-aware priors: how a builder would usually roof this footprint.
local function prior(spec, roof, runs)
    local aspect = math.max(roof.w, roof.h) / math.min(roof.w, roof.h)
    local short = math.min(roof.w, roof.h)
    local kind = spec.kind
    if kind == "flat" then return short >= 14 and 0.55 or 0.3 end
    if roof.rectangle then
        if kind == "gable" then
            local along = spec.alongX == (roof.w >= roof.h)
            if aspect >= 1.25 then return along and 1.0 or 0.5 end
            return 0.8
        end
        if kind == "hip" then return aspect < 1.25 and 0.95 or 0.78 end
        if kind == "shed" then return (short <= 4 and 0.6 or 0.35) + (spec.leans and 0.5 or 0) end
    else
        local wings = runs and #runs or 1
        -- Every extra wing adds a ridge and two valleys to build and keep dry.
        local wingCost = 0.03 * math.max(0, wings - 2)
        if kind == "crossGable" then return 0.98 - wingCost end
        if kind == "hip" then return 0.92 end
        if kind == "hipWings" then return 0.9 - wingCost * 0.5 end
        if kind == "gableHipWings" then return 0.84 - wingCost end
        if kind == "mixed" then return 0.7 - wingCost end
        if kind == "shed" then return 0.3 + (spec.leans and 0.5 or 0) end
    end
    return 0.5
end

local function score(spec, out, roof, runs)
    local m = out.metrics
    local cells = #roof.list
    local value = prior(spec, roof, runs)
    value = value - 0.6 * m.missing / cells - 0.25 * m.approx / cells
    if m.levels > 2 then value = value - 0.08 * (m.levels - 2) end
    if spec.cap and spec.kind ~= "flat" then value = value - 0.05 end
    if m.leaks then value = value - 0.2 end
    if (m.ridgeGaps or 0) > 0 then value = value - 0.15 end
    -- The stand-in apex of an odd-size 45 degree hip shows a small step.
    if m.apexStandIn then value = value - 0.2 end
    -- Mostly one-tile-wide footprints turn into a field of ridge caps; a
    -- flat roof reads better there.
    local ridgeShare = (m.ridges or 0) / cells
    if spec.kind ~= "flat" and ridgeShare > 0.25 then value = value - 2 * (ridgeShare - 0.25) end
    value = value - 0.002 * m.shifted
    return value
end

---Start an incremental layout search. Only cheap checks run here; call
---RoofPlanner.step(ctx, budget) every frame until it returns true, then
---RoofPlanner.results(ctx). `accept` is either function(placements) -> reason,
---or { each = function(placement) -> reason } checked a slice at a time.
---@return table|nil ctx, string|nil reason
function RoofPlanner.prepare(profile, footprint, options, accept)
    options = options or {}
    if not profile then return nil, "no_profile" end
    local region, reason = asRegion(footprint)
    if not region then return nil, reason or "dimensions" end
    if #region.list == 0 then return nil, "dimensions" end
    if #region.list > RoofPlanner.MAX_CELLS then return nil, "too_large" end
    local overhang = options.overhang or 0
    if not integer(overhang) or overhang < 0 or overhang > 2 then return nil, "dimensions" end
    local roof
    roof, reason = expandRegion(region, overhang)
    if not roof then return nil, reason end
    local z = options.z or ((region.z or 0) + 1)
    if not integer(z) then return nil, "dimensions" end
    local steps = profile.stepsPerLevel
    local pitched = integer(steps) and steps >= 1 and profile.complete ~= false
        and (profile.pieces or {})["slope:S:1"] ~= nil
    local rise = options.riseLevels
    if rise ~= nil and (not integer(rise) or rise < 1 or rise > 31) then return nil, "dimensions" end
    -- Height limits: the world top, and the storey a lean-to touches. Slopes
    -- may fill `limit` storeys; a flat crown sits on top of `crownLimit`.
    local limit = RoofPlanner.MAX_Z - z + 1
    if region.ceiling then limit = math.min(limit, region.ceiling) end
    local crownLimit = math.min(limit, RoofPlanner.MAX_Z - z, 4)
    return { profile = profile, region = region, roof = roof, z = z, rise = rise, limit = limit,
        crownLimit = crownLimit, specs = {}, index = 0, layouts = {}, pitched = pitched, options = options,
        accept = accept, phase = "plan", fingerprints = {},
        hasEaves = (profile.pieces or {})["eave:S"] ~= nil and (profile.pieces or {})["eave:E"] ~= nil }
end

-- Candidate layouts for the footprint (run as the first step).
local function planSpecs(ctx)
    local profile, roof, options = ctx.profile, ctx.roof, ctx.options
    local specs, seen = ctx.specs, {}
    local function add(spec)
        local key = spec.kind .. ":" .. signature(roof, spec.labels, (spec.field or "") .. tostring(spec.face))
        if seen[key] then return end
        seen[key] = true
        specs[#specs + 1] = spec
    end
    if ctx.pitched and options.kind ~= "flat" then
        if roof.rectangle then
            -- A slope needs two tiles of span; a one-tile strip only takes a
            -- lean-to along it or a flat roof.
            local natural = roof.w >= roof.h
            local whole = { wholeRun(roof) }
            if (natural and roof.h or roof.w) >= 2 then
                add({ kind = "gable", labels = wingLabels(roof, whole, { "gable" }, nil), alongX = natural })
            end
            if (natural and roof.w or roof.h) >= 2 then
                add({ kind = "gable", labels = wingLabels(roof, whole, { "gable" }, { true }), alongX = not natural })
            end
            if math.min(roof.w, roof.h) >= 2 then add({ kind = "hip", labels = {} }) end
        else
            local runs = regionRuns(roof)
            ctx.runs = runs
            local wings = runs and #runs or 0
            if runs and wings <= RoofPlanner.MAX_WINGS then
                -- Each wing ends in gables or hips. Two wings try every mix;
                -- more wings keep the four combinations a builder would pick.
                local masks = {}
                local all = 2 ^ wings - 1
                if wings <= 2 then
                    for mask = 0, all do masks[#masks + 1] = mask end
                else
                    masks = { all, 0, all - 1, 1 }
                end
                for m = 1, #masks do
                    local mask = masks[m]
                    local styles, gables = {}, 0
                    for i = 1, wings do
                        local bit = math.floor(mask / 2 ^ (i - 1)) % 2
                        styles[i] = bit == 1 and "gable" or "hip"
                        if bit == 1 then gables = gables + 1 end
                    end
                    local kind
                    if gables == 0 then kind = "hip"
                    elseif gables == wings then kind = "crossGable"
                    elseif styles[1] == "hip" and gables == wings - 1 then kind = "hipWings"
                    elseif styles[1] == "gable" and gables == 1 then kind = "gableHipWings"
                    else kind = "mixed" end
                    add({ kind = kind, labels = wingLabels(roof, runs, styles, nil), styles = styles })
                end
            else
                add({ kind = "hip", labels = {} })
            end
        end
        local faces = { "S", "E", "N", "W" }
        for i = 1, 4 do
            local face = faces[i]
            if not (profile.hidden or {})[face] then
                local labels = shedLabels(roof, face)
                if labels then
                    local leans = false
                    for key in pairs(roof.abut or {}) do
                        if string.sub(key, -1) == OPPOSITE[face] then leans = true end
                    end
                    add({ kind = "shed", labels = labels, field = "planar", face = face, leans = leans })
                end
            end
        end
    end
    if profile.flat then add({ kind = "flat" }) end
    if options.kind then
        -- An explicit request keeps only matching layouts.
        local kept = {}
        for i = 1, #specs do
            local sp = specs[i]
            local same = sp.kind == options.kind
                or options.kind == "gable" and sp.kind == "crossGable"
                or options.kind == "crossGable" and sp.kind == "gable"
            if same and options.kind == "shed" and options.direction then same = sp.face == options.direction end
            if same and sp.kind == "gable" and options.direction and roof.rectangle then
                same = sp.alongX == (options.direction == "N" or options.direction == "S")
            end
            if same then kept[#kept + 1] = sp end
        end
        ctx.specs = kept
    end
end

local function runOptionsFor(ctx, spec)
    local options = ctx.options
    -- Eave trim is optional decoration: sets without it (30 degree) still
    -- get every pitched layout.
    return { z = ctx.z, ceiling = options.ceiling,
        eaves = spec.kind ~= "flat" and options.eaves and ctx.hasEaves or false,
        gable = spec.kind ~= "flat" and spec.kind ~= "hip" and options.gable or nil,
        decorateGable = options.decorateGable, accents = options.accents }
end

local function startSpec(ctx, spec)
    local capLevels = spec.kind ~= "flat" and (spec.cap or ctx.rise) or nil
    -- A requested rise never pushes the crown through the storey above.
    if capLevels and ctx.crownLimit >= 1 and capLevels > ctx.crownLimit then capLevels = ctx.crownLimit end
    spec.cap = capLevels
    ctx.current = { spec = spec, job = newJob(ctx.profile, ctx.region, ctx.roof, spec, runOptionsFor(ctx, spec)),
        stage = "build" }
end

local function finishSpec(ctx)
    local current = ctx.current
    local spec, built = current.spec, current.job.out
    -- Two specs can describe the same roof (a gable against an upper
    -- storey is a lean-to); keep the first, which carries the better prior.
    local key = #built.list .. ":" .. built.hashA .. ":" .. built.hashB
    if ctx.fingerprints[key] then return end
    ctx.fingerprints[key] = true
    local kind, face = spec.kind, spec.face
    -- Name the roof by its eaves: one eave side is a lean-to, whatever the
    -- spec that produced it.
    if kind ~= "flat" then
        local faces, count, only = {}, 0, nil
        eachBoundary(ctx.roof, function(_, direction, bkey)
            if not (ctx.roof.abut or {})[bkey] and not (spec.labels or {})[bkey] and not faces[direction] then
                faces[direction] = true; count = count + 1; only = direction
            end
        end)
        if count == 1 then kind, face = "shed", only end
    end
    local leans = false
    if kind == "shed" and face then
        for akey in pairs(ctx.roof.abut or {}) do
            if string.sub(akey, -1) == OPPOSITE[face] then leans = true end
        end
    end
    local layout = { kind = kind, spec = spec, placements = built.list, metrics = built.metrics,
        info = built.info, cap = spec.cap, roof = ctx.roof, region = ctx.region, face = face,
        alongX = spec.alongX, styles = spec.styles, labels = spec.labels, leans = leans }
    layout.score = score(spec, built, ctx.roof, ctx.runs)
    current.layout = layout
    current.stage = "accept"
    current.index = 0
end

local function publish(ctx)
    local current = ctx.current
    local layout, spec = current.layout, current.spec
    if layout.reason then layout.score = layout.score - 10 end
    ctx.layouts[#ctx.layouts + 1] = layout
    -- A roof taller than two storeys also gets a flat-crowned variant.
    if spec.kind ~= "flat" and not spec.cap and not ctx.rise and layout.metrics.levels > 2 and ctx.profile.flat
        and not spec.crownOf and ctx.crownLimit >= 2 then
        local crown = {}
        for k, v in pairs(spec) do crown[k] = v end
        crown.cap = 2
        crown.crownOf = spec
        ctx.specs[#ctx.specs + 1] = crown
    end
end

---Do up to `budget` units of work (default: everything). Returns true once
---every layout is done. One unit is roughly one roof cell.
function RoofPlanner.step(ctx, budget)
    if not ctx then return true end
    budget = budget or 1000000000
    while budget > 0 do
        local current = ctx.current
        if ctx.phase == "plan" then
            planSpecs(ctx)
            ctx.phase = "run"
            budget = budget - #ctx.roof.list
        elseif not current then
            if ctx.index >= #ctx.specs then return true end
            ctx.index = ctx.index + 1
            startSpec(ctx, ctx.specs[ctx.index])
        elseif current.stage == "build" then
            local job = current.job
            local finished
            finished, budget = runJob(job, budget)
            if finished then
                local spec = current.spec
                local built = job.phase == "done" and job.out or nil
                local why = job.reason
                -- Too tall for the world or for the storey it leans on: crown it flat.
                local tooTall = built and spec.kind ~= "flat" and built.metrics.levels > ctx.limit
                    or not built and why == "height_limit"
                if tooTall and not spec.cap and ctx.profile.flat and spec.kind ~= "flat" and ctx.crownLimit >= 1
                    and not current.retried then
                    spec.cap = ctx.crownLimit
                    current.job = newJob(ctx.profile, ctx.region, ctx.roof, spec, runOptionsFor(ctx, spec))
                    current.retried = true
                elseif not built or (spec.kind ~= "flat" and built.metrics.levels > ctx.limit) then
                    ctx.lastReason = built and "height_limit" or why
                    ctx.current = nil
                else
                    finishSpec(ctx)
                    if ctx.current.stage ~= "accept" then ctx.current = nil end
                end
            end
        elseif current.stage == "accept" then
            local layout, accept = current.layout, ctx.accept
            if type(accept) == "function" then
                layout.reason = accept(layout.placements)
                budget = budget - #layout.placements
            elseif type(accept) == "table" and accept.each then
                local list = layout.placements
                if current.index == 0 and accept.start then accept.start(layout) end
                local stop = math.min(#list, current.index + math.max(1, math.floor(budget * 4)))
                for i = current.index + 1, stop do
                    local why = accept.each(list[i])
                    if why then layout.reason = why; stop = #list; break end
                end
                budget = budget - (stop - current.index) / 4
                current.index = stop
                if stop < #list then return false end
            end
            publish(ctx)
            ctx.current = nil
        end
    end
    return ctx.phase ~= "plan" and not ctx.current and ctx.index >= #ctx.specs
end

---Layouts built so far, best first.
function RoofPlanner.results(ctx)
    if not ctx then return {}, "no_profile" end
    local layouts = {}
    for i = 1, #ctx.layouts do layouts[i] = ctx.layouts[i] end
    table.sort(layouts, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return #a.placements < #b.placements
    end)
    if #layouts == 0 and ctx.phase ~= "plan" and not ctx.current and ctx.index >= #ctx.specs then
        return layouts, ctx.lastReason or (ctx.pitched and "unsupported_shape" or "missing_slope")
    end
    return layouts, nil
end

---All layouts that fit this footprint, best first.
---@return table[] layouts { kind, spec, placements, metrics, score, info, reason }
function RoofPlanner.suggest(profile, footprint, options, accept)
    local ctx, reason = RoofPlanner.prepare(profile, footprint, options, accept)
    if not ctx then return {}, reason end
    while not RoofPlanner.step(ctx) do end
    return RoofPlanner.results(ctx)
end

---Placements for one requested layout (compatibility entry point).
function RoofPlanner.generate(profile, footprint, options)
    options = options or {}
    if not profile or not footprint then return nil, "no_profile" end
    local kind = options.kind or "flat"
    if kind ~= "flat" and not profile.stepsPerLevel and not profile.flat then return nil, "manual_only" end
    if kind ~= "flat" and not profile.stepsPerLevel and #(profile.details or {}) > 0 then return nil, "manual_only" end
    if kind == "flat" and options.eaves then return nil, "eaves_shape" end
    if kind == "flat" and options.riseLevels then return nil, "rise_shape" end
    if options.gable and (kind == "flat" or kind == "shed" or kind == "hip") then return nil, "gable_shape" end
    local overhang = options.overhang or 0
    if not integer(overhang) or overhang < 0 or overhang > 2 then return nil, "dimensions" end
    if options.z ~= nil and not integer(options.z) then return nil, "dimensions" end
    local region, reason = asRegion(footprint)
    if not region then return nil, reason or "dimensions" end
    local roof = expandRegion(region, overhang)
    if not roof then return nil, "too_large" end
    if kind == "flat" and not profile.flat then return nil, "missing_flat" end
    local pieces = profile.pieces or {}
    if kind == "hip" and roof.rectangle and math.min(roof.w, roof.h) < 2 then return nil, "dimensions" end
    if kind ~= "flat" and not pieces["slope:S:1"] and not pieces["slope:E:1"] then
        if not profile.stepsPerLevel then return nil, "missing_slope" end
        -- A set without visible south slopes can still form sheds facing a
        -- face it has.
        if kind ~= "shed" then return nil, "missing_face" end
    end
    if options.eaves and kind ~= "flat" and (not pieces["eave:S"] or not pieces["eave:E"]) then
        return nil, "missing_eaves"
    end
    if kind == "shed" and options.direction and (profile.hidden or {})[options.direction] then
        return nil, "missing_face"
    end
    local z = options.z or ((region.z or 0) + 1)
    local spec
    if kind == "flat" then spec = { kind = "flat" }
    elseif kind == "shed" then
        local face = options.direction or "S"
        local labels = shedLabels(roof, face)
        if not labels then return nil, "unsupported_shape" end
        spec = { kind = "shed", labels = labels, field = "planar", face = face }
    elseif kind == "hip" then spec = { kind = "hip", labels = {} }
    elseif kind == "gable" and roof.rectangle then
        -- Slopes falling north and south meet in a ridge running east-west;
        -- slopes falling west and east (the default) one running north-south.
        local natural = roof.w >= roof.h
        local alongX = options.direction == "N" or options.direction == "S"
        if (alongX and roof.h or roof.w) < 2 then return nil, "dimensions" end
        spec = { kind = "gable", alongX = alongX,
            labels = wingLabels(roof, { wholeRun(roof) }, { "gable" }, { alongX ~= natural }) }
    else
        local runs = regionRuns(roof)
        if not runs then return nil, "too_complex" end
        if #runs > RoofPlanner.MAX_WINGS then return nil, "too_complex" end
        local styles = {}
        for i = 1, #runs do
            if kind == "hipWings" then styles[i] = i == 1 and "hip" or "gable"
            elseif kind == "gableHipWings" then styles[i] = i == 1 and "gable" or "hip"
            else styles[i] = "gable" end
        end
        spec = { kind = kind, labels = wingLabels(roof, runs, styles, nil) }
    end
    spec.cap = kind ~= "flat" and options.riseLevels or nil
    local built, why = build(profile, region, roof, spec, { z = z, ceiling = options.ceiling,
        eaves = options.eaves, gable = options.gable, decorateGable = options.decorateGable,
        accents = options.accents })
    if not built then return nil, why end
    if #built.list == 0 then return nil, "missing_face" end
    -- An explicit request must not leave an open ridge for a set without
    -- odd-span ridge tiles; the suggestion list ranks such layouts down instead.
    if (built.metrics.ridgeGaps or 0) > 0 then return nil, "odd_gable" end
    if (built.metrics.missing or 0) > 0 then return nil, "missing_face" end
    return built.list, nil, built
end

---Best layout for the footprint (compatibility entry point).
---@return table|nil selected options, table|nil placements, string|nil reason
function RoofPlanner.autoLayout(profile, footprint, options, accept)
    if not profile or not footprint then return nil, nil, "no_profile" end
    options = options or {}
    local request = {}
    for k, v in pairs(options) do request[k] = v end
    request.kind = nil
    local layouts, reason = RoofPlanner.suggest(profile, footprint, request, accept)
    for i = 1, #layouts do
        local layout = layouts[i]
        if not layout.reason then
            local selected = { kind = layout.kind, direction = layout.face or (layout.alongX ~= nil and (layout.alongX and "N" or "W")) or "S",
                z = options.z, overhang = options.overhang or 0, riseLevels = layout.cap,
                ceiling = options.ceiling, eaves = layout.kind ~= "flat" and options.eaves or false,
                gable = layout.kind ~= "flat" and layout.kind ~= "hip" and options.gable or nil,
                accents = options.accents, layout = layout }
            return selected, layout.placements, nil
        end
        reason = layout.reason
    end
    return nil, nil, reason or "unsupported_shape"
end

-- Kept for callers that ask whether a valley can be drawn: with substitute
-- pieces every valley orientation now resolves.
function RoofPlanner.unsupportedValley(region, parts)
    return false
end

-- Diagram data for one layout: per cell height share and piece kind.
function RoofPlanner.diagram(layout)
    if not layout or not layout.roof then return nil end
    local cells, top = {}, 0
    for key, info in pairs(layout.info or {}) do
        if (info.h or 0) > top then top = info.h end
        cells[key] = info
    end
    return { roof = layout.roof, cells = cells, top = top, labels = layout.labels or {} }
end

return RoofPlanner
