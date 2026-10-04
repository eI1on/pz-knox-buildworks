import unittest
from test_catalog_workspace import runtime, LUA


def requirements_runtime():
    lua = runtime()
    lua.execute("""
        function instanceof(item, kind) return kind=='DrainableComboItem' and item.drain==true end
        function copyTable(t) return modules['KnoxBuildworks/Util/Table'].copy(t) end
        function javaList(items)
            return {size=function() return #items end,get=function(s,i) return items[i+1] end}
        end
        stock={}; ground={}; records={}
        inventory={
            getAllTypeEvalRecurse=function(s,fullType,predicate)
                local out={}
                for i=1,#stock do local item=stock[i]
                    if not item.removed and item.fullType==fullType and predicate(item) then out[#out+1]=item end
                end
                return javaList(out)
            end,
            getAllEvalRecurse=function(s,predicate)
                local out={}
                for i=1,#stock do if not stock[i].removed and predicate(stock[i]) then out[#out+1]=stock[i] end end
                return javaList(out)
            end,
            Remove=function(s,item) item.removed=true end
        }
        square={getX=function() return 0 end,getY=function() return 0 end,getZ=function() return 0 end}
        player={isBuildCheat=function() return false end,getSquare=function() return square end,
            getInventory=function() return inventory end,removeFromHands=function() end,
            tooDarkToRead=function() return false end}
        function makeItem(fullType, uses)
            return {fullType=fullType,drain=uses~=nil,uses=uses or 0,
                getFullType=function(s) return s.fullType end,
                getCurrentUses=function(s) return s.uses end,
                UseAndSync=function(s) assert(s.uses>0); s.uses=s.uses-1 end,
                getContainer=function() return inventory end,
                getWorldItem=function(s) return s.world end,
                isBroken=function(s) return s.broken==true end}
        end
        function sendRemoveItemFromContainer() end
        buildUtil={getMaterialOnGround=function() return ground end}
        Events={OnContainerUpdate={Add=function() end}}
        ArrayList={new=function() return {} end}
        modules['KnoxBuildworks/Core']={sandboxValue=function(k,default) return default end}
        modules['KnoxBuildworks/Definitions/StageConfig']={recipe=function() return {} end}
        modules['KnoxBuildworks/Entity/EntityCompat']={craftRecipeObject=function() return {} end}
        modules['KnoxBuildworks/Crafting/RecipeData']={new=function() return {
            record=function(s,input,item,index) records[#records+1]={id=input.id,item=item} end} end}
        modules['KnoxBuildworks/Util/Profiler']={count=function() end,now=function() return 0 end,add=function() end}
    """)
    allocation = lua.execute((LUA / "shared/KnoxBuildworks/Validation/SupplyAllocation.lua").read_text(encoding="utf-8"))
    lua.globals().modules["KnoxBuildworks/Validation/SupplyAllocation"] = allocation
    lua.globals().allocation = allocation
    lua.globals().requirements = lua.execute((LUA / "shared/KnoxBuildworks/Validation/Requirements.lua").read_text(encoding="utf-8"))
    return lua


class AllocationTests(unittest.TestCase):
    def test_possible_aliases_keep_stock_after_manual_choice_changes(self):
        lua = requirements_runtime()
        lua.execute("""
            stock={makeItem('Base.SmithingHammer')}
            inventory.getFirstTypeEvalRecurse=function(s,fullType,predicate)
                for i=1,#stock do
                    if not stock[i].removed and stock[i].fullType==fullType and predicate(stock[i]) then return stock[i] end
                end
                return nil
            end
            local stage={requirements={inputs={{
                id='hammer', role='tool', mode='keep', amount=1,
                items={'Base.SmithingHammer','Base.ClawHammer'}}}}}
            local status=requirements.evaluate(player,{},stage,nil,{hammer='Base.ClawHammer'})
            assert(status.rows[1].available==0, 'selected Claw Hammer should remain unavailable')
            assert(status.rows[1].possibleAvailableItems[1].fullType=='Base.SmithingHammer')
            assert(status.rows[1].possibleAvailableItems[1].available==1,
                'Possible Items must retain the Smithing Hammer stock count')
        """)

    def test_construction_paint_toggle_waives_only_paint_rows(self):
        lua = requirements_runtime()
        lua.execute("""
            modules['KnoxBuildworks/Core'].sandboxValue=function() return false end
            local original={
                {id='tool_paintbrush',items={'Base.Paintbrush'},role='tool',mode='keep',amount=1},
                {id='finish_paint',items={'Base.PaintWhite'},mode='drain',uses=2},
                {id='lumber',items={'Base.Plank'},amount=3}}
            local rows=requirements.getInputs({}, {requirements={inputs=original}})
            assert(rows[1].amount==0 and rows[2].uses==0 and rows[2].amount==0)
            assert(rows[3].amount==3)
            assert(original[1].amount==1 and original[2].uses==2, 'definition inputs must stay immutable')
        """)

    def test_overlapping_inputs_fail_before_any_consumption(self):
        lua = requirements_runtime()
        lua.execute("""
            stock={makeItem('Base.Plank')}
            stage={requirements={inputs={
                {id='a',items={'Base.Plank'},amount=1},
                {id='b',items={'Base.Plank'},amount=1}}}}
            local status=requirements.evaluate(player,{},stage)
            assert(not status.ok and status.rows[1].available==1 and status.rows[2].available==0)
            assert(not requirements.consume(player,stage,nil,{}))
            assert(not stock[1].removed and #records==0)
            stock[2]=makeItem('Base.Plank')
            assert(requirements.consume(player,stage,nil,{}))
            assert(stock[1].removed and stock[2].removed and #records==2)
            assert(records[1].item~=records[2].item)
        """)

    def test_ground_bucket_drains_reserved_uses_across_inputs(self):
        lua = requirements_runtime()
        lua.execute("""
            local paint=makeItem('Base.PaintWhite',3)
            paint.world={}
            ground={['Base.PaintWhite']={paint}}
            stage={requirements={inputs={
                {id='coat',items={'Base.PaintWhite'},mode='drain',uses=2},
                {id='trim',items={'Base.PaintWhite'},mode='drain',uses=1}}}}
            assert(requirements.evaluate(player,{},stage).ok)
            assert(requirements.consume(player,stage,square,{}))
            assert(paint.uses==0 and #records==3)
        """)

    def test_retained_tools_reuse_and_drainable_tools_sum(self):
        lua = requirements_runtime()
        lua.execute("""
            local hammer=makeItem('Base.Hammer')
            stock={hammer}
            local stage={requirements={inputs={
                {id='hammer',items={'Base.Hammer'},role='tool',mode='keep',amount=1},
                {id='hammer_again',items={'Base.Hammer'},role='tool',mode='keep',amount=1}}}}
            assert(requirements.consume(player,stage,nil,{}))
            assert(not hammer.removed and #records==2)
            local torch=makeItem('Base.BlowTorch',3)
            stock={torch}; records={}
            stage.requirements.inputs={
                {id='weld',items={'Base.BlowTorch'},role='tool',mode='drain',uses=2},
                {id='weld_again',items={'Base.BlowTorch'},role='tool',mode='drain',uses=2}}
            assert(not requirements.consume(player,stage,nil,{}))
            assert(torch.uses==3 and #records==0)
        """)

    def test_ground_predicates_match_inventory_predicates(self):
        lua = requirements_runtime()
        lua.execute("""
            local paint=makeItem('Base.PaintWhite',3); paint.broken=true
            ground={['Base.PaintWhite']={paint}}
            local stage={requirements={inputs={{id='paint',items={'Base.PaintWhite'},mode='drain',uses=1,flags={'NoBrokenItems'}}}}}
            assert(not requirements.evaluate(player,{},stage).ok)
            local snapshot=requirements.snapshot(player,square)
            assert(not requirements.evaluateReadiness(player,{},stage,snapshot).ok)
        """)


if __name__ == "__main__":
    unittest.main()
