"""Regression coverage for actual roof profiles and native world rendering repair."""
import json
import importlib.util
import unittest

from test_catalog_workspace import LUA, ROOT, runtime
from test_building_improvements import module

_audit_spec = importlib.util.spec_from_file_location("audit_roof_definitions", ROOT / "tools/audit_roof_definitions.py")
_audit_module = importlib.util.module_from_spec(_audit_spec)
_audit_spec.loader.exec_module(_audit_module)
_preview_spec = importlib.util.spec_from_file_location("roof_preview", ROOT / "tools/roof_preview.py")
_preview = importlib.util.module_from_spec(_preview_spec)
_preview_spec.loader.exec_module(_preview)


class RoomShapeTests(unittest.TestCase):
    def test_connected_irregular_room_has_only_exposed_edges_and_roof_cells(self):
        lua = runtime()
        shape = module(lua, "shared/KnoxBuildworks/Planning/RoomShape.lua", "shape")
        lua.globals().modules["KnoxBuildworks/Planning/RoomShape"] = shape
        module(lua, "shared/KnoxBuildworks/Planning/RoofPlanner.lua", "roof")
        lua.execute("""
            local room={id='main',x=10,y=20,z=1,w=3,h=2}
            local rects=shape.extend(room,{x=12,y=22,w=2,h=2})
            assert(rects and #rects==2)
            room.rects=rects
            assert(shape.contains(room,13,23) and not shape.contains(room,10,23))
            local cells,list=shape.cells(room)
            assert(#list==10 and cells['13:23'])
            local edges=shape.perimeter(room)
            assert(#edges==8)
            local perimeter=0
            for i=1,#edges do
                local e=edges[i]
                perimeter=perimeter+math.abs(e[3]-e[1])+math.abs(e[4]-e[2])
            end
            assert(perimeter==16)
            assert(shape.extend(room,{x=15,y=24,w=1,h=1})==nil) -- corner/disconnected
            local region=roof.findRegion({room},'main')
            assert(region and #region.list==10 and not region.rectangle)
            assert(not region.cells['10:23'])
            local expanded=roof.previewFootprint(region,1)
            assert(expanded and #expanded.list>#region.list)
            assert(expanded.cells['9:20'] and expanded.cells['14:23'])
            assert(#shape.perimeterCells(expanded.cells,expanded.list)>0)
            room.x=110; room.y=120
            assert(shape.contains(room,113,123) and not shape.contains(room,110,123))
            local ring={x=0,y=0,w=3,h=1}
            ring.rects=shape.extend(ring,{x=0,y=1,w=1,h=2})
            ring.rects=shape.extend(ring,{x=2,y=1,w=1,h=2})
            ring.rects=shape.extend(ring,{x=1,y=2,w=1,h=1})
            assert(not shape.contains(ring,1,1))
            local length=0
            for _,edge in pairs(shape.perimeter(ring)) do
                length=length+math.abs(edge[3]-edge[1])+math.abs(edge[4]-edge[2])
            end
            assert(length==16) -- outer boundary and enclosed opening
        """)


class AuthoredRoofTests(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()
        module(self.lua, "shared/KnoxBuildworks/Planning/RoofPlanner.lua", "roof")
        directory = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions"
        definitions = []
        for path in sorted(directory.rglob("*.json")):
            definitions.extend(json.loads(path.read_text(encoding="utf-8")).get("buildables", []))
        self.lua.globals().definitions = self.lua.table_from(definitions, recursive=True)
        atlas = self.lua.globals().modules["KnoxBuildworks/Planning/RoofAtlas"]
        self.lua.globals().atlas = atlas
        self.lua.execute("""
            profiles=roof.profiles(definitions); gables=roof.gables(definitions)
            byId={}; for i=1,#definitions do byId[definitions[i].id]=definitions[i] end
            for i=1,#profiles do if profiles[i].id=='black:45' then steep=profiles[i] end
                if profiles[i].id=='black:30' then low=profiles[i] end end
            assert(steep and low and #gables>0)
            function spriteOf(item)
                local d=byId[item.buildableId]
                for j=1,#d.stages do if d.stages[j].id==item.stageId then
                    return roof.faceSprite(d.stages[j],({'W','N','E','S'})[item.direction]) end end
            end
            function verify(p)
                local occupied={}
                for i=1,#p do
                    local item=p[i]; local d=byId[item.buildableId]; assert(d)
                    local s=d.stages[1]; assert(s.id==item.stageId)
                    assert(s.geometry.faces[({'W','N','E','S'})[item.direction]])
                    local layer=d.placement.kind
                    if layer=='wall' then layer=layer..((item.direction==2 or item.direction==4) and 'N' or 'W') end
                    local key=item.x..':'..item.y..':'..item.z..':'..layer
                    assert(not occupied[key], 'duplicate '..key)
                    occupied[key]=true
                end
                return p
            end
            function checked(options,w,h)
                local p,r=roof.generate(steep,{x=100,y=200,z=0,w=w or 8,h=h or 6},options)
                assert(p,r)
                return verify(p)
            end
            function region(rooms,id) return roof.findRegion(rooms,id or rooms[1].id) end
        """)

    def test_atlas_reads_real_facing_from_vanilla_sheets(self):
        self.lua.execute("""
            -- 45 degree: only south and east faces exist; Facing is downhill.
            local s=atlas.roofPiece('roofs_02_0'); assert(s.kind=='slope' and s.facing=='S' and s.step==1)
            local e=atlas.roofPiece('roofs_02_3'); assert(e.kind=='slope' and e.facing=='E' and e.step==3)
            assert(atlas.roofPiece('roofs_02_8').kind=='outer' and atlas.roofPiece('roofs_02_8').corner=='SE')
            assert(atlas.roofPiece('roofs_02_11').kind=='valley' and atlas.roofPiece('roofs_02_11').corner=='SE')
            assert(atlas.roofPiece('roofs_02_36').facing=='E' and atlas.roofPiece('roofs_02_36').step==2)
            -- 30 degree: all four faces; the two inner-corner runs are the
            -- visible south-east valley (32..37) and the hidden north-west one.
            assert(atlas.roofPiece('roofs_30_02_16').facing=='W')
            assert(atlas.roofPiece('roofs_30_02_29').facing=='N' and atlas.roofPiece('roofs_30_02_29').step==1)
            assert(atlas.roofPiece('roofs_30_02_32').corner=='SE' and atlas.roofPiece('roofs_30_02_32').kind=='valley')
            assert(atlas.roofPiece('roofs_30_02_48').corner=='NW')
            assert(atlas.roofPiece('roofs_30_02_96').axis=='EW' and atlas.roofPiece('roofs_30_02_104').step==6)
            -- Gable ends: 30 degree north walls rise from the west at 16..21.
            local g=atlas.gablePiece('walls_exterior_roofs_30_19_16',30)
            assert(g.wall=='N' and g.low=='W' and g.step==1)
            g=atlas.gablePiece('walls_exterior_roofs_30_19_29',30)
            assert(g.wall=='N' and g.low=='E' and g.step==1)
            g=atlas.gablePiece('walls_exterior_roofs_01_37',45,24)
            assert(g.wall=='N' and g.low=='W' and g.step==1)
            -- Profiles resolve pieces through the sprite, whatever face it sits on.
            assert(steep.hidden.N and steep.hidden.W and not low.hidden.N and not low.hidden.W)
            local south=steep.pieces['slope:S:1']
            assert(atlas.roofPiece(roof.faceSprite(south.stage,south.face)).facing=='S')
            local west=low.pieces['slope:W:2']
            assert(atlas.roofPiece(roof.faceSprite(west.stage,west.face)).facing=='W')
        """)

    def test_auto_fit_caps_height_and_reuses_footprint_analysis(self):
        self.lua.execute("""
            local r=region({{id='a',x=0,y=0,z=29,w=24,h=24}})
            local selected,pieces,reason=roof.autoLayout(steep,r,{z=30})
            assert(selected and selected.kind~='flat' and selected.riseLevels==1,reason)
            local crown=0
            for i=1,#pieces do
                assert(pieces[i].z<=31)
                if pieces[i].z==31 and byId[pieces[i].buildableId].stages[1].roof.role=='flat' then
                    crown=crown+1
                end
            end
            assert(crown>0)
            local l=region({{id='a',x=0,y=0,z=0,w=8,h=4},{id='b',x=0,y=4,z=0,w=4,h=4}})
            local expanded=roof.previewFootprint(l,1)
            assert(expanded==roof.previewFootprint(l,1))
            local runs=roof.regionRuns(expanded)
            assert(runs==roof.regionRuns(expanded))
            local covered={}
            for i=1,#runs do
                local run=runs[i]
                for y=run.y,run.y+run.h-1 do for x=run.x,run.x+run.w-1 do
                    assert(expanded.cells[x..':'..y]); covered[x..':'..y]=true
                end end
            end
            for i=1,#expanded.list do local c=expanded.list[i]; assert(covered[c.x..':'..c.y]) end
        """)

    def test_roof_roles_and_installed_sprite_properties(self):
        tiles = _audit_module.DEFAULT_TILES
        errors, count = _audit_module.audit(tiles if tiles.exists() else None)
        self.assertGreater(count, 1000)
        self.assertEqual([], errors)

    def test_steep_gables_resolve_visible_faces_ridges_ceiling_and_eaves(self):
        self.lua.execute("""
            for _,direction in pairs({'W','N','E','S'}) do
                checked({kind='gable',direction=direction,ceiling=true,eaves=true},8,6)
                checked({kind='gable',direction=direction},9,7)
            end
            local p=checked({kind='gable',direction='S',ceiling=true,eaves=true},8,6)
            local deck,eave=0,0
            for i=1,#p do
                if byId[p[i].buildableId].stages[1].roof.role=='flat' then deck=deck+1 end
                if p[i].z==0 then eave=eave+1 end
            end
            assert(deck==48 and eave==8)
            -- Only south- and east-facing tiles exist at 45 degrees.
            for i=1,#p do
                local piece=atlas.roofPiece(spriteOf(p[i]) or '')
                if piece and piece.kind=='slope' then assert(piece.facing=='S' or piece.facing=='E') end
            end
        """)

    def test_hips_use_real_corners_ridges_and_thirty_degree_corners(self):
        self.lua.execute("""
            local p=checked({kind='hip',ceiling=true,eaves=true},8,6)
            local corners=0
            for i=1,#p do
                local piece=atlas.roofPiece(spriteOf(p[i]) or '')
                if piece and piece.kind=='outer' then corners=corners+1 end
            end
            assert(corners>0)
            checked({kind='hip',eaves=true},7,7)
            local p=checked({kind='hip',eaves=true},7,11)
            local ridges=0
            for i=1,#p do if p[i].buildableId:find('_section_r1_1') then ridges=ridges+1 end end
            assert(ridges>0)
            checked({kind='hip',riseLevels=1},9,9)
            p=verify(assert(roof.generate(low,{x=0,y=0,w=8,h=8},{kind='hip'})))
            local kinds={}
            for i=1,#p do
                local piece=atlas.roofPiece(spriteOf(p[i]) or '')
                if piece then kinds[piece.kind..':'..tostring(piece.facing or piece.corner)]=true end
            end
            -- every face of a 30 degree hip is built, including the back ones
            assert(kinds['slope:N'] and kinds['slope:W'] and kinds['outer:NW'] and kinds['outer:SE'])
        """)

    def test_odd_span_ridge_sits_on_the_centre_line_over_the_deck(self):
        self.lua.execute("""
            local pieces=checked({kind='gable',direction='W'},9,7)
            local decks={}; local ridges=0
            for i=1,#pieces do
                local p=pieces[i]
                if byId[p.buildableId].stages[1].roof.role=='flat' then decks[p.x..':'..p.y]=p.z end
            end
            for i=1,#pieces do
                local p=pieces[i]
                if p.buildableId:find('section_r1_1',1,true) then
                    ridges=ridges+1
                    assert(p.x==104 and decks[p.x..':'..p.y]==1)
                end
            end
            assert(ridges==7)
        """)

    def test_gable_walls_follow_the_roof_profile(self):
        self.lua.execute("""
            local matches=0
            for i=1,#gables do
                local g=gables[i]
                if g.pitch==45 and g.fills.N and g.fills.W then
                    for _,direction in pairs({'W','N','E','S'}) do
                        checked({kind='gable',direction=direction,gable=g,ceiling=true},14,14)
                        checked({kind='gable',direction=direction,gable=g},9,9)
                    end
                    matches=matches+1
                end
            end
            assert(matches>0)
            local p,r=roof.generate(steep,{x=0,y=0,w=8,h=8},{kind='shed',gable=gables[1]})
            assert(p==nil and r=='gable_shape')
            -- An 8 x 6 ridge running west-east: the west end wall rises from
            -- both eaves and meets in the middle; every 30 degree gable tile
            -- must rise toward the ridge, never away from it.
            for i=1,#gables do
                local g=gables[i]
                if g.pitch==30 and g.fills.N and g.fills.W then
                    local walls=verify(assert(roof.generate(low,{x=0,y=0,z=0,w=8,h=6},
                        {kind='gable',direction='N',gable=g})))
                    local seen=0
                    for j=1,#walls do
                        local q=walls[j]
                        local piece=atlas.gablePiece(spriteOf(q) or '',30)
                        if piece and piece.wall=='W' and q.x==0 then
                            seen=seen+1
                            if q.y<3 then assert(piece.low=='N' and piece.step==q.y+1)
                            else assert(piece.low=='S' and piece.step==6-q.y) end
                        end
                    end
                    assert(seen==6)
                    break
                end
            end
        """)

    def test_detail_profiles_include_shallow_and_all_mapping_faces_exist(self):
        self.lua.execute("""
            local shallow=false
            for i=1,#profiles do
                local p=profiles[i]
                if p.pitch=='shallow' then shallow=true; assert(#p.details>0) end
                for part,e in pairs(p.pieces) do assert(e.stage.geometry.faces[e.face],part) end
            end
            assert(shallow)
            for i=1,#definitions do
                if definitions[i].category=='Roofing' then
                    for j=1,#definitions[i].stages do assert(definitions[i].stages[j].roof, definitions[i].id) end
                end
            end
            local p,r=roof.generate(steep,{x=0,y=0,w=1,h=6},{kind='gable',direction='W'})
            assert(p==nil and r=='dimensions')
        """)

    def test_connected_l_rooms_use_valleys_at_both_pitches(self):
        self.lua.execute("""
            local rooms={{id='main',x=100,y=200,z=0,w=8,h=4},
                {id='wing',x=100,y=204,z=0,w=4,h=4}}
            local r,regions=roof.findRegion(rooms,'main')
            assert(r and #regions==1 and #r.list==48 and not r.rectangle)
            assert(r.roomIds.main and r.roomIds.wing)
            for _,profile in pairs({steep,low}) do
                local p=verify(assert(roof.generate(profile,r,{kind='crossGable',z=1})))
                local valley=0
                for i=1,#p do
                    local piece=atlas.roofPiece(spriteOf(p[i]) or '')
                    if piece and piece.kind=='valley' then valley=valley+1 end
                end
                assert(valley>0, profile.id)
                verify(assert(roof.generate(profile,r,{kind='hip',z=1,ceiling=true})))
                verify(assert(roof.generate(profile,r,{kind='hipWings',z=1})))
            end
            assert(#roof.generate(steep,r,{kind='flat',z=1})==48)
            -- A west-facing lean-to uses the west-facing tiles, not the
            -- north-facing ones that happen to share a face name.
            local shed=assert(roof.generate(low,r,{kind='shed',direction='W',z=1}))
            assert(#shed==48)
            for i=1,#shed do assert(atlas.roofPiece(spriteOf(shed[i])).facing=='W') end
            local broken,brokenReason=roof.generate(low,r,{kind='shed',direction='S',z=1})
            assert(broken==nil and brokenReason=='unsupported_shape')
            local hidden,hiddenReason=roof.generate(steep,r,{kind='shed',direction='W',z=1})
            assert(hidden==nil and hiddenReason=='missing_face')
            for i=1,#gables do
                if gables[i].pitch==45 and gables[i].fills.N and gables[i].fills.W then
                    local filled=verify(assert(roof.generate(steep,r,{kind='crossGable',z=1,gable=gables[i]})))
                    local walls=0
                    for j=1,#filled do
                        local piece=atlas.gablePiece(spriteOf(filled[j]) or '',45,0)
                        if byId[filled[j].buildableId].stages[1].roof.role=='gable' then walls=walls+1 end
                    end
                    assert(walls>0)
                    verify(assert(roof.generate(steep,r,
                        {kind='crossGable',z=1,gable=gables[i],overhang=1,riseLevels=1,ceiling=true,eaves=true})))
                    break
                end
            end
        """)

    def test_complex_footprint_gets_a_continuous_pitched_roof(self):
        self.lua.execute("""
            local room={id='complex',x=10,y=20,z=0,w=5,h=7,rects={
                {dx=0,dy=0,w=5,h=7},{dx=-4,dy=0,w=5,h=2},
                {dx=-3,dy=1,w=3,h=4},{dx=-5,dy=2,w=6,h=4},
                {dx=-5,dy=-3,w=3,h=6},{dx=-2,dy=4,w=5,h=8},
                {dx=-7,dy=0,w=3,h=9},{dx=-5,dy=4,w=5,h=6}
            }}
            local r=roof.findRegion({room},'complex')
            assert(r and #r.list==131)
            assert(#roof.regionRuns(r)==4)
            for _,profile in pairs({steep,low}) do
                local options,pieces,reason=roof.autoLayout(profile,r,{z=1})
                assert(options and options.kind~='flat',reason)
                verify(pieces)
                local covered={}
                for i=1,#pieces do
                    local q=pieces[i]
                    if byId[q.buildableId].stages[1].roof.role~='gable' and q.z>=1 then covered[q.x..':'..q.y]=true end
                end
                for i=1,#r.list do assert(covered[r.list[i].x..':'..r.list[i].y]) end
            end
        """)

    def test_thin_comb_footprint_prefers_a_flat_roof(self):
        self.lua.execute("""
            local rooms={{id='spine',x=0,y=0,z=0,w=40,h=1}}
            for x=0,38,2 do rooms[#rooms+1]={id='tooth'..x,x=x,y=1,z=0,w=1,h=1} end
            local r=roof.findRegion(rooms,'spine')
            assert(r and #r.list==60 and not r.rectangle)
            local tiles,reason=roof.generate(steep,r,{kind='flat',z=1})
            assert(tiles and #tiles==60,reason)
            local selected,automatic=roof.autoLayout(steep,r,{z=1})
            assert(selected and selected.kind=='flat' and #automatic==60)
        """)

    def test_region_split_by_upper_storey_and_thirty_degree_back_facing_slopes(self):
        self.lua.execute("""
            local rooms={{id='lower',x=0,y=0,z=0,w=8,h=6},
                {id='upper',x=4,y=0,z=1,w=4,h=6}}
            local lower,regions=roof.findRegion(rooms,'lower')
            local upper=roof.findRegion(rooms,'upper')
            assert(#regions==2 and #lower.list==24 and #upper.list==24)
            assert(lower.rectangle and upper.rectangle and lower.maxX==3 and upper.minX==4)
            assert(lower.abut['3:0:E'] and lower.abut['3:5:E'] and lower.ceiling==1)
            local flat,flatReason=roof.generate(steep,lower,{kind='flat',overhang=1,z=1})
            assert(flat,flatReason)
            for i=1,#flat do
                local p=flat[i]
                assert(not (p.x>=4 and p.x<=7 and p.y>=0 and p.y<=5))
            end
            local north=verify(assert(roof.generate(low,lower,{kind='gable',direction='N',z=1})))
            local facing={}
            for i=1,#north do facing[atlas.roofPiece(spriteOf(north[i])).facing or '?']=true end
            assert(facing.N and facing.S)
            local layouts=roof.suggest(low,lower,{})
            assert(layouts[1].kind=='shed' and layouts[1].face=='W' and layouts[1].leans)
        """)

    def test_cross_gable_handles_each_l_orientation_without_invented_parts(self):
        self.lua.execute("""
            for side=0,1 do
                for vertical=0,1 do
                    local wingX=side==0 and 0 or 4
                    local wingY=vertical==0 and 0 or -4
                    local rooms={{id='body',x=0,y=0,z=0,w=8,h=4},
                        {id='wing',x=wingX,y=wingY,z=0,w=4,h=8}}
                    local r=roof.findRegion(rooms,'body')
                    assert(r and #r.list==48)
                    for _,profile in pairs({steep,low}) do
                        verify(assert(roof.generate(profile,r,{kind='crossGable',z=1})))
                    end
                end
            end
        """)

    def test_auto_fit_covers_irregular_footprints_across_complete_roof_families(self):
        self.lua.execute("""
            local footprints={
                {{id='a',x=0,y=0,z=0,w=7,h=5}},
                {{id='a',x=0,y=0,z=0,w=8,h=4},{id='b',x=0,y=4,z=0,w=4,h=4}},
                {{id='a',x=0,y=0,z=0,w=8,h=4},{id='b',x=4,y=4,z=0,w=4,h=4}},
                {{id='a',x=0,y=4,z=0,w=12,h=4},{id='b',x=4,y=0,z=0,w=4,h=4}},
                {{id='a',x=0,y=0,z=0,w=4,h=8},{id='b',x=8,y=0,z=0,w=4,h=8},
                    {id='c',x=0,y=4,z=0,w=12,h=4}},
                {{id='a',x=0,y=3,z=0,w=11,h=4},{id='b',x=3,y=0,z=0,w=5,h=10},
                    {id='c',x=8,y=7,z=0,w=3,h=4}},
            }
            local checked=0
            for profileIndex=1,#profiles do
                local profile=profiles[profileIndex]
                -- Shallow sets only reach two rows; large footprints get a flat roof.
                if profile.flat and profile.complete and not profile.maxStep then
                    for shapeIndex=1,#footprints do
                        local r=roof.findRegion(footprints[shapeIndex],'a')
                        assert(r)
                        local options,pieces,reason=roof.autoLayout(profile,r,{z=1})
                        assert(options and pieces and not reason,profile.id..':'..tostring(reason))
                        assert(options.kind~='flat',profile.id..' shape '..shapeIndex)
                        verify(pieces)
                        local covered={}
                        for pieceIndex=1,#pieces do
                            local piece=pieces[pieceIndex]
                            local definition=byId[piece.buildableId]
                            if definition.stages[1].roof.role~='gable' then covered[piece.x..':'..piece.y]=true end
                        end
                        for cellIndex=1,#r.list do
                            local cell=r.list[cellIndex]
                            assert(covered[cell.x..':'..cell.y],profile.id..' missing '..cell.x..':'..cell.y)
                        end
                        checked=checked+1
                    end
                end
            end
            assert(checked>=60)
        """)

    def test_compound_layouts_follow_t_and_u_footprints(self):
        self.lua.execute("""
            local footprints={
                {{id='a',x=0,y=4,z=0,w=12,h=4},{id='b',x=4,y=0,z=0,w=4,h=4}},
                {{id='a',x=0,y=0,z=0,w=4,h=8},{id='b',x=8,y=0,z=0,w=4,h=8},
                    {id='c',x=0,y=4,z=0,w=12,h=4}},
            }
            for index=1,#footprints do
                local r=roof.findRegion(footprints[index],'a')
                assert(r and not r.rectangle)
                for _,kind in pairs({'crossGable','hipWings','hip'}) do
                    local pieces=verify(assert(roof.generate(steep,r,{kind=kind,z=1,ceiling=true,riseLevels=2})))
                    local deck={}
                    for item=1,#pieces do
                        local p=pieces[item]
                        if byId[p.buildableId].stages[1].roof.role=='flat' and p.z==1 then deck[p.x..':'..p.y]=true end
                    end
                    local count=0; for _ in pairs(deck) do count=count+1 end
                    assert(count==#r.list,'ceiling must cover every room tile')
                end
            end
        """)


class SeamTests(unittest.TestCase):
    @unittest.skipUnless(_preview.DEFAULT_SEAMS.exists(), "needs the game's media/seams.txt")
    def test_exact_roof_pieces_join_as_the_game_expects(self):
        seams = _preview.load_seams(_preview.DEFAULT_SEAMS)
        lua = _preview.runtime()
        checked = 0
        for profile in ("brown_shingles:45", "brown_shingles:30", "black:45", "black:30"):
            for shape in ("rect", "odd", "square", "L", "T", "U", "plus", "court"):
                cells = sorted(set(_preview.SHAPES[shape]))
                found, reason = _preview.layouts(lua, profile, cells, None, {"z": 1})
                self.assertTrue(found, reason)
                for layout in found:
                    info = layout.info
                    def exact(position):
                        cell = info[f"{position[0]}:{position[1]}"]
                        return cell is not None and not cell.approx and cell.kind not in ("ridge", "peak")
                    ok, bad = _preview.check_seams(_preview.pieces(lua, layout.placements), seams)
                    bad = [b for b in bad if exact(b[0]) and exact((b[0][0] + (1 if "ast" in b[2] else 0),
                                                                        b[0][1] + (1 if "outh" in b[2] else 0)))]
                    self.assertEqual([], bad, f"{profile} {shape} {layout.kind}")
                    checked += ok
        self.assertGreater(checked, 1000)


class WorldRenderingTests(unittest.TestCase):
    def test_plan_cursor_uses_controller_square_and_preserves_mouse_input(self):
        lua = runtime()
        lua.execute("""
            Events={OnGameStart={Add=function() end}}
            local drag={xJoypad=41,yJoypad=62}
            function getCell() return {getDrag=function(_,index) return drag end} end
            function getSpecificPlayer() return {getZ=function() return 0 end} end
            function getMouseX() return 100 end
            function getMouseY() return 200 end
            function screenToIsoX() return 10.8 end
            function screenToIsoY() return 20.2 end
            mouseRecent=false
            function wasMouseActiveMoreRecentlyThanJoypad() return mouseRecent end
            JoypadState={players={{player=0}}}
        """)
        module(lua, "client/KnoxBuildworks/Planning/PlanCursor.lua", "cursor")
        lua.execute("""
            local x,y=cursor.pickTileAt(0,2)
            assert(x==41 and y==62)
            mouseRecent=true
            x,y=cursor.pickTileAt(0,2)
            assert(x==10 and y==20)
            mouseRecent=false; JoypadState.players={}
            x,y=cursor.pickTileAt(0,2)
            assert(x==10 and y==20)
        """)

    def test_plan_cursor_uses_engine_square_unless_vanilla_pins_a_drag(self):
        lua = runtime()
        lua.execute("""
            Events={OnGameStart={Add=function(f) definePlanClass=f end}}
            KBWBuildingObject={derive=function() return {} end}
            modules['KnoxBuildworks/Geometry/Matrix']={getFaceCells=function() return nil end}
            function getSpecificPlayer() return {getZ=function() return 0 end} end
            function screenToIsoX() return 10.8 end
            function screenToIsoY() return 20.2 end
            function getMouseX() return 100 end
            function getMouseY() return 200 end
        """)
        module(lua, "client/KnoxBuildworks/Planning/PlanCursor.lua", "cursor")
        lua.execute("""
            definePlanClass()
            local plan={player=0,nSprite=1,definition={placement={kind='object'}},stage={},
                getPlanZ=function() return 2 end,
                snapDirectionToPrevious=function() end,
                snapDirectionToFinishTarget=function() end}
            KBWPlanCursor.updatePlanPosition(plan,14,27,0)
            assert(plan.planX==14 and plan.planY==27)
            plan.definition.placement.kind='wall'; plan.isLeftDown=true
            KBWPlanCursor.updatePlanPosition(plan,14,27,0)
            assert(plan.planX==10 and plan.planY==20)
            assert(plan.lineAnchorX==10 and plan.lineAnchorY==20)
            plan.isLeftDown=false; plan.build=true
            KBWPlanCursor.updatePlanPosition(plan,14,27,0)
            assert(plan.planX==10 and plan.planY==20)
            local drag={xJoypad=41,yJoypad=62}
            function getCell() return {getDrag=function() return drag end} end
            JoypadState={players={{}}}
            KBWPlanCursor.updatePlanPosition(plan,14,27,0)
            assert(plan.planX==41 and plan.planY==62)
        """)

    def test_post_render_uses_current_player_without_indexing_java_frame_state(self):
        lua = runtime()
        lua.execute("""
            IsoCamera={frameState=17} -- Kahlua cannot index the Java FrameState object.
            local players={
                {getPlayerNum=function() return 0 end,getZ=function() return 0 end},
                {getPlayerNum=function() return 1 end,getZ=function() return 1 end}}
            currentPlayer=players[1]
            currentPlayer.plan={level=2,placements={}}
            function getPlayer() return currentPlayer end
            function getSpecificPlayer() error('post-render must use the current player') end
            Events={OnPostRender={Add=function(f) postRender=f end}}
            drawn={}; flushed={}; preferences={}
            modules['KnoxBuildworks/Planning/Blueprints']={active=function(p) return p.plan end}
            modules['KnoxBuildworks/Planning/GhostRenderer']={
                applyPreferences=function(p) preferences[#preferences+1]=p:getPlayerNum() end,
                renderBlueprint=function(plan,level,placement,room,index)
                    assert(level==2 and plan==players[1].plan)
                    drawn[#drawn+1]=index end,
                flushWorldAreaHighlights=function(index) flushed[#flushed+1]=index end}
        """)
        module(lua, "client/KnoxBuildworks/Planning/Planner.lua", "planner")
        lua.execute("""
            postRender()
            currentPlayer={getPlayerNum=function() return 1 end,getZ=function() return 1 end}
            postRender()
            assert(#drawn==1 and drawn[1]==0)
            assert(#preferences==2 and preferences[1]==0 and preferences[2]==1)
            assert(#flushed==2 and flushed[1]==0 and flushed[2]==1)
        """)

    def test_area_tiles_draw_every_post_render_and_stay_with_their_player(self):
        lua = runtime()
        lua.execute("""
            unpack=table.unpack
            function getPlayerScreenLeft() return 0 end
            function getPlayerScreenTop() return 0 end
            function getPlayerScreenWidth() return 100 end
            function getPlayerScreenHeight() return 100 end
            function screenToIsoX(p,x) return x end
            function screenToIsoY(p,x,y) return y end
            function getSpecificPlayer() return {getX=function() return 20 end,getY=function() return 20 end} end
            modules['KnoxBuildworks/Definitions/Registry']={get=function()
                return {placement={kind='object'},category='Roofing'} end}
            draws={}
            function renderIsoLine(x1,y1,z1,x2,y2,z2,thickness,r,g,b,a)
                draws[#draws+1]={kind='line',x=x1,y=y1,tx=x2,ty=y2,z=z1,a=a} end
        """)
        module(lua, "client/KnoxBuildworks/Planning/GhostRenderer.lua", "ghost")
        lua.execute("""
            ghost.setOpacity(.35)
            ghost.getFloorCursorSprite=function() return {RenderGhostTileColor=function(s,x,y,z,r,g,b,a)
                draws[#draws+1]={x=x,y=y,z=z,a=a} end} end
            local room={x=20,y=20,z=1,w=4,h=4,color={r=.2,g=.6,b=1,a=.26}}
            ghost.renderRoom(room,1,1,nil,0)
            ghost.renderTileHighlight(30,30,1,nil,nil,1)
            ghost.flushWorldAreaHighlights(0)
            assert(#draws==4 and draws[1].kind=='line' and draws[1].a==.26)
            draws={}; ghost.flushWorldAreaHighlights(1)
            assert(#draws==1 and draws[1].x==30)
            draws={}; ghost.renderRoom(room,1,1,nil,0); ghost.flushWorldAreaHighlights(0)
            assert(#draws==4 and draws[1].a==.26)
            draws={}
            ghost.placementCells=function() return {{x=20,y=20,z=1,sprite='roof'}} end
            ghost.getSprite=function() return {RenderGhostTileColor=function()
                draws[#draws+1]={kind='roof'} end} end
            ghost.renderBlueprint({rooms={room},placements={{buildableId='roof'}}},1,nil,nil,0)
            assert(#draws==5 and draws[1].kind=='line' and draws[5].kind=='roof')
            draws={}; room.z=2
            ghost.renderBlueprint({rooms={room},placements={{buildableId='roof'}}},1,nil,nil,0)
            assert(#draws==5 and draws[1].kind=='roof' and draws[5].kind=='line')
            draws={}; ghost.renderRect(0,0,99,99,1,{r=.2,g=.6,b=1,a=.2},0)
            ghost.flushWorldAreaHighlights(0)
            assert(#draws==396)
        """)

    def test_expanded_cells_sort_by_z_then_diagonal_and_cache_multiple_plans(self):
        lua = runtime()
        lua.execute("""
            unpack=table.unpack
            modules['KnoxBuildworks/Definitions/Registry']={get=function(s,id)
                return {placement={kind=id},category=id=='roof' and 'Roofing' or 'Other'} end}
            function getPlayerScreenLeft() return 0 end
            function getPlayerScreenTop() return 0 end
            function getPlayerScreenWidth() return 100 end
            function getPlayerScreenHeight() return 100 end
            function screenToIsoX(p,x,y,z) return 10000+x end
            function screenToIsoY(p,x,y,z) return 20000+y end
            function getSpecificPlayer() return nil end
            function getPlayer() return nil end
        """)
        module(lua, "client/KnoxBuildworks/Planning/GhostRenderer.lua", "ghost")
        lua.execute("""
            local expansions=0; local calls={}
            ghost.placementCells=function(p) expansions=expansions+1; return p.cells end
            ghost.getSprite=function(name) return {RenderGhostTileColor=function() calls[#calls+1]=name end} end
            local function c(x,y,z,name) return {x=10000+x,y=20000+y,z=z,sprite=name} end
            local plan={updated=1,placements={
                {buildableId='object',cells={c(0,0,2,'upper'),c(0,5,0,'near')}},
                {buildableId='floor',cells={c(90,90,0,'floor')}},
                {buildableId='wall',cells={c(0,5,0,'wall')}},
                {buildableId='object',cells={c(3,0,0,'far')}}}}
            ghost.view.levels='all'; ghost.renderBlueprint(plan,nil,nil,nil,0)
            assert(table.concat(calls,',')=='floor,far,wall,near,upper',table.concat(calls,','))
            local preview={updated=1,placements={}}
            ghost.renderBlueprint(preview,nil,nil,nil,0)
            calls={}; ghost.renderBlueprint(plan,nil,nil,nil,0); assert(expansions==4)
            calls={}; ghost.renderBlueprintOffset(plan,1,1,0)
            assert(table.concat(calls,',')=='floor,far,wall,near,upper')
            plan.updated=2; plan.placements[4].cells={c(3,0,1,'moved')}
            calls={}; ghost.renderBlueprint(plan,nil,nil,nil,0); assert(expansions==8)
            assert(table.concat(calls,',')=='floor,wall,near,moved,upper')
            calls={}; ghost.view.walls=false; ghost.view.levels='current'
            ghost.renderBlueprint(plan,0,nil,nil,0); assert(table.concat(calls,',')=='floor,near')
        """)

    def setUp(self):
        self.lua = runtime()
        self.lua.execute("""
            Events={OnTick={Add=function() end},OnGameStart={Add=function() end},LoadGridsquare={Add=function() end}}
            IsoFlagType={exterior='exterior'}
            function isServer() return false end
            function isClient() return false end
            ArrayList={new=function() return {items={},clear=function(s) s.items={} end,
                size=function(s) return #s.items end,get=function(s,i) return s.items[i+1] end} end}
            nativeBuilding={}; liveRoom={getBuilding=function() return nativeBuilding end}
            roomDef={getID=function() return 123 end,getIsoRoom=function() return liveRoom end}
            roomPresent=true; exterior=true; dirty=0; reads=0; repairs={}
            -- A Java square: methods only. Writing a field throws, as Kahlua does.
            state={}
            square=setmetatable({},{__newindex=function(t,k) error('attempted index of non-table: '..tostring(k)) end,
                __index={getX=function() return 2 end,getY=function() return 2 end,getZ=function() return 0 end,
                getRoom=function(s) return state.room end,getRoomID=function(s) return state.roomID or -1 end,
                setRoomID=function(s,id) state.roomID=id end,setRoom=function(s,r) state.room=r end,
                getProperties=function() return {has=function(s,flag) assert(flag=='exterior'); return exterior end,
                    set=function(s,flag) assert(flag=='exterior'); exterior=true end,
                    unset=function(s,flag) assert(flag=='exterior'); exterior=false end} end,
                invalidateRenderChunkLevel=function(s,flags) assert(flags==2112); dirty=dirty+1 end}})
            definition={isUserDefined=function() return true end,getX=function() return 2 end,
                getY=function() return 2 end,getX2=function() return 5 end,getY2=function() return 5 end,
                getMinLevel=function() return 0 end,getMaxLevel=function() return 0 end,
                getRooms=function() return {size=function() return 1 end} end}
            visible=true; playerQueries={}; chunk={}
            grid={getRoomAt=function() return roomPresent and roomDef or nil end,
                getEmptyOutsideAt=function() return roomPresent and roomDef or nil end,
                getBuildingsIntersecting=function(s,x,y,w,h,out)
                    playerQueries[#playerQueries+1]=x; if visible then out.items={definition} end end}
            cell={getChunk=function(s,x,y) if x==0 and y==0 then return chunk end end,
                getGridSquare=function(s,x,y,z) reads=reads+1; return square end}
            function getCell() return cell end
            function getWorld() return {getMetaGrid=function() return grid end} end
            function getNumActivePlayers() return 2 end
            function getSpecificPlayer(i) return {getX=function() return i*8 end,getY=function() return i*8 end} end
        """)
        module(self.lua, "client/KnoxBuildworks/World/BuildingRender.lua", "render")

    def test_native_room_objects_and_cutaways_are_repaired_and_cleared(self):
        self.lua.execute("""
            render.repairSquare(square,grid)
            assert(state.room==liveRoom and state.roomID==123 and not exterior)
            state.roomID=999 -- Already-correct room object: preserve the engine's ID.
            render.repairSquare(square,grid); assert(state.roomID==999)
            roomPresent=false; render.repairSquare(square,grid)
            assert(state.room==nil and state.roomID==-1 and exterior)
        """)

    def test_repair_budget_split_screen_cache_reload_and_demolition(self):
        self.lua.execute("""
            render.scan(); assert(#playerQueries==2 and playerQueries[1]~=playerQueries[2])
            render.step(11); assert(reads==11 and dirty==1)
            render.scan(); render.step(1000); assert(reads==320 and dirty==1)
            render.scan(); render.step(1000); assert(reads==320)
            chunk={}; render.scan(); render.step(1000); assert(reads==640)
            visible=false; roomPresent=false; render.scan(); render.step(1000); assert(reads==960 and dirty==2)
            assert(state.room==nil)
            render.scan(); render.step(1000); assert(reads==960)
            render.reset(); visible=true; render.scan(); chunk={}; render.step(1000); assert(reads==960)
        """)


class QuickbarKeyTests(unittest.TestCase):
    def test_number_keys_respect_text_entry_and_roof_window(self):
        lua=runtime()
        lua.execute("""
            ISPanel={derive=function() return {} end}; Keyboard={KEY_1=2,KEY_9=10,KEY_ESCAPE=1}
            typing=false
            function getCore() return {isDoingTextEntry=function() return typing end} end
        """)
        module(lua,"client/KnoxBuildworks/UI/PlanQuickbar.lua","barClass")
        lua.execute("""
            local b=setmetatable({owner={}},{__index=barClass})
            assert(b:keySlot(2)==1 and b:keySlot(10)==9 and b:keySlot(1)==nil)
            typing=true; assert(b:keySlot(2)==nil); typing=false
            b.owner.roofWindow={isVisible=function() return true end}; assert(b:keySlot(2)==nil)
        """)


if __name__ == '__main__':
    unittest.main()
