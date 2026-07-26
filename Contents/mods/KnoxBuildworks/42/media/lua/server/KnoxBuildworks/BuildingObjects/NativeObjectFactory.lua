local NativeObjectTypes = require("KnoxBuildworks/World/NativeObjectTypes")

local NativeObjectFactory = {}

local handlers = {}

local function register(objectType, handler)
    handlers[objectType] = handler
end

register("generator", {
    create = function (config, square, spriteName)
        local item = config and instanceItem(config.item) or nil
        local object = item and IsoGenerator.new(item, getCell(), square) or nil
        if not object then
            return nil, "could not initialize IsoGenerator from " .. tostring(config and config.item)
        end
        if spriteName then object:setSprite(getSprite(spriteName)) end
        return object, {
            alreadyAdded = true,
            alreadyTransmitted = isServer()
        }
    end,
    finalize = function (object, square)
        square:RecalcAllWithNeighbours(true)
        IsoGenerator.updateGenerator(square)
    end
})

register("fireplace", {
    create = function (config, square, spriteName)
        local sprite = spriteName and getSprite(spriteName) or nil
        if not sprite then
            return nil, "could not resolve fireplace sprite " .. tostring(spriteName)
        end
        return IsoFireplace.new(getCell(), square, sprite), {
            alreadyAdded = false,
            alreadyTransmitted = false
        }
    end,
    finalize = function (object, square)
        square:RecalcAllWithNeighbours(true)
    end
})

function NativeObjectFactory.resolve(config, spriteName)
    return NativeObjectTypes.resolve(config, spriteName)
end

function NativeObjectFactory.create(objectType, config, square, spriteName)
    local handler = handlers[objectType]
    if not handler then return nil, nil, "unsupported native object type " .. tostring(objectType) end
    local object, stateOrReason = handler.create(config or {}, square, spriteName)
    if not object then return nil, nil, stateOrReason end
    local state = stateOrReason or {}
    state.type = objectType
    return object, state, nil
end

function NativeObjectFactory.insert(object, state, square, insertIndex)
    if state and state.alreadyAdded then return end
    if insertIndex and insertIndex >= 0 then
        square:AddSpecialObject(object, insertIndex)
    else
        square:AddSpecialObject(object)
    end
end

function NativeObjectFactory.finalize(object, state, square)
    local handler = state and handlers[state.type] or nil
    if handler and handler.finalize then handler.finalize(object, square) end
end

return NativeObjectFactory
