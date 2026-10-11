-- B42's IsoRegions creates native buildings from enclosed player structures.
-- Its update only visits dirty region chunks; roofs and boundary chunks can
-- retain stale room references. Repair those from the current metagrid.
-- No synthetic rooms, save records, server commands or framework dependency.
local BuildingRender = { SQUARES_PER_TICK = 192, SCAN_TICKS = 120, RADIUS = 40 }
local CHUNK_SIZE = 8 -- B42 IsoChunk / IsoCell.getChunk, not B41's ten tiles.
local RENDER_DIRTY = 2112 -- FBORenderChunk.DIRTY_OBJECT_ADD + DIRTY_CUTAWAYS
local cached, queue, ticks = {}, {}, 0

function BuildingRender.repairSquare(square, grid)
    local x,y,z = square:getX(),square:getY(),square:getZ()
    local definition = grid:getRoomAt(x,y,z)
    local room = definition and definition:getIsoRoom() or nil
    local changed = false
    -- Preserve already-correct native IDs. When repairing an association, set
    -- the exact object too: long RoomIDs can lose precision at the Lua bridge.
    if square:getRoom() ~= room or not room and square:getRoomID() ~= -1 then
        square:setRoomID(definition and definition:getID() or -1)
        square:setRoom(room)
        changed = true
    end
    local properties = square:getProperties()
    if room and properties:has(IsoFlagType.exterior) then
        properties:unset(IsoFlagType.exterior)
        changed = true
    elseif not room and not properties:has(IsoFlagType.exterior) then
        properties:set(IsoFlagType.exterior)
        changed = true
    end
    if changed then square:invalidateRenderChunkLevel(RENDER_DIRTY) end
end

local function sameRoster(a,b)
    for definition,signature in pairs(a) do if b[definition] ~= signature then return false end end
    for definition in pairs(b) do if a[definition] == nil then return false end end
    return true
end

-- Chunk identities catch unload/reload even when the BuildingDef is unchanged.
-- Cache only the current nearby set, so travelling does not retain old worlds.
function BuildingRender.scan()
    local cell, world = getCell(), getWorld()
    if not cell or not world then return end
    local grid, wanted, found = world:getMetaGrid(), {}, ArrayList.new()
    for playerIndex = 0, getNumActivePlayers()-1 do
        local player = getSpecificPlayer(playerIndex)
        if player then
            local px,py = math.floor(player:getX()),math.floor(player:getY())
            local radius = BuildingRender.RADIUS
            found:clear()
            grid:getBuildingsIntersecting(px-radius,py-radius,radius*2,radius*2,found)
            for index = 0, found:size()-1 do
                local definition = found:get(index)
                if definition:isUserDefined() then
                    local x1,y1 = math.max(px-radius,definition:getX()-1),math.max(py-radius,definition:getY()-1)
                    local x2,y2 = math.min(px+radius,definition:getX2()),math.min(py+radius,definition:getY2())
                    local z1,z2 = math.max(-32,math.min(0,definition:getMinLevel())),math.min(31,definition:getMaxLevel()+4)
                    local signature = definition:getX()..":"..definition:getY()..":"..definition:getX2()..":"
                        ..definition:getY2()..":"..z1..":"..z2..":"..definition:getRooms():size()
                    for cx = math.floor(x1/CHUNK_SIZE),math.floor(x2/CHUNK_SIZE) do
                        for cy = math.floor(y1/CHUNK_SIZE),math.floor(y2/CHUNK_SIZE) do
                            local chunk = cell:getChunk(cx,cy)
                            if chunk then
                                local key = cx..":"..cy
                                local job = wanted[key]
                                if not job then
                                    job = {key=key,chunk=chunk,cx=cx,cy=cy,z1=z1,z2=z2,roster={}}
                                    wanted[key] = job
                                end
                                job.z1,job.z2 = math.min(job.z1,z1),math.max(job.z2,z2)
                                job.roster[definition] = signature
                            end
                        end
                    end
                end
            end
        end
    end
    -- A demolished room disappears from the query. Clear its old square
    -- associations once as well; otherwise roofs can stay hidden outdoors.
    for key,previous in pairs(cached) do
        if not wanted[key] and cell:getChunk(previous.cx,previous.cy) == previous.chunk then
            if not previous.cleanup then
                wanted[key] = {key=key,chunk=previous.chunk,cx=previous.cx,cy=previous.cy,
                    z1=previous.z1,z2=previous.z2,roster={},cleanup=true}
            elseif not previous.complete then wanted[key] = previous end
        end
    end
    local pending = {}
    for key,job in pairs(wanted) do
        local previous = cached[key]
        if previous and previous.chunk == job.chunk and previous.z1 == job.z1 and previous.z2 == job.z2
            and sameRoster(previous.roster,job.roster) then
            job = previous; wanted[key] = job
        end
        if not job.complete then job.offset = job.offset or 0; pending[#pending+1] = job end
    end
    table.sort(pending,function(a,b) return a.key < b.key end)
    cached,queue = wanted,pending
end

function BuildingRender.step(budget)
    local cell,world = getCell(),getWorld()
    if not cell or not world then return end
    local grid = world:getMetaGrid()
    budget = budget or BuildingRender.SQUARES_PER_TICK
    while budget > 0 and #queue > 0 do
        local job = queue[1]
        -- Never apply a queued scan to a replacement chunk.
        if cell:getChunk(job.cx,job.cy) ~= job.chunk then
            cached[job.key] = nil; table.remove(queue,1)
        else
            local offset = job.offset
            local x = job.cx*CHUNK_SIZE + offset%CHUNK_SIZE
            local y = job.cy*CHUNK_SIZE + math.floor(offset/CHUNK_SIZE)%CHUNK_SIZE
            local z = job.z1 + math.floor(offset/(CHUNK_SIZE*CHUNK_SIZE))
            local square = cell:getGridSquare(x,y,z)
            if square then BuildingRender.repairSquare(square,grid) end
            job.offset,budget = offset+1,budget-1
            if job.offset >= CHUNK_SIZE*CHUNK_SIZE*(job.z2-job.z1+1) then
                job.complete = true; table.remove(queue,1)
            end
        end
    end
end

function BuildingRender.reset()
    cached,queue,ticks = {},{},0
end

function BuildingRender.onTick()
    if isServer() and not isClient() then return end
    ticks = ticks+1
    if ticks == 1 or ticks >= BuildingRender.SCAN_TICKS then
        BuildingRender.scan(); ticks = 1
    end
    BuildingRender.step()
end

Events.OnGameStart.Add(BuildingRender.reset)
Events.OnTick.Add(BuildingRender.onTick)
return BuildingRender
