---Lists, under a literature tooltip, the buildables its learned recipes unlock
---(derived from the loaded definitions, not the item script).
require "ISUI/ISToolTipInv"
local Registry = require("KnoxBuildworks/Definitions/Registry")
local I18n = require("KnoxBuildworks/I18n")
local KBW = require("KnoxBuildworks/Core")

local MagazineTooltip = {}

local MAX_LINES = 14 -- card names; above this, catalogue sections
local MAX_SECTION_LINES = 30
local PAD = 6

local index = nil -- { hash = string, byRecipe = { [recipe] = { [cardName] = section } } }

local function cardName(definition)
    local group = definition.group
    if type(group) == "table" and group.id ~= nil then
        return I18n.text(group.translationKey or I18n.groupKey(group.id), group.name or I18n.definitionName(definition))
    end
    return I18n.definitionName(definition)
end

local function sectionName(definition)
    return I18n.category(definition.category or "General") .. " / " .. I18n.subcategory(definition.subcategory or "General")
end

local function buildIndex()
    local byRecipe = {}
    local definitions = Registry:list()
    for definitionIndex = 1, #definitions do
        local definition = definitions[definitionIndex]
        local stages = definition.stages or {}
        for stageIndex = 1, #stages do
            local requirements = stages[stageIndex].requirements or {}
            local knowledge = requirements.knowledge or {}
            local lists = { requirements.recipes or {}, knowledge.recipes or {} }
            for listIndex = 1, #lists do
                local recipes = lists[listIndex]
                for recipeIndex = 1, #recipes do
                    local recipe = tostring(recipes[recipeIndex])
                    byRecipe[recipe] = byRecipe[recipe] or {}
                    byRecipe[recipe][cardName(definition)] = sectionName(definition)
                end
            end
        end
    end
    return byRecipe
end

local function recipesIndex()
    local hash = Registry.hash
    if not hash then return nil end
    if not index or index.hash ~= hash then
        index = { hash = hash, byRecipe = buildIndex() }
    end
    return index.byRecipe
end

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local linesByRecipes = {} -- render runs every frame; the lines only change with the registry

local function linesFor(learned, byRecipe)
    local recipes = {}
    for recipeIndex = 0, learned:size() - 1 do recipes[#recipes + 1] = tostring(learned:get(recipeIndex)) end
    local key = index.hash .. "|" .. table.concat(recipes, ";")
    local cached = linesByRecipes[key]
    if cached then return cached end
    local cards = {}
    local relevant = {}
    for recipeIndex = 1, #recipes do
        local unlocked = byRecipe[recipes[recipeIndex]]
        if unlocked then
            relevant[#relevant + 1] = recipes[recipeIndex]
            for name, section in pairs(unlocked) do cards[name] = section end
        end
    end
    cached = { recipes = relevant }
    local names = sortedKeys(cards)
    cached.count = #names
    if #names <= MAX_LINES then
        cached.lines = names
    else
        local sections = {}
        for nameIndex = 1, #names do
            local section = cards[names[nameIndex]]
            sections[section] = (sections[section] or 0) + 1
        end
        local lines = sortedKeys(sections)
        for lineIndex = 1, #lines do
            lines[lineIndex] = lines[lineIndex] .. " (" .. tostring(sections[lines[lineIndex]]) .. ")"
        end
        cached.lines = lines
    end
    linesByRecipes[key] = cached
    return cached
end

---Card names, or catalogue sections with counts when there are many.
---@param item InventoryItem
---@param character IsoGameCharacter|nil
---@return string[]|nil lines, boolean known, number cards
function MagazineTooltip.unlocksFor(item, character)
    if not item or not instanceof(item, "Literature") then return nil, false, 0 end
    local learned = item:getLearnedRecipes()
    if not learned or learned:isEmpty() then return nil, false, 0 end
    local byRecipe = recipesIndex()
    if not byRecipe then return nil, false, 0 end
    local entry = linesFor(learned, byRecipe)
    if entry.count == 0 then return nil, false, 0 end
    local known = character ~= nil
    for recipeIndex = 1, #entry.recipes do
        if known and not character:isRecipeActuallyKnown(entry.recipes[recipeIndex]) then known = false end
    end
    return entry.lines, known, entry.count
end

local function drawUnlocks(tooltip)
    local names, known, cards = MagazineTooltip.unlocksFor(tooltip.item,
        tooltip.tooltip and tooltip.tooltip:getCharacter() or getSpecificPlayer(0))
    if not names then return end
    local font = UIFont.Small
    local textManager = getTextManager()
    local lineHeight = textManager:getFontHeight(font)
    local lines = { { text = getText("IGUI_KBW_MagazineUnlocks", tostring(cards)), header = true } }
    local shown = math.min(#names, MAX_SECTION_LINES)
    for nameIndex = 1, shown do lines[#lines + 1] = { text = names[nameIndex] } end
    if #names > shown then
        lines[#lines + 1] = { text = getText("IGUI_KBW_MagazineUnlocksMore", tostring(#names - shown)) }
    end
    local width = tooltip.width
    for lineIndex = 1, #lines do
        width = math.max(width, textManager:MeasureStringX(font, lines[lineIndex].text) + PAD * 2 + (lines[lineIndex].header and 0 or 8))
    end
    local height = #lines * lineHeight + PAD * 2
    local top = tooltip.height
    if tooltip:getAbsoluteY() + tooltip.height + height > getCore():getScreenHeight() then top = -height end
    local background, border = tooltip.backgroundColor, tooltip.borderColor
    tooltip:drawRect(0, top, width, height, background.a, background.r, background.g, background.b)
    tooltip:drawRectBorder(0, top, width, height, border.a, border.r, border.g, border.b)
    for lineIndex = 1, #lines do
        local line = lines[lineIndex]
        local y = top + PAD + (lineIndex - 1) * lineHeight
        if line.header then
            tooltip:drawText(line.text, PAD, y, 1, 1, 0.8, 1, font)
        elseif known then
            tooltip:drawText(line.text, PAD + 8, y, 0.45, 0.85, 0.45, 1, font)
        else
            tooltip:drawText(line.text, PAD + 8, y, 0.9, 0.9, 0.9, 1, font)
        end
    end
end

-- Vanilla's tooltip has no extension point; wrap render once.
if not KBW.originalTooltipRender then
    KBW.originalTooltipRender = ISToolTipInv.render
    function ISToolTipInv:render()
        KBW.originalTooltipRender(self)
        if self.item and not (ISContextMenu.instance and ISContextMenu.instance.visibleCheck) then
            drawUnlocks(self)
        end
    end
end

return MagazineTooltip
