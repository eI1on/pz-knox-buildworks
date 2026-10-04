local Collision = {}

function Collision.isPassableOpening(spriteName, north)
    local sprite = spriteName and getSprite(spriteName)
    local props = sprite and sprite:getProperties()
    if not props or props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans) then return false end
    if north then
        return props:has(IsoFlagType.cutN) and not (
            props:has(IsoFlagType.collideN) or props:has(IsoFlagType.WallN)
                or props:has(IsoFlagType.WallNW) or props:has(IsoFlagType.WindowN)
                or props:has(IsoFlagType.HoppableN) or props:has(IsoFlagType.doorN)
        )
    end
    return props:has(IsoFlagType.cutW) and not (
        props:has(IsoFlagType.collideW) or props:has(IsoFlagType.WallW)
            or props:has(IsoFlagType.WallNW) or props:has(IsoFlagType.WindowW)
            or props:has(IsoFlagType.HoppableW) or props:has(IsoFlagType.doorW)
    )
end

return Collision
