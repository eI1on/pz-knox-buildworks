---Integrity provides the Knox Buildworks multiplayer integrity layer.
local KBW = require("KnoxBuildworks/Core")

---@class KBW.IntegrityModule
---@type KBW.IntegrityModule
local Integrity = { serverClients = {} }

---@param status KBW.RequirementStatus
---@param message string
function Integrity.setClient(status, message)
    KBW.Runtime.integrity, KBW.Runtime.integrityMessage = status, message
end

---@param player IsoPlayer
---@param message string
function Integrity.setServer(player, allowed, message)
    if player then
        Integrity.serverClients[player:getUsername()] = { allowed = allowed, message = message }
    end
end

---@param player IsoPlayer
function Integrity.isAllowed(player)
    if not isClient() and not isServer() then return true end
    if isServer() then
        local state = player and Integrity.serverClients[player:getUsername()]
        return state ~= nil and state.allowed == true
    end
    return KBW.Runtime.integrity == "ok"
end

return Integrity
