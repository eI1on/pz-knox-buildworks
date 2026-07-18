---I18n provides the Knox Buildworks shared runtime layer.
-- Shared localization helpers for Knox Buildworks UI and definitions.
--
-- Definition ids remain stable machine data. Every player-facing value is
-- resolved through a routed Project Zomboid translation key first, with the
-- JSON display string retained only as an add-on-safe fallback.
---@class KBW.I18nModule
---@type KBW.I18nModule
local I18n = {}

local function translated(key)
    if not key or key == "" or not getText then return nil end
    local value = getText(key)
    if value and value ~= "" and value ~= key then return value end
    return nil
end

---@param key string|number
function I18n.text(key, fallback)
    return translated(key) or fallback or key or ""
end

-- Translation keys must be ASCII identifiers even when the source label is
-- localized. The original value remains the fallback for third-party add-ons.
---@param value unknown
function I18n.keyPart(value)
    local part = tostring(value or "")
    part = string.gsub(part, "[^A-Za-z0-9]+", "_")
    part = string.gsub(part, "_+", "_")
    part = string.gsub(part, "^_+", "")
    part = string.gsub(part, "_+$", "")
    return part ~= "" and part or "General"
end

---@param value unknown
function I18n.category(value)
    return I18n.text("IGUI_KBW_Category_" .. I18n.keyPart(value), tostring(value or ""))
end

---@param value unknown
function I18n.subcategory(value)
    return I18n.text("IGUI_KBW_Subcategory_" .. I18n.keyPart(value or "General"), tostring(value or "General"))
end

---@param value unknown
function I18n.materialTag(value)
    return I18n.text("IGUI_KBW_MaterialTag_" .. I18n.keyPart(value), tostring(value or ""))
end

---@param value unknown
function I18n.skill(value)
    value = tostring(value or "")
    return I18n.text("IGUI_perks_" .. value, value)
end

function I18n.groupKey(groupId)
    return "IGUI_KBW_Group_" .. I18n.keyPart(groupId)
end

---@param definition KBW.BuildableDefinition
function I18n.definitionName(definition)
    if not definition then return "?" end
    return I18n.text(definition.translationKey, definition.displayName or definition.id or "?")
end

---@param definition KBW.BuildableDefinition
function I18n.definitionDescription(definition)
    if not definition then return "" end
    local descriptionKey = definition.descriptionKey
    if descriptionKey and descriptionKey ~= "" then
        return I18n.text(descriptionKey, definition.description or "")
    end
    local description = definition.description
    if description and description ~= "" then
        return I18n.text(description, description)
    end
    return I18n.text(definition.tooltipKey, "")
end

function I18n.optionName(option, fallback)
    if not option then return fallback or "?" end
    local raw = option.displayName or option.label or option.name or option.id or fallback or "?"
    return I18n.text(option.translationKey or option.labelKey, raw)
end

return I18n
