---Blueprints provides the Knox Buildworks blueprint planning layer.
local KBW = require("KnoxBuildworks/Core")
local Resolver = require("KnoxBuildworks/Definitions/Resolver")
local Requirements = require("KnoxBuildworks/Validation/Requirements")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local TableUtil = require("KnoxBuildworks/Util/Table")
local Placement = require("KnoxBuildworks/Validation/Placement")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local JSON = require("ElyonLib/FileUtils/JSON")
local SafeJSON = require("KnoxBuildworks/Util/SafeJSON")
local I18n = require("KnoxBuildworks/I18n")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")

local Files = require("KnoxBuildworks/Planning/BlueprintFiles")

---@class KBW.BlueprintsModule
---@type KBW.BlueprintsModule
local Blueprints = { VERSION = 1, ITEM_TYPE = "KnoxBuildworks.KBW_Blueprint", EXPORT_FOLDER = "KnoxBuildworks/exports" }

local function timestamp()
    if getTimestampMs then return tostring(getTimestampMs()) end
    if getTimestamp then return tostring(getTimestamp()) end
    return tostring(ZombRand(1000000000))
end

local function playerName(player)
    if not player then return "player" end
    if player.getUsername then return tostring(player:getUsername()) end
    if player.getDescriptor and player:getDescriptor() then
        return tostring(player:getDescriptor():getForename())
    end
    return "player"
end

-- Short random ids keep blueprint files and every network payload small.
-- Callers pass a `taken(id)` lookup for the scope the id must be unique in
-- (the store for blueprints, one blueprint for placements and rooms).
local ID_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"
local idFallback = 0

local function randomId(prefix, length)
    local chars = {}
    for charIndex = 1, length do
        local roll
        if ZombRand then
            roll = ZombRand(36)
        else
            idFallback = (idFallback + 17) % 36
            roll = idFallback
        end
        -- ensure number index for string.sub (type-checkers expect number)
        chars[charIndex] = string.sub(ID_ALPHABET, math.floor(roll) + 1, math.floor(roll) + 1)
    end
    return tostring(prefix or "") .. table.concat(chars)
end

local function newId(prefix, taken)
    for _ = 1, 32 do
        local id = randomId(prefix, 6)
        if not taken or not taken(id) then return id end
    end
    return randomId(prefix, 12)
end

local function findById(list, id)
    list = list or {}
    for index = 1, #list do
        if list[index].id == id then return list[index], index end
    end
    return nil, nil
end

local function entryIdTaken(list)
    return function (id) return findById(list, id) ~= nil end
end

local function defaultName()
    local key = "IGUI_KBW_DefaultBlueprintName"
    local text = getText and getText(key) or key
    if text == key then return "New blueprint" end
    return text
end

-- SHARED STORAGE ----------------------------------------------------------
-- Blueprints are shared and server-authoritative. The authoritative store (the
-- server, or the local session in singleplayer) keeps one JSON file per
-- blueprint under Lua/KnoxBuildworks/blueprints/<save>/ and mirrors it in
-- memory; multiplayer clients hold a synced in-memory cache of the blueprints
-- they are allowed to view. Each player's *active* blueprint is a local view
-- preference kept in their own mod data, never shared.

local clientCache = { items = {} }
local store = nil

local function isMPClient()
    return isClient() == true
end

local function persist(blueprint)
    if not isMPClient() and blueprint then Files.queueSave(blueprint) end
end

local function touch(blueprint)
    if not blueprint then return end
    blueprint.updated = timestamp()
    persist(blueprint)
end

function Blueprints.sharedItems()
    if isMPClient() then
        clientCache.items = clientCache.items or {}
        return clientCache.items
    end
    if not store then store = Files.loadAll() end
    return store
end

-- Replaces / upserts the client cache from a server sync payload.
---@param replace boolean|nil
function Blueprints.applySync(items, replace)
    if replace then
        clientCache.items = {}
    end
    clientCache.items = clientCache.items or {}
    for id, blueprint in pairs(items or {}) do
        clientCache.items[tostring(id)] = blueprint
    end
end

function Blueprints.forget(id)
    if not id then return end
    clientCache.items = clientCache.items or {}
    clientCache.items[tostring(id)] = nil
end

-- Applies a server-broadcast delta to the client cache. The server already
-- enforced permissions, so no checks here; placement/room changes are
-- idempotent upserts by id. Unknown blueprints are ignored (a full BPSync
-- arrives whenever this client is meant to see one).
---@param command string
---@param args table
function Blueprints.applyRemoteDelta(command, args)
    args = args or {}
    local blueprint = clientCache.items and clientCache.items[tostring(args.id or "")] or nil
    if not blueprint then return end
    if command == "BPAddPlacement" and args.placement and args.placement.id then
        if args.anchor and not blueprint.anchored then
            blueprint.anchor = args.anchor
            blueprint.anchored = true
        end
        blueprint.placements = blueprint.placements or {}
        local _, index = findById(blueprint.placements, args.placement.id)
        blueprint.placements[index or (#blueprint.placements + 1)] = args.placement
    elseif command == "BPRemovePlacement" then
        local _, index = findById(blueprint.placements, args.placementId)
        if index then table.remove(blueprint.placements, index) end
    elseif command == "BPAddRoom" and args.room and args.room.id then
        blueprint.rooms = blueprint.rooms or {}
        local _, index = findById(blueprint.rooms, args.room.id)
        blueprint.rooms[index or (#blueprint.rooms + 1)] = args.room
    elseif command == "BPRemoveRoom" then
        local _, index = findById(blueprint.rooms, args.roomId)
        if index then table.remove(blueprint.rooms, index) end
    elseif command == "BPUpdateRoom" and type(args.fields) == "table" then
        local room = findById(blueprint.rooms, args.roomId)
        if room then
            for key, value in pairs(args.fields) do
                room[key] = TableUtil.copy(value)
            end
        end
    elseif command == "BPSetGatherArea" then
        blueprint.gatherArea = args.area or nil
    elseif command == "BPMove" then
        Blueprints.move(nil, args.id, args.dx, args.dy, args.dz, true)
    elseif command == "BPRename" and args.name then
        blueprint.name = tostring(args.name)
    elseif command == "BPSetLevel" and tonumber(args.level) then
        blueprint.level = math.floor(args.level)
    elseif command == "BPSetAccess" then
        local access = blueprint.access or { scope = "private", players = {}, factions = {} }
        blueprint.access = access
        access.players = access.players or {}
        access.factions = access.factions or {}
        if args.scope then access.scope = args.scope end
        if args.playerUser then
            if args.playerLevel == "none" then
                access.players[args.playerUser] = nil
            else
                access.players[args.playerUser] = args.playerLevel
            end
        end
        if args.factionName then
            if args.factionLevel == "none" then
                access.factions[args.factionName] = nil
            else
                access.factions[args.factionName] = args.factionLevel
            end
        end
    end
    if args.updated then blueprint.updated = args.updated end
end

local function viewStore(player)
    if not player or not player.getModData then return {} end
    local data = player:getModData()
    data.KBW_BP_View = data.KBW_BP_View or {}
    return data.KBW_BP_View
end

-- Networking: client mutators mirror their change to the server; the server
-- re-applies authoritatively and broadcasts the result back. Both are no-ops
-- in singleplayer.
local function sendToServer(player, command, args)
    if isMPClient() and sendClientCommand then
        sendClientCommand(player, KBW.NETWORK_MODULE, command, args or {})
    end
end

-- SERVER SYNC ---------------------------------------------------------------
-- The server never rebroadcasts whole blueprints on ordinary edits: it echoes
-- the (validated) delta command to the players who may view the blueprint,
-- skipping the sender, who already applied the change locally. Full blueprint
-- payloads are reserved for login sync, creation, access changes and rollback
-- after a rejected command.

local function eachOnlinePlayer(callback)
    if not getOnlinePlayers then return end
    local players = getOnlinePlayers()
    if not players then return end
    for playerIndex = 0, players:size() - 1 do
        callback(players:get(playerIndex))
    end
end

local function samePlayer(a, b)
    return a ~= nil and b ~= nil and playerName(a) == playerName(b)
end

-- username -> player map of everyone online who can currently view the
-- blueprint. Captured before access changes and deletions to diff visibility.
---@param blueprint KBW.Blueprint
function Blueprints.onlineViewers(blueprint)
    local viewers = {}
    if not blueprint then return viewers end
    eachOnlinePlayer(function (target)
        if Blueprints.shouldSync(target, blueprint) then viewers[playerName(target)] = target end
    end)
    return viewers
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.serverSyncTo(player, blueprint)
    sendServerCommand(player, KBW.NETWORK_MODULE, "BPSync", { item = blueprint })
end

---@param player IsoPlayer
function Blueprints.serverForgetTo(player, id)
    sendServerCommand(player, KBW.NETWORK_MODULE, "BPForget", { id = id })
end

-- Full blueprint to every viewer except the sender (creation, import).
---@param blueprint KBW.Blueprint
function Blueprints.serverBroadcastFull(blueprint, sender)
    if not isServer() or not blueprint then return end
    eachOnlinePlayer(function (target)
        if not samePlayer(target, sender) and Blueprints.shouldSync(target, blueprint) then
            Blueprints.serverSyncTo(target, blueprint)
        end
    end)
end

-- Validated delta to every viewer except the sender.
---@param blueprint KBW.Blueprint
---@param command string
---@param args table
function Blueprints.serverBroadcastDelta(blueprint, command, args, sender)
    if not isServer() or not blueprint then return end
    eachOnlinePlayer(function (target)
        if not samePlayer(target, sender) and Blueprints.shouldSync(target, blueprint) then
            sendServerCommand(target, KBW.NETWORK_MODULE, command, args)
        end
    end)
end

-- Access changes re-filter visibility: players who can now view get the full
-- blueprint, players who lost view get a forget, everyone else hears nothing.
---@param blueprint KBW.Blueprint
function Blueprints.serverBroadcastAccessChange(blueprint, viewersBefore, sender)
    if not isServer() or not blueprint then return end
    eachOnlinePlayer(function (target)
        if samePlayer(target, sender) then return end
        local username = playerName(target)
        if Blueprints.shouldSync(target, blueprint) then
            Blueprints.serverSyncTo(target, blueprint)
        elseif viewersBefore[username] then
            Blueprints.serverForgetTo(target, blueprint.id)
        end
    end)
end

-- Sends every blueprint a player is allowed to see (login / explicit request).
---@param player IsoPlayer
function Blueprints.serverSyncAll(player)
    if not isServer() then return end
    local visible = {}
    for id, blueprint in pairs(Blueprints.sharedItems()) do
        if Blueprints.shouldSync(player, blueprint) then visible[id] = blueprint end
    end
    sendServerCommand(player, KBW.NETWORK_MODULE, "BPSyncAll", { items = visible })
end

-- PERMISSIONS -------------------------------------------------------------
local ACCESS_LEVELS = { none = 0, view = 1, build = 2, contribute = 3 }
local ACCESS_SCOPES = { private = true, view = true, build = true, contribute = true }
Blueprints.ACCESS_LEVELS = ACCESS_LEVELS

local function defaultAccess()
    return { scope = "private", players = {}, factions = {} }
end

local function playerFactionName(player)
    if not player or not Faction or not Faction.getPlayerFaction then return nil end
    local faction = Faction.getPlayerFaction(player)
    if faction and faction.getName then return faction:getName() end
    return nil
end

-- Faction lookup by username string. B42 Faction.getPlayerFaction(String)
-- scans owner + member name lists, so offline members resolve too. Shared so
-- the access UI displays the same faction the server resolves.
function Blueprints.factionNameForUser(username)
    if not username or username == "" or not Faction or not Faction.getPlayerFaction then return nil end
    local faction = Faction.getPlayerFaction(tostring(username))
    if faction and faction.getName then return faction:getName() end
    return nil
end

local function isAdmin(player)
    if not player or not player.getAccessLevel then return false end
    return string.lower(tostring(player:getAccessLevel() or "")) == "admin"
end

local function playerCanManageFaction(player, factionName, level)
    if factionName == nil or factionName == "" then return false end
    if isAdmin(player) then return true end
    if level == "none" then return true end
    local ownFaction = playerFactionName(player)
    return ownFaction ~= nil and tostring(ownFaction) == tostring(factionName)
end

---@param player IsoPlayer
function Blueprints.isAdmin(player)
    return isAdmin(player)
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.isBlueprintOwner(player, blueprint)
    return blueprint ~= nil and blueprint.owner ~= nil and tostring(blueprint.owner) == playerName(player)
end

-- Effective access level (0..3) a player has on a blueprint. An ownerless
-- blueprint (malformed/legacy data) grants nothing implicitly; every creation
-- path stamps an owner.
---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.accessLevel(player, blueprint)
    if not blueprint then return 0 end
    local user = playerName(player)
    if blueprint.owner ~= nil and blueprint.owner == user then return ACCESS_LEVELS.contribute end
    if isAdmin(player) then return ACCESS_LEVELS.contribute end
    local access = blueprint.access or {}
    local byPlayer = access.players and access.players[user]
    if byPlayer and byPlayer ~= "none" then return ACCESS_LEVELS[byPlayer] or 0 end
    local factionName = playerFactionName(player)
    if factionName and access.factions and access.factions[factionName] and access.factions[factionName] ~= "none" then
        return ACCESS_LEVELS[access.factions[factionName]] or 0
    end
    return ACCESS_LEVELS[access.scope] or 0
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.canView(player, blueprint)
    return Blueprints.accessLevel(player, blueprint) >= ACCESS_LEVELS.view
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.canBuild(player, blueprint)
    return Blueprints.accessLevel(player, blueprint) >= ACCESS_LEVELS.build
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.canContribute(player, blueprint)
    return Blueprints.accessLevel(player, blueprint) >= ACCESS_LEVELS.contribute
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.isOwner(player, blueprint)
    return Blueprints.isBlueprintOwner(player, blueprint) or isAdmin(player)
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.canManageAccess(player, blueprint)
    return Blueprints.isBlueprintOwner(player, blueprint) or isAdmin(player)
end

-- Authorization and discovery are intentionally separate. Public or shared
-- blueprints remain usable by their members, but non-owners only receive them
-- while inside the blueprint's planning radius. This keeps large MP servers
-- from synchronizing every public blueprint to every connected player.
---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.distanceFrom(player, blueprint)
    if not player or not blueprint or not player.getX or not player.getY then return math.huge end
    local anchor = Blueprints.rangeAnchor(blueprint)
    if not anchor then return math.huge end
    local dx = math.abs((tonumber(player:getX()) or 0) - (tonumber(anchor.x) or 0))
    local dy = math.abs((tonumber(player:getY()) or 0) - (tonumber(anchor.y) or 0))
    return math.max(dx, dy)
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.shouldSync(player, blueprint)
    if not blueprint then return false end
    if Blueprints.isBlueprintOwner(player, blueprint) then return true end
    if not Blueprints.canView(player, blueprint) then return false end
    local radius = tonumber(blueprint.radius) or Blueprints.blueprintRadius()
    return Blueprints.distanceFrom(player, blueprint) <= radius
end

local function ensureAccess(blueprint)
    if type(blueprint.access) ~= "table" then blueprint.access = defaultAccess() end
    blueprint.access.players = blueprint.access.players or {}
    blueprint.access.factions = blueprint.access.factions or {}
    for username, level in pairs(blueprint.access.players) do
        if level == "none" then blueprint.access.players[username] = nil end
    end
    for factionName, level in pairs(blueprint.access.factions) do
        if level == "none" then blueprint.access.factions[factionName] = nil end
    end
    return blueprint.access
end

---@param player IsoPlayer
---@param scope string
function Blueprints.setAccessScope(player, id, scope)
    local blueprint = Blueprints.get(player, id)
    if not blueprint or not Blueprints.canManageAccess(player, blueprint) then return false end
    if not ACCESS_SCOPES[scope] then return false end
    ensureAccess(blueprint).scope = scope
    touch(blueprint)
    sendToServer(player, "BPSetAccess", { id = id, scope = scope })
    return true
end

---@param player IsoPlayer
---@param targetUser string
---@param level number|string
function Blueprints.setPlayerAccess(player, id, targetUser, level)
    local blueprint = Blueprints.get(player, id)
    if not blueprint or not Blueprints.canManageAccess(player, blueprint) then return false end
    level = level or "none"
    if not ACCESS_LEVELS[level] then return false end
    if targetUser == nil or targetUser == "" then return false end
    if blueprint.owner ~= nil and tostring(targetUser) == tostring(blueprint.owner) then return false end
    local access = ensureAccess(blueprint)
    if level == "none" then
        access.players[targetUser] = nil
    else
        access.players[targetUser] = level
    end
    touch(blueprint)
    sendToServer(player, "BPSetAccess", { id = id, playerUser = targetUser, playerLevel = level })
    return true
end

---@param player IsoPlayer
---@param factionName string
---@param level number|string
function Blueprints.setFactionAccess(player, id, factionName, level)
    local blueprint = Blueprints.get(player, id)
    if not blueprint or not Blueprints.canManageAccess(player, blueprint) then return false end
    level = level or "none"
    if not ACCESS_LEVELS[level] then return false end
    if not playerCanManageFaction(player, factionName, level) then return false end
    local access = ensureAccess(blueprint)
    if level == "none" then
        access.factions[factionName] = nil
    else
        access.factions[factionName] = level
    end
    touch(blueprint)
    sendToServer(player, "BPSetAccess", { id = id, factionName = factionName, factionLevel = level })
    return true
end

-- CRUD --------------------------------------------------------------------
function Blueprints.blueprintRadius()
    return math.floor(tonumber(KBW.sandboxValue("KnoxBuildworks.BlueprintRadius", 200)) or 200)
end

function Blueprints.maxPlacements()
    return math.floor(tonumber(KBW.sandboxValue("KnoxBuildworks.MaxPlacementsPerBlueprint", 1000)) or 1000)
end

local function storeIdTaken(items)
    return function (id) return items[id] ~= nil end
end

---@param player IsoPlayer
---@param name string|nil
---@param level number|string
function Blueprints.create(player, name, level)
    local items = Blueprints.sharedItems()
    local id = newId("bp", storeIdTaken(items))
    local x = player and player.getX and math.floor(player:getX()) or 0
    local y = player and player.getY and math.floor(player:getY()) or 0
    local z = level
    if z == nil and player and player.getZ then z = math.floor(player:getZ()) end
    z = z or 0
    local blueprint = {
        id = id,
        name = name or defaultName(),
        level = z,
        origin = { x = x, y = y, z = z },
        anchored = false,
        radius = Blueprints.blueprintRadius(),
        owner = playerName(player),
        access = defaultAccess(),
        rooms = {},
        placements = {},
        updated = timestamp()
    }
    items[id] = blueprint
    persist(blueprint)
    viewStore(player).activeId = id
    if isMPClient() then
        sendToServer(player, "BPCreate", { blueprint = blueprint })
    end
    return blueprint
end

---@param player IsoPlayer
function Blueprints.list(player)
    local list = {}
    for _, blueprint in pairs(Blueprints.sharedItems()) do
        if Blueprints.shouldSync(player, blueprint) then list[#list + 1] = blueprint end
    end
    table.sort(list, function (a, b)
        local aOwned = Blueprints.isBlueprintOwner(player, a)
        local bOwned = Blueprints.isBlueprintOwner(player, b)
        if aOwned ~= bOwned then return aOwned end
        if not aOwned then
            local aDistance = Blueprints.distanceFrom(player, a)
            local bDistance = Blueprints.distanceFrom(player, b)
            if aDistance ~= bDistance then return aDistance < bDistance end
        end
        return tostring(a.updated or a.id) > tostring(b.updated or b.id)
    end)
    return list
end

---@param player IsoPlayer
function Blueprints.get(player, id)
    if not id then return nil end
    return Blueprints.sharedItems()[tostring(id)] or nil
end

---@param player IsoPlayer
function Blueprints.active(player)
    local id = viewStore(player).activeId
    local blueprint = id and Blueprints.get(player, id) or nil
    if blueprint and not Blueprints.canView(player, blueprint) then return nil end
    return blueprint
end

---@param player IsoPlayer
function Blueprints.activeOrCreate(player)
    return Blueprints.active(player) or Blueprints.create(player)
end

-- Passing nil clears the active blueprint, which disables all ghost drawing.
-- Active blueprint is a purely local view preference (not networked).
---@param player IsoPlayer
function Blueprints.setActive(player, id)
    local view = viewStore(player)
    if id == nil then
        view.activeId = nil
        return nil
    end
    local blueprint = Blueprints.get(player, id)
    if blueprint and Blueprints.canView(player, blueprint) then
        view.activeId = tostring(id)
        return blueprint
    end
    return nil
end

---@param player IsoPlayer
function Blueprints.isActive(player, id)
    return id ~= nil and viewStore(player).activeId == tostring(id)
end

---@param player IsoPlayer
function Blueprints.delete(player, id)
    id = tostring(id or "")
    local items = Blueprints.sharedItems()
    local blueprint = items[id]
    if not blueprint then return false end
    if not Blueprints.isOwner(player, blueprint) then return false end
    items[id] = nil
    if not isMPClient() then Files.remove(id) end
    if viewStore(player).activeId == id then viewStore(player).activeId = nil end
    sendToServer(player, "BPDelete", { id = id })
    return true
end

local function resolveDefinition(placement)
    if not placement then return nil, nil end
    local definition, stage = Resolver.resolveStage(
        placement.buildableId, placement.variantId, placement.materialId, placement.stageId
    )
    return definition, stage
end

-- Shared with the ghost renderer and the editor so previews always use the
-- same variant/material-merged stage as validation.
---@param placement KBW.BlueprintPlacement
function Blueprints.resolvePlacement(placement)
    return resolveDefinition(placement)
end

-- Expanded cells are cached per placement id and revalidated by identity
-- (edits replace the placement table, moves shift coordinates in place), so
-- intersection checks over large blueprints do not re-expand every footprint
-- on every mouse move.
local placementCellCache = {}
local placementCellCacheCount = 0
local PLACEMENT_CELL_CACHE_LIMIT = 4096

local function placementCells(placement)
    local key = placement.id
    local cached = key and placementCellCache[key] or nil
    if cached and cached.placement == placement and cached.x == placement.x and cached.y == placement.y
        and cached.z == placement.z and cached.direction == placement.direction then
        return cached.cells, cached.definition, cached.stage
    end
    local definition, stage = resolveDefinition(placement)
    if not stage then return {} end
    local placementKind = ((definition or {}).placement or {}).kind or "object"
    local cells = Matrix.getFaceCells(stage, tonumber(placement.direction) or 1)
    if not cells then
        cells = {
            {
                dx = 0,
                dy = 0,
                dz = 0,
                sprite = Matrix.getFaceSprite(stage, tonumber(placement.direction) or 1),
                blocks = true
            }
        }
    end
    local out = {}
    for cellIndex = 1, #cells do
        local cell = cells[cellIndex]
        if cell.sprite or cell.blocks then
            out[#out + 1] = {
                x = (placement.x or 0) + (cell.dx or 0),
                y = (placement.y or 0) + (cell.dy or 0),
                z = (placement.z or 0) + (cell.dz or 0),
                layer = cell.kind or placementKind,
                sprite = cell.sprite,
                buildableId = placement.buildableId,
                placementId = placement.id,
                sourcePlacement = placement
            }
        end
    end
    if key then
        if placementCellCacheCount >= PLACEMENT_CELL_CACHE_LIMIT then
            placementCellCache = {}
            placementCellCacheCount = 0
        end
        if placementCellCache[key] == nil then placementCellCacheCount = placementCellCacheCount + 1 end
        placementCellCache[key] = {
            placement = placement,
            x = placement.x,
            y = placement.y,
            z = placement.z,
            direction = placement.direction,
            cells = out,
            definition = definition,
            stage = stage
        }
    end
    return out, definition, stage
end

local function cellKey(cell)
    return tostring(cell.x) .. "," .. tostring(cell.y) .. "," .. tostring(cell.z)
end

local function placementLayer(layer)
    layer = tostring(layer or "object")
    if layer == "floor" then return "floor" end
    if layer == "wall" or layer == "fence" or layer == "barrier" then return "wall" end
    if layer == "overlay" or layer == "wallCovering" or layer == "finish" or layer == "paint" or layer == "wallpaper"
        or layer == "graffiti" then
        return "overlay"
    end
    return "object"
end

local function layersConflict(a, b)
    a = placementLayer(a)
    b = placementLayer(b)
    if a == "overlay" or b == "overlay" then return false end
    return a == b
end

local function stackableCell(cell)
    if not cell or not cell.sprite or not getSprite then return false end
    local sprite = getSprite(cell.sprite)
    local props = sprite and sprite:getProperties()
    return props and props:has("IsStackable") == true
end

local function canShareCell(a, b)
    if placementLayer(a and a.layer) ~= "object" or placementLayer(b and b.layer) ~= "object" then return false end
    return stackableCell(a) and stackableCell(b)
end

-- A tile has two independent wall edges. A west-edge wall and a north-edge
-- wall may occupy the same x/y/z to form a corner, while duplicate walls,
-- stages, frames or finishes on the same edge continue through the stricter
-- compatibility checks below.
local function perpendicularWallEdges(a, b)
    if placementLayer(a and a.layer) ~= "wall" or placementLayer(b and b.layer) ~= "wall" then return false end
    local aPlacement = a and a.sourcePlacement
    local bPlacement = b and b.sourcePlacement
    if not aPlacement or not bPlacement then return false end
    local aDirection = tonumber(aPlacement.direction) or 1
    local bDirection = tonumber(bPlacement.direction) or 1
    local aNorth = aDirection == 2 or aDirection == 4
    local bNorth = bDirection == 2 or bDirection == 4
    return aNorth ~= bNorth
end

local function compactName(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "[%s_%-%(%)%.:]+", "")
    value = string.gsub(value, "wooden", "wood")
    return value
end

local function previousNameList(previousStage)
    local names = {}
    if type(previousStage) == "table" then
        for nameIndex = 1, #previousStage do
            names[#names + 1] = compactName(previousStage[nameIndex])
        end
    else
        names[1] = compactName(previousStage)
    end
    return names
end

local function stageNameMatches(definition, stage, names)
    if not definition or not stage then return false end
    local compat = EntityCompat.metadata(stage)
    local spriteConfig = compat.spriteConfig or {}
    local candidates = {
        stage.id, stage.label, stage.displayName, definition.id, definition.displayName, compat.entity,
        spriteConfig.logicClass
    }
    for candidateIndex = 1, #candidates do
        local candidate = compactName(candidates[candidateIndex])
        if candidate ~= "" then
            for nameIndex = 1, #names do
                if candidate == names[nameIndex] then return true end
            end
        end
    end
    return false
end

local function plannedStageMatches(previousStage, placement)
    local definition, stage = resolveDefinition(placement)
    return stageNameMatches(definition, stage, previousNameList(previousStage))
end

-- Directions 1/3 (W/E) and 2/4 (N/S) resolve to the same wall edge, so frame
-- and upgrade only need to agree on north-ness, exactly like the built-object
-- getNorth() comparison in Placement.validate.
local function directionNorth(direction)
    direction = tonumber(direction) or 1
    return direction == 2 or direction == 4
end

local function wallCoveringAction(definition, stage)
    if not definition or ((definition.placement or {}).kind ~= "wallCovering") then return nil end
    local compat = EntityCompat.metadata(stage)
    local config = compat.wallCoveringConfig or {}
    return config.type or (definition.placement or {}).wallCoveringType
end

local function isFinalCovering(action)
    action = WallFinishes.actionMode(action)
    return action == "paint" or action == "wallpaper"
end

local function wallCoveringsConflict(existing, incoming)
    if not existing or not incoming then return false end
    if tonumber(existing.x) ~= tonumber(incoming.x) or tonumber(existing.y) ~= tonumber(incoming.y)
        or tonumber(existing.z) ~= tonumber(incoming.z) then
        return false
    end
    if directionNorth(existing.direction) ~= directionNorth(incoming.direction) then return false end
    local existingDefinition, existingStage = resolveDefinition(existing)
    local incomingDefinition, incomingStage = resolveDefinition(incoming)
    local existingAction = wallCoveringAction(existingDefinition, existingStage)
    local incomingAction = wallCoveringAction(incomingDefinition, incomingStage)
    if not existingAction or not incomingAction then return false end
    local existingMode = WallFinishes.actionMode(existingAction)
    local incomingMode = WallFinishes.actionMode(incomingAction)
    if existingMode == incomingMode then return true end
    return isFinalCovering(existingMode) and isFinalCovering(incomingMode)
end

local function objectWallEdge(object, north)
    if not object or not object.getProperties then return false end
    if instanceof(object, "IsoThumpable") and object.getNorth then return object:getNorth() == north end
    local props = object:getProperties()
    if not props then return false end
    if north then
        return props:has("WallN") or props:has("WindowN") or props:has("DoorWallN") or props:has("WallNW")
    end
    return props:has("WallW") or props:has("WindowW") or props:has("DoorWallW") or props:has("WallNW")
end

-- Finds a built wall on the placement's edge the finish can apply to. When
-- every edge object rejects the finish, the second return carries the most
-- specific rejection so the player hears "must be plastered first" or "not
-- mapped for this wall" instead of a generic no-wall message.
---@param placement KBW.BlueprintPlacement
---@param hasPlasterAction boolean|nil
function Blueprints.findFinishObject(placement, hasPlasterAction)
    if not placement or not getCell then return nil end
    local definition, stage = resolveDefinition(placement)
    local action = wallCoveringAction(definition, stage)
    if not action then return nil end
    local square = getCell():getGridSquare(placement.x, placement.y, placement.z)
    if not square then return nil end
    local north = directionNorth(placement.direction)
    local bestReason = nil
    local function findIn(objects)
        for objectIndex = 0, objects:size() - 1 do
            local object = objects:get(objectIndex)
            if objectWallEdge(object, north) then
                local ok, reason = WallFinishes.canApplyToObject(action, placement.finish, object, hasPlasterAction)
                if ok then return object end
                bestReason = bestReason or reason
            end
        end
        return nil
    end
    local found = findIn(square:getSpecialObjects()) or findIn(square:getObjects())
    return found, bestReason
end

-- Resolves and stamps the wall face targeted by a planned covering. The
-- target can be a planned wall or an already-built wall on the exact N/W
-- edge. Addons only need to provide their wall finish mapping/capabilities;
-- no planner code changes are required for new tile packs.
---@param player IsoPlayer
---@param blueprint KBW.Blueprint
---@param placement KBW.BlueprintPlacement
function Blueprints.prepareFinishPlacement(player, blueprint, placement)
    local definition, stage = resolveDefinition(placement)
    local action = wallCoveringAction(definition, stage)
    if not action then return true end
    placement.direction = directionNorth(placement.direction) and 2 or 1
    local north = directionNorth(placement.direction)
    local targets = {}
    local hasPlasterAction = false
    local placements = blueprint and blueprint.placements or {}
    for placementIndex = 1, #placements do
        local existing = placements[placementIndex]
        if existing.id ~= placement.id and tonumber(existing.x) == tonumber(placement.x)
            and tonumber(existing.y) == tonumber(placement.y) and tonumber(existing.z) == tonumber(placement.z)
            and directionNorth(existing.direction) == north then
            local existingDefinition, existingStage = resolveDefinition(existing)
            local existingKind = existingDefinition and (existingDefinition.placement or {}).kind
            if existingKind == "wall" then
                targets[#targets + 1] = { placement = existing, definition = existingDefinition, stage = existingStage }
            elseif existingKind == "wallCovering" then
                local existingAction = wallCoveringAction(existingDefinition, existingStage)
                if WallFinishes.actionMode(existingAction) == "plaster" then hasPlasterAction = true end
                if wallCoveringsConflict(existing, placement) then return false, "finish action conflicts on this wall edge" end
            end
        end
    end
    local targetReason = nil
    for targetIndex = #targets, 1, -1 do
        local target = targets[targetIndex]
        local ok, reason, wallType = WallFinishes.canApplyToPlanned(
            action, placement.finish, target.definition, target.stage, target.placement.finish, hasPlasterAction
        )
        if ok then
            placement.finishTarget = {
                source = "plan",
                placementId = target.placement.id,
                buildableId = target.placement.buildableId,
                stageId = target.placement.stageId,
                wallType = wallType
            }
            return true
        end
        targetReason = targetReason or reason
    end
    if #targets > 0 then return false, targetReason or "planned wall does not support this finish" end
    local object, objectReason = Blueprints.findFinishObject(placement, hasPlasterAction)
    if not object then return false, objectReason or "no compatible wall on this edge" end
    local ok, reason, wallType = WallFinishes.canApplyToObject(action, placement.finish, object, hasPlasterAction)
    if not ok then return false, reason end
    placement.finishTarget = { source = "world", wallType = wallType }
    return true
end

---@param placement KBW.BlueprintPlacement
function Blueprints.placementMatchesPrevious(previousStage, placement)
    return plannedStageMatches(previousStage, placement)
end

local function plannedUpgradeCompatible(existing, incoming)
    if not existing or not incoming then return false end
    if tonumber(existing.z) ~= tonumber(incoming.z) then return false end
    if directionNorth(existing.direction) ~= directionNorth(incoming.direction) then return false end
    local incomingDefinition, incomingStage = resolveDefinition(incoming)
    local existingDefinition, existingStage = resolveDefinition(existing)
    local incomingPrevious = Placement.previousStageOf(incomingStage)
        or Placement.optionalReplacementStageOf(incomingStage)
    if incomingPrevious and stageNameMatches(existingDefinition, existingStage, previousNameList(incomingPrevious)) then
        return true
    end
    local existingPrevious = Placement.previousStageOf(existingStage)
        or Placement.optionalReplacementStageOf(existingStage)
    if existingPrevious and stageNameMatches(incomingDefinition, incomingStage, previousNameList(existingPrevious)) then
        return true
    end
    return false
end

local function faceSpriteFor(stage, direction)
    local name = Matrix.getFaceSprite(stage, tonumber(direction) or 1)
    return name and getSprite and getSprite(name) or nil
end

-- What kind of frame a placement's stage NEEDS on its wall edge, if any:
-- doors need a door frame (unless the script says dontNeedFrame), window
-- panes need a window frame.
local function requiredFrameKind(definition, stage, direction)
    if not definition or not stage then return nil end
    local placement = StageConfig.placement(definition, stage)
    local spriteConfig = StageConfig.sprite(definition, stage)
    if placement.needWindowFrame or spriteConfig.needWindowFrame then return "window" end
    if placement.dontNeedFrame or spriteConfig.dontNeedFrame then return nil end
    local sprite = faceSpriteFor(stage, direction)
    if sprite and (sprite:getType() == IsoObjectType.doorW or sprite:getType() == IsoObjectType.doorN) then
        return "door"
    end
    return nil
end

-- What kind of frame a placement's stage PROVIDES on its wall edge, if any.
local function providedFrameKind(definition, stage, direction)
    local sprite = faceSpriteFor(stage, direction)
    if not sprite then return nil end
    local spriteType = sprite:getType()
    if spriteType == IsoObjectType.doorFrW or spriteType == IsoObjectType.doorFrN then return "door" end
    local props = sprite:getProperties()
    if props then
        if props:has(IsoPropertyType.DOOR_WALL_W) or props:has(IsoPropertyType.DOOR_WALL_N) then return "door" end
        if props:has(IsoPropertyType.WINDOW_W) or props:has(IsoPropertyType.WINDOW_N) then return "window" end
    end
    return nil
end

-- A frame and its filler (door frame + door, window frame + window pane) may
-- share the same tile edge in a plan.
local function frameAndFillCompatible(existing, incoming)
    if not existing or not incoming then return false end
    if tonumber(existing.z) ~= tonumber(incoming.z) then return false end
    if directionNorth(existing.direction) ~= directionNorth(incoming.direction) then return false end
    local incomingDefinition, incomingStage = resolveDefinition(incoming)
    local existingDefinition, existingStage = resolveDefinition(existing)
    local need = requiredFrameKind(incomingDefinition, incomingStage, incoming.direction)
    if need and providedFrameKind(existingDefinition, existingStage, existing.direction) == need then
        return true
    end
    need = requiredFrameKind(existingDefinition, existingStage, existing.direction)
    if need and providedFrameKind(incomingDefinition, incomingStage, incoming.direction) == need then
        return true
    end
    return false
end

---@param placement KBW.BlueprintPlacement
function Blueprints.requiresFrame(placement)
    local definition, stage = resolveDefinition(placement)
    return requiredFrameKind(definition, stage, placement and placement.direction) ~= nil
end

-- A door/window ghost is only valid where its frame exists - either already
-- built in the world or planned on the same tile and edge.
---@param player IsoPlayer
---@param blueprint KBW.Blueprint
---@param placement KBW.BlueprintPlacement
function Blueprints.hasRequiredFrame(player, blueprint, placement)
    local definition, stage = resolveDefinition(placement)
    local need = requiredFrameKind(definition, stage, placement.direction)
    if not need then return true end
    local placements = blueprint and blueprint.placements or {}
    for placementIndex = 1, #placements do
        local existing = placements[placementIndex]
        if existing.id ~= placement.id and tonumber(existing.x) == tonumber(placement.x)
            and tonumber(existing.y) == tonumber(placement.y) and tonumber(existing.z) == tonumber(placement.z)
            and directionNorth(existing.direction) == directionNorth(placement.direction) then
            local existingDefinition, existingStage = resolveDefinition(existing)
            if providedFrameKind(existingDefinition, existingStage, existing.direction) == need then
                return true
            end
        end
    end
    local square = getCell() and getCell():getGridSquare(placement.x, placement.y, placement.z) or nil
    if square then
        return Placement.hasWallFrame(square, directionNorth(placement.direction), need == "window")
    end
    return false
end

---@param blueprint KBW.Blueprint
---@param placement KBW.BlueprintPlacement
function Blueprints.findIntersections(blueprint, placement)
    local conflicts = {}
    if not blueprint or not placement then return conflicts end
    local occupied = {}
    local placements = blueprint.placements or {}
    for placementIndex = 1, #placements do
        local existing = placements[placementIndex]
        if existing.id ~= placement.id then
            local cells = placementCells(existing)
            for cellIndex = 1, #cells do
                local cell = cells[cellIndex]
                local key = cellKey(cell)
                occupied[key] = occupied[key] or {}
                occupied[key][#occupied[key] + 1] = cell
            end
        end
    end
    local cells = placementCells(placement)
    for cellIndex = 1, #cells do
        local cell = cells[cellIndex]
        local previousCells = occupied[cellKey(cell)] or {}
        for previousIndex = 1, #previousCells do
            local previous = previousCells[previousIndex]
            if wallCoveringsConflict(previous.sourcePlacement, placement)
                or (layersConflict(cell.layer, previous.layer) and not canShareCell(cell, previous)
                    and not perpendicularWallEdges(cell, previous)
                    and not plannedUpgradeCompatible(previous.sourcePlacement, placement)
                    and not frameAndFillCompatible(previous.sourcePlacement, placement)) then
                conflicts[#conflicts + 1] = {
                    x = cell.x,
                    y = cell.y,
                    z = cell.z,
                    layer = placementLayer(cell.layer),
                    current = placement.buildableId,
                    previous = previous.buildableId,
                    previousPlacementId = previous.placementId
                }
            end
        end
    end
    return conflicts
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
---@param placement KBW.BlueprintPlacement
function Blueprints.hasPreviousStage(player, blueprint, placement)
    local definition, stage = resolveDefinition(placement)
    local previousStage = Placement.previousStageOf(stage) or Placement.optionalReplacementStageOf(stage)
    if not previousStage then return true end
    local placements = blueprint and blueprint.placements or {}
    for placementIndex = 1, #placements do
        local existing = placements[placementIndex]
        if existing.id ~= placement.id and tonumber(existing.x) == tonumber(placement.x)
            and tonumber(existing.y) == tonumber(placement.y) and tonumber(existing.z) == tonumber(placement.z)
            and directionNorth(existing.direction) == directionNorth(placement.direction)
            and plannedStageMatches(previousStage, existing) then
            return true
        end
    end
    local square = getCell() and getCell():getGridSquare(placement.x, placement.y, placement.z) or nil
    if square and definition then
        return Placement.findPrevious(square, definition.id, previousStage, directionNorth(placement.direction)) ~= nil
    end
    return false
end

-- Range: a blueprint is bounded to a square centred on its anchor (the first
-- ghost ever placed). radius comes from the sandbox option (400x400 => 200).
---@param blueprint KBW.Blueprint
function Blueprints.rangeAnchor(blueprint)
    if blueprint and blueprint.anchored and blueprint.anchor then return blueprint.anchor end
    if blueprint and blueprint.origin then return { x = blueprint.origin.x, y = blueprint.origin.y } end
    return nil
end

---@param blueprint KBW.Blueprint
---@param x number
---@param y number
function Blueprints.withinRange(blueprint, x, y)
    local anchor = Blueprints.rangeAnchor(blueprint)
    if not anchor then return true end
    local radius = tonumber(blueprint.radius) or Blueprints.blueprintRadius()
    return math.abs((tonumber(x) or 0) - (anchor.x or 0)) <= radius
        and math.abs((tonumber(y) or 0) - (anchor.y or 0)) <= radius
end

-- Mutators return (result, reasonCode) on failure. Codes are short stable
-- identifiers; Blueprints.planErrorText turns them into player-facing text.
---@param player IsoPlayer
---@param blueprintId string
---@param placement KBW.BlueprintPlacement
function Blueprints.addPlacement(player, blueprintId, placement)
    local blueprint = blueprintId and Blueprints.get(player, blueprintId) or Blueprints.activeOrCreate(player)
    if not blueprint or not placement or not placement.buildableId then return nil, "invalid_placement" end
    if not Blueprints.canContribute(player, blueprint) then return nil, "no_permission" end
    if #(blueprint.placements or {}) >= Blueprints.maxPlacements() then
        return nil, "placement_limit"
    end
    local entry = TableUtil.copy(placement)
    entry.id = entry.id or newId("p", entryIdTaken(blueprint.placements))
    entry.z = entry.z == nil and blueprint.level or entry.z
    local finishOk, finishReason = Blueprints.prepareFinishPlacement(player, blueprint, entry)
    if not finishOk then return nil, finishReason end
    -- The first ghost sets the range anchor; everything else must fall inside
    -- the blueprint's square.
    if not blueprint.anchored then
        blueprint.anchor = { x = tonumber(entry.x) or 0, y = tonumber(entry.y) or 0 }
        blueprint.anchored = true
    elseif not Blueprints.withinRange(blueprint, entry.x, entry.y) then
        return nil, "out_of_range"
    end
    local conflicts = Blueprints.findIntersections(blueprint, entry)
    if #conflicts > 0 then return nil, "plan_overlap", conflicts end
    blueprint.placements = blueprint.placements or {}
    blueprint.placements[#blueprint.placements + 1] = entry
    touch(blueprint)
    sendToServer(player, "BPAddPlacement", { id = blueprint.id, placement = entry, anchor = blueprint.anchor })
    return entry
end

---@param player IsoPlayer
---@param blueprintId string
---@param room KBW.BlueprintRoom
function Blueprints.addRoom(player, blueprintId, room)
    local blueprint = blueprintId and Blueprints.get(player, blueprintId) or Blueprints.activeOrCreate(player)
    if not blueprint or not room then return nil, "invalid_room" end
    if not Blueprints.canContribute(player, blueprint) then return nil, "no_permission" end
    local entry = TableUtil.copy(room)
    blueprint.rooms = blueprint.rooms or {}
    entry.id = entry.id or newId("r", entryIdTaken(blueprint.rooms))
    entry.type = entry.type or "room"
    entry.color = entry.color or { r = 0.25, g = 0.65, b = 0.95, a = 0.12 }
    entry.z = entry.z == nil and blueprint.level or entry.z
    blueprint.rooms = blueprint.rooms or {}
    blueprint.rooms[#blueprint.rooms + 1] = entry
    touch(blueprint)
    sendToServer(player, "BPAddRoom", { id = blueprint.id, room = entry })
    return entry
end

-- Gather area (container/vehicle search zone) is contributor-editable state.
---@param player IsoPlayer
---@param blueprintId string
function Blueprints.setGatherArea(player, blueprintId, area)
    local blueprint = Blueprints.get(player, blueprintId)
    if not blueprint then return false, "invalid_placement" end
    if not Blueprints.canContribute(player, blueprint) then return false, "no_permission" end
    blueprint.gatherArea = area and TableUtil.copy(area) or nil
    touch(blueprint)
    sendToServer(player, "BPSetGatherArea", { id = blueprintId, area = blueprint.gatherArea })
    return true
end

---@param player IsoPlayer
---@param blueprintId string
---@param dx number
---@param dy number
---@param dz number
---@param fromNetwork boolean|nil
function Blueprints.move(player, blueprintId, dx, dy, dz, fromNetwork)
    local blueprint = Blueprints.get(player, blueprintId)
    if not blueprint then return false end
    if not fromNetwork and not Blueprints.canContribute(player, blueprint) then return false end
    dx = dx or 0
    dy = dy or 0
    dz = dz or 0
    if blueprint.anchor then
        blueprint.anchor.x = (blueprint.anchor.x or 0) + dx
        blueprint.anchor.y = (blueprint.anchor.y or 0) + dy
    end
    if blueprint.origin then
        blueprint.origin.x = (blueprint.origin.x or 0) + dx
        blueprint.origin.y = (blueprint.origin.y or 0) + dy
        blueprint.origin.z = (blueprint.origin.z or 0) + dz
    end
    local rooms = blueprint.rooms or {}
    for roomIndex = 1, #rooms do
        local room = rooms[roomIndex]
        room.x = room.x and room.x + dx or room.x
        room.y = room.y and room.y + dy or room.y
        room.z = room.z and room.z + dz or room.z
    end
    local placements = blueprint.placements or {}
    for placementIndex = 1, #placements do
        local placement = placements[placementIndex]
        placement.x = placement.x and placement.x + dx or placement.x
        placement.y = placement.y and placement.y + dy or placement.y
        placement.z = placement.z and placement.z + dz or placement.z
    end
    local area = blueprint.gatherArea
    if area then
        area.x1 = (area.x1 or 0) + dx
        area.y1 = (area.y1 or 0) + dy
        area.x2 = (area.x2 or 0) + dx
        area.y2 = (area.y2 or 0) + dy
        area.z = (area.z or 0) + dz
    end
    blueprint.level = (tonumber(blueprint.level) or 0) + dz
    touch(blueprint)
    if not fromNetwork then sendToServer(player, "BPMove", { id = blueprintId, dx = dx, dy = dy, dz = dz }) end
    return true
end

---@param player IsoPlayer
---@param name string|nil
function Blueprints.rename(player, id, name)
    local blueprint = Blueprints.get(player, id)
    if not blueprint or not name or name == "" then return false end
    if not Blueprints.isOwner(player, blueprint) then return false end
    blueprint.name = tostring(name)
    touch(blueprint)
    sendToServer(player, "BPRename", { id = id, name = blueprint.name })
    return true
end

---@param player IsoPlayer
---@param level number|string
function Blueprints.setLevel(player, id, level)
    local blueprint = Blueprints.get(player, id)
    level = tonumber(level)
    if not blueprint or level == nil then return false end
    if not Blueprints.canContribute(player, blueprint) then return false end
    blueprint.level = math.floor(level)
    touch(blueprint)
    sendToServer(player, "BPSetLevel", { id = id, level = blueprint.level })
    return true
end

---@param player IsoPlayer
function Blueprints.duplicate(player, id)
    local blueprint = Blueprints.get(player, id)
    if not blueprint then return nil end
    local items = Blueprints.sharedItems()
    local copy = TableUtil.copy(blueprint)
    copy.id = newId("bp", storeIdTaken(items))
    copy.name = tostring(blueprint.name or blueprint.id) .. " (2)"
    copy.owner = playerName(player)
    copy.access = defaultAccess()
    copy.updated = timestamp()
    items[copy.id] = copy
    persist(copy)
    if isMPClient() then sendToServer(player, "BPCreate", { blueprint = copy }) end
    return copy
end

---@param blueprint KBW.Blueprint
---@param placementId string
function Blueprints.getPlacement(blueprint, placementId)
    return findById(blueprint and blueprint.placements, placementId)
end

---@param blueprint KBW.Blueprint
---@param roomId string
function Blueprints.getRoom(blueprint, roomId)
    return findById(blueprint and blueprint.rooms, roomId)
end

---@param player IsoPlayer
---@param blueprintId string
---@param roomId string
---@param fields table<string, unknown>
function Blueprints.updateRoom(player, blueprintId, roomId, fields)
    local blueprint = Blueprints.get(player, blueprintId)
    local room = Blueprints.getRoom(blueprint, roomId)
    if not room or type(fields) ~= "table" then return false end
    if not Blueprints.canContribute(player, blueprint) then return false end
    for key, value in pairs(fields) do
        room[key] = TableUtil.copy(value)
    end
    touch(blueprint)
    sendToServer(player, "BPUpdateRoom", { id = blueprintId, roomId = roomId, fields = fields })
    return true
end

---@param player IsoPlayer
---@param blueprintId string
---@param roomId string
function Blueprints.removeRoom(player, blueprintId, roomId)
    local blueprint = Blueprints.get(player, blueprintId)
    local room, index = Blueprints.getRoom(blueprint, roomId)
    if not room then return false end
    if not Blueprints.canContribute(player, blueprint) then return false end
    table.remove(blueprint.rooms, index)
    touch(blueprint)
    sendToServer(player, "BPRemoveRoom", { id = blueprintId, roomId = roomId })
    return true
end

-- Removing a placement happens both when a player erases a plan (needs
-- contribute) and when a built ghost is consumed (needs only build). The build
-- flow passes requireBuildOnly so a build-access player can complete plans.
---@param player IsoPlayer
---@param blueprintId string
---@param placementId string
---@param requireBuildOnly boolean|nil
function Blueprints.removePlacement(player, blueprintId, placementId, requireBuildOnly)
    local blueprint = Blueprints.get(player, blueprintId)
    local placement, index = Blueprints.getPlacement(blueprint, placementId)
    if not placement then return false end
    local allowed = requireBuildOnly and Blueprints.canBuild(player, blueprint)
        or Blueprints.canContribute(player, blueprint)
    if not allowed then return false end
    table.remove(blueprint.placements, index)
    touch(blueprint)
    sendToServer(player, "BPRemovePlacement", { id = blueprintId, placementId = placementId })
    return true
end

-- All placements whose expanded footprint covers the given world tile.
---@param blueprint KBW.Blueprint
---@param x number
---@param y number
---@param z number
function Blueprints.placementsAt(blueprint, x, y, z)
    local found = {}
    local placements = blueprint and blueprint.placements or {}
    for placementIndex = 1, #placements do
        local placement = placements[placementIndex]
        local cells = placementCells(placement)
        for cellIndex = 1, #cells do
            local cell = cells[cellIndex]
            if cell.x == x and cell.y == y and cell.z == z then
                found[#found + 1] = placement
                break
            end
        end
    end
    return found
end

---@param blueprint KBW.Blueprint
---@param x number
---@param y number
---@param z number
function Blueprints.roomsAt(blueprint, x, y, z)
    local found = {}
    local rooms = blueprint and blueprint.rooms or {}
    for roomIndex = 1, #rooms do
        local room = rooms[roomIndex]
        local roomZ = tonumber(room.z or blueprint.level or 0)
        local width = room.w or room.width or 1
        local height = room.h or room.height or 1
        if roomZ == z and x >= (room.x or 0)
            and x < (room.x or 0) + width and y >= (room.y or 0)
            and y < (room.y or 0) + height then
            found[#found + 1] = room
        end
    end
    return found
end

-- Erase tool: removes ONE placement covering the tile - the most recently
-- planned one - so clicking a planned shelf never takes the floor plan or the
-- room underneath with it. Repeated clicks peel stacked plans one at a time.
-- Returns the removed placement (or nil).
---@param player IsoPlayer
---@param blueprintId string
---@param x number
---@param y number
---@param z number
function Blueprints.erasePlacementAt(player, blueprintId, x, y, z)
    local blueprint = Blueprints.get(player, blueprintId)
    if not blueprint then return nil end
    local covering = Blueprints.placementsAt(blueprint, x, y, z)
    local target = covering[#covering]
    if not target then return nil end
    if Blueprints.removePlacement(player, blueprintId, target.id) then return target end
    return nil
end

-- Room erase is a separate, explicit mode; it removes only the topmost room
-- covering the tile and never touches placements.
---@param player IsoPlayer
---@param blueprintId string
---@param x number
---@param y number
---@param z number
function Blueprints.eraseRoomAt(player, blueprintId, x, y, z)
    local blueprint = Blueprints.get(player, blueprintId)
    if not blueprint then return nil end
    local covering = Blueprints.roomsAt(blueprint, x, y, z)
    local target = covering[#covering]
    if not target then return nil end
    if Blueprints.removeRoom(player, blueprintId, target.id) then return target end
    return nil
end

local function addMaterialTotal(totals, key, label, labelKey, amount, row)
    local bucket = totals[key]
    if not bucket then
        bucket = { key = key, label = label, labelKey = labelKey, amount = 0, rows = 0, row = row }
        totals[key] = bucket
    end
    bucket.amount = bucket.amount + (amount or 1)
    bucket.rows = bucket.rows + 1
    return bucket
end

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
function Blueprints.totals(player, blueprint)
    local result = { materials = {}, tools = {}, skills = {}, recipes = {}, buildables = {}, placements = 0 }
    if not blueprint then return result end
    local placements = blueprint.placements or {}
    result.placements = #placements
    for placementIndex = 1, #placements do
        local placement = placements[placementIndex]
        local definition, stage = resolveDefinition(placement)
        if definition and stage then
            local buildable = result.buildables[definition.id] or { id = definition.id, count = 0 }
            buildable.count = buildable.count + 1
            result.buildables[definition.id] = buildable
            local inputs = Requirements.getInputs(definition, stage)
            local choices = placement.inputChoices or {}
            for inputIndex = 1, #inputs do
                local input = inputs[inputIndex]
                local amount = input.uses or input.amount or 1
                local key = input.id or "input"
                local label = input.label or key
                local labelKey = input.labelKey
                local totalRow = input
                -- A concrete item picked for this input (paint color,
                -- wallpaper pattern) totals under that item, not the tag.
                local chosen = input.id and choices[input.id] or nil
                if chosen then
                    key = tostring(chosen)
                    label = key
                    totalRow = {
                        mode = input.mode,
                        uses = input.uses,
                        amount = input.amount,
                        selectedFullType = key,
                        items = { key },
                        tags = {}
                    }
                elseif input.items and input.items[1] then
                    key = input.items[1]
                    label = input.label or input.items[1]
                elseif input.tags and input.tags[1] then
                    key = "#" .. input.tags[1]
                    label = input.label or input.tags[1]
                end
                if input.role == "tool" or input.mode == "keep" then
                    local tool = result.tools[key]
                        or { key = key, label = label, labelKey = labelKey, amount = 0, row = totalRow }
                    tool.amount = math.max(tool.amount or 0, amount)
                    result.tools[key] = tool
                else
                    addMaterialTotal(result.materials, key, label, labelKey, amount, totalRow)
                end
            end
            -- Planned wall finishes add their own materials (plaster bucket
            -- uses, paint cans, wallpaper + paste).
            if WallFinishes.isWallFinish(placement.finish) then
                local finishRows = WallFinishes.statusRows(player, placement.finish)
                for rowIndex = 1, #finishRows do
                    local row = finishRows[rowIndex]
                    local key = (row.possibleItems and row.possibleItems[1]) or row.label or row.id
                    row.selectedFullType = key
                    local label = row.label or key
                    local labelKey = row.labelKey
                    local amount = row.uses or row.needed or 1
                    if row.role == "tool" then
                        local tool = result.tools[key]
                            or { key = key, label = label, labelKey = labelKey, amount = 0, row = row }
                        tool.amount = math.max(tool.amount or 0, amount)
                        result.tools[key] = tool
                    else
                        addMaterialTotal(result.materials, key, label, labelKey, amount, row)
                    end
                end
            end
            local skills = (stage.requirements or {}).skills or {}
            for perkName, needed in pairs(skills) do
                local skill = result.skills[perkName] or { name = perkName, needed = 0 }
                skill.needed = math.max(skill.needed or 0, needed or 0)
                result.skills[perkName] = skill
            end
            local recipes = (stage.requirements or {}).recipes or {}
            for recipeIndex = 1, #recipes do
                result.recipes[recipes[recipeIndex]] = true
            end
            local knowledge = (stage.requirements or {}).knowledge or {}
            local knowledgeRecipes = knowledge.recipes or {}
            for recipeIndex = 1, #knowledgeRecipes do
                result.recipes[knowledgeRecipes[recipeIndex]] = true
            end
        end
    end
    return result
end

-- Blueprints are kept in world coordinates while in play (every consumer -
-- ghost renderer, intersection checks, build conversion - works on world
-- tiles), but they EXPORT in origin-relative coordinates so a shared blueprint
-- can be re-anchored anywhere on any map by any player. Exports carry only
-- what another save or player needs: name, rooms, placements and gather area.
-- Ownership, access lists, range anchoring, radius and timestamps are local
-- state and are rebuilt on import.
---@param blueprint KBW.Blueprint
function Blueprints.exportTable(blueprint)
    local data = TableUtil.copy(blueprint or {})
    data.id, data.owner, data.access, data.updated = nil, nil, nil, nil
    data.anchor, data.anchored, data.radius = nil, nil, nil
    local origin = data.origin or { x = 0, y = 0, z = tonumber(data.level) or 0 }
    local placements = data.placements or {}
    for placementIndex = 1, #placements do
        local placement = placements[placementIndex]
        placement.x = (placement.x or 0) - (origin.x or 0)
        placement.y = (placement.y or 0) - (origin.y or 0)
        placement.z = (placement.z or 0) - (origin.z or 0)
    end
    local rooms = data.rooms or {}
    for roomIndex = 1, #rooms do
        local room = rooms[roomIndex]
        room.x = (room.x or 0) - (origin.x or 0)
        room.y = (room.y or 0) - (origin.y or 0)
        if room.z ~= nil then room.z = room.z - (origin.z or 0) end
    end
    local area = data.gatherArea
    if area then
        area.x1 = (area.x1 or 0) - (origin.x or 0)
        area.y1 = (area.y1 or 0) - (origin.y or 0)
        area.x2 = (area.x2 or 0) - (origin.x or 0)
        area.y2 = (area.y2 or 0) - (origin.y or 0)
        area.z = (area.z or 0) - (origin.z or 0)
    end
    data.relativeLevel = (tonumber(data.level) or 0) - (origin.z or 0)
    data.level = nil
    data.origin = nil
    data.exportSchema = Blueprints.VERSION
    return data
end

-- Converts exported (relative) data back to world coordinates anchored at the
-- given tile.
function Blueprints.anchorImported(data, anchorX, anchorY, anchorZ)
    if not data then return nil end
    local origin = { x = math.floor(anchorX or 0), y = math.floor(anchorY or 0), z = math.floor(anchorZ or 0) }
    local placements = data.placements or {}
    for placementIndex = 1, #placements do
        local placement = placements[placementIndex]
        placement.x = (placement.x or 0) + origin.x
        placement.y = (placement.y or 0) + origin.y
        placement.z = (placement.z or 0) + origin.z
    end
    local rooms = data.rooms or {}
    for roomIndex = 1, #rooms do
        local room = rooms[roomIndex]
        room.x = (room.x or 0) + origin.x
        room.y = (room.y or 0) + origin.y
        if room.z ~= nil then room.z = room.z + origin.z end
    end
    local area = data.gatherArea
    if area then
        area.x1 = (area.x1 or 0) + origin.x
        area.y1 = (area.y1 or 0) + origin.y
        area.x2 = (area.x2 or 0) + origin.x
        area.y2 = (area.y2 or 0) + origin.y
        area.z = (area.z or 0) + origin.z
    end
    data.level = origin.z + (tonumber(data.relativeLevel) or 0)
    data.relativeLevel = nil
    data.origin = origin
    return data
end

-- Re-anchors a whole blueprint so its origin lands on the given world tile
-- ("bring my shared base plan to where I stand").
---@param player IsoPlayer
---@param x number
---@param y number
---@param z number
function Blueprints.moveTo(player, id, x, y, z)
    local blueprint = Blueprints.get(player, id)
    if not blueprint then return false end
    local origin = blueprint.origin or { x = 0, y = 0, z = tonumber(blueprint.level) or 0 }
    local dx = math.floor(x or 0) - (origin.x or 0)
    local dy = math.floor(y or 0) - (origin.y or 0)
    local dz = math.floor(z or 0) - (origin.z or 0)
    if dx == 0 and dy == 0 and dz == 0 then return true end
    return Blueprints.move(player, id, dx, dy, dz)
end

---@param blueprint KBW.Blueprint
function Blueprints.exportJSON(blueprint)
    return JSON.stringify(Blueprints.exportTable(blueprint))
end

-- Writes a blueprint onto an existing KBW_Blueprint inventory item, so
-- sharing works through the item's own context menu instead of conjuring
-- items out of thin air.
---@param blueprint KBW.Blueprint
function Blueprints.writeToItem(item, blueprint)
    if not item or not blueprint then return nil end
    local data = item:getModData()
    data.KBW_Blueprint = Blueprints.exportTable(blueprint)
    if item.setName then item:setName(blueprint.name or defaultName()) end
    return item
end

function Blueprints.readBlueprintItem(item)
    if not item or not item.getModData then return nil end
    local data = item:getModData()
    return data and data.KBW_Blueprint or nil
end

-- Turns exported (relative) blueprint data into a live blueprint owned by the
-- importing player. Shared by item and file import. Relative coordinates
-- anchor where the player stands; the Move blueprint cursor re-anchors after.
-- The importer gets a fresh private ACL and the range anchor re-locks around
-- wherever the plan lands.
---@param player IsoPlayer
function Blueprints.importExported(player, exported)
    if type(exported) ~= "table" or type(exported.placements) ~= "table" then
        return nil, "invalid_blueprint"
    end
    if exported.exportSchema ~= Blueprints.VERSION then
        return nil, "unsupported_schema:" .. tostring(exported.exportSchema)
    end
    local blueprint = TableUtil.copy(exported)
    blueprint.exportSchema = nil
    Blueprints.anchorImported(
        blueprint, player and player.getX and player:getX() or 0, player and player.getY and player:getY() or 0,
        player and player.getZ and player:getZ() or 0
    )
    local items = Blueprints.sharedItems()
    blueprint.id = newId("bp", storeIdTaken(items))
    blueprint.name = tostring(blueprint.name or defaultName())
    blueprint.owner = playerName(player)
    blueprint.access = defaultAccess()
    blueprint.radius = Blueprints.blueprintRadius()
    blueprint.anchored = false
    blueprint.anchor = nil
    if #(blueprint.placements or {}) > 0 then
        blueprint.anchor = { x = blueprint.placements[1].x, y = blueprint.placements[1].y }
        blueprint.anchored = true
    end
    blueprint.updated = timestamp()
    items[blueprint.id] = blueprint
    persist(blueprint)
    viewStore(player).activeId = blueprint.id
    if isMPClient() then sendToServer(player, "BPCreate", { blueprint = blueprint }) end
    return blueprint
end

---@param player IsoPlayer
function Blueprints.importBlueprintItem(player, item)
    local exported = Blueprints.readBlueprintItem(item)
    if not exported then return nil, "invalid_blueprint" end
    return Blueprints.importExported(player, exported)
end

-- FILE EXPORT / IMPORT ------------------------------------------------------
-- Players exchange blueprints as plain .json files in Lua/KnoxBuildworks/
-- exports/ (their own Zomboid/Lua folder): export writes there, import lists
-- whatever .json files were dropped there - from another player or another
-- save - and reads them with the non-throwing decoder so a malformed file is
-- reported instead of erroring.

-- Export file names must stay ASCII so they survive any OS and language.
-- A readable ASCII fragment is retained when a blueprint title has one; the
-- stable blueprint id guarantees that titles in Cyrillic, CJK, Arabic, etc.
-- never become invalid or colliding paths. The original full name remains in
-- the JSON and is shown as the primary label by the import window.
local function fileSlug(name)
    local slug = string.lower(tostring(name or ""))
    slug = string.gsub(slug, "[^A-Za-z0-9]+", "_")
    slug = string.gsub(slug, "^_+", "")
    slug = string.gsub(slug, "_+$", "")
    if #slug > 32 then slug = string.sub(slug, 1, 32) end
    return slug
end

---@param blueprint KBW.Blueprint
function Blueprints.exportFileName(blueprint)
    local slug = fileSlug(blueprint and blueprint.name)
    local id = string.gsub(tostring(blueprint and blueprint.id or "blueprint"), "[^A-Za-z0-9_-]", "_")
    local prefix = "knox_blueprint"
    if slug ~= "" then prefix = prefix .. "_" .. slug end
    return prefix .. "_" .. id .. ".json"
end

---@param blueprint KBW.Blueprint
function Blueprints.exportToFile(blueprint)
    if not blueprint then return nil end
    local path = Blueprints.EXPORT_FOLDER .. "/" .. Blueprints.exportFileName(blueprint)
    local writer = getFileWriter(path, true, false)
    if not writer then return nil end
    writer:write(Blueprints.exportJSON(blueprint))
    writer:close()
    return path
end

function Blueprints.listImportFiles()
    local names = {}
    if not listFilesInZomboidLuaDirectory then return names end
    local files = listFilesInZomboidLuaDirectory(Blueprints.EXPORT_FOLDER)
    if not files then return names end
    for fileIndex = 0, files:size() - 1 do
        local name = tostring(files:get(fileIndex))
        if string.sub(name, -5) == ".json" then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

-- Keep the portable filename as data, but read the blueprint title from JSON
-- for the player-facing import list. This makes exports with any language easy
-- to identify without relying on Unicode filesystem behaviour.
function Blueprints.listImportFileDetails()
    local details = {}
    local names = Blueprints.listImportFiles()
    for nameIndex = 1, #names do
        local fileName = names[nameIndex]
        local data = Blueprints.readImportFile(fileName)
        local displayName = data and data.name and tostring(data.name) or fileName
        details[#details + 1] = { fileName = fileName, displayName = displayName }
    end
    table.sort(details, function (a, b)
        local nameA = string.lower(tostring(a.displayName or a.fileName))
        local nameB = string.lower(tostring(b.displayName or b.fileName))
        if nameA ~= nameB then return nameA < nameB end
        return tostring(a.fileName) < tostring(b.fileName)
    end)
    return details
end

-- Reads and decodes one export file without importing it (the import window
-- uses this to show the blueprint name stored inside each file).
---@param fileName string
function Blueprints.readImportFile(fileName)
    if not fileName or string.find(fileName, "[/\\]") then return nil, "invalid_file_name" end
    local reader = getFileReader(Blueprints.EXPORT_FOLDER .. "/" .. fileName, false)
    if not reader then return nil, "file_not_found" end
    local lines, line = {}, reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    local data, err = SafeJSON.decode(table.concat(lines, "\n"))
    if not data then return nil, "invalid_json" end
    return data
end

---@param player IsoPlayer
---@param fileName string
function Blueprints.importFromFile(player, fileName)
    local data, err = Blueprints.readImportFile(fileName)
    if not data then return nil, err end
    return Blueprints.importExported(player, data)
end

-- Player-facing text for plan editing failures (addPlacement/addRoom/
-- setGatherArea reason codes plus the plan cursor's validity checks).
---@param code string|nil
---@param blueprint KBW.Blueprint
function Blueprints.planErrorText(code, blueprint)
    code = tostring(code or "")
    if code == "no_permission" then return I18n.text("IGUI_KBW_PlanNoPermission") end
    if code == "placement_limit" then
        return string.format(I18n.text("IGUI_KBW_PlanLimitReached"), Blueprints.maxPlacements())
    end
    if code == "out_of_range" then
        local radius = (blueprint and tonumber(blueprint.radius)) or Blueprints.blueprintRadius()
        return string.format(I18n.text("IGUI_KBW_PlanOutOfRange"), radius)
    end
    if code == "plan_overlap" then return I18n.text("IGUI_KBW_PlanConflict") end
    if code == "needs_previous_stage" then return I18n.text("IGUI_KBW_PlanNeedsPreviousStage") end
    if code == "needs_wall_frame" then return I18n.text("IGUI_KBW_PlanNeedsWallFrame") end
    if code == "needs_frame" then return I18n.text("IGUI_KBW_PlanNeedsFrame") end
    return I18n.text("IGUI_KBW_PlanInvalid")
end

local finishErrorKeys = {
    ["no compatible wall face"] = "IGUI_KBW_FinishNoWall",
    ["no compatible wall on this edge"] = "IGUI_KBW_FinishNoWall",
    ["finish is not mapped for this wall surface"] = "IGUI_KBW_FinishNotMapped",
    ["wall surface cannot be plastered"] = "IGUI_KBW_FinishCannotPlaster",
    ["wall is not ready for plaster"] = "IGUI_KBW_FinishNotReadyForPlaster",
    ["wall surface cannot be painted"] = "IGUI_KBW_FinishCannotPaint",
    ["wall must be plastered before painting"] = "IGUI_KBW_FinishNeedsPlasterPaint",
    ["wall surface cannot be wallpapered"] = "IGUI_KBW_FinishCannotWallpaper",
    ["wall must be plastered before wallpapering"] = "IGUI_KBW_FinishNeedsPlasterWallpaper",
    ["planned wall cannot be plastered"] = "IGUI_KBW_FinishCannotPlaster",
    ["planned wall is already plastered"] = "IGUI_KBW_FinishAlreadyPlastered",
    ["planned wall cannot be painted"] = "IGUI_KBW_FinishCannotPaint",
    ["plan plaster before painting"] = "IGUI_KBW_FinishPlanPlasterPaint",
    ["planned wall cannot be wallpapered"] = "IGUI_KBW_FinishCannotWallpaper",
    ["plan plaster before wallpapering"] = "IGUI_KBW_FinishPlanPlasterWallpaper",
    ["finish action conflicts on this wall edge"] = "IGUI_KBW_FinishConflict",
    ["planned wall does not support this finish"] = "IGUI_KBW_FinishNotMapped",
    ["finish sprite is unavailable for target wall"] = "IGUI_KBW_FinishNotMapped"
}

---@param reason string|nil
function Blueprints.finishErrorText(reason)
    local key = finishErrorKeys[tostring(reason or "")]
    return key and I18n.text(key) or I18n.text("IGUI_KBW_PlanInvalid")
end

function Blueprints.importErrorText(error)
    error = tostring(error or "")
    if error == "invalid_blueprint" then return I18n.text("IGUI_KBW_BlueprintImportInvalid") end
    if error == "invalid_file_name" or error == "file_not_found" then
        return I18n.text("IGUI_KBW_BlueprintImportFileMissing")
    end
    if error == "invalid_json" then return I18n.text("IGUI_KBW_BlueprintImportMalformed") end
    local schema = string.match(error, "^unsupported_schema:(.+)$")
    if schema then return string.format(I18n.text("IGUI_KBW_BlueprintImportUnsupportedSchema"), schema) end
    return I18n.text("IGUI_KBW_BlueprintImportMalformed")
end

-- True when the placement's target square already holds the matching built
-- object. Lets the server tell an honest build-consume removal (build access
-- suffices) from a plan erase (contribute required) without trusting the
-- client's stated intent.
local function placementBuiltInWorld(placement)
    if not placement or not getCell then return false end
    local square = getCell():getGridSquare(placement.x, placement.y, placement.z)
    if not square then return false end
    local definition, stage = resolveDefinition(placement)
    local action = wallCoveringAction(definition, stage)
    if action then
        local wallType = placement.finishTarget and placement.finishTarget.wallType or nil
        local north = directionNorth(placement.direction)
        local expected = wallType and WallFinishes.spriteForWallType(action, placement.finish, north, wallType) or nil
        if not expected then return false end
        local function hasFinishedObject(list)
            for objectIndex = 0, list:size() - 1 do
                local object = list:get(objectIndex)
                local sprite = object and object.getSprite and object:getSprite() or nil
                if sprite and sprite:getName() == expected and objectWallEdge(object, north) then return true end
            end
            return false
        end
        return hasFinishedObject(square:getSpecialObjects()) or hasFinishedObject(square:getObjects())
    end
    local special = square:getSpecialObjects()
    for objectIndex = 0, special:size() - 1 do
        local data = special:get(objectIndex):getModData()
        if data and data.KBW and data.KBW.buildableId == placement.buildableId then return true end
    end
    local objects = square:getObjects()
    for objectIndex = 0, objects:size() - 1 do
        local data = objects:get(objectIndex):getModData()
        if data and data.KBW and data.KBW.buildableId == placement.buildableId then return true end
    end
    return false
end

-- Applies a client's networked mutation on the server (authoritative).
-- Returns (blueprint, applied): applied=true means the change was accepted
-- exactly as sent, so the caller may echo the same delta to other viewers;
-- applied=false means the sender must be rolled back to the returned
-- authoritative blueprint (or told to forget args.id when nil).
-- May canonicalize args in place (e.g. the accepted range anchor) so the
-- echoed delta always carries server-approved values.
---@param player IsoPlayer
---@param command string
---@param args table<string, unknown>
function Blueprints.applyServerCommand(player, command, args)
    args = args or {}
    if command == "BPCreate" then
        local blueprint = args.blueprint
        if type(blueprint) ~= "table" or not blueprint.id then return nil, false end
        if #(blueprint.placements or {}) > Blueprints.maxPlacements() then return nil, false end
        local items = Blueprints.sharedItems()
        local id = tostring(blueprint.id)
        -- Random ids never collide in practice; if one does, the sender is
        -- rolled back to the existing blueprint instead of overwriting it.
        if items[id] then return items[id], false end
        -- The creator always owns their blueprint; never trust a client-sent owner.
        blueprint.owner = playerName(player)
        blueprint.radius = Blueprints.blueprintRadius()
        local access = ensureAccess(blueprint)
        if not ACCESS_SCOPES[access.scope] then access.scope = "private" end
        blueprint.updated = timestamp()
        items[id] = blueprint
        persist(blueprint)
        return blueprint, true
    elseif command == "BPDelete" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if not Blueprints.isOwner(player, blueprint) then return blueprint, false end
        Blueprints.sharedItems()[tostring(args.id)] = nil
        Files.remove(args.id)
        return blueprint, true
    elseif command == "BPAddPlacement" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if Blueprints.canContribute(player, blueprint) and args.placement
            and args.placement.id and #(blueprint.placements or {}) < Blueprints.maxPlacements()
            and not Blueprints.getPlacement(blueprint, args.placement.id) then
            if not blueprint.anchored and args.anchor then
                blueprint.anchor = args.anchor
                blueprint.anchored = true
            end
            local finishOk = Blueprints.prepareFinishPlacement(player, blueprint, args.placement)
            if finishOk and (blueprint.anchored ~= true
                    or Blueprints.withinRange(blueprint, args.placement.x, args.placement.y))
                and #Blueprints.findIntersections(blueprint, args.placement) == 0 then
                blueprint.placements = blueprint.placements or {}
                blueprint.placements[#blueprint.placements + 1] = TableUtil.copy(args.placement)
                touch(blueprint)
                args.anchor = blueprint.anchor
                return blueprint, true
            end
        end
        return blueprint, false
    elseif command == "BPRemovePlacement" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        local placement, index = Blueprints.getPlacement(blueprint, args.placementId)
        -- Erasing a plan needs contribute (mirrors the client gate); consuming
        -- a just-built plan needs only build, verified by the matching object
        -- actually standing on the placement's tile.
        local allowed = Blueprints.canContribute(player, blueprint)
            or (Blueprints.canBuild(player, blueprint) and placementBuiltInWorld(placement))
        if index and allowed then
            table.remove(blueprint.placements, index)
            touch(blueprint)
            return blueprint, true
        end
        return blueprint, false
    elseif command == "BPAddRoom" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if Blueprints.canContribute(player, blueprint) and args.room
            and args.room.id and not Blueprints.getRoom(blueprint, args.room.id) then
            blueprint.rooms = blueprint.rooms or {}
            blueprint.rooms[#blueprint.rooms + 1] = TableUtil.copy(args.room)
            touch(blueprint)
            return blueprint, true
        end
        return blueprint, false
    elseif command == "BPRemoveRoom" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if Blueprints.canContribute(player, blueprint) then
            local _, index = Blueprints.getRoom(blueprint, args.roomId)
            if index then
                table.remove(blueprint.rooms, index)
                touch(blueprint)
                return blueprint, true
            end
        end
        return blueprint, false
    elseif command == "BPUpdateRoom" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if Blueprints.canContribute(player, blueprint) and type(args.fields) == "table" then
            local room = Blueprints.getRoom(blueprint, args.roomId)
            if room then
                for key, value in pairs(args.fields) do
                    room[key] = TableUtil.copy(value)
                end
                touch(blueprint)
                return blueprint, true
            end
        end
        return blueprint, false
    elseif command == "BPSetGatherArea" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if Blueprints.canContribute(player, blueprint) then
            blueprint.gatherArea = args.area and TableUtil.copy(args.area) or nil
            touch(blueprint)
            return blueprint, true
        end
        return blueprint, false
    elseif command == "BPMove" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if Blueprints.canContribute(player, blueprint) then
            Blueprints.move(player, args.id, args.dx, args.dy, args.dz, true)
            return blueprint, true
        end
        return blueprint, false
    elseif command == "BPRename" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if Blueprints.isOwner(player, blueprint) and args.name and args.name ~= "" then
            blueprint.name = tostring(args.name)
            touch(blueprint)
            return blueprint, true
        end
        return blueprint, false
    elseif command == "BPSetLevel" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if Blueprints.canContribute(player, blueprint) and tonumber(args.level) then
            blueprint.level = math.floor(args.level)
            touch(blueprint)
            return blueprint, true
        end
        return blueprint, false
    elseif command == "BPSetAccess" then
        local blueprint = Blueprints.get(player, args.id)
        if not blueprint then return nil, false end
        if not Blueprints.canManageAccess(player, blueprint) then return blueprint, false end
        local access = ensureAccess(blueprint)
        local applied = false
        if args.scope and ACCESS_SCOPES[args.scope] then
            access.scope = args.scope
            applied = true
        end
        local playerLevel = args.playerLevel or "none"
        if args.playerUser and tostring(args.playerUser) ~= tostring(blueprint.owner) and ACCESS_LEVELS[playerLevel] then
            if playerLevel == "none" then
                access.players[args.playerUser] = nil
            else
                access.players[args.playerUser] = playerLevel
            end
            applied = true
        end
        local factionLevel = args.factionLevel or "none"
        if args.factionName and ACCESS_LEVELS[factionLevel]
            and playerCanManageFaction(player, args.factionName, factionLevel) then
            if factionLevel == "none" then
                access.factions[args.factionName] = nil
            else
                access.factions[args.factionName] = factionLevel
            end
            applied = true
        end
        if applied then touch(blueprint) end
        return blueprint, applied
    end
    return nil, false
end

return Blueprints
