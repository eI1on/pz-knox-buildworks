---Hash provides the Knox Buildworks utility layer.
local TableUtil = require("KnoxBuildworks/Util/Table")

-- Deterministic 32-bit content hash for definition and override integrity.
-- Kahlua has no bit operations, so this is a multiplicative rolling hash
-- (value = value * 33 + byte, mod 2^32) in plain double arithmetic;
-- (2^32 - 1) * 33 + 255 < 2^53 keeps every step exact, so client and server
-- always agree. Fast enough to hash megabytes of JSON without lookup tables.
---@class KBW.HashModule
---@type KBW.HashModule
local Hash = {}

local MOD = 4294967296 -- 2^32

-- Streaming API so large inputs can be hashed in slices across ticks.
---@return {value: number}
function Hash.begin()
    return { value = 5381 }
end

---@param text string
---@param state {value:number}
---@param from? number
---@param to? number
function Hash.update(state, text, from, to)
    from = from or 1
    to = to or #text
    local value = state.value
    local byteAt = string.byte
    for index = from, to do
        value = (value * 33 + byteAt(text, index)) % MOD
    end
    state.value = value
    return state
end

---@param state {value:number}
---@return string
function Hash.finish(state)
    local low = state.value % 65536
    local high = (state.value - low) / 65536
    return string.format("%04x%04x", high, low)
end

---@param text string
---@return string
function Hash.string(text)
    text = tostring(text or "")
    local state = Hash.begin()
    Hash.update(state, text, 1, #text)
    return Hash.finish(state)
end

local function canonical(value)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    if kind ~= "table" then return '"<' .. kind .. '>"' end
    if value[1] ~= nil then
        local values = {}
        for i = 1, #value do
            values[i] = canonical(value[i])
        end
        return "[" .. table.concat(values, ",") .. "]"
    end
    local values = {}
    local keys = TableUtil.sortedKeys(value)
    for keyIndex = 1, #keys do
        local key = keys[keyIndex]
        values[#values + 1] = canonical(tostring(key)) .. ":" .. canonical(value[key])
    end
    return "{" .. table.concat(values, ",") .. "}"
end

---@param value unknown
---@return string
function Hash.table(value)
    return Hash.string(canonical(value))
end

---@param value unknown
---@return string
function Hash.canonical(value)
    return canonical(value)
end

return Hash
