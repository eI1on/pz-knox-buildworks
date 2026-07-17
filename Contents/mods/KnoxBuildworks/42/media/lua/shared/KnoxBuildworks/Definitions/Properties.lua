---Properties provides the Knox Buildworks data-driven definition layer.
local KBW = require("KnoxBuildworks/Core")
local TableUtil = require("KnoxBuildworks/Util/Table")
local Log = require("KnoxBuildworks/Log")

-- Extensible stage-property handlers. A handler binds behavior to a
-- stage-level JSON key so new script properties (e.g. container capacity)
-- plug in without editing Knox core. Third-party mods register their own:
--
--   local Properties = require("KnoxBuildworks/Definitions/Properties")
--   Properties.register("myProperty", {
--       normalize     = function(value, stage, definition, addError) return value end,
--       applyToCursor = function(buildObj, stage, definition) end,
--       applyToObject = function(part, buildObj, stage, context) end,
--   })
--
-- All callbacks are optional. Dispatch only fires for stages that actually
-- carry the key, in sorted key order so normalization stays deterministic.
--  * normalize     - validate/default the value during Schema.normalize;
--                    a non-nil return replaces the stored value.
--  * applyToCursor - derive cursor/build-object fields in KBWBuildingObject:new.
--  * applyToObject - apply behavior to the built world object (server
--                    authoritative). context = { square, spriteConfig,
--                    tileIndex, isFloor }.

---@class KBW.PropertiesModule
---@type KBW.PropertiesModule
local Properties = {}

local handlers = {}
local sortedNames = {}
local namesDirty = false

local function handlerNames()
    if namesDirty then
        sortedNames = TableUtil.sortedKeys(handlers)
        namesDirty = false
    end
    return sortedNames
end

---@param name string|nil
function Properties.register(name, handler)
    if type(name) ~= "string" or name == "" or type(handler) ~= "table" then
        Log:error("Properties.register: invalid handler registration for '%s'", tostring(name))
        return false
    end
    if handlers[name] then
        Log:warning("Properties.register: handler '%s' replaced", name)
    end
    handlers[name] = handler
    namesDirty = true
    return true
end

---@param name string|nil
function Properties.get(name)
    return handlers[name]
end

-- Called from Schema.normalize for every stage (including variant/material
-- option stages). addError feeds the bundle's validation error list.
---@param stage KBW.BuildStage
---@param definition KBW.BuildableDefinition
function Properties.normalizeStage(stage, definition, errors)
    local names = handlerNames()
    for nameIndex = 1, #names do
        local name = names[nameIndex]
        local handler = handlers[name]
        if stage[name] ~= nil and handler.normalize then
            local function addError(message)
                errors[#errors + 1] = "stage " .. tostring(stage.id)
                    .. " property '" .. name
                    .. "': " .. tostring(message)
            end
            local replaced = handler.normalize(stage[name], stage, definition, addError)
            if replaced ~= nil then stage[name] = replaced end
        end
    end
end

-- Called at the end of KBWBuildingObject:new to derive cursor fields.
function Properties.applyToCursor(buildObj)
    local stage = buildObj and buildObj.stage
    if not stage then return end
    local names = handlerNames()
    for nameIndex = 1, #names do
        local name = names[nameIndex]
        local handler = handlers[name]
        if stage[name] ~= nil and handler.applyToCursor then
            handler.applyToCursor(buildObj, stage, buildObj.definition)
        end
    end
end

-- Called per built part in KBWBuildingObject:create (server authoritative).
function Properties.applyToObject(part, buildObj, context)
    local stage = buildObj and buildObj.stage
    if not part or not stage then return end
    local names = handlerNames()
    for nameIndex = 1, #names do
        local name = names[nameIndex]
        local handler = handlers[name]
        if stage[name] ~= nil and handler.applyToObject then
            handler.applyToObject(part, buildObj, stage, context or {})
        end
    end
end

-- BUILT-IN HANDLERS ---------------------------------------------------------
-- "container": reference implementation. { type = string?, capacity = number? }
-- makes the built thumpable a container with the given capacity.
Properties.register("container", {
    normalize = function (value, stage, definition, addError)
        if type(value) ~= "table" then
            addError("must be an object with optional 'type' and 'capacity'")
            return value
        end
        if value.type ~= nil and type(value.type) ~= "string" then addError("'type' must be a string") end
        if value.capacity ~= nil and type(value.capacity) ~= "number" then addError("'capacity' must be a number") end
        return value
    end,
    applyToCursor = function (buildObj, stage)
        buildObj.isContainer = true
        buildObj.containerType = stage.container.type or nil
    end,
    applyToObject = function (part, buildObj, stage, context)
        if not context.isFloor and part.getContainer and part:getContainer() then
            part:getContainer():setCapacity(stage.container.capacity or 30)
        end
    end
})

KBW.Properties = Properties

return Properties

