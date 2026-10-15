if not isDebugEnabled() then return end

---StudioExport writes the engine data Buildworks Studio cannot read offline.
--
-- Vanilla stages keep only `entityCompat` identity in JSON; their sprites,
-- geometry and native recipe inputs come from Java GameEntityScript
-- components. The studio pipeline cannot parse those exactly, so this dumps
-- what EntityCompat.metadata actually returns in a running game, plus the
-- item, tag and tile-property data the shared rules look up through Java.
-- Output: Zomboid/Lua/KnoxBuildworks/studio/*.txt (JSON-formatted; B42 only
-- writes txt). The studio pipeline reads it via KBW_STUDIO_DUMP.
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Resolver = require("KnoxBuildworks/Definitions/Resolver")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local JSON = require("ElyonLib/FileUtils/JSON")
local Log = require("KnoxBuildworks/Log")

---@class KBW.StudioExportModule
local StudioExport = { FOLDER = "KnoxBuildworks/studio", SCHEMA = 2 }

local MAX_DEPTH = 48

-- Plain-data copy for JSON: drops functions, marks Java objects and cycles so
-- the pipeline can report them instead of silently losing data.
local function plain(value, active, depth)
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return value end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        return value
    end
    if kind == "function" then return nil end
    if kind ~= "table" then return { ["$java"] = tostring(value) } end
    if active[value] or depth > MAX_DEPTH then return { ["$cycle"] = true } end
    active[value] = true
    local result = {}
    for key, entry in pairs(value) do
        local copied = plain(entry, active, depth + 1)
        if copied ~= nil then result[key] = copied end
    end
    active[value] = nil
    return result
end

local function copy(value)
    return plain(value, {}, 0)
end

local function gameVersion()
    local core = getCore and getCore() or nil
    local version = core and core.getGameVersion and core:getGameVersion() or nil
    return version and tostring(version) or nil
end

local function writeFile(name, data)
    local path = StudioExport.FOLDER .. "/" .. name
    local writer = getFileWriter(path, true, false)
    if not writer then
        Log:error("Studio export: could not write %s", path)
        return false
    end
    writer:write(JSON.stringify(data))
    writer:close()
    return true
end

local function eachStage(callback)
    local list = Registry:list()
    for definitionIndex = 1, #list do
        local definition = list[definitionIndex]
        local stages = definition.stages or {}
        for stageIndex = 1, #stages do callback(definition, stages[stageIndex]) end
        local variants = definition.variants or {}
        for variantIndex = 1, #variants do
            local variantStages = variants[variantIndex].stages or {}
            for stageIndex = 1, #variantStages do callback(definition, variantStages[stageIndex]) end
        end
    end
end

local function exportEntities(header)
    local entities, missing, seen = {}, {}, {}
    eachStage(function (_, stage)
        if not stage.entityCompat then return end
        local name = EntityCompat.scriptName(stage)
        if not name or seen[name] then return end
        seen[name] = true
        local script = EntityCompat.resolveScript(stage)
        if script then
            entities[name] = copy(EntityCompat.metadata(stage))
        else
            missing[#missing + 1] = name
        end
    end)
    table.sort(missing)
    return writeFile("entities.txt", {
        header = header, entities = entities, missing = missing
    })
end

local function javaListStrings(list)
    local result = {}
    if not list then return result end
    for index = 0, list:size() - 1 do result[#result + 1] = tostring(list:get(index)) end
    return result
end

-- Item:getTags() is a Java Set, which Kahlua cannot iterate reliably. Its
-- string form lists each ItemTag's resource id ("[base:hammer, base:tool]"),
-- and each id resolves back to the tag the way Requirements does.
local function tagFromId(id)
    if not ItemTag or not ResourceLocation then return nil end
    return ItemTag.get(ResourceLocation.of(id))
end

local function itemTags(scriptItem, tagSet)
    local result = {}
    local tags = scriptItem:getTags()
    if not tags then return result end
    local text = tostring(tags)
    for id in string.gmatch(text, "[^%[%],%s]+") do
        result[#result + 1] = id
        if tagSet[id] == nil then
            local tag = tagFromId(id)
            if tag then
                tagSet[id] = { tag = tag, translationName = tag:getTranslationName() }
            else
                tagSet[id] = false
            end
        end
    end
    table.sort(result)
    return result
end

local function textureName(scriptItem)
    local texture = scriptItem.getNormalTexture and scriptItem:getNormalTexture() or nil
    return texture and texture.getName and tostring(texture:getName()) or nil
end

local function exportItems(header)
    local manager = getScriptManager()
    local all = manager:getAllItems()
    local items, tagSet = {}, {}
    for index = 0, all:size() - 1 do
        local scriptItem = all:get(index)
        local fullType = tostring(scriptItem:getFullName())
        items[fullType] = {
            name = tostring(scriptItem:getDisplayName()),
            icon = scriptItem.getIcon and scriptItem:getIcon() or nil,
            texture = textureName(scriptItem),
            category = scriptItem.getDisplayCategory and scriptItem:getDisplayCategory() or nil,
            r = scriptItem.getR and scriptItem:getR() or nil,
            g = scriptItem.getG and scriptItem:getG() or nil,
            b = scriptItem.getB and scriptItem:getB() or nil,
            tags = itemTags(scriptItem, tagSet)
        }
    end
    -- Item order inside a tag matters (the first match names a tag row), so
    -- each list comes from the engine's own getItemsTag, not from items above.
    local tags = {}
    local unresolved = {}
    for id, entry in pairs(tagSet) do
        if entry then
            local list = manager:getItemsTag(entry.tag)
            local fullTypes = {}
            if list then
                for index = 0, list:size() - 1 do fullTypes[#fullTypes + 1] = tostring(list:get(index):getFullName()) end
            end
            tags[id] = { translationName = entry.translationName, items = fullTypes }
        else
            unresolved[#unresolved + 1] = id
        end
    end
    table.sort(unresolved)
    if #unresolved > 0 then Log:warning("Studio export: %d tag ids did not resolve", #unresolved) end
    return writeFile("items.txt", { header = header, items = items, tags = tags, unresolvedTags = unresolved })
end

local function spriteProperties(name)
    local sprite = getSprite(name)
    if not sprite then return nil end
    local properties = sprite:getProperties()
    if not properties then return { flags = {}, values = {} } end
    local values = {}
    local names = properties:getPropertyNames()
    for index = 0, names:size() - 1 do
        local key = tostring(names:get(index))
        values[key] = properties:get(key)
    end
    local flags = javaListStrings(properties:getFlagsList())
    table.sort(flags)
    -- getType() is what plan checks compare (doorW/doorN/doorFrW/...); Java
    -- derives it while loading tile definitions, so record the result.
    local spriteType = sprite.getType and sprite:getType() or nil
    return { flags = flags, values = values, type = spriteType and tostring(spriteType) or nil }
end

-- Every sprite a stage can place: registry-indexed sprites plus the face
-- cells of each (variant, material, stage, direction), as ghosts expand them.
local function plannedSpriteNames()
    local set = {}
    for name in pairs(Registry.sprites or {}) do set[name] = true end
    local list = Registry:list()
    for definitionIndex = 1, #list do
        local definition = list[definitionIndex]
        local variantIds, materialIds = { "" }, { "" }
        local variants = definition.variants or {}
        for index = 1, #variants do variantIds[#variantIds + 1] = variants[index].id end
        local materials = definition.materialOptions or {}
        for index = 1, #materials do materialIds[#materialIds + 1] = materials[index].id end
        for v = 1, #variantIds do
            for m = 1, #materialIds do
                local resolved = Resolver.resolve(definition.id, variantIds[v], materialIds[m])
                local stages = resolved and resolved.stages or {}
                for s = 1, #stages do
                    for direction = 1, 4 do
                        local cells = Matrix.getFaceCells(stages[s], direction) or {}
                        for c = 1, #cells do
                            if type(cells[c].sprite) == "string" then set[cells[c].sprite] = true end
                        end
                        local face = Matrix.getFaceSprite(stages[s], direction)
                        if type(face) == "string" then set[face] = true end
                    end
                end
            end
        end
    end
    local names = {}
    for name in pairs(set) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- Vanilla paint and wallpaper choices (ISPaintMenu) that FinishOptions offers.
local function paintMenus()
    if not ISPaintMenu then require "BuildingObjects/ISPaintMenu" end
    if not ISPaintMenu then return nil end
    return { paint = copy(ISPaintMenu.PaintMenuItems), wallpaper = copy(ISPaintMenu.WallpaperMenuItems) }
end

local function exportSprites(header)
    local sprites, missing = {}, {}
    local names = plannedSpriteNames()
    for index = 1, #names do
        local entry = spriteProperties(names[index])
        if entry then sprites[names[index]] = entry else missing[#missing + 1] = names[index] end
    end
    return writeFile("sprites.txt", { header = header, sprites = sprites, missing = missing, paintMenus = paintMenus() })
end

-- Hydrated registry (after EntityCompat filled native stage fields) so the
-- studio can check that its own Loader run reproduces the game's.
local function exportRegistry(header)
    return writeFile("registry.txt", { header = header, hash = Registry.hash, buildables = copy(Registry:list()) })
end

---Writes every studio file. Returns true when all of them were written.
function StudioExport.run()
    local started = getTimestampMs()
    local mods = {}
    local active = getActivatedMods and getActivatedMods() or nil
    if active then mods = javaListStrings(active) end
    table.sort(mods)
    local header = {
        schema = StudioExport.SCHEMA,
        gameVersion = gameVersion(),
        registryHash = Registry.hash,
        activeMods = mods,
        exportedAt = tostring(started)
    }
    eachStage(function (_, stage) EntityCompat.hydrateStage(stage) end)
    local ok = exportEntities(header)
    ok = exportItems(header) and ok
    ok = exportSprites(header) and ok
    ok = exportRegistry(header) and ok
    Log:info("Studio export %s in %d ms", ok and "written" or "incomplete", getTimestampMs() - started)
    return ok
end

return StudioExport
