import json
import unittest
from test_catalog_workspace import runtime, LUA
from test_supply_allocation import requirements_runtime


class PlanningTests(unittest.TestCase):
    def test_planning_uses_its_own_two_panel_catalogue(self):
        mode = (LUA / "client/KnoxBuildworks/UI/PlanningMode.lua").read_text(encoding="utf-8")
        catalog = (LUA / "client/KnoxBuildworks/UI/PlanningCatalog.lua").read_text(encoding="utf-8")
        self.assertIn('require("KnoxBuildworks/UI/PlanningCatalog")', mode)
        self.assertNotIn('require("KnoxBuildworks/UI/Catalog")', mode)
        self.assertNotIn("openSideCatalog", mode)
        self.assertIn("self.catalogPanel = PlanningCatalog:new", mode)
        self.assertIn("self.catalogPanel:addToUIManager()", mode)
        self.assertIn("self.catalogPanel:close()", mode)
        self.assertIn('require("KnoxBuildworks/UI/BlueprintPreview")', mode)
        self.assertIn("self.previewWindow = BlueprintPreview.open", mode)
        preview = (LUA / "client/KnoxBuildworks/UI/BlueprintPreview.lua").read_text(encoding="utf-8")
        self.assertIn('o.viewMode = "iso"', preview)
        self.assertIn("function KBWBlueprintPreviewCanvas:drawTopDown", preview)
        self.assertIn("function KBWBlueprintPreviewCanvas:drawIso", preview)
        self.assertIn("self:setStencilRect", preview)
        self.assertIn("function KBWBlueprintPreviewCanvas:onMouseWheel", preview)
        self.assertIn("self.doneButton = makeButton", preview)
        self.assertNotIn("self.closeButton = makeButton", preview)
        self.assertIn("self:removeFromUIManager()", preview)
        self.assertIn('require "ISUI/ISComboBox"', catalog)
        self.assertIn("self.categoryCombo = ISComboBox:new", catalog)
        self.assertIn("self.subcategoryCombo = ISComboBox:new", catalog)
        self.assertIn('local kinds = { "stage", "variant", "material", "finish" }', catalog)
        self.assertIn('self.catalogGrid:setViewMode("grid")', catalog)
        self.assertNotIn("REFRESH_BATCH", catalog)
        self.assertNotIn("processCatalogRefresh", catalog)
        self.assertIn("self:refreshSubcategories()", catalog)

    def test_planning_catalog_carousels_resolve_group_variants(self):
        lua = runtime()
        lua.execute("""
            function getTexture() return nil end
            ISPanel={}
            function ISPanel:derive(name)
                local class={}; class.__index=class; setmetatable(class,{__index=self}); return class
            end
            function ISPanel.update() end
            function ISPanel.prerender() end
            ISComboBox=ISButton; ISTextEntryBox=ISButton; ISTickBox=ISButton
            modules['KnoxBuildworks/UI/BuildCardGrid']={}
            modules['KnoxBuildworks/UI/PinnedRecipes']={}
            modules['KnoxBuildworks/UI/FinishOptions']={entriesFor=function()
                return {{id='none',none=true},{id='green'}}
            end}
            modules['KnoxBuildworks/UI/CatalogIndex']={visibilityGeneration=0}
            modules['KnoxBuildworks/Util/Profiler']={}
            modules['KnoxBuildworks/UI/CatalogVisibility']={
                shouldShowAll=function() return false end,
                filteredStages=function(player,definition) return definition.stages or {} end
            }
            modules['KnoxBuildworks/Definitions/Groups']={
                resolveDefinition=function(definition,stage) return stage and stage.member or definition end,
                resolveStageId=function(stage) return stage.id end
            }
            modules['KnoxBuildworks/I18n'].optionName=function(option) return option.id end
        """)
        lua.globals().planning_catalog = lua.execute(
            (LUA / "client/KnoxBuildworks/UI/PlanningCatalog.lua").read_text(encoding="utf-8")
        )
        lua.execute("""
            local base={id='wall',stages={{id='built'}},
                variants={{id='painted',stages={{id='built',variantStage=true}}}},
                materialOptions={{id='stone',stages={{id='built',materialStage=true}}}}}
            local group={id='walls',stages={{id='built',member=base}}}
            local owner={selectedBuildable=group}
            local panel={owner=owner,player={},visibleStages={},variantOptions={},materialOptions={},finishOptions={},
                catalogGrid={setSelectionPreview=function() end}}
            panel.layout=function() end
            setmetatable(panel,{__index=planning_catalog})
            panel:selectDefinition(group)
            assert(#panel.visibleStages==1 and #panel.variantOptions==2 and #panel.materialOptions==2)
            assert(#panel.finishOptions==2 and panel:selectedFinish()==nil)
            panel:onSelectorCycle({selectorKind='variant',internal=1})
            assert(panel:selectedVariant()=='painted')
            assert(panel:selectedStage().variantStage==true)
            panel:onSelectorCycle({selectorKind='finish',internal=1})
            assert(panel:selectedFinish().id=='green')
            owner.isFavorite=function() return false end
            owner.isPinnedDefinition=function() return false end
            panel.width=340; panel.height=620
            panel.search=control(); panel.categoryCombo=control(); panel.subcategoryCombo=control()
            panel.categories={'All','Walls'}; panel.subcategories={'All','Interior'}
            panel.showAllTickBox=control(); panel.showAllTickBox.width=120
            panel.placePlanButton=control(); panel.catalogGrid=control()
            panel.favoriteButton=control(); panel.favoriteButton.width=26; panel.favoriteButton.height=26
            panel.pinButton=control(); panel.pinButton.width=26; panel.pinButton.height=26
            panel.selectorButtons={}
            for _,kind in pairs({'stage','variant','material','finish'}) do
                panel.selectorButtons[kind]={control(),control()}
            end
            panel.layout=planning_catalog.layout
            panel:layout()
            assert(panel.catalogGrid.y+panel.catalogGrid.height<=panel.selectorPanelY)
            assert(panel.selectorPanelY+panel.selectorPanelH<panel.placePlanButton.y)
            assert(panel.placePlanButton.y+panel.placePlanButton.height<=panel.height-10)
            assert(panel.favoriteButton.x>=0 and panel.pinButton.x+panel.pinButton.width<=panel.width)
        """)

    def test_blueprint_preview_models_each_floor_with_rooms_and_supply_zone(self):
        lua = runtime()
        lua.execute("""
            Core={getTileScale=function() return 2 end}
            function getCore() return {getScreenWidth=function() return 1600 end,
                getScreenHeight=function() return 900 end} end
            local texture={getWidthOrig=function() return 128 end,getHeightOrig=function() return 256 end,
                getWidth=function() return 128 end,getHeight=function() return 256 end,
                getOffsetX=function() return 0 end,getOffsetY=function() return 0 end}
            function getTexture() return texture end
            Keyboard={KEY_ESCAPE=1}
            ISPanel={}
            function ISPanel:derive(name)
                local class={}; class.__index=class; setmetatable(class,{__index=self}); return class
            end
            function ISPanel:new(x,y,w,h)
                return {x=x,y=y,width=w,height=h,setWantKeyEvents=function() end}
            end
            function ISPanel.prerender() end
            ISCollapsableWindow=ISPanel:derive('ISCollapsableWindow')
            function ISCollapsableWindow:new(x,y,w,h)
                return ISPanel.new(self,x,y,w,h)
            end
            function ISCollapsableWindow.close() end
            function ISCollapsableWindow:titleBarHeight() return 16 end
            modules['KnoxBuildworks/Planning/GhostRenderer']={
                GATHER_COLOR={r=.38,g=.86,b=.56,a=.22},
                placementCells=function(placement) return placement.cells end
            }
            modules['KnoxBuildworks/UI/IconResolver']={textureForSpriteName=function() return texture end}
            modules['KnoxBuildworks/UI/Theme']={
                backdrop={r=0,g=0,b=0,a=1},border={r=1,g=1,b=1,a=1},
                borderSoft={r=.2,g=.2,b=.2,a=1},accent={r=1,g=.8,b=.2,a=1},
                text={r=1,g=1,b=1,a=1},textMuted={r=.7,g=.7,b=.7,a=1},
                color=function(value) return value end,applyButton=function() end,
                setButtonEnabled=function() end
            }
            blueprint={id='bp',level=0,updated=1,placements={
                {cells={{x=10,y=12,z=0,sprite='tile_a'},{x=10,y=12,z=1,sprite='tile_b'}}}
            },rooms={{x=8,y=9,z=0,w=4,h=3,color={r=1,g=0,b=0,a=.2}}},
                gatherArea={x1=20,y1=21,x2=22,y2=24,z=1}}
            modules['KnoxBuildworks/Planning/Blueprints']={get=function() return blueprint end}
        """)
        lua.globals().blueprint_preview = lua.execute(
            (LUA / "client/KnoxBuildworks/UI/BlueprintPreview.lua").read_text(encoding="utf-8")
        )
        lua.execute("""
            local window=blueprint_preview:new({}, {}, blueprint)
            assert(#window.levels==2 and window.levels[1]==0 and window.levels[2]==1)
            local ground=window:model()
            assert(#ground.cells==1 and #ground.sprites==1 and #ground.rooms==1 and ground.supply==nil)
            assert(ground.minX==8 and ground.minY==9 and ground.maxX==11 and ground.maxY==12)
            window.levelIndex=2
            local upper=window:model()
            assert(#upper.cells==1 and #upper.rooms==0 and upper.supply~=nil)
            assert(upper.supply.x1==20 and upper.supply.y2==24)
        """)

    def test_planning_catalog_populates_atomically_and_preserves_selection(self):
        lua = runtime()
        lua.execute("""
            function getTexture() return nil end
            ISPanel={}
            function ISPanel:derive(name)
                local class={}; class.__index=class; setmetatable(class,{__index=self}); return class
            end
            ISComboBox=ISButton; ISTextEntryBox=ISButton; ISTickBox=ISButton
            modules['KnoxBuildworks/UI/BuildCardGrid']={}
            modules['KnoxBuildworks/UI/PinnedRecipes']={pinnedBuildableIds=function() return {},0 end}
            modules['KnoxBuildworks/UI/FinishOptions']={entriesFor=function() return {} end}
            local records={}
            for i=1,4342 do
                records[i]={definition={id='item'..i},category='Walls',subcategory='Interior',
                    alwaysVisible=true,searchTextExtended='item'..i}
            end
            modules['KnoxBuildworks/UI/CatalogIndex']={visibilityGeneration=0,get=function()
                return {orderByName=records,categories={'Walls'},allFilters={subcategories={Interior=true}},
                    filtersByCategory={Walls={subcategories={Interior=true}}}}
            end,pumpVisibility=function() end}
            modules['KnoxBuildworks/Util/Profiler']={now=function() return 1 end,add=function() end,count=function() end}
            modules['KnoxBuildworks/UI/CatalogVisibility']={shouldShowAll=function() return false end,
                definitionEnabled=function() return true end,filteredStages=function() return {} end}
            modules['KnoxBuildworks/Definitions/Groups']={anyMemberIn=function() return false end}
            modules['KnoxBuildworks/I18n'].subcategory=function(value) return value end
        """)
        lua.globals().planning_catalog = lua.execute(
            (LUA / "client/KnoxBuildworks/UI/PlanningCatalog.lua").read_text(encoding="utf-8")
        )
        lua.execute("""
            local grid={items={},setCalls=0}
            grid.setItems=function(s,items,selectedId)
                s.setCalls=s.setCalls+1; s.items=items; s.selectedIndex=#items>0 and 1 or 0
                for i=1,#items do if items[i].id==selectedId then s.selectedIndex=i end end
            end
            local selected={id='item2200'}
            local owner={selectedBuildable=selected,isFavorite=function() return false end,
                onCatalogSelected=function(s,item) s.selectedBuildable=item end}
            local panel={owner=owner,player={},categories={'All'},categoryIndex=1,
                subcategories={'All'},subcategoryIndex=1,catalogGrid=grid}
            setmetatable(panel,{__index=planning_catalog})
            panel:refreshCatalog()
            assert(#grid.items==4342 and grid.setCalls==1)
            assert(owner.selectedBuildable.id=='item2200' and grid.selectedIndex==2200)
            assert(panel.catalogRefreshState==nil)
        """)

    def test_workspace_creates_all_controls_from_an_empty_owner(self):
        lua = runtime()
        lua.execute("""
            ISTextEntryBox=ISButton
            ISContextMenu={get=function() return {addOption=function() return {} end} end}
            modules['KnoxBuildworks/Planning/Blueprints']={isOwner=function() return true end}
        """)
        lua.globals().workspace = lua.execute((LUA / "client/KnoxBuildworks/UI/PlanningWorkspace.lua").read_text(encoding="utf-8"))
        lua.execute("""
            local noop=function() end
            local o={width=420,height=720,children={},player={getZ=function() return 0 end}}
            o.addChild=function(s,c) s.children[#s.children+1]=c end
            o.selectedBlueprint=function() return nil end
            o.updateAccessControls=noop
            o.refreshRooms=noop; o.refreshPlacements=noop; o.refreshTotals=noop
            workspace.create(o,{{r=1,g=0,b=0,a=1},{r=0,g=1,b=0,a=1}},{.35,.65,1})
            assert(o.blueprintList and o.placementList and o.roomList and o.totalList)
            assert(o.blueprintName and o.roomName and o.workspaceSummary)
            assert(#o.workspaceTabs==4 and #o.colorButtons==2 and #o.opacityButtons==3)
            assert(o.colorButtons[1].backgroundColorEnabled==o.colorButtons[1].backgroundColor)
            assert(o.browseButton and o.moreButton and o.exitButton)
            assert(o.previewButton)
            assert(o.duplicateButton and o.pinBlueprintButton and o.manageAccessButton)
            assert(o.exportButton and o.importButton and o.copyJsonButton and o.deleteButton)
            for i=1,#o.children do local c=o.children[i]
                if c.visible then assert(c.x>=0 and c.y>=0 and c.x+c.width<=o.width and c.y+c.height<=o.height) end
            end
        """)

    def test_tabs_keep_controls_inside_sidebar(self):
        lua = runtime()
        lua.globals().translations = lua.table_from(json.loads((LUA / "shared/Translate/EN/IG_UI.json").read_text(encoding="utf-8")))
        lua.execute("getText=function(key) return translations[key] or key end")
        lua.globals().workspace = lua.execute((LUA / "client/KnoxBuildworks/UI/PlanningWorkspace.lua").read_text(encoding="utf-8"))
        lua.execute("""
            for _,size in pairs({{380,650,16},{460,672,28},{460,900,22}}) do
                fontHeight=size[3]
                local o={width=size[1],height=size[2],children={},colorButtons={},opacityButtons={}}
                local names={'blueprintList','blueprintName','renameButton','newButton','duplicateButton','deleteButton',
                    'activateButton','pinBlueprintButton','exportButton','importButton','copyJsonButton','manageAccessButton',
                    'totalList','roomName','drawRoomButton','eraseRoomButton','eraseButton','gatherAreaButton','buildToolButton',
                    'buildAllButton','stopToolButton','stopQueueButton','moveBlueprintButton','roomList','updateRoomButton',
                    'deleteRoomButton','placementList','buildSelectedButton','exitButton','levelDownButton','levelUpButton','usePlayerLevelButton'}
                for i=1,#names do o[names[i]]=control(); o.children[#o.children+1]=o[names[i]] end
                o.renameButton.title=getText('IGUI_KBW_Rename')
                o.usePlayerLevelButton.title=getText('IGUI_KBW_UsePlayerLevel')
                for i=1,10 do o.colorButtons[i]=control(); o.children[#o.children+1]=o.colorButtons[i] end
                for i=1,3 do o.opacityButtons[i]=control(); o.children[#o.children+1]=o.opacityButtons[i] end
                o.addChild=function(s,c) s.children[#s.children+1]=c end
                o.updateAccessControls=function() end
                o.selectedBlueprint=function() return nil end
                workspace.create(o)
                for _,tab in pairs({'plans','pieces','rooms','supplies'}) do
                    o.workspaceTab=tab; workspace.layout(o)
                    for i=1,#o.children do local c=o.children[i]
                        if c.visible then
                            assert(c.x>=0 and c.y>=0)
                            assert(c.x+c.width<=o.width and c.y+c.height<=o.height,tab..' control overflow')
                        end
                    end
                    assert(o.blueprintList.visible==(tab=='plans'))
                    assert(o.roomList.visible==(tab=='rooms'))
                    assert(o.totalList.visible==(tab=='supplies'))
                    assert(o.placementList.visible==(tab=='pieces'))
                    if tab=='plans' then
                        assert(o.duplicateButton.visible and o.pinBlueprintButton.visible and o.manageAccessButton.visible)
                        assert(o.activateButton.visible and o.browseButton.visible)
                    end
                end
            end
        """)

    def test_supply_totals_reserve_shared_materials_and_reuse_tools(self):
        lua = requirements_runtime()
        lua.execute("""
            function getItemNameFromFullType(t) return t end
            gathered={}; scanCalls=0; scanIncomplete=false
            modules['KnoxBuildworks/Planning/BuildQueue']={
                supplyOrder=function(p) return p end,
                inspectSupplies=function(p,area)
                    scanCalls=scanCalls+1
                    if area then assert(area.y2-area.y1+1<=24) end
                    return gathered,scanIncomplete
                end}
            modules['KnoxBuildworks/UI/IconResolver']={displayNameForTag=function(t) return t end}
            modules['KnoxBuildworks/Validation/WallFinishes']={fetchRows=function() return {} end}
            modules['KnoxBuildworks/Planning/Blueprints']={resolvePlacement=function(p) return p.definition,p.stage end}
            modules['KnoxBuildworks/Validation/Requirements']=requirements
            stock={makeItem('Base.Plank'),makeItem('Base.Plank'),makeItem('Base.Plank'),makeItem('Base.Hammer')}
            local stage={requirements={inputs={
                {id='hammer',items={'Base.Hammer'},mode='keep',role='tool',amount=1},
                {id='wood',items={'Base.Plank'},amount=2}}}}
            blueprint={updated=1,placements={{id='a',definition={},stage=stage},{id='b',definition={},stage=stage}}}
        """)
        lua.globals().supplies = lua.execute((LUA / "client/KnoxBuildworks/Planning/Supplies.lua").read_text(encoding="utf-8"))
        lua.execute("""
            local state=supplies.new(player,blueprint)
            supplies.step(state)
            assert(state.phase=='done' and not state.allReady and state.anyReady)
            assert(state.singleReady.a and state.singleReady.b)
            for _,row in pairs(state.materials) do assert(row.amount==4 and row.stock==3 and row.available==3) end
            for _,row in pairs(state.tools) do assert(row.amount==1 and row.stock==1) end
            assert(#records==0 and not stock[1].removed)
            gathered={makeItem('Base.Plank')}
            blueprint.gatherArea={x1=0,x2=1,y1=0,y2=49,z=0}
            state=supplies.new(player,blueprint)
            supplies.step(state)
            assert(state.phase=='scan')
            for i=1,10 do supplies.step(state) end
            assert(state.phase=='done' and state.allReady)
            for _,row in pairs(state.materials) do assert(row.amount==4 and row.stock==4 and row.available==4) end
            scanIncomplete=true
            blueprint.gatherArea={x1=0,x2=0,y1=0,y2=0,z=0}
            state=supplies.new(player,blueprint)
            supplies.step(state); supplies.step(state)
            assert(state.phase=='done' and not state.allReady, 'unloaded gather tiles must keep Build All disabled')
            scanIncomplete=false
            assert(supplies.current(state,blueprint))
            now=state.checkedAt+4001
            assert(not supplies.current(state,blueprint), 'completed supply results must expire')
            now=1000
            blueprint.gatherArea=nil
            state=supplies.new(player,blueprint)
            assert(supplies.current(state,blueprint))
            square.getX=function() return 1 end
            assert(not supplies.current(state,blueprint), 'moving must invalidate nearby supplies')
            square.getX=function() return 0 end
            state=supplies.new(player,blueprint)
            modules['KnoxBuildworks/Admin/BuildableRules'].revision=2
            assert(not supplies.current(state,blueprint), 'server rule changes must invalidate readiness')
        """)

    def test_drainable_tools_stay_in_the_tools_section(self):
        lua = requirements_runtime()
        lua.execute("""
            function getItemNameFromFullType(t) return t end
            modules['KnoxBuildworks/Planning/BuildQueue']={supplyOrder=function(p) return p end,
                inspectSupplies=function() return {},false end}
            modules['KnoxBuildworks/UI/IconResolver']={displayNameForTag=function(t) return t end}
            modules['KnoxBuildworks/Validation/WallFinishes']={fetchRows=function() return {} end}
            modules['KnoxBuildworks/Planning/Blueprints']={resolvePlacement=function(p) return p.definition,p.stage end}
            modules['KnoxBuildworks/Validation/Requirements']=requirements
            stock={makeItem('Base.BlowTorch',4)}
            local stage={requirements={inputs={{id='torch',items={'Base.BlowTorch'},role='tool',mode='drain',uses=2}}}}
            blueprint={updated=1,placements={{id='a',definition={},stage=stage},{id='b',definition={},stage=stage}}}
        """)
        lua.globals().supplies = lua.execute((LUA / "client/KnoxBuildworks/Planning/Supplies.lua").read_text(encoding="utf-8"))
        lua.execute("""
            local state=supplies.new(player,blueprint)
            supplies.step(state)
            local materialCount,toolCount=0,0
            for _ in pairs(state.materials) do materialCount=materialCount+1 end
            for _,row in pairs(state.tools) do toolCount=toolCount+1; assert(row.amount==4 and row.stock==4) end
            assert(materialCount==0 and toolCount==1 and state.allReady)
        """)


if __name__ == "__main__":
    unittest.main()
