import json
import re
import unittest
from pathlib import Path

from test_catalog_workspace import LUA, ROOT, runtime
from test_supply_allocation import requirements_runtime, supply_scan_stub


def module(lua, relative, name):
    if relative.endswith(("RoofPlanner.lua", "GhostRenderer.lua", "PlanningMode.lua")):
        lua.globals().modules["KnoxBuildworks/Planning/RoomShape"] = lua.execute(
            (LUA / "shared/KnoxBuildworks/Planning/RoomShape.lua").read_text(encoding="utf-8")
        )
    if relative.endswith("RoofPlanner.lua"):
        lua.globals().modules["KnoxBuildworks/Planning/RoofAtlas"] = lua.execute(
            (LUA / "shared/KnoxBuildworks/Planning/RoofAtlas.lua").read_text(encoding="utf-8")
        )
    if relative.endswith("RoofHelper.lua"):
        lua.globals().modules["KnoxBuildworks/UI/RoofModelView"] = lua.execute(
            (LUA / "client/KnoxBuildworks/UI/RoofModelView.lua").read_text(encoding="utf-8")
        )
    value = lua.execute((LUA / relative).read_text(encoding="utf-8"))
    lua.globals()[name] = value
    return value


class SupplyContainerTests(unittest.TestCase):
    def test_site_materials_outside_gather_area_are_counted_once_across_builds(self):
        lua = requirements_runtime()
        lua.execute("""
            local plank=makeItem('Base.Plank'); plank.world={}
            local target={}
            buildUtil.getMaterialOnGround=function(s) return s==target and {['Base.Plank']={plank}} or {} end
            function getCell() return {getGridSquare=function() return target end} end
            function getItemNameFromFullType(t) return t end
            modules['KnoxBuildworks/Planning/BuildQueue']={supplyOrder=function(p) return p end,
                inspectSupplies=function() return {},false end}
            modules['KnoxBuildworks/UI/IconResolver']={displayNameForTag=function(t) return t end}
            modules['KnoxBuildworks/Validation/WallFinishes']={fetchRows=function() return {} end}
            modules['KnoxBuildworks/Planning/Blueprints']={resolvePlacement=function(p) return {},p.stage end}
            modules['KnoxBuildworks/Validation/Requirements']=requirements
            local stage={requirements={inputs={{id='wood',items={'Base.Plank'},amount=1}}}}
            blueprint={updated=1,placements={{id='a',x=10,y=10,z=0,stage=stage},{id='b',x=11,y=10,z=0,stage=stage}}}
        """)
        supply_scan_stub(lua)
        module(lua, "client/KnoxBuildworks/Planning/Supplies.lua", "supplies")
        lua.execute("""
            local state=supplies.new(player,blueprint)
            supplies.step(state); supplies.step(state)
            assert(state.phase=='done' and state.singleReady.a and state.singleReady.b)
            assert(not state.allReady)
            for _,row in pairs(state.materials) do assert(row.amount==2 and row.available==1) end
        """)

    def test_floor_batch_reserves_main_inventory_and_skips_oversized_items(self):
        lua = runtime()
        module(lua, "client/KnoxBuildworks/Planning/SupplyContainers.lua", "containers")
        lua.execute("""
            local main={getCapacityWeight=function() return 8 end,getEffectiveCapacity=function() return 10 end,
                hasRoomFor=function() return true end}
            local player={getInventory=function() return main end,
                getClothingItem_Back=function() error('floor pickup must reserve main inventory') end}
            local function item(weight) return {getUnequippedWeight=function() return weight end,
                getContainer=function() return nil end} end
            local huge,a,b,c=item(20),item(1),item(1),item(1)
            local plan=containers.carryPlan(player,{huge,a,a,b,c},true)
            assert(#plan==2 and plan[1].item==a and plan[2].item==b)
            assert(plan[1].destination==main and plan[2].destination==main)
        """)

    def test_remote_floor_pickup_without_loot_container_uses_native_world_action(self):
        lua = runtime()
        source = (LUA / "client/KnoxBuildworks/Planning/BuildQueue.lua").read_text(encoding="utf-8")
        start = source.index("local function queueWorldItemTransfer")
        end = source.index("local function canTryContainer", start)
        lua.execute(source[start:end] + "\nqueuePickup=queueWorldItemTransfer")
        lua.execute("""
            function isClient() return true end
            local queued={}
            ISTimedActionQueue={add=function(action) queued[#queued+1]=action end}
            ISWorldObjectContextMenu={grabItemTime=function() return 10 end}
            ISInventoryTransferUtil={newInventoryTransferAction=function(p,item,source,dest)
                assert(source); return {kind='container',dest=dest} end}
            ISGrabItemAction={new=function(s,p,world,time) return {kind='world',world=world} end}
            local source=nil
            local world={getItem=function() return {getContainer=function() return source end} end}
            queuePickup({player={}},world,{})
            assert(queued[1].kind=='world' and queued[1].world==world)
            source={}; queuePickup({player={}},world,{})
            assert(queued[2].kind=='container')
        """)

    def test_fetch_reserves_backpack_and_main_capacity_and_skips_carried_items(self):
        lua = runtime()
        module(lua, "client/KnoxBuildworks/Planning/SupplyContainers.lua", "containers")
        lua.execute("""
            function instanceof(item,kind) return item.bag==true and kind=='InventoryContainer' end
            local main={getCapacityWeight=function() return 7 end,getEffectiveCapacity=function() return 10 end,
                hasRoomFor=function() return true end}
            local bag={getCapacityWeight=function() return 0 end,getEffectiveCapacity=function() return 3 end,
                hasRoomFor=function() return true end,isInside=function() return false end}
            local worn={bag=true,getInventory=function() return bag end,getWeightReduction=function() return 50 end}
            local player={getInventory=function() return main end,getClothingItem_Back=function() return worn end}
            local outside={isRemoveItemAllowed=function() return true end,isInCharacterInventory=function() return false end}
            local function item(weight,source) return {getUnequippedWeight=function() return weight end,
                getContainer=function() return source or outside end} end
            local a,b,c=item(2),item(2),item(2)
            local carried=item(1,{isInCharacterInventory=function() return true end})
            local plan=containers.carryPlan(player,{a,a,b,c,carried})
            assert(#plan==2 and plan[1].item==a and plan[1].destination==bag)
            assert(plan[2].item==b and plan[2].destination==main)
            main.getCapacityWeight=function() return 10 end
            assert(#containers.carryPlan(player,{a})==0)
        """)

    def test_native_server_lists_deeply_nested_bags_once(self):
        lua = runtime()
        source = (LUA / "server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua").read_text()
        start = source.index("local function addCarriedContainers")
        end = source.index("-- ISInventoryPaneContextMenu", start)
        lua.execute(source[start:end] + "\ncollect=addCarriedContainers")
        lua.execute("""
            local depth=0
            local function bag(level)
                local inner=level<8 and bag(level+1) or nil
                return {getItemsFromCategory=function() return {
                    size=function() return inner and 1 or 0 end,
                    get=function() return {getInventory=function() return inner end} end} end}
            end
            local root=bag(1); local out={add=function() depth=depth+1 end}; local seen={}
            collect(root,out,seen); collect(root,out,seen)
            assert(depth==8)
        """)

    def test_nested_and_dropped_bags_are_discovered_once_and_walk_to_root(self):
        lua = runtime()
        module(lua, "client/KnoxBuildworks/Planning/SupplyContainers.lua", "containers")
        lua.execute("""
            function instanceof(item, kind) return item.bag and kind=='InventoryContainer' end
            function inventory(items)
                return {getItems=function() return {size=function() return #items end,
                    get=function(s,i) return items[i+1] end} end}
            end
            local item={}; local inner=inventory({item}); local bag={bag=true,getInventory=function() return inner end}
            local outer=inventory({bag}); local nested={bag=true,getInventory=function() return outer end}
            local crate=inventory({nested}); local result,seen={},{}
            containers.add(result,seen,crate); containers.add(result,seen,inner)
            containers.addBag(result,seen,nested)
            assert(#result==3 and result[1]==crate and result[3]==inner)
            inner.getOutermostContainer=function() return crate end
            local walked
            luautils={walkToContainer=function(c,p) walked=c; return true end,
                walkAdj=function(p,s) walked=s; return true end}
            local player={getPlayerNum=function() return 0 end}
            assert(containers.walk(player,inner) and walked==crate)
            local square={}; local world={getSquare=function() return square end}
            crate.getContainingItem=function() return {getWorldItem=function() return world end} end
            assert(containers.walk(player,inner) and walked==square)
        """)

    def test_queue_inspection_includes_bag_contents_on_ground_and_in_storage(self):
        lua = requirements_runtime()
        containers = module(lua, "client/KnoxBuildworks/Planning/SupplyContainers.lua", "containers")
        lua.globals().modules["KnoxBuildworks/Planning/SupplyContainers"] = containers
        module(lua, "client/KnoxBuildworks/Planning/BuildQueue.lua", "queue")
        lua.execute("""
            function instanceof(item,kind) return item.bag==true and kind=='InventoryContainer' end
            local plank=makeItem('Base.Plank'); local nails=makeItem('Base.Nails')
            local inner={getItems=function() return javaList({plank}) end}
            local bag={bag=true,getInventory=function() return inner end,getWorldItem=function() return nil end}
            local crate={getItems=function() return javaList({bag}) end}
            local dropped={bag=true,getInventory=function() return {getItems=function() return javaList({nails}) end} end}
            local world={getItem=function() return dropped end,getSquare=function() return square end}
            dropped.getWorldItem=function() return world end
            ground={Bag={dropped}}
            local lockedItem=makeItem('Base.Screws')
            local locked={getItems=function() return javaList({lockedItem}) end,
                isRemoveItemAllowed=function() return false end}
            ISInventoryPaneContextMenu={getContainers=function() return javaList({crate,inner,locked}) end}
            local items,incomplete=queue.inspectSupplies(player,nil)
            local count=0
            for i=1,#items do
                assert(items[i]~=lockedItem, 'locked container stock must not appear available')
                if items[i]==plank or items[i]==nails then count=count+1 end
            end
            assert(count==2 and not incomplete)
        """)


class RoofTests(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()
        module(self.lua, "shared/KnoxBuildworks/Planning/RoofPlanner.lua", "roof")
        # A custom tile pack the atlas does not know: authored faceByEdge
        # metadata ("low edge -> face") is the fallback.
        self.lua.execute("""
            defs={{id='flat',stages={{id='built',sprites={W='flat'},roof={family='sample',pitch=0,role='flat'}}}}}
            for i=1,6 do defs[#defs+1]={id='slope'..i,stages={{id='built',sprites={W='w',N='n',E='e',S='s'},
                roof={family='sample',pitch=30,role='slope',step=i,stepsPerLevel=6,
                    faceByEdge={W='N',N='W',E='S',S='E'}}}}} end
            profile=roof.profiles(defs)[1]
            assert(profile.id=='sample:30' and profile.stepsPerLevel==6 and profile.flat)
        """)

    def test_flat_overhang_and_explicit_target_level(self):
        self.lua.execute("""
            local p,reason=roof.generate(profile,{x=10,y=20,z=1,w=2,h=3},{kind='flat',overhang=1,z=5})
            assert(not reason and #p==20 and p[1].x==9 and p[1].y==19)
            assert(p[20].x==12 and p[20].y==23 and p[20].z==5)
        """)

    def test_height_cap_uses_flat_tiles_and_odd_span_needs_a_ridge(self):
        self.lua.execute("""
            local p,r=roof.generate(profile,{x=0,y=0,z=0,w=15,h=1},
                {kind='gable',direction='W',riseLevels=1})
            assert(not r and #p==15, r)
            for i=1,6 do assert(p[i].buildableId=='slope'..i and p[i].z==1) end
            for i=7,9 do assert(p[i].buildableId=='flat' and p[i].z==2 and p[i].direction==1) end
            assert(p[10].buildableId=='slope6' and p[15].buildableId=='slope1')
            profile.flat=nil
            p,r=roof.generate(profile,{x=0,y=0,w=15,h=1},{kind='gable',riseLevels=1})
            assert(p==nil and r=='missing_flat')
            p,r=roof.generate(profile,{x=0,y=0,w=15,h=1},{kind='gable',riseLevels=2})
            assert(p==nil and r=='odd_gable', r)
        """)

    def test_profiles_filter_each_stage_including_shared_flat_tiles(self):
        self.lua.execute("""
            local defs={{id='family',stages={
                {id='lockedFlat',roof={family='wood',pitch=0,role='flat'}},
                {id='slope1',sprites={W='a'},roof={family='wood',pitch=30,role='slope',step=1,stepsPerLevel=6,faceByEdge={S='W'}}},
                {id='lockedSlope',sprites={W='b'},roof={family='wood',pitch=30,role='slope',step=2,stepsPerLevel=6,faceByEdge={S='W'}}}}}}
            local profiles=roof.profiles(defs,function(d,s) return s.id=='slope1' end)
            assert(#profiles==1 and profiles[1].pieces['slope:S:1'].stageId=='slope1')
            assert(profiles[1].pieces['slope:S:2']==nil and profiles[1].flat==nil)
        """)

    def test_shed_pitch_changes_z_after_six_tiles_and_resolves_authored_face(self):
        self.lua.execute("""
            local p=roof.generate(profile,{x=0,y=0,z=0,w=8,h=2},{kind='shed',direction='W'})
            assert(#p==16 and p[1].z==1 and p[6].buildableId=='slope6')
            assert(p[7].z==2 and p[7].buildableId=='slope1' and p[1].direction==2)
        """)

    def test_gable_symmetry_and_unsupported_combinations(self):
        self.lua.execute("""
            local p=roof.generate(profile,{x=0,y=0,z=0,w=8,h=2},{kind='gable',direction='W'})
            assert(#p==16 and p[1].direction==2 and p[8].direction==4)
            assert(p[4].buildableId=='slope4' and p[5].buildableId=='slope4')
            local none,reason=roof.generate(profile,{x=0,y=0,w=7,h=2},{kind='gable'})
            assert(none==nil and reason=='odd_gable')
            for i=1,#defs do if defs[i].id=='slope1' then defs[i].stages[1].roof.faceByEdge.E=nil end end
            profile=roof.profiles(defs)[1]
            none,reason=roof.generate(profile,{x=0,y=0,w=8,h=2},{kind='gable',direction='W'})
            assert(none==nil and reason=='missing_face', reason)
        """)

    def test_limits_and_invalid_numbers_fail_without_partial_output(self):
        self.lua.execute("""
            local p,r=roof.generate(profile,{x=0,y=0,w=25,h=25},{kind='flat'})
            assert(p==nil and r=='too_large')
            p,r=roof.generate(profile,{x=0,y=0,w=8,h=2},{kind='shed',direction='W',z=31})
            assert(p==nil and r=='height_limit')
            p,r=roof.generate(profile,{x=0/0,y=0,w=8,h=2},{})
            assert(p==nil and r=='dimensions')
        """)

    def test_unused_flat_and_hidden_shed_eaves_options_are_rejected(self):
        self.lua.execute("""
            local rect={x=0,y=0,w=4,h=4}
            local p,r=roof.generate(profile,rect,{kind='flat',eaves=true})
            assert(p==nil and r=='eaves_shape')
            p,r=roof.generate(profile,rect,{kind='flat',riseLevels=1})
            assert(p==nil and r=='rise_shape')
            p,r=roof.generate(profile,rect,{kind='shed',direction='W',eaves=true})
            assert(p==nil and r=='missing_eaves')
        """)

    def test_detail_only_profiles_are_explained_instead_of_failing_as_a_slope(self):
        self.lua.execute("""
            local p,r=roof.generate({details={{}}},{x=0,y=0,w=4,h=4},{kind='gable'})
            assert(p==nil and r=='manual_only')
        """)

    def test_suggestions_are_incremental_ranked_and_deduplicated(self):
        self.lua.execute("""
            -- prepare only validates; planning and every layout run in slices.
            local ctx=roof.prepare(profile,{x=0,y=0,z=0,w=8,h=4},{z=1})
            assert(ctx and #ctx.specs==0 and ctx.phase=='plan')
            local steps=0
            repeat steps=steps+1; assert(steps<500) until roof.step(ctx,8)
            assert(#ctx.specs>3 and steps>#ctx.specs)
            local layouts=roof.results(ctx)
            assert(#layouts>=4 and layouts[1].kind=='gable' and layouts[1].alongX)
            for i=2,#layouts do assert(layouts[i-1].score>=layouts[i].score) end
            local seen={}
            for i=1,#layouts do
                local keys={}
                for j=1,#layouts[i].placements do local q=layouts[i].placements[j]
                    keys[#keys+1]=q.buildableId..q.direction..q.x..q.y..q.z end
                table.sort(keys); local key=table.concat(keys,';')
                assert(not seen[key],'duplicate layout'); seen[key]=true
            end
            -- A rejected layout stays listed but sinks below every valid one.
            local blocked=roof.suggest(profile,{x=0,y=0,z=0,w=8,h=4},{z=1},function(p)
                return #p>32 and 'plan_overlap' or nil end)
            local sawBlocked=false
            for i=1,#blocked do
                if blocked[i].reason then sawBlocked=true else assert(not sawBlocked) end
            end
            -- A per-piece checker stops at the first conflicting piece.
            local checked=0
            local each=roof.suggest(profile,{x=0,y=0,z=0,w=8,h=4},{z=1},{each=function(p)
                checked=checked+1
                if p.x==3 and p.y==0 then return 'plan_overlap' end
            end})
            assert(#each==#layouts and checked>0)
            for i=1,#each do
                local hits=false
                for j=1,#each[i].placements do local p=each[i].placements[j]
                    if p.x==3 and p.y==0 then hits=true end end
                assert((each[i].reason=='plan_overlap')==hits)
            end
        """)

    def test_lean_to_against_an_upper_storey_is_named_and_capped(self):
        self.lua.execute("""
            local rooms={{id='ground',x=0,y=0,z=0,w=10,h=8},{id='upper',x=0,y=0,z=1,w=10,h=4}}
            local region=roof.findRegion(rooms,'ground')
            assert(region and #region.list==40 and region.ceiling==1)
            local layouts=roof.suggest(profile,region,{})
            assert(layouts[1].kind=='shed' and layouts[1].face=='S' and layouts[1].leans)
            for i=1,#layouts do
                for j=1,#layouts[i].placements do assert(layouts[i].placements[j].z<=2) end
            end
        """)

    def test_helper_options_and_room_refresh(self):
        lua = runtime()
        module(lua, "shared/KnoxBuildworks/Planning/RoofPlanner.lua", "roof")
        lua.execute("""
            modules['KnoxBuildworks/Planning/RoofPlanner']=roof
            ISCollapsableWindow={derive=function() return {} end,update=function() end}
            ISPanel={derive=function() return {} end}
            function copyTable(t) local r={}; for k,v in pairs(t) do r[k]=v end; return r end
            modules['KnoxBuildworks/Definitions/Registry']={get=function() return nil end}
            plan={updated=2,rooms={{id='room',x=5,y=6,z=0,w=8,h=6}}}
            modules['KnoxBuildworks/Planning/Blueprints']={get=function() return plan end,
                getRoom=function(b,id) assert(id=='room'); return b.rooms[1] end}
        """)
        module(lua, "client/KnoxBuildworks/UI/RoofHelper.lua", "helper")
        lua.execute("""
            local function car(values,selected)
                local items={}
                for i=1,#values do items[i]={value=values[i],gable=values[i]~=false and type(values[i])=='table' and values[i] or nil} end
                return setmetatable({items=items,selected=selected},{__index=KBWRoofCarousel})
            end
            local w=setmetatable({room={id='room',x=0,y=0,z=0,w=4,h=4},checkedUpdated=1,
                blueprintId='plan',player={},
                overhang=car({0,1,2},2),rise=car({false,1,2},3),elevation=car({0,1,2},2),
                ceiling=car({'auto','yes','no'},1),eaves=car({true,false},1),
                gable=car({false,{id='wall'}},2),finish=car({},1)},{__index=helper})
            local o=w:selectedRoofOptions()
            assert(o.gable.id=='wall' and o.overhang==1 and o.riseLevels==2 and o.z==1)
            assert(o.ceiling==nil and o.eaves==true and o.decorateGable==nil)
            w.ceiling.selected=2; assert(w:selectedRoofOptions().ceiling==true)
            w.ceiling.selected=3; assert(w:selectedRoofOptions().ceiling==false)
            -- A painted look decorates every end-wall piece.
            w.finish.items={{style={id='x|p',finish={actionType='wallFinish',paintType='PaintRed',label='Red'}}}}
            w.finishChoices=function() return {paint='Base.PaintRed'} end
            local deco=w:selectedRoofOptions().decorateGable
            local item={}; deco(item,{buildableId='wall_a',stageId='built'})
            assert(item.finish.paintType=='PaintRed' and item.inputChoices.paint=='Base.PaintRed')
            w.gable.selected=1; assert(w:selectedRoofOptions().gable==nil)
            w.rebuild=function(s) s.rebuilt=true end
            w:update(); assert(w.rebuilt and w.room.x==5 and w.room.w==8)
            assert(w.room~=plan.rooms[1])
        """)

    def test_helper_controls_fit_large_fonts_and_close_removes_preview_hook(self):
        lua = runtime()
        translations = json.loads((LUA / "shared/Translate/EN/IG_UI.json").read_text(encoding="utf-8"))
        lua.globals().strings = lua.table_from(translations)
        module(lua, "shared/KnoxBuildworks/Planning/RoofPlanner.lua", "roof")
        directory = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions"
        definitions = []
        for folder in ("roofing", "walls"):
            for path in sorted((directory / folder).glob("*.json")):
                definitions.extend(json.loads(path.read_text(encoding="utf-8")).get("buildables", []))
        lua.globals().definitions = lua.table_from(definitions, recursive=True)
        lua.execute("""
            function getText(key, ...)
                local s=strings[key] or key
                local args={...}
                for i=1,#args do s=s:gsub('%%'..i,tostring(args[i])) end
                return s
            end
            function copyTable(t) return modules['KnoxBuildworks/Util/Table'].copy(t) end
            modules['KnoxBuildworks/Planning/RoofPlanner']=roof
            modules['KnoxBuildworks/Definitions/Registry']={list=function() return definitions end}
            modules['KnoxBuildworks/UI/CatalogVisibility']={definitionEnabled=function() return true end,
                stagePasses=function() return true end}
            plan={id='plan',updated=1,placements={},rooms={{id='r',x=0,y=0,z=0,w=8,h=4},{id='w',x=0,y=4,z=0,w=4,h=4}}}
            modules['KnoxBuildworks/Planning/Blueprints']={get=function() return plan end,
                canContribute=function() return true end,maxPlacements=function() return 100000 end,
                intersectionIndex=function() return {} end,findIntersections=function() return {} end,
                indexPlacement=function() end,withinRange=function() return true end,
                resolvePlacement=function() return {},{} end}
            local byId={}
            for i=1,#definitions do byId[definitions[i].id]=definitions[i] end
            modules['KnoxBuildworks/Definitions/Registry'].get=function(self,id) return byId[id] end
            modules['KnoxBuildworks/Definitions/Resolver']={resolveStage=function(id,v,m,s)
                local d=byId[id]; if not d then return nil end
                for i=1,#d.stages do if d.stages[i].id==s then return d,d.stages[i] end end
                return d,d.stages[1] end}
            paintEntries=0
            modules['KnoxBuildworks/Validation/WallFinishes']={
                entriesFor=function() paintEntries=paintEntries+1
                    return {{actionType='wallFinish',paintType='PaintRed',label='Red',color={1,0,0}},
                        {actionType='wallFinish',plaster=true,label='Plaster'}} end,
                isWallFinish=function(f) return f.actionType=='wallFinish' end,
                previewSprite=function(f,n,d,s,base) return base end,
                paintComponents=function() return {} end}
            modules['KnoxBuildworks/Geometry/Matrix']={getFaceCells=function() return nil end}
            local T=modules['KnoxBuildworks/UI/Theme']
            for _,k in pairs({'selected','surfaceRaised','accent','borderSoft','textMuted','text','bad','good','warn'}) do
                T[k]=T[k] or {r=1,g=1,b=1,a=1} end
            rendered=0; outlined=0; flushed=0
            modules['KnoxBuildworks/Planning/GhostRenderer']={renderBlueprint=function()
                rendered=rendered+1 end,
                renderOutline=function(lines,z,color,playerIndex)
                    assert(#lines>0 and z==1 and playerIndex==0)
                    outlined=outlined+1
                end,
                flushWorldAreaHighlights=function(playerIndex)
                    assert(playerIndex==0); flushed=flushed+1
                end,HIGHLIGHT_COLOR={},CONFLICT_COLOR={}}
            modules['KnoxBuildworks/UI/Theme'].setButtonEnabled=function(b,value) b.enabled=value end
            modules['KnoxBuildworks/UI/Theme'].applyActionButton=function(b,value) b.enabled=value end
            modules['KnoxBuildworks/UI/Theme'].applyCombo=function() end
            modules['KnoxBuildworks/I18n'].subcategory=function(v) return v end
            Events={OnPostRender={Add=function(f) hook=f end,Remove=function(f) assert(hook==f); hook=nil end}}
            local function element(s,x,y,w,h)
                local c=control(); c.x=x; c.y=y; c.width=w; c.height=h; c.children={}
                c.addChild=function(self,child) self.children[#self.children+1]=child end
                c.removeFromUIManager=function(self) self.removed=true end
                c.getMouseY=function() return 10 end
                setmetatable(c,{__index=s}); return c
            end
            ISCollapsableWindow={derive=function(s) local c={}; setmetatable(c,{__index=s}); return c end,
                createChildren=function() end,update=function() end,titleBarHeight=function() return 24 end,
                prerender=function() end,new=element}
            ISPanel={derive=function(s) local c={}; setmetatable(c,{__index=s}); return c end,
                new=function(s,x,y,w,h) local c=element(s,x,y,w,h)
                    c.instantiate=function(self) if self.createChildren then self:createChildren() end end
                    return c end,
                prerender=function() end}
            ISButton={new=function(s,x,y,w,h,title)
                local c=element({},x,y,w,h); c.title=title
                c.addOption=function(self,text) self.options[#self.options+1]=text end
                c.clear=function(self) self.options={} end
                c.setEnabled=function(self,value) self.enabled=value end
                return c
            end}
            ISComboBox=ISButton; ISRichTextPanel=ISButton
        """)
        module(lua, "client/KnoxBuildworks/UI/RoofHelper.lua", "helper")
        lua.execute("""
            for _,height in pairs({16,24,32}) do
                fontHeight=height
                local owner={screenLeft=0,screenTop=0,screenW=1280,screenH=720,
                    player={getPlayerNum=function() return 0 end}}
                local window=helper:new(owner,plan,plan.rooms[1])
                owner.roofWindow=window; window:createChildren()
                local family=window.family:current()
                assert(family and family.profile.complete and family.profile.pitch==45)
                -- Only families the helper can lay out itself; no hand-placement button.
                for i=1,#window.family.items do assert(helper.isAutomatic(window.family.items[i].profile)) end
                assert(window.details==nil and window.status==nil and window.help)
                -- End walls offer the bare wall plus every common finish.
                assert(window.gable:current().gable and #window.finish.items>=3, #window.finish.items)
                assert(window.finish.items[1].style.finish==nil and window.finish.items[2].style.finish.paintType=='PaintRed')
                -- The family carousel steps and wraps.
                local count=#window.family.items
                local start=window.family.selected
                window.family:step(-1)
                assert(count<2 or window.family.selected==(start==1 and count or start-1))
                window.family:step(1); assert(window.family.selected==start)
                assert(window.gable:current().gable.pitch==45)
                now=1000; window:update() -- first update rebuilds, later ones step layouts
                local guard=0
                repeat now=now+20; window:update(); guard=guard+1 until (window.active and window.active.done) or guard>400
                assert(window.active.done and #window.layouts>3, #window.layouts)
                -- Prefetching next to the first family wraps to the last one
                -- (Kahlua's % is not a floored modulo).
                local keep=window.family.selected
                window.family.selected=1; window.prefetch=nil
                window:stepLayouts(); assert(#window.prefetch>=0)
                window.family.selected=keep; window.prefetch=nil
                assert(window.layouts[1].kind=='crossGable' and window.selectedIndex==1)
                assert(window.apply.enabled)
                for i=1,#window.list.rows do
                    local row=window.list.rows[i]
                    assert(row.model and #row.model.polys>0 and row.height>=84)
                end
                window.getIsVisible=function() return true end
                currentPlayer=owner.player
                function getPlayer() return currentPlayer end
                local before=rendered
                hook(); assert(rendered==before+1)
                currentPlayer={getPlayerNum=function() return 1 end}
                hook(); assert(rendered==before+1)
                assert(window.y>=0 and window.y+window.height<=720)
                -- Family, gable walls and finish are picker cards with a large tile preview.
                for _,key in pairs({'family','gable','finish'}) do
                    local card=window[key]
                    assert(card.preview>=64 and card:isVisible(), key)
                    assert(card.height>=card.preview+2*fontHeight and card.width>=card.preview+2*card:arrowWidth(), key)
                end
                assert(window.family.y==window.gable.y and window.gable.y==window.finish.y)
                for i=1,#window.children do
                    local c=window.children[i]
                    assert(c.x>=0 and c.y>=0 and c.x+c.width<=window.width and c.y+c.height<=window.height)
                end
                for i=1,#window.labels do
                    local label=window.labels[i]
                    local right=window.width-12
                    for j=1,#window.labels do
                        local other=window.labels[j]
                        if other.y==label.y and other.x>label.x then right=math.min(right,other.x-12) end
                    end
                    if label.text~=strings.IGUI_KBW_RoofLayouts then
                        assert(getTextManager():MeasureStringX(UIFont.Small,label.text)<=right-label.x,label.text)
                    end
                end
                window.list.scroll=window.list.rows[2].y; window.list:clampScroll()
                -- A half-scrolled list never draws outside its own viewport.
                local list=window.list
                local function inside(ya,yb) assert(ya>=0 and yb<=list.height, ya..'..'..yb..' of '..list.height) end
                list.setStencilRect=function() end; list.clearStencilRect=function() end
                list.drawRect=function(s,x,y,w,h) inside(y,y+h) end
                list.drawText=function(s,t,x,y) inside(y,y+fontHeight) end
                list.drawPolygon=function(s,t,x1,y1,x2,y2,x3,y3,x4,y4) inside(math.min(y1,y2,y3,y4),math.max(y1,y2,y3,y4)) end
                for _,offset in pairs({0,17,list.rows[1].height-5,list.contentHeight}) do
                    list.scroll=offset; list:clampScroll(); list:render()
                end
                list.scroll=list.rows[2].y; list:clampScroll()
                window.list:onMouseDown(0, window.list.rows[2].y-window.list.scroll + 4)
                assert(window.selectedIndex==2)
                window:close(); assert(hook==nil and owner.roofWindow==nil and window.removed)
            end
        """)

class QuickbarTests(unittest.TestCase):
    def test_saved_configuration_is_copied_and_disabled_recipes_cannot_activate(self):
        lua = runtime()
        lua.execute("""
            ISPanel={derive=function() return {} end}
            local definition,stage={id='wall'},{id='built'}
            enabled=true; visible=true; permission=true; starts=0; errors=0
            modules['KnoxBuildworks/Definitions/Resolver']={resolveStage=function(id,v,m,s)
                assert(id=='wall' and v=='oak' and m=='wood' and s=='built'); return definition,stage end}
            modules['KnoxBuildworks/UI/CatalogVisibility']={definitionEnabled=function() return enabled end,
                stagePasses=function() return visible end}
            modules['KnoxBuildworks/Planning/Blueprints']={canContribute=function() return permission end,
                setActive=function() end}
            modules['KnoxBuildworks/Planning/Planner']={begin=function(p,id,s,v,m,dir,finish)
                starts=starts+1; assert(dir==3 and finish.paintType=='blue'); finish.paintType='mutated' end}
            HaloTextHelper={addBadText=function() errors=errors+1 end}
        """)

        module(lua, "client/KnoxBuildworks/UI/PlanQuickbar.lua", "barClass")
        lua.execute("""
            local data={}; local selection={buildableId='wall',stageId='built',variantId='oak',materialId='wood',
                direction=3,finish={paintType='blue'}}
            local owner={planSelection=function() return selection end,selectedOrActiveBlueprint=function() return {id='plan'} end}
            local bar=setmetatable({owner=owner,player={getModData=function() return data end},refresh=function() end},{__index=barClass})
            bar:assign(1); selection.finish.paintType='red'
            assert(data.KBW_UI.quickbar['1'].finish.paintType=='blue')
            bar:activate(1); assert(starts==1 and data.KBW_UI.quickbar['1'].finish.paintType=='blue')
            enabled=false; bar:activate(1); assert(starts==1 and errors==1)
            enabled=true; visible=false; bar:activate(1); assert(starts==1 and errors==2)
            visible=true; permission=false; bar:activate(1); assert(starts==1)
        """)


class PreviewTests(unittest.TestCase):
    def test_preferences_restore_per_player_and_reset_invalid_saved_values(self):
        lua = runtime()
        module(lua, "client/KnoxBuildworks/Planning/GhostRenderer.lua", "ghost")
        lua.execute("""
            local a={getModData=function() return {KBW_UI={ghostOpacityIndex=4,
                ghostView={style='solid',levels='all',roofs=false,rooms=false}}} end}
            local b={getModData=function() return {} end}
            ghost.applyPreferences(a)
            assert(ghost.opacity==1 and ghost.view.style=='solid' and not ghost.view.roofs)
            ghost.applyPreferences(b)
            assert(ghost.opacity==.35 and ghost.view.style=='ghost' and ghost.view.roofs and ghost.view.rooms)
            assert(ghost.view.levels=='adjacent')
            local broken={getModData=function() return {KBW_UI={ghostView='bad',ghostOpacityIndex=99}} end}
            ghost.applyPreferences(broken)
            assert(ghost.opacity==.35 and ghost.view.style=='ghost')
        """)

    def test_true_opacity_solid_texture_and_level_filters(self):
        lua = runtime()
        module(lua, "client/KnoxBuildworks/Planning/GhostRenderer.lua", "ghost")
        lua.execute("""
            local calls={}
            ghost.placementCells=function() return {{x=1,y=2,z=3,sprite='wall'}} end
            ghost.getSprite=function() return {RenderGhostTileColor=function(s,x,y,z,r,g,b,a)
                calls[#calls+1]={r=r,g=g,b=b,a=a} end} end
            ghost.setOpacity(.35); ghost.renderPlacement({},3)
            assert(calls[1].a==.35 and calls[1].r==.55)
            ghost.view.style='texture'; ghost.renderPlacement({},3)
            assert(calls[2].a==.35 and calls[2].r==1)
            ghost.view.style='solid'; ghost.renderPlacement({},3)
            assert(calls[3].a==1 and calls[3].b==1)
            ghost.view.levels='current'; assert(ghost.levelAlpha(2,3,1)==0)
            ghost.view.levels='below'; assert(ghost.levelAlpha(1,3,1)==1 and ghost.levelAlpha(4,3,1)==0)
            ghost.view.levels='all'; assert(ghost.levelAlpha(8,3,1)==1)
        """)


class ProgressionTests(unittest.TestCase):
    def test_cached_catalog_index_does_not_bypass_new_knowledge_gates(self):
        lua = requirements_runtime()
        lua.globals().modules["KnoxBuildworks/Validation/Requirements"] = lua.globals().requirements
        lua.execute("""
            Perks={Woodwork='Woodwork'}
            known=false
            player.isRecipeActuallyKnown=function() return known end
            player.getPerkLevel=function() return 0 end
            definition={id='gated',stages={{id='built',requirements={knowledge={hideUntilLearned=true,recipes={'secret'}}}}}}
            modules['KnoxBuildworks/Definitions/Registry']={hash='test',list=function() return {definition} end}
            modules['KnoxBuildworks/Definitions/Groups'].groupedList=function(d) return d end
            modules['KnoxBuildworks/I18n'].category=function(s) return s end
            modules['KnoxBuildworks/I18n'].subcategory=function(s) return s end
            modules['KnoxBuildworks/I18n'].optionName=function(s) return s.id end
        """)
        module(lua, "client/KnoxBuildworks/UI/CatalogIndex.lua", "index")
        lua.execute("""
            local record=index.get().records[1]
            assert(not record.alwaysVisible)
            assert(not index.recordVisible(player,record,false))
            known=true; now=6000
            index.recordVisible(player,record,false); index.pumpVisibility(8)
            assert(index.recordVisible(player,record,false))
        """)

    def test_magazine_or_skill_gates_visibility_and_authoritative_requirements(self):
        lua = requirements_runtime()
        lua.globals().modules["KnoxBuildworks/Validation/Requirements"] = lua.globals().requirements
        module(lua, "client/KnoxBuildworks/UI/CatalogVisibility.lua", "visibility")
        lua.execute("""
            Perks={Woodwork='Woodwork'}
            local level,known,cheat=3,false,false
            player.getPerkLevel=function() return level end
            player.isRecipeActuallyKnown=function() return known end
            player.isBuildCheat=function() return cheat end
            local stage={requirements={skills={Woodwork=3},knowledge={hideUntilLearned=true,
                recipes={'KnoxKnowledge'},skillAlternatives={{mode='all',skills={Woodwork=7}}}}}}
            assert(not visibility.stagePasses(player,{},stage,false))
            assert(visibility.stagePasses(player,{},stage,true))
            assert(not requirements.evaluate(player,{},stage).ok)
            known=true
            assert(visibility.stagePasses(player,{},stage,false) and requirements.evaluate(player,{},stage).ok)
            known=false; level=7
            assert(visibility.stagePasses(player,{},stage,false) and requirements.evaluate(player,{},stage).ok)
            level=0; cheat=true
            assert(requirements.evaluateReadiness(player,{},stage,{}).ok)
        """)

    def test_all_magazines_teach_used_gates_and_all_components_have_sources(self):
        media = LUA.parent
        manifest = json.loads((ROOT / "docs/building-items.json").read_text())
        progression = json.loads((ROOT / "docs/magazine-progression.json").read_text())
        self.assertEqual(set(progression), set(manifest["magazines"]))
        items = (media / "scripts/knox_buildworks_items.txt").read_text()
        loot = (ROOT / "Contents/mods/KnoxBuildworks/42/media/lua/server/Items/KnoxBuildworksDistributions.lua").read_text()
        names = json.loads((LUA / "shared/Translate/EN/ItemName.json").read_text())
        recipes = json.loads((LUA / "shared/Translate/EN/Recipes.json").read_text())
        for magazine in manifest["magazines"]:
            self.assertIn("LearnedRecipes = KBWKnowledge_" + magazine + ",", items)
            self.assertIn("KBWKnowledge_" + magazine, recipes)
        for item in manifest["magazines"] + manifest["items"]:
            self.assertIn("KnoxBuildworks." + item, names)
            self.assertIn('"KnoxBuildworks.' + item + '"', loot)
        for asset in manifest["assets"]:
            self.assertTrue((media / asset).is_file(), asset)
        self.assertNotIn("module Base", items)
        # Core mod content, not an add-on: core KBW names, no expansion folders.
        models = (media / "scripts/knox_buildworks_models.txt").read_text()
        recipes_script = (media / "scripts/knox_buildworks_recipes.txt").read_text()
        for text in (items, models, loot):
            self.assertNotIn("KBWX", text)
            self.assertNotIn("KBWExpansion", text)
        for recipe in ("KBWCutPlasticSheet", "KBWPrepareRubberTube", "KBWAssembleCompressor"):
            self.assertIn("craftRecipe " + recipe, recipes_script)
        for model in re.findall(r"WorldStaticModel = KnoxBuildworks\.(\w+),", items):
            self.assertIn("model " + model + "\n", models.replace("\r\n", "\n"))
        self.assertFalse((ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media/scripts").exists())

    def test_authored_roofs_have_real_face_mappings_and_structured_knowledge_sources(self):
        directory = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions"
        slopes = 0
        for path in directory.rglob("*.json"):
            for definition in json.loads(path.read_text(encoding="utf-8")).get("buildables", []):
                for stage in definition.get("stages", []):
                    knowledge = stage.get("requirements", {}).get("knowledge", {})
                    if knowledge.get("hideUntilLearned"):
                        self.assertTrue(knowledge["recipes"] and knowledge["skillAlternatives"])
                        for source in knowledge["sources"]:
                            self.assertIsInstance(source, dict)
                    roof = stage.get("roof", {})
                    if roof.get("role") == "slope":
                        slopes += 1
                        for face in roof["faceByEdge"].values():
                            self.assertIn(face, stage["geometry"]["faces"])
                        self.assertLessEqual(roof["step"], roof["stepsPerLevel"])
        self.assertGreater(slopes, 50)


if __name__ == "__main__":
    unittest.main()
