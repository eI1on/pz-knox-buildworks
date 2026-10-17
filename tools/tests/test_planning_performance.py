"""Behavior and bounded-work regressions for roof and supply previews."""
import unittest
from test_catalog_workspace import LUA, runtime
from test_supply_allocation import requirements_runtime


def load(lua, path, name):
    value = lua.execute((LUA / path).read_text(encoding="utf-8-sig"))
    lua.globals()[name] = value
    return value


class PlanningPerformanceTests(unittest.TestCase):
    def test_totals_panel_does_not_start_a_synchronous_plan_walk(self):
        lua = runtime()
        source = (LUA / "client/KnoxBuildworks/UI/PlanningMode.lua").read_text(encoding="utf-8-sig")
        method = source[source.index("function KBWPlanningMode:refreshTotals()"):source.index("function KBWPlanningMode:onBlueprintSelected()")]
        lua.execute("""
            KBWPlanningMode={}
            local FONT_HGT_SMALL=16
            local function wrapLines(text) return {text} end
            local function setItemHeight() end
            local Blueprints={totals=function() error('must not synchronously walk the plan') end}
            local Supplies={current=function() return false end,new=function()
                return {phase='scan',count=576,materials={},tools={},skills={},recipes={}} end}
        """ + method)
        lua.execute("""
            local window=setmetatable({totalList=control(),selectedBlueprint=function() return {rooms={}} end},
                {__index=KBWPlanningMode})
            window.totalList.width=300
            window:refreshTotals()
            assert(window.supplyState.phase=='scan' and #window.totalList.items==2)
            assert(window.totalList.items[2].text=='CheckingSupplies')
        """)

    def test_roof_option_changes_coalesce_and_disable_apply_until_rebuilt(self):
        lua = runtime()
        lua.execute("""
            ISCollapsableWindow={derive=function() return {} end,update=function() end}
            ISPanel={derive=function() return {} end}
            blueprint={updated=1,placements={},rooms={}}
            modules['KnoxBuildworks/Planning/Blueprints']={get=function() return blueprint end}
            modules['KnoxBuildworks/UI/Theme'].setButtonEnabled=function(button,enabled) button.enabled=enabled end
        """)
        load(lua, "client/KnoxBuildworks/UI/RoofHelper.lua", "helper")
        lua.execute("""
            local window=setmetatable({checkedUpdated=1,apply={},rebuilds=0}, {__index=helper})
            function window:rebuild()
                self.rebuilds=self.rebuilds+1; self.rebuildAt=nil; self.apply.enabled=true
            end
            now=1000; window:onOptionsChanged()
            now=1050; window:onOptionsChanged()
            assert(window.rebuilds==0 and not window.apply.enabled)
            now=1109; window:update(); assert(window.rebuilds==0)
            now=1110; window:update(); assert(window.rebuilds==1 and window.apply.enabled)
            -- Without a pending change every update spends one frame budget.
            window.steps=0
            function window:stepLayouts() self.steps=self.steps+1 end
            now=1300; window:update(); window:update(); window:update()
            assert(window.steps==3 and window.rebuilds==1)
        """)

    def test_roof_layout_search_spreads_work_across_frames(self):
        lua = runtime()
        for name in ("RoomShape", "RoofAtlas", "RoofPlanner"):
            lua.globals().modules["KnoxBuildworks/Planning/" + name] = load(
                lua, "shared/KnoxBuildworks/Planning/%s.lua" % name, name)
        lua.execute("""
            local roof=RoofPlanner
            local defs={{id='flat',stages={{id='b',sprites={W='roofs_01_22'},roof={family='f',pitch=0,role='flat'}}}}}
            for i=0,31 do defs[#defs+1]={id='p'..i,stages={{id='b',sprites={W='roofs_01_'..i},
                roof={family='f',pitch=45,role='detail'}}}} end
            local profile=roof.profiles(defs)[1]
            assert(profile.complete)
            local ctx=roof.prepare(profile,{x=0,y=0,z=0,w=24,h=24},{z=1})
            local built=0
            local before=#ctx.layouts
            roof.step(ctx)
            assert(#ctx.layouts-before<=1,'one layout per step')
            while not roof.step(ctx) do built=built+1; assert(built<64) end
            assert(#roof.results(ctx)>=3)
        """)

    def test_supply_recipes_reuse_metadata_and_respect_each_manual_choice(self):
        lua = requirements_runtime()
        containers = load(lua, "client/KnoxBuildworks/Planning/SupplyContainers.lua", "containers")
        lua.globals().modules["KnoxBuildworks/Planning/SupplyContainers"] = containers
        lua.execute("""
            function getItemNameFromFullType(t) return t end
            stock={}; for i=1,256 do stock[#stock+1]=makeItem('Base.Plank') end
            for i=1,2000 do stock[#stock+1]=makeItem('Base.Nails') end
            reads=0
            inventory.getItems=function() reads=reads+1; return javaList(stock) end
            inventory.getAllTypeEvalRecurse=function() error('no per-recipe inventory scan') end
            inventory.getAllEvalRecurse=inventory.getAllTypeEvalRecurse
            ISInventoryPaneContextMenu={getContainers=function() return javaList({}) end}
            function getCell() return {getGridSquare=function() return nil end} end
            modules['KnoxBuildworks/UI/IconResolver']={displayNameForTag=function(t) return t end}
            modules['KnoxBuildworks/Validation/WallFinishes']={fetchRows=function() return {} end}
            resolutions=0
            modules['KnoxBuildworks/Planning/Blueprints']={resolvePlacement=function(p)
                resolutions=resolutions+1
                return {},{requirements={inputs={{id='material',items={'Base.Plank','Base.Nails'},amount=2}}}}
            end}
            modules['KnoxBuildworks/Validation/Requirements']=requirements
            descriptions=0; local describe=requirements.describe
            requirements.describe=function(...)
                descriptions=descriptions+1; return describe(...)
            end
            blueprint={updated=1,placements={}}
            for i=1,128 do blueprint.placements[i]={id='p'..i,buildableId='roof',stageId='built',
                inputChoices={material=i<=64 and 'Base.Plank' or 'Base.Nails'}} end
        """)
        queue = load(lua, "client/KnoxBuildworks/Planning/BuildQueue.lua", "queue")
        lua.globals().modules["KnoxBuildworks/Planning/BuildQueue"] = queue
        lua.execute("queue.supplyOrder=function(placements) return placements end")
        load(lua, "client/KnoxBuildworks/Planning/Supplies.lua", "supplies")
        lua.execute("""
            local state=supplies.new(player,blueprint)
            assert(reads==0 and resolutions==0)
            local steps=0
            repeat
                local before=state.cursor
                supplies.step(state); steps=steps+1
                assert(state.cursor-before<=32)
                assert(steps<100)
            until state.phase=='done'
            assert(state.allReady and descriptions==1 and resolutions==1)
            local totals=0
            for _,row in pairs(state.materials) do
                assert(row.amount==128 and row.available==128); totals=totals+1
            end
            assert(totals==2,'manual alternatives must stay separate')
        """)

    def test_large_nested_stockpile_is_scanned_incrementally(self):
        lua = requirements_runtime()
        containers = load(lua, "client/KnoxBuildworks/Planning/SupplyContainers.lua", "containers")
        lua.globals().modules["KnoxBuildworks/Planning/SupplyContainers"] = containers
        load(lua, "client/KnoxBuildworks/Planning/BuildQueue.lua", "queue")
        lua.execute("""
            reads=0
            local function list(items) return {size=function() return #items end,
                get=function(_,index) reads=reads+1; return items[index+1] end} end
            local function box(items) return {getItems=function() return list(items) end} end
            function instanceof(item,kind) return kind=='InventoryContainer' and item.bag==true end
            local large={}; for i=1,2000 do large[i]=makeItem('Base.Plank') end
            local inner=box(large)
            local bag={bag=true,getInventory=function() return inner end}
            local crate=box({bag}); crate.isRemoveItemAllowed=function() return false end
            inventory.getItems=function() return list({makeItem('Base.Hammer')}) end
            local vehicle=box({makeItem('Base.Nails')})
            local groundBag={getItem=function() return bag end}
            local site={getWorldObjects=function() return list({groundBag}) end,
                getObjects=function() return list({{getContainerCount=function() return 1 end,
                    getContainerByIndex=function() return crate end}}) end,
                getVehicleContainer=function() return vehicle end}
            function getCell() return {getGridSquare=function(_,x) return x==0 and site or nil end} end
            local scan=queue.newSupplyScan(player,{x1=0,x2=1,y1=0,y2=0,z=0})
            assert(reads==0,'opening the helper must not enumerate stock')
            local seen,count,steps={},0,0
            repeat
                local before=reads
                local items,done=queue.stepSupplyScan(scan,3)
                assert(reads-before<=128,'one packed container must yield within the work limit')
                for i=1,#items do assert(not seen[items[i]]); seen[items[i]]=true; count=count+1 end
                steps=steps+1
                assert(steps<100)
            until done
            assert(steps>10 and count==2003 and scan.incomplete)
            assert(seen[bag]) -- the floor bag is also referenced by storage, but its contents are visited once
            local clock=1000
            function getTimestampMs() clock=clock+1; return clock end
            local bounded=queue.newSupplyScan(player,{x1=0,x2=1,y1=0,y2=0,z=0})
            local items,done=queue.stepSupplyScan(bounded,3)
            assert(not done and #items<=3,'the time budget must yield before the operation limit')
        """)

    def test_allocation_skips_consumed_prefix_and_keeps_shared_aliases_correct(self):
        lua = requirements_runtime()
        lua.execute("""
            local items={}
            for i=1,1000 do items[i]=makeItem('Base.Plank') end
            local row={needed=1,availableItems={{items=items}}}
            local state=allocation.new()
            local visits=0; local original=instanceof
            function instanceof(item,kind) visits=visits+1; return original(item,kind) end
            for i=1,1000 do assert(allocation.row(row,state,true).ok) end
            assert(not allocation.row(row,state,true).ok)
            assert(visits<=2000,'repeated recipes must not rescan the consumed prefix')
            local torch=makeItem('Base.BlowTorch',5)
            local shared={torch}
            state=allocation.new()
            assert(allocation.row({needed=2,mode='drain',availableItems={{items=shared}}},state,true).ok)
            assert(not allocation.row({needed=1,mode='consume',availableItems={{items=shared}}},state,true).ok)
            assert(allocation.row({needed=1,mode='keep',availableItems={{items=shared}}},state,true).ok)
            assert(allocation.row({needed=3,mode='drain',availableItems={{items=shared}}},state,true).ok)
            assert(not allocation.row({needed=1,mode='keep',availableItems={{items=shared}}},state,true).ok)
        """)

    def test_recipe_description_never_enumerates_inventory_and_keeps_access_rules(self):
        lua = requirements_runtime()
        lua.execute("""
            inventory.getAllTypeEvalRecurse=function() error('inventory must not be scanned') end
            inventory.getAllEvalRecurse=inventory.getAllTypeEvalRecurse
            Perks={Woodwork='Woodwork'}
            player.getPerkLevel=function() return 1 end
            local stage={requirements={skills={Woodwork=3},inputs={{id='wood',items={'Base.Plank'},amount=2}}}}
            local result=requirements.describe(player,{},stage)
            assert(not result.ok and #result.rows==2)
            assert(result.rows[1].needed==2 and result.rows[2].available==1)
            player.tooDarkToRead=function() return true end
            assert(requirements.describe(player,{},stage).reason=='requires light')
        """)

    def test_collision_index_expands_plan_once_and_checks_anonymous_candidates(self):
        lua = runtime()
        lua.execute("""
            expansions=0; resolutions=0
            modules['KnoxBuildworks/Definitions/Resolver']={resolveStage=function(id)
                resolutions=resolutions+1
                return {id=id,placement={kind='floor'}},{id='built'} end}
            modules['KnoxBuildworks/Geometry/Matrix']={getFaceCells=function()
                expansions=expansions+1; return {{dx=0,dy=0,blocks=true,kind='floor'}} end,
                getFaceSprite=function() return nil end}
            modules['KnoxBuildworks/Validation/Placement']={previousStageOf=function() end,
                optionalReplacementStageOf=function() end}
            modules['KnoxBuildworks/Definitions/StageConfig']={placement=function(d) return d.placement end,
                sprite=function() return {} end}
            modules['KnoxBuildworks/Planning/BlueprintFiles']={queueSave=function() end}
            function isClient() return false end
            function isServer() return false end
        """)
        load(lua, "shared/KnoxBuildworks/Planning/Blueprints.lua", "bp")
        lua.execute("""
            local plan={placements={}}
            for i=1,1000 do plan.placements[i]={id='p'..i,buildableId='floor',x=i,y=0,z=0} end
            local occupied=bp.intersectionIndex(plan)
            assert(expansions==1000 and resolutions==1)
            for i=1,576 do
                local candidate={buildableId='floor',x=i,y=1,z=0}
                assert(#bp.findIntersections(plan,candidate,occupied)==0)
                bp.indexPlacement(occupied,candidate)
            end
            assert(expansions==2152 and resolutions==1)
            assert(#bp.findIntersections(plan,{buildableId='floor',x=10,y=1,z=0},occupied)==1)
            assert(#bp.findIntersections(plan,plan.placements[1],occupied)==0)
            local candidate={buildableId='floor',x=20,y=0,z=0}
            assert(#bp.findIntersections(plan,candidate,occupied)==#bp.findIntersections(plan,candidate))
            plan.id='plan'
            bp.get=function() return plan end
            bp.canContribute=function() return true end
            bp.prepareFinishPlacement=function() return true end
            bp.maxPlacements=function() return 2000 end
            bp.withinRange=function() return true end
            local indexes=0; local makeIndex=bp.intersectionIndex
            bp.intersectionIndex=function(...) indexes=indexes+1; return makeIndex(...) end
            local added,reason=bp.addPlacements({},'plan',{
                {id='new-a',buildableId='floor',x=1,y=2,z=0},
                {id='new-b',buildableId='floor',x=2,y=2,z=0},
                {id='overlap',buildableId='floor',x=1,y=2,z=0}})
            assert(#added==2 and reason=='plan_overlap' and indexes==1)
        """)


if __name__ == "__main__":
    unittest.main()
