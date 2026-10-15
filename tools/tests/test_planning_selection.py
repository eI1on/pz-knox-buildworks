"""Room cutting, multi-piece removal and the box selection used in Planning Mode."""
import unittest

from test_catalog_workspace import LUA, runtime


def load(lua, path, name=None):
    value = lua.execute((LUA / path).read_text(encoding="utf-8-sig"))
    if name:
        lua.globals()[name] = value
    return value


def blueprint_runtime():
    lua = runtime()
    lua.execute("""
        modules['KnoxBuildworks/Definitions/Resolver']={resolveStage=function(id)
            return {id=id,placement={kind='floor'}},{id='built',wide=(id=='bench')} end}
        modules['KnoxBuildworks/Geometry/Matrix']={getFaceCells=function(stage, dir)
            if stage.wide then return {{dx=0,dy=0,blocks=true},{dx=1,dy=0,blocks=true}} end
            return {{dx=0,dy=0,blocks=true,kind='floor'}} end,
            getFaceSprite=function() return nil end}
        modules['KnoxBuildworks/Validation/Placement']={previousStageOf=function() end,
            optionalReplacementStageOf=function() end}
        modules['KnoxBuildworks/Definitions/StageConfig']={placement=function(d) return d.placement end,
            sprite=function() return {} end}
        modules['KnoxBuildworks/Planning/BlueprintFiles']={queueSave=function() end}
        function isClient() return false end
    """)
    shape = load(lua, "shared/KnoxBuildworks/Planning/RoomShape.lua", "RoomShape")
    lua.globals().modules["KnoxBuildworks/Planning/RoomShape"] = shape
    load(lua, "shared/KnoxBuildworks/Planning/Blueprints.lua", "bp")
    return lua


class RoomCutTests(unittest.TestCase):
    def test_subtract_cuts_holes_notches_and_whole_rooms(self):
        lua = blueprint_runtime()
        lua.execute("""
            local function count(room) local _,list=RoomShape.cells(room); return #list end
            local room={x=10,y=20,w=6,h=4}
            -- A notch out of one corner keeps every other tile.
            local rects=RoomShape.subtract(room,{x=14,y=20,w=2,h=2})
            room.rects=rects
            assert(count(room)==20 and not RoomShape.contains(room,15,20) and RoomShape.contains(room,15,22))
            -- A hole in the middle.
            rects=RoomShape.subtract(room,{x=12,y=21,w=1,h=2})
            room.rects=rects
            assert(count(room)==18 and not RoomShape.contains(room,12,22) and RoomShape.contains(room,11,22))
            -- An area outside the room is refused.
            local none,why=RoomShape.subtract(room,{x=0,y=0,w=2,h=2})
            assert(none==nil and why=='nothing_to_cut')
            -- Covering the whole room leaves nothing.
            local empty=RoomShape.subtract(room,{x=0,y=0,w=40,h=40})
            assert(type(empty)=='table' and #empty==0)
            -- The rebuilt rectangles keep exactly the remaining tiles.
            local before={}
            local _,list=RoomShape.cells(room)
            for i=1,#list do before[list[i].x..':'..list[i].y]=true end
            local again={x=room.x,y=room.y,rects=RoomShape.subtract(room,{x=10,y=23,w=1,h=1})}
            local _,after=RoomShape.cells(again)
            assert(#after==#list-1)
            for i=1,#after do assert(before[after[i].x..':'..after[i].y]) end
        """)

    def test_shrink_room_syncs_and_removes_an_emptied_room(self):
        lua = blueprint_runtime()
        lua.execute("""
            sent={}
            local plan={id='plan',rooms={{id='r1',x=0,y=0,w=4,h=4,z=0},{id='r2',x=10,y=0,w=2,h=2,z=0}},placements={}}
            bp.get=function() return plan end
            bp.canContribute=function() return true end
            sendClientCommand=function(m,c,a) sent[#sent+1]={c=c,a=a} end
            function isClient() return true end
            local ok=bp.shrinkRoom({},'plan','r1',{x=0,y=0,w=2,h=4})
            local _,cells=RoomShape.cells(plan.rooms[1])
            assert(ok and #cells==8)
            local ok2,result=bp.shrinkRoom({},'plan','r2',{x=10,y=0,w=2,h=2})
            assert(ok2 and result=='removed' and #plan.rooms==1)
            -- Other viewers replay the same delta.
            local mirror={id='m',rooms={{id='r1',x=0,y=0,w=4,h=4,z=0}},placements={}}
            local server={id='s',rooms={{id='r1',x=0,y=0,w=4,h=4,z=0}},placements={}}
            bp.get=function() return server end
            local applied,ok3=bp.applyServerCommand({},'BPShrinkRoom',{id='s',roomId='r1',rect={x=0,y=0,w=2,h=4}})
            local _,serverCells=RoomShape.cells(server.rooms[1])
            assert(ok3 and #serverCells==8)
        """)

    def test_remove_placements_in_one_request(self):
        lua = blueprint_runtime()
        lua.execute("""
            local plan={id='plan',rooms={},placements={}}
            for i=1,5 do plan.placements[i]={id='p'..i,buildableId='floor',x=i,y=0,z=0} end
            bp.get=function() return plan end
            bp.canContribute=function() return true end
            bp.maxPlacements=function() return 1000 end
            bp.importLimit=function() return 1000 end
            assert(bp.removePlacements({},'plan',{'p2','p4','missing'})==2)
            assert(#plan.placements==3 and plan.placements[2].id=='p3')
            local server={id='s',placements={{id='a'},{id='b'},{id='c'}}}
            bp.get=function() return server end
            local args={id='s',placementIds={'a','c','zz'}}
            local _,ok=bp.applyServerCommand({},'BPRemovePlacements',args)
            assert(ok and #server.placements==1 and #args.placementIds==2)
            bp.canContribute=function() return false end
            local _,refused=bp.applyServerCommand({},'BPRemovePlacements',{id='s',placementIds={'b'}})
            assert(not refused and #server.placements==1)
        """)


class SelectionTests(unittest.TestCase):
    def test_box_picks_ghosts_with_any_cell_inside(self):
        lua = blueprint_runtime()
        lua.globals().modules["KnoxBuildworks/Planning/Blueprints"] = lua.globals().bp
        lua.execute("""
            ISBuildingObject={derive=function() return {} end}
            Events={OnGameStart={Add=function() end}}
        """)
        lua.execute("bp=modules['KnoxBuildworks/Planning/Blueprints']")
        select = load(lua, "client/KnoxBuildworks/Planning/SelectCursor.lua", "select")
        lua.execute("""
            local plan={placements={
                {id='in',buildableId='floor',x=2,y=2,z=0},
                {id='edge',buildableId='bench',x=4,y=3,z=0},
                {id='out',buildableId='floor',x=9,y=9,z=0},
                {id='up',buildableId='floor',x=3,y=3,z=1}}}
            -- The bench covers x=4 and x=5, so a box ending at x=5 catches it
            -- from its second tile; other levels are ignored.
            local ids,count=select.ghostsIn(plan,5,0,6,4,0)
            assert(count==1 and ids.edge)
            ids,count=select.ghostsIn(plan,0,0,5,5,0)
            assert(count==2 and ids['in'] and ids.edge and not ids.out and not ids.up)
        """)

    def test_world_objects_become_pieces_with_their_finish(self):
        lua = runtime()
        lua.execute("""
            KBW={Runtime={loaded=true}}
            modules['KnoxBuildworks/Core']=KBW
            local wall={id='wall',placement={kind='wall'}}
            local stage={id='built',cellsByFace={W={{dx=0,dy=0,sprite='wall_w'}},N={{dx=0,dy=0,sprite='wall_n'}}},
                requirements={inputs={{id='paint',tags={'Base:Paint'}}}}}
            local bench={id='bench',placement={kind='object'}}
            local benchStage={id='built',cellsByFace={S={{dx=0,dy=0,sprite='bench_a'},{dx=1,dy=0,sprite='bench_b'}}}}
            modules['KnoxBuildworks/UI/CatalogIndex']={get=function() return {list={
                {id='wall',stages={stage}},{id='bench',stages={benchStage}}}} end}
            modules['KnoxBuildworks/Definitions/Groups']={resolveDefinition=function(entry)
                return entry.id=='wall' and wall or bench end, resolveStageId=function(s) return s.id end}
            modules['KnoxBuildworks/Definitions/StageConfig']={sprite=function() return {} end,
                placement=function(d) return d.placement end}
            modules['KnoxBuildworks/UI/CatalogVisibility']={definitionEnabled=function() return true end,
                stagePasses=function() return true end}
            modules['KnoxBuildworks/I18n']={definitionName=function(d) return d.id end, optionName=function(o,id) return id or o.label end}
            modules['KnoxBuildworks/Util/Table']={copy=function(t) local r={} for k,v in pairs(t) do r[k]=v end return r end,
                merge=function(a,b) local r={} for k,v in pairs(a) do r[k]=v end for k,v in pairs(b or {}) do r[k]=v end return r end}
            local red={actionType='wallFinish',paintType='PaintRed',label='Red'}
            modules['KnoxBuildworks/Validation/WallFinishes']={
                entriesFor=function(d) return d.id=='wall' and {red} or {} end,
                isWallFinish=function(f) return f.actionType=='wallFinish' end,
                previewSprite=function() return nil end,
                plannedFinishSignature=function(f) return f.paintType end,
                objectFinishSignature=function(o) return o.paint end,
                paintComponents=function() return {} end, wallType=function() return nil end}
            modules['KnoxBuildworks/Validation/Placement']={previousStageOf=function() return nil end,
                optionalReplacementStageOf=function() return nil end}
            modules['KnoxBuildworks/UI/Catalog']={}
            IsoObjectType={doorN=1,doorW=2}
            function getSprite(name) return {getType=function() return 0 end, getName=function() return name end,
                getProperties=function() return {has=function() return false end} end} end
            Events={OnFillWorldObjectContextMenu={Add=function() end}}
            function object(sprite, x, y, paint)
                return {paint=paint, getSprite=function() return getSprite(sprite) end,
                    getSquare=function() return {getX=function() return x end,getY=function() return y end,
                        getZ=function() return 0 end} end}
            end
        """)
        load(lua, "client/KnoxBuildworks/UI/WorldCatalog.lua", "world")
        lua.execute("""
            local painted=world.placementsForObject({}, object('wall_n', 5, 7, 'PaintRed'))
            assert(#painted==1)
            local p=painted[1]
            assert(p.buildableId=='wall' and p.direction==2 and p.x==5 and p.y==7)
            assert(p.finish and p.finish.paintType=='PaintRed' and p.inputChoices.paint=='Base.PaintRed')
            -- The second tile of a two-tile bench anchors the piece one tile back.
            local benchPiece=world.placementsForObject({}, object('bench_b', 11, 3))[1]
            assert(benchPiece.buildableId=='bench' and benchPiece.x==10 and benchPiece.y==3 and benchPiece.direction==4)
            assert(benchPiece.finish==nil)
            assert(#world.placementsForObject({}, object('grass', 0, 0))==0)
        """)


if __name__ == "__main__":
    unittest.main()


class PreviewModelTests(unittest.TestCase):
    def test_tiles_sit_on_their_square_and_floors_draw_under_walls(self):
        lua = runtime()
        lua.execute("""
            Core={getTileScale=function() return 2 end}
            ISCollapsableWindow={derive=function() return {} end}
            ISPanel={derive=function() return {} end}
            cellsFor={}
            modules['KnoxBuildworks/Planning/GhostRenderer']={placementCells=function(p) return cellsFor[p.id] end}
            -- An untrimmed 2x tile: 128x256, nothing cut away.
            modules['KnoxBuildworks/UI/IconResolver']={textureForSpriteName=function(name)
                return {name=name,getWidthOrig=function() return 128 end,getHeightOrig=function() return 256 end,
                    getWidth=function() return 128 end,getHeight=function() return 256 end,
                    getOffsetX=function() return 0 end,getOffsetY=function() return 0 end} end}
        """)
        lua.globals().modules["KnoxBuildworks/Planning/RoomShape"] = load(
            lua, "shared/KnoxBuildworks/Planning/RoomShape.lua")
        load(lua, "client/KnoxBuildworks/UI/BlueprintPreview.lua")
        lua.execute("""
            local plan={placements={{id='w',x=2,y=1,z=0,direction=2},{id='f',x=2,y=1,z=0,direction=1}},rooms={}}
            cellsFor.w={{x=2,y=1,z=0,sprite='wall',kind='wall'}}
            cellsFor.f={{x=2,y=1,z=0,sprite='floor',kind='floor'}}
            local m=KBWBlueprintPreview.buildModel(plan,0)
            -- Square (2,1): iso point (32,48); the 64x128 image hangs 96 above it.
            local first,second=m.sprites[1],m.sprites[2]
            assert(first.texture.name=='floor' and second.texture.name=='wall', 'floor first')
            assert(first.x==0 and first.y==-48 and first.width==64 and first.height==128)
            assert(m.cells[2].north==false and m.cells[1].north==true and m.cells[1].kind=='wall')
        """)


class PlanningHoverTests(unittest.TestCase):
    def test_hover_details_dock_beside_the_catalogue_and_fit_the_screen(self):
        lua = runtime()
        lua.execute("""
            ISToolTip={derive=function() return {} end, new=function(self) return {} end, GetFont=function() return 1 end}
            ISPanel={derive=function() return {} end}
            screenH=720
            function getCore() return {getScreenWidth=function() return 1600 end,
                getScreenHeight=function() return screenH end} end
            mouseX, mouseY = 1450, 700
            function getMouseX() return mouseX end
            function getMouseY() return mouseY end
            UIFont.Medium=2
            local T=modules['KnoxBuildworks/UI/Theme']
            for _,k in pairs({'backdrop','border','borderSoft','text'}) do T[k]={r=1,g=1,b=1,a=1} end
            T.drawPreviewBackground=function() end
        """)
        load(lua, "client/KnoxBuildworks/UI/BuildCardGrid.lua")
        lua.execute("""
            local tip=setmetatable(KBWBuildablePreviewToolTip:new(),{__index=KBWBuildablePreviewToolTip})
            local x,y
            tip.setX=function(s,v) x=v; s.x=v end; tip.setY=function(s,v) y=v; s.y=v end
            tip.setWidth=function(s,v) s.width=v end; tip.setHeight=function(s,v) s.height=v end
            tip.drawRect=function() end; tip.drawRectBorder=function() end; tip.drawText=function() end
            tip.drawTextureScaledAspect=function() end
            tip.getAbsoluteX=function(s) return s.x or 0 end; tip.getAbsoluteY=function(s) return s.y or 0 end
            tip.name='Wooden Wall'
            tip.showDetails=true; tip.description='materials'
            local described=400
            tip.descriptionPanel={setWidth=function() end, paginate=function() end,
                getHeight=function() return described end, setX=function() end, setY=function() end,
                prerender=function() end, render=function() end}
            tip.dock={getAbsoluteX=function() return 1180 end, isReallyVisible=function() return true end}
            tip:doLayout(); tip:render()
            -- Left of the catalogue panel, never over it, and on screen.
            assert(x + tip.width <= 1180 - 8 and x >= 2)
            assert(y >= 2 and y + tip.height <= screenH - 2)
            -- A long list of materials shrinks the picture instead of
            -- running off the screen.
            described=600
            tip:doLayout()
            assert(tip.height <= screenH - 4 and tip.previewSize < tip.basePreviewSize, tip.height)
        """)


class PipetteTests(unittest.TestCase):
    def test_pipette_offers_planned_ghosts_then_built_pieces_top_down(self):
        lua = blueprint_runtime()
        lua.globals().modules["KnoxBuildworks/Planning/Blueprints"] = lua.globals().bp
        lua.execute("""
            ISBuildingObject={derive=function() return {} end}
            Events={OnGameStart={Add=function() end}}
            allowed=true
            modules['KnoxBuildworks/UI/CatalogVisibility']={definitionEnabled=function() return allowed end,
                stagePasses=function() return allowed end}
            modules['KnoxBuildworks/Definitions/Registry']={get=function(self,id) return {id=id} end}
            modules['KnoxBuildworks/I18n']={definitionName=function(d) return 'name:'..d.id end}
            local function obj(sprite) return {sprite=sprite} end
            local square={objects={obj('floor'),obj('wall_n'),obj('grass'),obj('chair')}}
            square.getObjects=function() return {size=function() return #square.objects end,
                get=function(_,i) return square.objects[i+1] end} end
            function getCell() return {getGridSquare=function(_,x,y,z) return square end} end
            local byName={floor={buildableId='floor_tile',direction=1,x=3,y=4,z=0,label='Floor'},
                wall_n={buildableId='brick_wall',direction=2,x=3,y=4,z=0,label='Brick wall',
                    finish={paintType='PaintRed'}},
                chair={buildableId='chair',direction=4,x=3,y=4,z=0,variantId='oak',label='Chair'}}
            modules['KnoxBuildworks/UI/WorldCatalog']={placementsForObject=function(player, o)
                local c=byName[o.sprite]; return c and {c} or {} end}
        """)
        load(lua, "client/KnoxBuildworks/Planning/PipetteCursor.lua", "pipette")
        lua.execute("""
            local plan={placements={{id='g1',buildableId='floor',x=3,y=4,z=0,direction=1},
                {id='g2',buildableId='crate',x=3,y=4,z=0,direction=3,variantId='blue'}}}
            local choices=pipette.choicesAt({},plan,3,4,0)
            -- Newest ghost first, then built pieces from the top of the square down.
            local order={}
            for i=1,#choices do order[i]=choices[i].source..':'..choices[i].placement.buildableId end
            assert(table.concat(order,',')=='ghost:crate,ghost:floor,world:chair,world:brick_wall,world:floor_tile',
                table.concat(order,','))
            assert(choices[1].placement.variantId=='blue' and choices[1].placement.direction==3)
            assert(choices[4].placement.finish.paintType=='PaintRed' and choices[4].placement.direction==2)
            assert(choices[1].label=='name:crate' and choices[3].label=='Chair')
            -- Pieces the player may not plan are not offered.
            allowed=false
            assert(#pipette.choicesAt({},plan,3,4,0)==3)
        """)
