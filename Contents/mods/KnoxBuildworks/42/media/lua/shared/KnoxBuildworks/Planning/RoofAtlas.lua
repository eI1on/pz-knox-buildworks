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
    elseif kind == "outer" or kind == "valley" or kind == "innerHalf" or kind == "outerHalf" then entry.corner = key
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

-- Per-sheet extras (BuildingEd's roof_slopes table, the tile art and the
-- vanilla map). Odd spans put ridges at half steps: the native ridge half
-- (14/15) is the 1.5-step piece, the "TwoPt5" tiles draw 2.5 steps in place.
-- innerHalf is the junction where two odd-span ridges meet over a south-east
-- valley; outerHalf ends an odd-span hip (seams.txt joins 66 to 70/71).
-- raisedFlat tiles are flat roof drawn 1 or 2 steps above the floor.
local function halves(t, outer, inner)
    for k = 1, 3 do
        t[outer + k - 1] = part("outerHalf", "SE", k)
        t[inner + k - 1] = part("innerHalf", "SE", k)
    end
    return t
end
local function twoPt5(t, ns, ew)
    t[ns] = part("ridge", "NS", 3)
    t[ew] = part("ridge", "EW", 3)
    return t
end
local function altRidge(t, ns, ew)
    t[ns] = part("ridge", "NS", 2, { native = true, alternate = true })
    t[ew] = part("ridge", "EW", 2, { native = true, alternate = true })
    return t
end
local function raised(t, rise, a, b)
    t[a] = part("raisedFlat", nil, rise)
    if b then t[b] = part("raisedFlat", nil, rise, { alternate = true }) end
    return t
end
-- Shallow roofs: two rows per side, eave 1/6 storey up, 1/12 storey per
-- row (BuildingEd ShallowSlope order E1, E2, W2, W1, N1, N2, S2, S1).
local SHALLOW_ORDER = { { "E", 1 }, { "E", 2 }, { "W", 2 }, { "W", 1 }, { "N", 1 }, { "N", 2 }, { "S", 2 }, { "S", 1 } }
local function shallow(t, first)
    for i = 1, 8 do t[first + i - 1] = part("slope", SHALLOW_ORDER[i][1], SHALLOW_ORDER[i][2], { shallow = true }) end
    return t
end
local STEEP_EXTRAS = {
    roofs_01 = shallow(twoPt5(twoPt5(halves(halves({}, 64, 67), 72, 75), 70, 71), 78, 79), 80),
    roofs_02 = shallow(twoPt5(twoPt5(halves({}, 64, 67), 70, 71), 78, 79), 80),
    roofs_05 = shallow(shallow(twoPt5(twoPt5(halves(halves({}, 64, 67), 72, 75), 70, 71), 78, 79), 80), 112),
    roofs_03 = raised(raised(twoPt5(twoPt5(altRidge(altRidge({}, 16, 17), 48, 49), 70, 71), 102, 103),
        1, 122, 123), 2, 124, 125),
    roofs_04 = raised(raised(raised(raised(twoPt5(twoPt5(altRidge(altRidge({}, 16, 17), 64, 65), 70, 71), 102, 103),
        1, 48, 49), 2, 50, 51), 1, 90, 91), 2, 92, 93),
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

-- roofs_shallow_01: the shallow rows of the families whose main sheet has none.
local SHALLOW_SHEET = {}
for _, first in pairs({ 0, 24, 48, 72, 96, 120 }) do shallow(SHALLOW_SHEET, first) end

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
        local extras = STEEP_EXTRAS[sheet]
        entry = extras and extras[index]
        if not entry and index < 64 then entry = STEEP[index % 32] end
        if entry and entry.shallow then pitch, steps = "shallow", 12 end
    elseif sheet == "roofs_shallow_01" then
        entry, pitch, steps = SHALLOW_SHEET[index], "shallow", 12
    elseif lowSheet(sheet) then
        pitch, steps = 30, 6
        entry = LOW[index]
    end
    if not entry then return nil end
    local result = { pitch = pitch, steps = steps, sprite = spriteName, maxStep = pitch == "shallow" and 2 or nil }
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

-- Roof accent trim (roofs_accents_01, roofs_accents_30_01). Rakes use the
-- gable wall keys of the piece they sit on; heights: low = 1/6 storey,
-- third, two_thirds, top = 1 storey. Which pair vanilla uses where was read
-- from the shipped map lotpacks (tools/analyze_roof_accents.py).
local function rake(wall, low, step) return { kind = "rake", wall = wall, low = low, step = step } end
local function apex(wall, step) return { kind = "rake", wall = wall, peak = true, step = step } end
local function board(kind, edge, height, extra)
    local entry = { kind = kind, edge = edge, height = height }
    for k, v in pairs(extra or {}) do entry[k] = v end
    return entry
end
local STEEP_ACCENT = {
    [17] = board("fascia", "N", "low"), [18] = board("fascia", "W", "low"),
    [40] = board("fascia", "N", "third"), [41] = board("fascia", "W", "third"),
    [51] = board("fascia", "N", "two_thirds"), [50] = board("fascia", "W", "two_thirds"),
    [45] = board("fascia", "N", "top"), [22] = board("fascia", "W", "top"),
    [44] = board("fascia", "N", "top", { alternate = true }), [21] = board("fascia", "W", "top", { alternate = true }),
    [15] = board("fasciaCorner", nil, "low"), [42] = board("fasciaCorner", nil, "third"),
    [48] = board("fasciaCorner", nil, "two_thirds"), [23] = board("fasciaCorner", nil, "top"),
    [55] = board("return", "N", "third"), [54] = board("return", "W", "third"),
    [49] = board("return", "N", "two_thirds"), [52] = board("return", "W", "two_thirds"),
    [20] = board("return", "N", "top"), [46] = board("return", "W", "top"),
    [43] = board("block", nil, "third"), [53] = board("block", nil, "two_thirds"), [47] = board("block", nil, "top"),
    [0] = board("shallowRake", "N", nil, { low = "W", row = 1 }), [1] = board("shallowRake", "N", nil, { low = "W", row = 2 }),
    [3] = board("shallowRake", "N", nil, { low = "E", row = 1 }), [2] = board("shallowRake", "N", nil, { low = "E", row = 2 }),
    [11] = board("shallowRake", "W", nil, { low = "N", row = 1 }), [10] = board("shallowRake", "W", nil, { low = "N", row = 2 }),
    [8] = board("shallowRake", "W", nil, { low = "S", row = 1 }), [9] = board("shallowRake", "W", nil, { low = "S", row = 2 }),
    [16] = board("shoe", "W"), [19] = board("shoe", "N"),
}
for k = 1, 3 do
    STEEP_ACCENT[27 + k] = rake("W", "S", k)
    STEEP_ACCENT[35 + k] = rake("W", "N", k)
    STEEP_ACCENT[7 - k] = rake("N", "E", k)
    STEEP_ACCENT[15 - k] = rake("N", "W", k)
    STEEP_ACCENT[23 + k] = apex("W", k)
    STEEP_ACCENT[35 - k] = apex("N", k)
end
-- Rake feet: one level below the roof, under a rake's eave end.
local LOW_ACCENT_FEET = {
    [6] = board("foot", "W", nil, { low = "S" }), [14] = board("foot", "W", nil, { low = "N" }),
    [22] = board("foot", "N", nil, { low = "W" }), [30] = board("foot", "N", nil, { low = "E" }),
}

---Decode a roof accent sprite. Returns nil for sprites outside the accent sheets.
---@param spriteName string
---@return table|nil  { kind, pitch, wall/low/peak/step (rakes) | edge/height (boards) }
function RoofAtlas.accentPiece(spriteName)
    local sheet, index = split(spriteName)
    if not sheet then return nil end
    local entry, pitch
    if sheet == "roofs_accents_01" then
        entry, pitch = STEEP_ACCENT[index], 45
    elseif sheet == "roofs_accents_30_01" then
        pitch = 30
        local gable = LOW_GABLE[index]
        if gable then
            entry = { kind = "rake", wall = gable.wall, low = gable.low, peak = gable.peak, step = gable.step }
        else
            entry = LOW_ACCENT_FEET[index]
        end
    end
    if not entry then return nil end
    local result = { pitch = pitch, sprite = spriteName }
    for k, v in pairs(entry) do result[k] = v end
    return result
end

---Accent set key for a decoded accent piece (nil for pieces placed by hand).
function RoofAtlas.accentKey(piece)
    if piece.kind == "rake" then return "rake:" .. piece.pitch .. ":" .. RoofAtlas.gableKey(piece) end
    if piece.alternate then return nil end
    if piece.kind == "fascia" or piece.kind == "return" then
        return piece.kind .. ":" .. piece.edge .. ":" .. piece.height
    end
    if piece.kind == "fasciaCorner" or piece.kind == "block" then return piece.kind .. ":" .. piece.height end
    if piece.kind == "foot" then return "foot:" .. piece.pitch .. ":" .. piece.edge .. ":low" .. piece.low end
    if piece.kind == "shallowRake" then return "rake:shallow:" .. piece.edge .. ":low" .. piece.low .. ":" .. piece.row end
    return nil
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
    if piece.kind == "innerHalf" or piece.kind == "outerHalf" then
        return piece.kind .. ":" .. piece.corner .. ":" .. tostring(piece.step)
    end
    if piece.kind == "raisedFlat" then return "raisedFlat:" .. tostring(piece.step) end
    if piece.kind == "eave" then return "eave:" .. piece.eave end
    return piece.kind
end

---Profile key for a gable part.
function RoofAtlas.gableKey(piece)
    if piece.peak then return piece.wall .. ":peak:" .. tostring(piece.step) end
    return piece.wall .. ":low" .. piece.low .. ":" .. tostring(piece.step)
end

return RoofAtlas
