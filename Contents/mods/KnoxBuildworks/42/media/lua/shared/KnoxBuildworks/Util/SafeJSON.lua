---SafeJSON provides the Knox Buildworks utility layer.
-- A non-throwing JSON decoder. ElyonLib's encoder remains the canonical writer;
-- this parser is deliberately local so a malformed addon file can be skipped.
---@class KBW.SafeJSONModule
---@type KBW.SafeJSONModule
local SafeJSON = {}

---@param text string
---@return unknown value
---@return string|nil error
local function decode(text)
    local index, length = 1, #text
    local parseValue
    local function fail(message)
        return nil, string.format("%s at byte %d", message, index)
    end
    local function whitespace()
        while index <= length and string.find(" \t\r\n", string.sub(text, index, index), 1, true) do
            index = index + 1
        end
    end
    local function parseString()
        index = index + 1
        local output = {}
        while index <= length do
            local char = string.sub(text, index, index)
            if char == '"' then
                index = index + 1
                return table.concat(output)
            end
            if char == "\\" then
                index = index + 1
                local escaped = string.sub(text, index, index)
                local simple = {
                    ['"'] = '"',
                    ['\\'] = '\\',
                    ['/'] = '/',
                    b = '\b',
                    f = '\f',
                    n = '\n',
                    r = '\r',
                    t = '\t'
                }
                if simple[escaped] then
                    output[#output + 1] = simple[escaped]
                elseif escaped == "u" then
                    local hex = string.sub(text, index + 1, index + 4)
                    local code = tonumber(hex, 16)
                    if not code then return fail("invalid unicode escape") end
                    output[#output + 1] = code < 128 and string.char(code) or "?"
                    index = index + 4
                else
                    return fail("invalid escape")
                end
            else
                output[#output + 1] = char
            end
            index = index + 1
        end
        return fail("unterminated string")
    end
    local function parseArray()
        local result = {}
        index = index + 1
        whitespace()
        if string.sub(text, index, index) == "]" then
            index = index + 1
            return result
        end
        while index <= length do
            local value, err = parseValue()
            if err then return nil, err end
            result[#result + 1] = value
            whitespace()
            local char = string.sub(text, index, index)
            index = index + 1
            if char == "]" then return result end
            if char ~= "," then return fail("expected comma or closing bracket") end
            whitespace()
        end
        return fail("unterminated array")
    end
    local function parseObject()
        local result = {}
        index = index + 1
        whitespace()
        if string.sub(text, index, index) == "}" then
            index = index + 1
            return result
        end
        while index <= length do
            if string.sub(text, index, index) ~= '"' then return fail("expected object key") end
            local key, err = parseString()
            if err then return nil, err end
            whitespace()
            if string.sub(text, index, index) ~= ":" then return fail("expected colon") end
            index = index + 1
            whitespace()
            local value
            value, err = parseValue()
            if err then return nil, err end
            result[key] = value
            whitespace()
            local char = string.sub(text, index, index)
            index = index + 1
            if char == "}" then return result end
            if char ~= "," then return fail("expected comma or closing brace") end
            whitespace()
        end
        return fail("unterminated object")
    end
    function parseValue()
        whitespace()
        local char = string.sub(text, index, index)
        if char == '"' then return parseString() end
        if char == "{" then return parseObject() end
        if char == "[" then return parseArray() end
        local tail = string.sub(text, index)
        if string.sub(tail, 1, 4) == "true" then
            index = index + 4
            return true
        end
        if string.sub(tail, 1, 5) == "false" then
            index = index + 5
            return false
        end
        if string.sub(tail, 1, 4) == "null" then
            index = index + 4
            return nil
        end
        local token = string.match(tail, "^-?%d+%.?%d*[eE]?[+-]?%d*")
        if token and token ~= "" then
            index = index + #token
            return tonumber(token)
        end
        return fail("unexpected token")
    end

    local value, err = parseValue()
    if err then return nil, err end
    whitespace()
    if index <= length then return fail("trailing data") end
    return value
end

SafeJSON.decode = decode
return SafeJSON
