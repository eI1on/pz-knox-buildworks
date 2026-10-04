local Resolver = require("KnoxBuildworks/Definitions/Resolver")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local Log = require("KnoxBuildworks/Log")

local EntityRepair = {}

---@param object IsoObject
---@return boolean repaired
function EntityRepair.repairObject(object)
    if isClient() or not object or not object.hasModData or not object:hasModData() then return false end
    if object.hasComponents and object:hasComponents() then return false end
    local data = object:getModData()
    local kbw = data and data.KBW or nil
    if type(kbw) ~= "table" or not kbw.buildableId then return false end
    local definition = Resolver.resolve(kbw.buildableId, kbw.variantId, kbw.materialId)
        or Registry:get(kbw.buildableId)
    local stage = definition and Registry:getStage(definition, kbw.stageId) or nil
    if not stage or not stage.entityCompat then return false end
    local attached, reason = EntityCompat.attach(object, stage, false)
    if not attached then
        Log:warning(
            "Could not repair entity components for %s:%s: %s",
            tostring(kbw.buildableId), tostring(kbw.stageId), tostring(reason)
        )
        return false
    end
    if object.sync then object:sync() end
    return true
end

---@param square IsoGridSquare
function EntityRepair.repairSquare(square)
    if isClient() or not square then return end
    local objects = square:getObjects()
    for objectIndex = 0, objects:size() - 1 do
        EntityRepair.repairObject(objects:get(objectIndex))
    end
end

Events.LoadGridsquare.Add(EntityRepair.repairSquare)
Events.OnObjectAdded.Add(EntityRepair.repairObject)

return EntityRepair
