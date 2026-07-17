---IconResolver provides the Knox Buildworks custom user-interface layer.
---@class KBW.IconResolverModule
---@type KBW.IconResolverModule
local IconResolver = {}
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")

local function scriptFor(fullType)
    if not fullType then return nil end
    if getItem then
        local script = getItem(fullType)
        if script then return script end
    end
    return ScriptManager and ScriptManager.instance and ScriptManager.instance:FindItem(fullType) or nil
end

local function normalizeTagName(name)
    if not name then return nil end
    local value = tostring(name)
    if string.sub(value, 1, 1) == "#" then value = string.sub(value, 2) end
    if not string.find(value, ":", 1, true) then
        local dotIndex = string.find(value, ".", 1, true)
        if dotIndex then
            local namespace = string.sub(value, 1, dotIndex - 1)
            local path = string.sub(value, dotIndex + 1)
            if namespace ~= "" and path ~= "" and not string.find(path, ".", 1, true) then
                value = namespace .. ":" .. path
            end
        end
    end
    return value
end

local function tagValue(name)
    local normalized = normalizeTagName(name)
    local tag = nil
    if normalized and ItemTag and ResourceLocation then tag = ItemTag.get(ResourceLocation.of(normalized)) end
    if not tag and ItemTag and normalized then
        local key = string.upper(string.gsub(normalized, "(%l)(%u)", "%1_%2"))
        key = string.gsub(key, "[^A-Z0-9]", "_")
        tag = ItemTag[key] or ItemTag[string.upper(normalized)]
    end
    return tag, normalized
end

local function fullTypeFromScriptItem(scriptItem)
    if not scriptItem then return nil end
    if scriptItem.getFullName then return scriptItem:getFullName() end
    if scriptItem.getFullType then return scriptItem:getFullType() end
    if scriptItem.getName then return scriptItem:getName() end
    return nil
end

local function firstItemForTag(tagName)
    local tag = tagValue(tagName)
    if not tag or not getScriptManager then return nil end
    local manager = getScriptManager()
    if not manager or not manager.getItemsTag then return nil end
    local scriptItems = manager:getItemsTag(tag)
    if scriptItems and scriptItems:size() > 0 then return fullTypeFromScriptItem(scriptItems:get(0)) end
    return nil
end

local function textureFromItem(fullType)
    local script = scriptFor(fullType)
    if script and script.getNormalTexture then
        local color = { r = 1, g = 1, b = 1, a = 1 }
        if script.getR then
            color.r = script:getR()
            color.g = script:getG()
            color.b = script:getB()
        end
        return script:getNormalTexture(), color
    end
    return nil, nil
end

local function textureFromTextureName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local texture = getTexture(name)
    if texture then return texture end
    texture = getTexture("media/textures/" .. name .. ".png")
    if texture then return texture end
    texture = getTexture("media/ui/" .. name .. ".png")
    if texture then return texture end
    texture = getTexture("media/ui/Entity/" .. name .. ".png")
    if texture then return texture end
    texture = getTexture("media/ui/craftingMenus/" .. name .. ".png")
    if texture then return texture end
    return nil
end

function IconResolver.textureForItem(fullType)
    return textureFromItem(fullType)
end

function IconResolver.firstItemForTag(tagName)
    return firstItemForTag(tagName)
end

function IconResolver.textureForTag(tagName)
    local fullType = firstItemForTag(tagName)
    if fullType then return textureFromItem(fullType) end
    return nil, nil
end

function IconResolver.displayNameForTag(tagName)
    local tag, normalized = tagValue(tagName)
    if tag and tag.getTranslationName then
        local translated = tag:getTranslationName()
        if translated and translated ~= "" then return translated end
    end
    local fullType = firstItemForTag(normalized or tagName)
    if fullType and getItemNameFromFullType then return getItemNameFromFullType(fullType) end
    return normalized or tostring(tagName or "?")
end

local function textureFromSprite(spriteName)
    local sprite = spriteName and getSprite(spriteName)
    return sprite and sprite:getTextureForCurrentFrame(IsoDirections.N) or nil
end

local function firstSprite(stage)
    local sprites = stage and stage.sprites or {}
    return sprites.S or sprites.W or sprites.N or sprites.E
end

---@param spriteName string|nil
function IconResolver.textureForSpriteName(spriteName)
    return textureFromSprite(spriteName)
end

---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param direction KBW.Direction
function IconResolver.textureForDefinition(definition, stage, direction)
    if not definition and not stage then return nil, nil end
    local recipe = StageConfig.recipe(definition, stage)
    local iconTexture = (stage and (stage.iconTexture or stage.icon)) or definition.iconTexture or definition.icon
    local texture = textureFromTextureName(iconTexture)
    if texture then return texture, { r = 1, g = 1, b = 1, a = 1 } end

    texture = textureFromTextureName((stage and stage.iconName) or definition.iconName or recipe.icon)
    if texture then return texture, { r = 1, g = 1, b = 1, a = 1 } end

    texture = textureFromSprite((stage and stage.iconSprite) or definition.iconSprite)
    if texture then return texture, { r = 1, g = 1, b = 1, a = 1 } end

    local itemTexture, color = textureFromItem((stage and stage.iconItem) or definition.iconItem)
    if itemTexture then return itemTexture, color end

    local face = direction or "S"
    texture = textureFromSprite(Matrix.getFaceSprite(stage, face) or firstSprite(stage))
    return texture, { r = 1, g = 1, b = 1, a = 1 }
end

return IconResolver
