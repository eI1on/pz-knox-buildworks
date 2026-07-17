---LuaCallback provides the Knox Buildworks utility layer.
---@class KBW.LuaCallbackModule
---@type KBW.LuaCallbackModule
local LuaCallback = {}

local function maybeRequireBuildRecipeCode(name)
    if type(name) ~= "string" then return end
    if string.sub(name, 1, 15) == "BuildRecipeCode" and not BuildRecipeCode then
        require "BuildRecipeCode/buildRecipeCode"
    end
end

---@param name string|nil
function LuaCallback.resolve(name)
    if type(name) == "function" then return name end
    if type(name) ~= "string" or name == "" then return nil end
    maybeRequireBuildRecipeCode(name)
    local value = _G
    for token in string.gmatch(name, "[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[token]
        if value == nil then return nil end
    end
    if type(value) == "function" then return value end
    return nil
end

---@param name string|nil
function LuaCallback.callBool(name, params, default)
    if not name then return default ~= false end
    local func = LuaCallback.resolve(name)
    if not func then return default ~= false end
    if BaseCraftingLogic and BaseCraftingLogic.callLuaBool and type(name) == "string" then
        return BaseCraftingLogic.callLuaBool(name, params) == true
    end
    return func(params) ~= false
end

---@param name string|nil
function LuaCallback.callObject(name, params)
    if not name then return nil end
    local func = LuaCallback.resolve(name)
    if not func then return nil end
    if BaseCraftingLogic and BaseCraftingLogic.callLuaObject and type(name) == "string" then
        return BaseCraftingLogic.callLuaObject(name, params)
    end
    return func(params)
end

return LuaCallback
