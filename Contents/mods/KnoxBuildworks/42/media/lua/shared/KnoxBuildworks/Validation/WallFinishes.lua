---WallFinishes provides the Knox Buildworks construction validation layer.
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
-- Wall finish pipeline: plasterable walls can be built directly with a finish
-- (plaster, plaster + paint color, plaster + wallpaper).
--
-- Sprite mappings are per WALL TYPE. The four vanilla wall types ("wall",
-- "doorframe", "windowsframe", "pillar") are bridged automatically from the
-- vanilla Painting/WallPaper tables, and mods/tilepacks can register their
-- own wall types either from Lua:
--
--   local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
--   WallFinishes.registerWallType("myaddon.plainA", {
--       plaster = { W = "my_walls_01_4", N = "my_walls_01_5" },
--       paints = {
--           PaintRed = { W = "my_walls_01_8", N = "my_walls_01_9" },
--       },
--       wallpapers = {
--           Wallpaper_BeigeStripe = { W = "...", N = "..." },
--       },
--   })
--
-- or inline on a stage in JSON (auto-registers the wallType id):
--
--   "finishes": {
--     "wallType": "myaddon.plainA",
--     "mapping": {
--       "plaster": { "W": "...", "N": "..." },
--       "paints": { "PaintRed": { "W": "...", "N": "..." } },
--       "wallpapers": {}
--     }
--   }
--
-- Paint/wallpaper keys may use vanilla short item types (PaintBlack,
-- Wallpaper_GreenDiamond) or full types (Base.PaintBlack). Material checks
-- normalize those into script items for icons, counts, and manual selection.
---@class KBW.WallFinishesModule
---@type KBW.WallFinishesModule
local WallFinishes = {}

local registeredWallTypes = {}
local registeredSpriteTypes = {}

local function translated(key, fallback)
    if not getText then return fallback or key end
    local text = getText(key)
    if text == key then return fallback or key end
    return text
end

local function scriptFor(fullType)
    if not fullType then return nil end
    if getItem then
        local script = getItem(fullType)
        if script then return script end
    end
    return ScriptManager and ScriptManager.instance and ScriptManager.instance:FindItem(fullType) or nil
end

local function normalizeFullType(itemType)
    if not itemType then return nil end
    local value = tostring(itemType)
    if string.find(value, ".", 1, true) then return value end
    if scriptFor("Base." .. value) then return "Base." .. value end
    return value
end

local function scriptFullType(scriptItem)
    if not scriptItem then return nil end
    if scriptItem.getFullName then return scriptItem:getFullName() end
    if scriptItem.getFullType then return scriptItem:getFullType() end
    if scriptItem.getName then return "Base." .. tostring(scriptItem:getName()) end
    return nil
end

local function itemLabel(itemType)
    local fullType = normalizeFullType(itemType)
    if fullType and getItemNameFromFullType then return getItemNameFromFullType(fullType) end
    return tostring(itemType or "?")
end

local function addUnique(result, seen, fullType)
    if not fullType or fullType == "" or seen[fullType] then return end
    seen[fullType] = true
    result[#result + 1] = fullType
end

local function possibleItemsForTag(tag)
    local result = {}
    local seen = {}
    if tag and getScriptManager then
        local manager = getScriptManager()
        local scriptItems = manager and manager.getItemsTag and manager:getItemsTag(tag) or nil
        if scriptItems then
            for scriptIndex = 0, scriptItems:size() - 1 do
                addUnique(result, seen, scriptFullType(scriptItems:get(scriptIndex)))
            end
        end
    end
    table.sort(result)
    return result
end

local function preferPossibleItem(items, preferred)
    if not preferred then return items end
    local foundIndex = nil
    for itemIndex = 1, #items do
        if items[itemIndex] == preferred then
            foundIndex = itemIndex
            break
        end
    end
    if not foundIndex or foundIndex == 1 then return items end
    table.remove(items, foundIndex)
    table.insert(items, 1, preferred)
    return items
end

local function preferredForTag(tag)
    if tag == ItemTag.PLASTER_TROWEL then return "Base.PlasterTrowel" end
    if tag == ItemTag.PLASTER_BUCKET then return "Base.BucketPlasterFull" end
    if tag == ItemTag.PAINTBRUSH then return "Base.Paintbrush" end
    if tag == ItemTag.WALLPAPER_PASTE then return "Base.BucketWallpaperPaste" end
    if tag == ItemTag.SCISSORS then return "Base.Scissors" end
    return nil
end

local function predicateAnyUsable(item)
    if not item then return false end
    if item.isDestroyed and item:isDestroyed() then return false end
    return true
end

local function predicateNotBroken(item)
    if not predicateAnyUsable(item) then return false end
    if item.isBroken and item:isBroken() then return false end
    return true
end

local function predicateEnoughDrain(item)
    if not predicateAnyUsable(item) then return false end
    if item.getCurrentUsesFloat then return item:getCurrentUsesFloat() >= 0.1 end
    if item.getCurrentUses then return item:getCurrentUses() > 0 end
    return true
end

local function amountForItem(item, countUses)
    if countUses and instanceof and instanceof(item, "DrainableComboItem") then
        if item.getCurrentUses then return item:getCurrentUses() end
    end
    return 1
end

local function addAvailable(result, seen, seenItems, item, countUses)
    if not item then return 0 end
    local itemKey = tostring(item)
    if seenItems[itemKey] then return 0 end
    seenItems[itemKey] = true
    local fullType = item.getFullType and item:getFullType()
        or normalizeFullType(item.getType and item:getType() or nil)
    if not fullType then return 0 end
    local amount = amountForItem(item, countUses)
    local entry = seen[fullType]
    if not entry then
        entry = { fullType = fullType, count = 0, uses = 0, available = 0, item = item, items = {} }
        seen[fullType] = entry
        result[#result + 1] = entry
    end
    entry.items[#entry.items + 1] = item
    entry.count = entry.count + 1
    entry.uses = entry.uses + amountForItem(item, true)
    entry.available = entry.available + amount
    return amount
end

local function scanTag(inventory, tag, predicate)
    if not inventory or not tag then return nil end
    if predicate then return inventory:getFirstTagEvalRecurse(tag, predicate) end
    return inventory:getFirstTagRecurse(tag)
end

local function allByTag(inventory, tag, predicate, countUses)
    local result, total = {}, 0
    if not inventory or not tag then return result, total end
    local seen, seenItems = {}, {}
    local items = inventory:getAllTagEvalRecurse(tag, predicate or predicateAnyUsable, ArrayList.new())
    if items then
        for itemIndex = 0, items:size() - 1 do
            total = total + addAvailable(result, seen, seenItems, items:get(itemIndex), countUses)
        end
    end
    return result, total
end

local function allByTypes(inventory, itemTypes, predicate, countUses)
    local result, total = {}, 0
    if not inventory then return result, total end
    local seen, seenItems = {}, {}
    for typeIndex = 1, #itemTypes do
        local items = inventory:getAllTypeEvalRecurse(itemTypes[typeIndex], predicate or predicateAnyUsable)
        if items then
            for itemIndex = 0, items:size() - 1 do
                total = total + addAvailable(result, seen, seenItems, items:get(itemIndex), countUses)
            end
        end
    end
    return result, total
end

local function typeAliases(itemType)
    local aliases = {}
    local seen = {}
    local raw = itemType and tostring(itemType) or nil
    local fullType = normalizeFullType(raw)
    addUnique(aliases, seen, fullType)
    if raw and raw ~= fullType then addUnique(aliases, seen, raw) end
    return aliases
end

local function firstType(inventory, itemType)
    if not inventory or not itemType then return nil end
    local aliases = typeAliases(itemType)
    for aliasIndex = 1, #aliases do
        local item = inventory:getFirstTypeRecurse(aliases[aliasIndex])
        if item then return item end
    end
    return nil
end

local function finishConfig(definition, stage)
    return (stage and stage.finishes) or (definition and definition.finishes) or {}
end

function WallFinishes.registerWallType(id, mapping)
    if id == nil or type(mapping) ~= "table" then return end
    registeredWallTypes[tostring(id)] = {
        plaster = mapping.plaster,
        paints = mapping.paints or {},
        wallpapers = mapping.wallpapers or {},
        directPaints = mapping.directPaints or mapping.barePaints or {},
        directWallpapers = mapping.directWallpapers or mapping.bareWallpapers or {},
        surface = mapping.surface or mapping.capabilities or {}
    }
    local sprites = mapping.sprites or mapping.baseSprites or {}
    for spriteIndex = 1, #sprites do
        registeredSpriteTypes[tostring(sprites[spriteIndex])] = tostring(id)
    end
end

WallFinishes.registerSurface = WallFinishes.registerWallType

---@param spriteName string|nil
---@param wallType string|nil
function WallFinishes.registerSpriteWallType(spriteName, wallType)
    if not spriteName or not wallType then return end
    registeredSpriteTypes[tostring(spriteName)] = tostring(wallType)
end

-- Bridges a vanilla Painting/WallPaper wall type into the registry shape.
local function vanillaMapping(wallType)
    local painting = Painting and Painting[wallType] or nil
    if not painting then return nil end
    local mapping = {
        plaster = painting.plasterTile
            and {
                W = painting.plasterTile,
                N = painting.plasterTileNorth or painting.plasterTile
            } or nil,
        paints = {},
        wallpapers = {},
        directPaints = {},
        directWallpapers = {},
        surface = {
            paintRequiresPlaster = true,
            wallpaperRequiresPlaster = true
        }
    }
    local paintItems = ISPaintMenu and ISPaintMenu.PaintMenuItems or {}
    for itemIndex = 1, #paintItems do
        local name = paintItems[itemIndex].paint
        if painting[name] then
            mapping.paints[name] = { W = painting[name], N = painting[name .. "North"] or painting[name] }
        end
    end
    local paper = WallPaper and WallPaper[wallType] or nil
    local paperItems = ISPaintMenu and ISPaintMenu.WallpaperMenuItems or {}
    if paper then
        for itemIndex = 1, #paperItems do
            local name = paperItems[itemIndex].paper
            if paper[name] then
                mapping.wallpapers[name] = { W = paper[name], N = paper[name .. "North"] or paper[name] }
            end
        end
    end
    return mapping
end

local function wallTypeFromSprite(spriteName)
    if spriteName and registeredSpriteTypes[tostring(spriteName)] then
        return registeredSpriteTypes[tostring(spriteName)]
    end
    local sprite = spriteName and getSprite and getSprite(spriteName) or nil
    local props = sprite and sprite:getProperties() or nil
    if not props then return nil end
    local paintingType = props:get("PaintingType")
    if paintingType ~= nil and tostring(paintingType) ~= "" then return tostring(paintingType) end
    if props:has("WindowN") or props:has("WindowW") then return "windowsframe" end
    if props:has("DoorWallN") or props:has("DoorWallW") then return "doorframe" end
    if props:has(IsoFlagType.WallSE) then return "pillar" end
    if props:has("WallN") or props:has("WallW") or props:has("WallNW") then return "wall" end
    return nil
end

---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param spriteName string|nil
function WallFinishes.wallType(definition, stage, spriteName)
    local configured = finishConfig(definition, stage).wallType
    if configured then return configured end
    local derived = wallTypeFromSprite(spriteName)
    if derived then return derived end
    local sprites = stage and stage.sprites or {}
    return wallTypeFromSprite(sprites.W) or wallTypeFromSprite(sprites.N) or "wall"
end

-- Resolves the sprite mapping for a stage: inline stage mapping first
-- (auto-registered under its wallType id), then registered wall types, then
-- the vanilla tables.
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param spriteName string|nil
function WallFinishes.mappingFor(definition, stage, spriteName)
    local config = finishConfig(definition, stage)
    local wallType = WallFinishes.wallType(definition, stage, spriteName)
    if type(config.mapping) == "table" then
        if not registeredWallTypes[wallType] then
            WallFinishes.registerWallType(wallType, config.mapping)
        end
        if config.surface and registeredWallTypes[wallType] then
            registeredWallTypes[wallType].surface = config.surface
        end
        return registeredWallTypes[wallType]
            or {
                plaster = config.mapping.plaster,
                paints = config.mapping.paints or {},
                wallpapers = config.mapping.wallpapers or {},
                directPaints = config.mapping.directPaints or config.mapping.barePaints or {},
                directWallpapers = config.mapping.directWallpapers or config.mapping.bareWallpapers or {},
                surface = config.surface or config.mapping.surface or config.mapping.capabilities or {}
            }
    end
    return registeredWallTypes[wallType] or vanillaMapping(wallType)
end

---@param wallType string|nil
function WallFinishes.mappingForWallType(wallType)
    wallType = tostring(wallType or "wall")
    return registeredWallTypes[wallType] or vanillaMapping(wallType)
end

local function surfaceValue(surface, key, fallback)
    if surface and surface[key] ~= nil then return surface[key] == true end
    return fallback
end

-- Surface capabilities are addon-extensible. JSON stages may declare:
-- "finishes": { "wallType": "addon.wall", "surface": {
--   "canPlaster": true, "canPaint": true, "canWallpaper": true,
--   "paintRequiresPlaster": false, "wallpaperRequiresPlaster": false } }
-- The default preserves vanilla constructed-wall behavior: paint and paper
-- require a plastered/paintable surface unless an addon opts out.
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param wallType string|nil
function WallFinishes.surfaceRules(definition, stage, wallType)
    local config = finishConfig(definition, stage)
    local mapping = wallType and WallFinishes.mappingForWallType(wallType) or WallFinishes.mappingFor(definition, stage)
    mapping = mapping or { paints = {}, wallpapers = {} }
    local surface = config.surface or mapping.surface or {}
    return {
        canPlaster = surfaceValue(surface, "canPlaster", mapping.plaster ~= nil),
        canPaint = surfaceValue(surface, "canPaint", mapping.paints ~= nil),
        canWallpaper = surfaceValue(surface, "canWallpaper", mapping.wallpapers ~= nil),
        paintRequiresPlaster = surfaceValue(surface, "paintRequiresPlaster", true),
        wallpaperRequiresPlaster = surfaceValue(surface, "wallpaperRequiresPlaster", true)
    }
end

---@param action string
function WallFinishes.actionMode(action)
    if action == "paintThump" then return "paint" end
    if action == "wallpaper" then return "wallpaper" end
    if action == "plaster" then return "plaster" end
    return action
end

---@param action string
---@param finish KBW.WallFinish|nil
---@param north boolean
---@param wallType string|nil
function WallFinishes.spriteForWallType(action, finish, north, wallType)
    local mode = WallFinishes.actionMode(action)
    local mapping = WallFinishes.mappingForWallType(wallType)
    if not mapping then return nil end
    local entry = nil
    if mode == "plaster" then
        entry = mapping.plaster
    elseif mode == "paint" then
        local direct = finish and finish.plaster == false
        if finish and finish.plaster == nil and mapping.surface and mapping.surface.paintRequiresPlaster == false then
            direct = true
        end
        local paints = direct and mapping.directPaints or mapping.paints
        if direct and (not paints or paints[finish and finish.paintType] == nil) then paints = mapping.paints end
        entry = finish and finish.paintType and paints and paints[finish.paintType] or nil
    elseif mode == "wallpaper" then
        local direct = finish and finish.plaster == false
        if finish and finish.plaster == nil and mapping.surface and mapping.surface.wallpaperRequiresPlaster == false then
            direct = true
        end
        local papers = direct and mapping.directWallpapers or mapping.wallpapers
        if direct and (not papers or papers[finish and finish.wallpaperType] == nil) then
            papers = mapping.wallpapers
        end
        entry = finish and finish.wallpaperType and papers and papers[finish.wallpaperType] or nil
    end
    if type(entry) ~= "table" then return nil end
    if north then return entry.N or entry.W end
    return entry.W or entry.N
end

function WallFinishes.objectWallType(object)
    if not object or not object.getSprite or not object:getSprite() then return nil end
    local data = object.getModData and object:getModData() or nil
    local kbw = data and data.KBW or nil
    if kbw and kbw.wallType then return tostring(kbw.wallType) end
    return wallTypeFromSprite(object:getSprite():getName())
end

function WallFinishes.objectNorth(object)
    if not object then return false end
    if instanceof(object, "IsoThumpable") and object.getNorth then return object:getNorth() == true end
    local props = object.getProperties and object:getProperties() or nil
    if not props then return false end
    return props:has("WallN") or props:has("WindowN") or props:has("DoorWallN")
end

local function objectIsPlastered(object)
    if not object then return false end
    if object.isPaintable and object:isPaintable() then return true end
    local props = object.getProperties and object:getProperties() or nil
    return props ~= nil and props:has("IsPaintable")
end

---@param action string
---@param finish KBW.WallFinish|nil
---@param hasPlasterAction boolean|nil
function WallFinishes.canApplyToObject(action, finish, object, hasPlasterAction)
    local mode = WallFinishes.actionMode(action)
    local wallType = WallFinishes.objectWallType(object)
    if not wallType then return false, "no compatible wall face", nil end
    local rules = WallFinishes.surfaceRules(nil, nil, wallType)
    if not WallFinishes.spriteForWallType(mode, finish, WallFinishes.objectNorth(object), wallType) then
        return false, "finish is not mapped for this wall surface", wallType
    end
    if mode == "plaster" then
        if not rules.canPlaster then return false, "wall surface cannot be plastered", wallType end
        if not (instanceof(object, "IsoThumpable") and object.canBePlastered and object:canBePlastered()) then
            return false, "wall is not ready for plaster", wallType
        end
        return true, nil, wallType
    end
    if mode == "paint" then
        if not rules.canPaint then return false, "wall surface cannot be painted", wallType end
        if rules.paintRequiresPlaster and not objectIsPlastered(object) and not hasPlasterAction then
            return false, "wall must be plastered before painting", wallType
        end
        return true, nil, wallType
    end
    if mode == "wallpaper" then
        if not rules.canWallpaper then return false, "wall surface cannot be wallpapered", wallType end
        if rules.wallpaperRequiresPlaster and not objectIsPlastered(object) and not hasPlasterAction then
            return false, "wall must be plastered before wallpapering", wallType
        end
        return true, nil, wallType
    end
    return false, "unsupported wall finish action", wallType
end

---@param action string
---@param finish KBW.WallFinish|nil
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param plannedFinish KBW.WallFinish|nil
---@param hasPlasterAction boolean|nil
function WallFinishes.canApplyToPlanned(action, finish, definition, stage, plannedFinish, hasPlasterAction)
    local mode = WallFinishes.actionMode(action)
    local wallType = WallFinishes.wallType(definition, stage)
    local rules = WallFinishes.surfaceRules(definition, stage, wallType)
    if not WallFinishes.spriteForWallType(mode, finish, false, wallType) then
        return false, "finish is not mapped for this wall surface", wallType
    end
    local plastered = WallFinishes.isWallFinish(plannedFinish) and plannedFinish.plaster == true
    plastered = plastered or hasPlasterAction == true
    if mode == "plaster" then
        if not rules.canPlaster or not WallFinishes.isPlasterable(definition, stage) then
            return false, "planned wall cannot be plastered", wallType
        end
        if plastered then return false, "planned wall is already plastered", wallType end
        return true, nil, wallType
    end
    if mode == "paint" then
        if not rules.canPaint then return false, "planned wall cannot be painted", wallType end
        if rules.paintRequiresPlaster and not plastered then
            return false, "plan plaster before painting", wallType
        end
        return true, nil, wallType
    end
    if mode == "wallpaper" then
        if not rules.canWallpaper then return false, "planned wall cannot be wallpapered", wallType end
        if rules.wallpaperRequiresPlaster and not plastered then
            return false, "plan plaster before wallpapering", wallType
        end
        return true, nil, wallType
    end
    return false, "unsupported wall finish action", wallType
end

---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
function WallFinishes.isPlasterable(definition, stage)
    local config = finishConfig(definition, stage)
    if config.enabled == false then return false end
    if config.enabled == true then return true end
    if not stage then return false end
    if stage.canBePlastered == true then return true end
    local spriteConfig = StageConfig.sprite(definition, stage)
    if spriteConfig.onCreate == "BuildRecipeCode.canBePlastered.OnCreate" then return true end
    local tags = definition and definition.tags or {}
    for tagIndex = 1, #tags do
        if tags[tagIndex] == "plasterable" then return true end
    end
    return false
end

---@param finish KBW.WallFinish|nil
function WallFinishes.isWallFinish(finish)
    return type(finish) == "table" and (finish.actionType == "wallFinish" or finish.plaster == true)
end

-- Sprite for one application step ("plaster", "paint", "wallpaper") on the
-- given wall face. nil when the wall type has no mapping for that step -
-- which is also how validation decides a finish does not apply to a wall.
---@param mode string|nil
---@param finish KBW.WallFinish|nil
---@param north boolean
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param baseSprite string|nil
function WallFinishes.spriteFor(mode, finish, north, definition, stage, baseSprite)
    local mapping = WallFinishes.mappingFor(definition, stage, baseSprite)
    if not mapping then return nil end
    local entry = nil
    if mode == "plaster" then
        entry = mapping.plaster
    elseif mode == "paint" then
        local direct = finish and finish.plaster == false
        local paints = direct and mapping.directPaints or mapping.paints
        if direct and (not paints or paints[finish and finish.paintType] == nil) then paints = mapping.paints end
        entry = finish and finish.paintType and paints and paints[finish.paintType] or nil
    elseif mode == "wallpaper" then
        local direct = finish and finish.plaster == false
        local papers = direct and mapping.directWallpapers or mapping.wallpapers
        if direct and (not papers or papers[finish and finish.wallpaperType] == nil) then
            papers = mapping.wallpapers
        end
        entry = finish and finish.wallpaperType and papers and papers[finish.wallpaperType] or nil
    end
    if type(entry) ~= "table" then return nil end
    if north then return entry.N or entry.W end
    return entry.W or entry.N
end

-- Final visible face for previews (ghosts, cursors, catalog).
---@param finish KBW.WallFinish|nil
---@param north boolean
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param baseSprite string|nil
function WallFinishes.previewSprite(finish, north, definition, stage, baseSprite)
    if not WallFinishes.isWallFinish(finish) then return nil end
    local mode = "plaster"
    if finish.wallpaperType then
        mode = "wallpaper"
    elseif finish.paintType then
        mode = "paint"
    end
    return WallFinishes.spriteFor(mode, finish, north, definition, stage, baseSprite)
        or WallFinishes.spriteFor("plaster", finish, north, definition, stage, baseSprite)
end

local function allowedByConfig(configured, name)
    if configured == false then return false end
    if type(configured) ~= "table" then return true end
    for index = 1, #configured do
        if configured[index] == name then return true end
    end
    return false
end

local function paintLabel(name)
    local items = ISPaintMenu and ISPaintMenu.PaintMenuItems or {}
    for index = 1, #items do
        if items[index].paint == name then return translated(items[index].text, name), items[index].color end
    end
    if getItemNameFromFullType then return getItemNameFromFullType("Base." .. tostring(name)), nil end
    return tostring(name), nil
end

local function paperLabel(name)
    local items = ISPaintMenu and ISPaintMenu.WallpaperMenuItems or {}
    for index = 1, #items do
        if items[index].paper == name then return translated(items[index].text, name) end
    end
    if getItemNameFromFullType then return getItemNameFromFullType("Base." .. tostring(name)) end
    return tostring(name)
end

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map or {}) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    return keys
end

-- Finish entries for the catalog/planning combos. Every entry is a
-- self-contained finish selection stored on placements and cursors.
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
function WallFinishes.entriesFor(definition, stage)
    local entries = {}
    local config = finishConfig(definition, stage)
    local mapping = WallFinishes.mappingFor(definition, stage)
    if not mapping then return entries end
    local rules = WallFinishes.surfaceRules(definition, stage)
    local plasterLabel = translated("ContextMenu_Plaster", "Plaster")
    local canPlaster = rules.canPlaster and mapping.plaster ~= nil and WallFinishes.isPlasterable(definition, stage)
    if canPlaster then
        entries[#entries + 1] = { label = plasterLabel, actionType = "wallFinish", plaster = true }
        local paintNames = sortedKeys(mapping.paints)
        for nameIndex = 1, #paintNames do
            local name = paintNames[nameIndex]
            if allowedByConfig(config.paints, name) then
                local label, color = paintLabel(name)
                entries[#entries + 1] = {
                    label = plasterLabel .. " + " .. label,
                    actionType = "wallFinish",
                    plaster = true,
                    paintType = name,
                    color = color
                }
            end
        end
        local paperNames = sortedKeys(mapping.wallpapers)
        for nameIndex = 1, #paperNames do
            local name = paperNames[nameIndex]
            if allowedByConfig(config.wallpapers, name) then
                entries[#entries + 1] = {
                    label = plasterLabel .. " + " .. paperLabel(name),
                    actionType = "wallFinish",
                    plaster = true,
                    wallpaperType = name
                }
            end
        end
    end
    if rules.canPaint and not rules.paintRequiresPlaster then
        local paints = mapping.directPaints or {}
        if #sortedKeys(paints) == 0 then paints = mapping.paints or {} end
        local paintNames = sortedKeys(paints)
        for nameIndex = 1, #paintNames do
            local name = paintNames[nameIndex]
            if allowedByConfig(config.paints, name) then
                local label, color = paintLabel(name)
                entries[#entries + 1] = {
                    label = label,
                    actionType = "wallFinish",
                    plaster = false,
                    paintType = name,
                    color = color
                }
            end
        end
    end
    if rules.canWallpaper and not rules.wallpaperRequiresPlaster then
        local papers = mapping.directWallpapers or {}
        if #sortedKeys(papers) == 0 then papers = mapping.wallpapers or {} end
        local paperNames = sortedKeys(papers)
        for nameIndex = 1, #paperNames do
            local name = paperNames[nameIndex]
            if allowedByConfig(config.wallpapers, name) then
                entries[#entries + 1] = {
                    label = paperLabel(name),
                    actionType = "wallFinish",
                    plaster = false,
                    wallpaperType = name
                }
            end
        end
    end
    return entries
end

-- Checks the player carries the tools/materials needed by the selected
-- pipeline. Direct-paint/direct-paper surfaces omit plaster requirements.
---@param player IsoPlayer
---@param finish KBW.WallFinish|nil
function WallFinishes.validateItems(player, finish)
    if not WallFinishes.isWallFinish(finish) then return true end
    if not player then return false, "missing player" end
    if player.isBuildCheat and player:isBuildCheat() then return true end
    local inventory = player:getInventory()
    if not inventory then return false, "missing inventory" end
    if finish.plaster ~= false then
        if not scanTag(inventory, ItemTag.PLASTER_TROWEL, predicateNotBroken) then
            return false, "missing plastering trowel"
        end
        if not scanTag(inventory, ItemTag.PLASTER_BUCKET, predicateEnoughDrain) then
            return false, "missing plaster bucket"
        end
    end
    if finish.paintType then
        if not scanTag(inventory, ItemTag.PAINTBRUSH, predicateNotBroken) then return false, "missing paintbrush" end
        if not firstType(inventory, finish.paintType) then return false, "missing selected paint" end
    end
    if finish.wallpaperType then
        if not scanTag(inventory, ItemTag.PAINTBRUSH, predicateNotBroken) then return false, "missing paintbrush" end
        if not firstType(inventory, finish.wallpaperType) then return false, "missing selected wallpaper" end
        if not scanTag(inventory, ItemTag.WALLPAPER_PASTE, predicateEnoughDrain) then
            return false, "missing wallpaper paste"
        end
        if not scanTag(inventory, ItemTag.SCISSORS, predicateNotBroken) then return false, "missing scissors" end
    end
    return true
end

local function tagRow(player, id, label, tag, tagName, mode, role, predicate, flags)
    local inventory = player and player:getInventory() or nil
    local countUses = mode == "drain"
    local item = inventory and scanTag(inventory, tag, predicate) or nil
    local availableItems, available = allByTag(inventory, tag, predicate, countUses)
    local cheat = player and player.isBuildCheat and player:isBuildCheat()
    return {
        id = id,
        kind = "input",
        role = role or "tool",
        mode = mode or "keep",
        resourceType = "Item",
        label = label,
        needed = 1,
        uses = countUses and 1 or nil,
        available = available,
        ok = cheat == true or available >= 1,
        item = item,
        matchTag = tag,
        isFinish = true,
        possibleItems = preferPossibleItem(possibleItemsForTag(tag), preferredForTag(tag)),
        possibleTags = { tagName },
        flags = flags or {},
        availableItems = availableItems
    }
end

local function itemRow(player, id, itemType, mode, role)
    local inventory = player and player:getInventory() or nil
    local fullType = normalizeFullType(itemType)
    local countUses = mode == "drain"
    local availableItems, available = allByTypes(inventory, typeAliases(itemType), predicateAnyUsable, countUses)
    local cheat = player and player.isBuildCheat and player:isBuildCheat()
    return {
        id = id,
        kind = "input",
        role = role or "material",
        mode = mode or "drain",
        resourceType = "Item",
        label = itemLabel(fullType),
        selectedFullType = fullType,
        needed = 1,
        uses = countUses and 1 or nil,
        available = available,
        ok = cheat == true or available >= 1,
        isFinish = true,
        possibleItems = { fullType },
        items = { fullType },
        possibleTags = {},
        flags = {},
        availableItems = availableItems
    }
end

-- Requirement-panel rows describing what the selected finish will use.
---@param player IsoPlayer
---@param finish KBW.WallFinish|nil
function WallFinishes.statusRows(player, finish)
    local rows = {}
    if not WallFinishes.isWallFinish(finish) then return rows end
    if finish.plaster ~= false then
        rows[#rows + 1] = tagRow(
            player, "finish-plaster-trowel", translated("IGUI_KBW_PlasterTrowel", "Plastering trowel"),
            ItemTag.PLASTER_TROWEL, "base:plastertrowel", "keep", "tool", predicateNotBroken,
            { "Prop1", "MayDegradeVeryLight" }
        )
        rows[#rows + 1] = tagRow(
            player, "finish-plaster", translated("IGUI_KBW_PlasterBucket", "Plaster bucket"), ItemTag.PLASTER_BUCKET,
            "base:plasterbucket", "drain", "material", predicateEnoughDrain
        )
    end
    if finish.paintType then
        rows[#rows + 1] = tagRow(
            player, "finish-brush", translated("IGUI_KBW_Paintbrush", "Paintbrush"), ItemTag.PAINTBRUSH,
            "base:paintbrush", "keep", "tool", predicateNotBroken
        )
        rows[#rows + 1] = itemRow(player, "finish-paint", finish.paintType, "drain", "material")
    end
    if finish.wallpaperType then
        rows[#rows + 1] = tagRow(
            player, "finish-brush", translated("IGUI_KBW_Paintbrush", "Paintbrush"), ItemTag.PAINTBRUSH,
            "base:paintbrush", "keep", "tool", predicateNotBroken
        )
        rows[#rows + 1] = itemRow(player, "finish-paper", finish.wallpaperType, "drain", "material")
        rows[#rows + 1] = tagRow(
            player, "finish-paste", translated("IGUI_KBW_WallpaperPaste", "Wallpaper paste"), ItemTag.WALLPAPER_PASTE,
            "base:wallpaperpaste", "drain", "material", predicateEnoughDrain
        )
        rows[#rows + 1] = tagRow(
            player, "finish-scissors", translated("IGUI_KBW_Scissors", "Scissors"), ItemTag.SCISSORS, "base:scissors",
            "keep", "tool", predicateNotBroken
        )
    end
    return rows
end

-- Rows for the build queue's material fetching (same shape, only missing
-- checks matter there).
---@param player IsoPlayer
---@param finish KBW.WallFinish|nil
function WallFinishes.fetchRows(player, finish)
    return WallFinishes.statusRows(player, finish)
end

return WallFinishes
