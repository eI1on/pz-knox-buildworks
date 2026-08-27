---Durability provides the Knox Buildworks default construction health layer.
---
---Build 42 computes a finished object's health as
---  health + bonusHealth * sandboxMultiplier + highestRelevantSkill * skillBaseHealth
---(ISBuildIsoEntity:create). Entity-backed buildables read those three numbers
---off their vanilla script, but a JSON-only buildable declares none of them, so
---every one of them used to finish at a flat 100 with no skill scaling at all --
---a high fence was as tough as a poster.
---
---This module supplies the missing numbers instead: a structural class derived
---from the buildable's placement and category, scaled by its material and by
---the skill its recipe demands. Anything the definition or the vanilla script
---states explicitly still wins; this only fills the gap.
local Durability = {}

-- Unskilled wood is the reference. Calibrated against the vanilla entity
-- scripts: wooden wall 450, wooden fence 250, wall frame 50, carpentry stairs
-- 150, log bench 100.
local CLASS = {
    wall = { base = 450, skill = 20 },
    fence = { base = 250, skill = 20 },
    railing = { base = 150, skill = 10 },
    frame = { base = 60, skill = 20 },
    door = { base = 250, skill = 20 },
    floor = { base = 150, skill = 10 },
    stairs = { base = 150, skill = 50 },
    container = { base = 120, skill = 10 },
    workstation = { base = 100, skill = 20 },
    furniture = { base = 100, skill = 10 },
    decoration = { base = 40, skill = 5 },
    overlay = { base = 30, skill = 0 }
}

-- Metal wall 700 and brick wall 500 against the wooden 450 set these.
local MATERIAL = {
    Wood = 1.0,
    ["Wood and Metal"] = 1.25,
    Natural = 0.8,
    Fabric = 0.5,
    Glass = 0.6,
    Electronics = 0.8,
    Other = 1.0,
    Brick = 1.15,
    Stone = 1.25,
    Concrete = 1.7,
    Metal = 1.55
}

-- Masonry work scales far harder with skill in vanilla (brick wall 70/level,
-- stone wall 400/level) than carpentry does.
local SKILL_MATERIAL = {
    Brick = 2.5,
    Stone = 2.5,
    Concrete = 2.5,
    Metal = 1.0
}

-- A build that demands more skill is sturdier, the way vanilla walks its wooden
-- wall 450 -> 550 -> 650 up the carpentry ladder. Stage group level is NOT used
-- for this: groups index shape as often as quality ("Roof Slope Wall 6"), so
-- scaling on it would hand shape 6 three times the health of shape 1.
local SKILL_STEP = 0.08

local WORKSTATION_CATEGORIES = {
    Blacksmithing = true, Pottery = true, Agricultural = true, Animals = true, Appliances = true
}

local DECORATION_CATEGORIES = {
    Decorations = true, ["Road Work"] = true, Vegetation = true, ["Wall Finishes"] = true
}

local function matches(text, word)
    return type(text) == "string" and string.find(string.lower(text), word, 1, true) ~= nil
end

-- Fences, railings, wall frames and doors all place as walls but take very
-- different punishment, so the subcategory decides between them.
local function wallClass(definition)
    local category, subcategory = definition.category, definition.subcategory
    -- A wall frame is the bare skeleton raised before the wall itself; vanilla
    -- rates it 50-100 against a finished wall's 450.
    if matches(subcategory, "wall frame") then return "frame" end
    -- A door or window opening stays part of the wall. Vanilla agrees: its
    -- wooden window frame and wooden wall share 450/550/650 tier for tier.
    if matches(subcategory, "window") or matches(subcategory, "door frame") then return "wall" end
    if category == "Windows" then return "wall" end
    if category == "Doors" or matches(subcategory, "door") or matches(subcategory, "gate") then return "door" end
    if matches(subcategory, "railing") then return "railing" end
    if category == "Fencing" or category == "Fences & Gates" or matches(subcategory, "fence") then return "fence" end
    return "wall"
end

local function objectClass(definition)
    local category, subcategory = definition.category, definition.subcategory
    if category == "Containers" then return "container" end
    if WORKSTATION_CATEGORIES[category] or matches(subcategory, "workstation") then return "workstation" end
    if DECORATION_CATEGORIES[category] then return "decoration" end
    if category == "Fencing" or category == "Fences & Gates" then
        return matches(subcategory, "railing") and "railing" or "fence"
    end
    if category == "Structural" then return "wall" end
    return "furniture"
end

---Structural class Knox treats this buildable as for durability purposes.
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage|nil
---@return string
function Durability.classOf(definition, stage)
    if not definition then return "furniture" end
    local placement = (stage and stage.placement) or definition.placement or {}
    local kind = placement.kind
    if kind == "overlay" or kind == "wallCovering" then return "overlay" end
    if kind == "floor" then return "floor" end
    if kind == "stairs" then return "stairs" end
    if kind == "wall" then return wallClass(definition) end
    return objectClass(definition)
end

local function requiredSkillLevel(stage)
    local skills = ((stage or {}).requirements or {}).skills or {}
    local highest = 0
    for _, level in pairs(skills) do
        local value = tonumber(level) or 0
        if value > highest then highest = value end
    end
    return highest
end

---Base and per-skill-level health for a buildable that declares neither.
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage|nil
---@return number base
---@return number skillBase
function Durability.derive(definition, stage)
    local class = CLASS[Durability.classOf(definition, stage)] or CLASS.furniture
    local material = definition and definition.material or nil
    local base = class.base * (MATERIAL[material] or 1.0) * (1 + SKILL_STEP * requiredSkillLevel(stage))
    local skill = class.skill * (SKILL_MATERIAL[material] or 1.0)
    return math.floor(base + 0.5), math.floor(skill + 0.5)
end

---Final (base, bonus, skillBase) for a cursor. Explicit stage values win over
---the vanilla script, which wins over the derived defaults.
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage|nil
---@param spriteConfig table|nil resolved SpriteConfig (carries entity script values)
---@return number base
---@return number bonus
---@return number skillBase
function Durability.resolve(definition, stage, spriteConfig)
    spriteConfig = spriteConfig or {}
    local derivedBase, derivedSkill = Durability.derive(definition, stage)
    local base = spriteConfig.health
    local skill = spriteConfig.skillBaseHealth
    -- A vanilla script with health = -1 is stripped to nil by EntityCompat and
    -- carries all of its durability in skillBaseHealth; deriving a base for it
    -- would make Knox's copy tougher than the base game's.
    if base == nil and skill == nil then
        base, skill = derivedBase, derivedSkill
    else
        base = base or 0
        skill = skill or 0
    end
    return base, spriteConfig.bonusHealth or 0, skill
end

return Durability
