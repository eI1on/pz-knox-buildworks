---BlueprintFiles provides the Knox Buildworks blueprint planning layer.
local JSON = require("ElyonLib/FileUtils/JSON")
local SafeJSON = require("KnoxBuildworks/Util/SafeJSON")
local Log = require("KnoxBuildworks/Log")

-- Authoritative blueprint persistence: one JSON-formatted .txt file per
-- blueprint under
-- Lua/KnoxBuildworks/blueprints/<save>/. Only the authoritative side (the
-- server, or the local session in singleplayer) reads and writes here;
-- multiplayer clients keep a synced in-memory cache instead.
--
-- B42.20 limits writable files to ini/cfg/txt/log. Legacy .json files remain
-- readable and are migrated on load. PZ exposes no file-delete API for the Lua
-- directory, so removal writes a .txt tombstone that overrides legacy data.
---@class KBW.BlueprintFilesModule
---@type KBW.BlueprintFilesModule
local BlueprintFiles = {}

BlueprintFiles.ROOT = "KnoxBuildworks/blueprints"
BlueprintFiles.EXTENSION = ".txt"
BlueprintFiles.LEGACY_EXTENSION = ".json"

-- One subfolder per save so two saves on the same machine never share
-- blueprints. getWorld():getWorld() is the save folder name (Core.gameSaveWorld).
local function saveKey()
    local world = getWorld and getWorld() or nil
    local name = world and world:getWorld() or nil
    if not name or name == "" then return "shared" end
    return string.gsub(tostring(name), "[^%w_%-]", "_")
end

function BlueprintFiles.folder()
    return BlueprintFiles.ROOT .. "/" .. saveKey()
end

local function filePath(id)
    return BlueprintFiles.folder() .. "/" .. tostring(id) .. BlueprintFiles.EXTENSION
end

local function readText(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local lines, line = {}, reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return table.concat(lines, "\n")
end

function BlueprintFiles.loadAll()
    local items = {}
    if not listFilesInZomboidLuaDirectory then return items end
    local names = listFilesInZomboidLuaDirectory(BlueprintFiles.folder())
    if not names then return items end
    local currentIds = {}
    local function loadExtension(extension, current)
        for nameIndex = 0, names:size() - 1 do
            local name = tostring(names:get(nameIndex))
            if string.sub(string.lower(name), -#extension) == extension then
                local text = readText(BlueprintFiles.folder() .. "/" .. name)
                if text and text ~= "" then
                    local data, err = SafeJSON.decode(text)
                    if type(data) == "table" and data.id then
                        local id = tostring(data.id)
                        if current then currentIds[id] = true end
                        if data.deleted == true then
                            items[id] = nil
                        else
                            items[id] = data
                        end
                    elseif err then
                        Log:warning("Skipped blueprint file %s: %s", name, err)
                    end
                end
            end
        end
    end
    -- Current files deliberately win over stale legacy files with the same id.
    loadExtension(BlueprintFiles.LEGACY_EXTENSION, false)
    loadExtension(BlueprintFiles.EXTENSION, true)
    -- Preserve existing saves without ever trying to write the now-forbidden
    -- .json extension. The old file can remain; the new .txt wins thereafter.
    for id, blueprint in pairs(items) do
        if not currentIds[id] then BlueprintFiles.save(blueprint) end
    end
    return items
end

---@param blueprint KBW.Blueprint
function BlueprintFiles.save(blueprint)
    if not blueprint or not blueprint.id then return false end
    local writer = getFileWriter(filePath(blueprint.id), true, false)
    if not writer then
        Log:error("Could not write blueprint file %s", filePath(blueprint.id))
        return false
    end
    writer:write(JSON.stringify(blueprint))
    writer:close()
    return true
end

-- Mutations coalesce in a dirty set. Long build queues suspend ordinary tick
-- flushes so removing each completed ghost does not serialize a large house
-- repeatedly; save events and the minute safety flush remain authoritative.
local dirty = {}
local flushHooked = false
local batches = {}

local function flush(force)
    local remaining = {}
    for id, blueprint in pairs(dirty) do
        if force == true or not batches[tostring(id)] then
            BlueprintFiles.save(blueprint)
        else
            remaining[tostring(id)] = blueprint
        end
    end
    dirty = remaining
end

local function flushForced()
    flush(true)
end

local function hookFlush()
    if flushHooked then return end
    flushHooked = true
    Events.OnTick.Add(flush)
    Events.EveryOneMinute.Add(flushForced)
    -- Catches the quit/save path so the last edit of a session is never lost.
    Events.OnSave.Add(flushForced)
end

---@param blueprint KBW.Blueprint
function BlueprintFiles.queueSave(blueprint)
    if not blueprint or not blueprint.id then return end
    dirty[tostring(blueprint.id)] = blueprint
    hookFlush()
end

function BlueprintFiles.beginBatch(id)
    id = tostring(id or "")
    if id == "" then return end
    batches[id] = (batches[id] or 0) + 1
end

function BlueprintFiles.endBatch(id)
    id = tostring(id or "")
    if id == "" then return end
    local depth = batches[id] or 0
    if depth > 1 then
        batches[id] = depth - 1
    else
        batches[id] = nil
    end
    flush(false)
end

function BlueprintFiles.remove(id)
    if not id then return end
    id = tostring(id)
    dirty[id] = nil
    -- The tombstone prevents an undeletable legacy .json file from restoring
    -- the blueprint on the next load.
    local writer = getFileWriter(filePath(id), true, false)
    if not writer then
        Log:error("Could not write blueprint tombstone %s", filePath(id))
        return
    end
    writer:write(JSON.stringify({ id = id, deleted = true }))
    writer:close()
end

return BlueprintFiles
