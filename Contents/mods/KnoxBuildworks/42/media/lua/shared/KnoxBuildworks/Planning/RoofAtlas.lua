-- Geometry of the vanilla roof and gable tile sheets.
--
-- Every roof sprite is described by what it really draws, never by the
-- buildable face (W/N/E/S) it happens to be authored under:
--   slope  facing  - the downhill direction. A slope "facing S" is low on its
--                    south edge and its surface points south, exactly like the
--                    tile property Facing=S on furniture means "front points S".
--   outer  corner  - convex hip corner; "SE" is low on its south and east edges.
--   valley corner  - concave corner; "SE" is low only at its south-east corner.
--   ridge  axis    - odd-span ridge cell; "EW" carries a ridge running east-west.
--   peak           - odd-span pyramid top.
--   eave   kind    - trim hung one level below the roof (45 degree sets only).
-- Steps count from 1 within a storey: a 45 degree set rises 3 steps per storey,
-- a 30 degree set 6. Sheet layouts follow the official BuildingEd tile tables
-- and were checked against the joins listed in media/seams.txt.
local RoofAtlas = {}

local function split(spriteName)
    if type(spriteName) ~= "string" then return nil, nil end
    local sheet, index = string.match(spriteName, "^(.-)_(%d+)$")
    if not sheet then return nil, nil end
    return sheet, tonumber(index)
end
RoofAtlas.split = split

local function part(kind, key, step, extra)
    local entry = { kind = kind, step = step }
    if kind == "slope" then entry.facing = key
    elseif kind == "outer" or kind == "valley" then entry.corner = key
    elseif kind == "ridge" then entry.axis = key
    elseif kind == "eave" then entry.eave = key end
    if extra then
        for k, v in pairs(extra) do entry[k] = v end
    end
    return entry
end

-- One 32-tile block of a 45 degree sheet (roofs_01..05 hold two blocks).
local STEEP = {}
for k = 1, 3 do
    STEEP[k - 1] = part("slope", "S", k)
    STEEP[6 - k] = part("slope", "E", k)
    STEEP[7 + k] = part("outer", "SE", k)
    STEEP[10 + k] = part("valley", "SE", k)
    STEEP[23 + k] = part("outer", "SW", k)
    STEEP[30 - k] = part("outer", "NE", k)
end
-- The odd-span ridge halves are drawn one step above their own level (they
-- are the "one and a half" pieces); the planner shifts them diagonally.
STEEP[14] = part("ridge", "NS", 2, { native = true })
STEEP[15] = part("ridge", "EW", 2, { native = true })
STEEP[6] = part("eave", "S")
STEEP[7] = part("eave", "E")
STEEP[20] = part("eave", "valley")
STEEP[21] = part("eave", "SE")
STEEP[30] = part("eave", "SW")
STEEP[31] = part("eave", "NE")
STEEP[22] = part("flat", nil)
STEEP[23] = part("flat", nil)

-- Sheet-wide extras outside the two blocks (first block only). 64..69 are
-- the ends of half-step ridges (seams.txt joins 66 to the end of 70/71), not
-- pyramid tops, so they stay manual details.
local STEEP_EXTRA = {
    [70] = part("ridge", "NS", 2, { native = true, alternate = true }),
    [71] = part("ridge", "EW", 2, { native = true, alternate = true }),
}

-- A 30 degree sheet: all four slopes are visible, so every face has a tile.
local LOW = {}
for k = 1, 6 do
    LOW[k - 1] = part("slope", "S", k)
    LOW[14 - k] = part("slope", "E", k)
    LOW[15 + k] = part("slope", "W", k)
    LOW[30 - k] = part("slope", "N", k)
    LOW[31 + k] = part("valley", "SE", k)
    LOW[47 + k] = part("valley", "NW", k)
    LOW[46 - k] = part("valley", "NE", k)
    LOW[62 - k] = part("valley", "SW", k)
    LOW[63 + k] = part("outer", "SE", k)
    LOW[78 - k] = part("outer", "NE", k)
    LOW[94 - k] = part("outer", "NW", k)
    LOW[79 + k] = part("outer", "SW", k)
    LOW[95 + k] = part("ridge", "EW", k)
    LOW[110 - k] = part("ridge", "NS", k)
    LOW[111 + k] = part("peak", nil, k)
end

local function steepSheet(sheet)
    return string.match(sheet, "^roofs_0%d$") ~= nil
end

local function lowSheet(sheet)
    return string.match(sheet, "^roofs_30_%d%d$") ~= nil
end

---Decode a roof sprite. Returns nil for sprites outside the known sheets.
---@param spriteName string
---@return table|nil  { kind, facing|corner|axis|eave, step, pitch, steps }
function RoofAtlas.roofPiece(spriteName)
    local sheet, index = split(spriteName)
    if not sheet then return nil end
    local entry, pitch, steps
    if steepSheet(sheet) then
        pitch, steps = 45, 3
        if index < 64 then entry = STEEP[index % 32] else entry = STEEP_EXTRA[index] end
    elseif lowSheet(sheet) then
        pitch, steps = 30, 6
        entry = LOW[index]
    end
    if not entry then return nil end
    local result = { pitch = pitch, steps = steps, sprite = spriteName }
    for k, v in pairs(entry) do result[k] = v end
    return result
end

-- Gable end walls. "low" names the end of the wall at eave height; a wall
-- on a west edge ("W") runs north-south, a wall on a north edge ("N") runs
-- west-east. A peak piece rises to the middle of the edge and falls again.
local STEEP_GABLE = {}
for k = 1, 3 do
    STEEP_GABLE[k - 1] = { wall = "W", low = "S", step = k }
    STEEP_GABLE[7 + k] = { wall = "W", low = "N", step = k }
    STEEP_GABLE[14 - k] = { wall = "N", low = "W", step = k }
    STEEP_GABLE[6 - k] = { wall = "N", low = "E", step = k }
end
STEEP_GABLE[15] = { wall = "W", peak = true, step = 1 }
STEEP_GABLE[14] = { wall = "W", peak = true, step = 2 }
STEEP_GABLE[16] = { wall = "W", peak = true, step = 3 }
STEEP_GABLE[7] = { wall = "N", peak = true, step = 1 }
STEEP_GABLE[6] = { wall = "N", peak = true, step = 2 }
STEEP_GABLE[17] = { wall = "N", peak = true, step = 3 }

local LOW_GABLE = {}
for k = 1, 6 do
    LOW_GABLE[k - 1] = { wall = "W", low = "S", step = k }
    LOW_GABLE[14 - k] = { wall = "W", low = "N", step = k }
    LOW_GABLE[15 + k] = { wall = "N", low = "W", step = k }
    LOW_GABLE[30 - k] = { wall = "N", low = "E", step = k }
    LOW_GABLE[31 + k] = { wall = "W", peak = true, step = k }
    LOW_GABLE[39 + k] = { wall = "N", peak = true, step = k }
end

---Decode a gable wall sprite. A 45 degree gable run is an 18-tile block whose
---first tile is `base`; 30 degree gable sheets use a fixed 48-tile layout.
---@param spriteName string
---@param pitch integer|string
---@param base integer|nil
---@return table|nil  { wall, low|peak, step, pitch, steps }
function RoofAtlas.gablePiece(spriteName, pitch, base)
    local sheet, index = split(spriteName)
    if not sheet then return nil end
    local entry, steps
    if pitch == 30 and string.match(sheet, "^walls_exterior_roofs_30_") then
        entry, steps = LOW_GABLE[index % 48], 6
    elseif pitch == 45 and base and index >= base and index - base < 18 then
        entry, steps = STEEP_GABLE[index - base], 3
    end
    if not entry then return nil end
    local result = { pitch = pitch, steps = steps, sprite = spriteName }
    for k, v in pairs(entry) do result[k] = v end
    return result
end

---Profile key for a roof part.
function RoofAtlas.key(piece)
    if piece.kind == "slope" then return "slope:" .. piece.facing .. ":" .. tostring(piece.step) end
    if piece.kind == "outer" or piece.kind == "valley" then
        return piece.kind .. ":" .. piece.corner .. ":" .. tostring(piece.step)
    end
    if piece.kind == "ridge" then
        return "ridge:" .. piece.axis .. (piece.native and "" or ":" .. tostring(piece.step))
    end
    if piece.kind == "peak" then return "peak:" .. tostring(piece.step) end
    if piece.kind == "eave" then return "eave:" .. piece.eave end
    return piece.kind
end

---Profile key for a gable part.
function RoofAtlas.gableKey(piece)
    if piece.peak then return piece.wall .. ":peak:" .. tostring(piece.step) end
    return piece.wall .. ":low" .. piece.low .. ":" .. tostring(piece.step)
end

return RoofAtlas
