local VanillaTilePatches = {}

local WEST_INDEX_RANGES = {
    { 0, 0 },
    { 8, 60 },
    { 68, 70 },
    { 80, 80 }
}

local function patchWindowFrame(manager, spriteIndex, north)
    local sprite = manager:getSprite("walls_interior_house_05_" .. tostring(spriteIndex))
    local props = sprite and sprite:getProperties() or nil
    if not props then return end

    if north then
        props:set("WindowN", "", false)
        props:set(IsoFlagType.collideN)
        props:set(IsoFlagType.transparentN)
        props:set(IsoFlagType.cutN)
        props:set(IsoFlagType.canPathN)
        props:set(IsoFlagType.WindowN)
    else
        props:set("WindowW", "", false)
        props:set(IsoFlagType.collideW)
        props:set(IsoFlagType.transparentW)
        props:set(IsoFlagType.cutW)
        props:set(IsoFlagType.canPathW)
        props:set(IsoFlagType.WindowW)
    end

    props:set("wall", "", false)
    props:CreateKeySet()
end

function VanillaTilePatches.apply(manager)
    if not manager then return end
    for rangeIndex = 1, #WEST_INDEX_RANGES do
        local range = WEST_INDEX_RANGES[rangeIndex]
        for westIndex = range[1], range[2], 2 do
            patchWindowFrame(manager, westIndex, false)
            patchWindowFrame(manager, westIndex + 1, true)
        end
    end
end

Events.OnLoadedTileDefinitions.Add(VanillaTilePatches.apply)

return VanillaTilePatches
