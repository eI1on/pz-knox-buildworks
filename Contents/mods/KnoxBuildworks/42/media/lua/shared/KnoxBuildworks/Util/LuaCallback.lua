---LuaCallback provides the Knox Buildworks utility layer.
---@class KBW.LuaCallbackModule
---@type KBW.LuaCallbackModule
local LuaCallback = {}
---@type table<string, { requiresNativeRecipe?: boolean }>
local CALLBACK_POLICIES = {
    ["BuildRecipeCode.barricade.OnCreate"] = { requiresNativeRecipe = true }
}

---@param name any
---@return boolean
function LuaCallback.isValidName(name)
    if type(name) ~= "string" or name == "" then return false end
    local count = 0
    for token in string.gmatch(name, "[^%.]+") do
        if not string.match(token, "^[A-Za-z_][A-Za-z0-9_]*$") then return false end
        count = count + 1
    end
    if count < 2 then return false end
    if string.sub(name, 1, 1) == "." or string.sub(name, -1) == "." then return false end
    if string.find(name, "..", 1, true) then return false end
    return true
end

---@param name string|nil
---@return boolean
function LuaCallback.requiresNativeRecipe(name)
    local policy = CALLBACK_POLICIES[name]
    return policy ~= nil and policy.requiresNativeRecipe == true
end

---@param name string
---@param policy table
---@return boolean
function LuaCallback.registerPolicy(name, policy)
    if not LuaCallback.isValidName(name) or type(policy) ~= "table" then return false end
    CALLBACK_POLICIES[name] = policy
    return true
end

---@param name string|nil
---@return table|nil
function LuaCallback.getPolicy(name)
    return CALLBACK_POLICIES[name]
end

local function loadKnownCallbackModule(name)
    if type(name) ~= "string" then return end
    if string.find(name, "KnoxBuildworks.JsonCallbacks.", 1, true) == 1
        and (not KnoxBuildworks or not KnoxBuildworks.JsonCallbacks) then
        require("KnoxBuildworks/Callbacks/JsonBuildable")
    end
    if string.sub(name, 1, 15) == "BuildRecipeCode" and not BuildRecipeCode then
        require "BuildRecipeCode/buildRecipeCode"
    end
end

---@param name string|nil
function LuaCallback.resolve(name)
    if type(name) == "function" then return name end
    if not LuaCallback.isValidName(name) then return nil end
    loadKnownCallbackModule(name)
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
