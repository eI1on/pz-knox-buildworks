"""B42 catalogue logic checks. Run with python -m unittest discover -s tools/tests.

Requires lupa. UI doubles check geometry and state; they do not replace an
in-game rendering or multiplayer test.
"""
from pathlib import Path
import unittest
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "Contents/mods/KnoxBuildworks/42/media/lua"


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
        modules = {}
        function require(name) return modules[name] or {} end
        UIFont = {Small=1, Medium=2}
        fontHeight = 16
        function getText(key) return key:gsub('IGUI_KBW_', '') end
        function getTextManager() return {
            getFontHeight=function() return fontHeight end,
            MeasureStringX=function(_,font,text) return #text * fontHeight * .45 end
        } end
        function getTimestampMs() return now or 1000 end
        function control()
            return {
                visible=true, items={}, selected=1, title='', options={},
                setX=function(s,v) s.x=v end, setY=function(s,v) s.y=v end,
                setWidth=function(s,v) s.width=v end, setHeight=function(s,v) s.height=v end,
                setVisible=function(s,v) s.visible=v end, isVisible=function(s) return s.visible end,
                setTooltip=function(s,v) s.tooltip=v end,
                setTitle=function(s,v) s.title=v end,
                initialise=function() end, instantiate=function() end, onResize=function() end,
                setOnMouseDownFunction=function() end, setMargins=function() end,
                addScrollBars=function() end, setText=function(s,v) s.text=v end,
                paginate=function() end, setYScroll=function() end,
                getScrollHeight=function(s) return s.scrollHeight or 0 end,
                setScrollHeight=function(s,v) s.scrollHeight=v end,
                clear=function(s) s.items={} end,
                addItem=function(s,text,item)
                    local entry={text=text,item=item,height=s.itemheight or 0}
                    s.items[#s.items+1]=entry
                    s.scrollHeight=(s.scrollHeight or 0)+entry.height
                    return entry
                end,
                replaceItems=function(s,rows)
                    s.items={}; s.scrollHeight=0
                    for i=1,#rows do
                        local entry={text=rows[i].name,item=rows[i].definition,height=s.itemheight or 0,index=i}
                        s.items[i]=entry; s.scrollHeight=s.scrollHeight+entry.height
                    end
                end,
                getInternalText=function() return '' end
            }
        end
        ISButton={new=function(s,x,y,w,h,title) local c=control(); c.title=title or ''; return c end}
        ISScrollingListBox=ISButton; ISRichTextPanel=ISButton
        modules['KnoxBuildworks/UI/Theme']={color=function(v) return v end,
            applyButton=function() end, applyActionButton=function() end, lockButtonColors=function(button)
                button.backgroundColorEnabled=button.backgroundColor
                button.borderColorEnabled=button.borderColor
            end}
        modules['KnoxBuildworks/UI/VirtualListBox']={new=function() return control() end}
        modules['KnoxBuildworks/I18n']={category=function(v) return v end,
            definitionName=function(d) return d.id end}
        modules['KnoxBuildworks/Definitions/Groups']={
            resolveDefinition=function(d,s) return s and s.member or d end,
            resolveStageId=function(s) return s.id end,
            resolveBuildableId=function(d,s) return (s.member or d).id end
        }
        modules['KnoxBuildworks/UI/BuildableInfo']={description=function() return 'Description' end,
            dimensionsText=function() return '1 x 1' end, capacityLines=function() return {} end}
        modules['KnoxBuildworks/UI/CatalogVisibility']={filteredStages=function(p,d) return d.stages end,
            stagePasses=function() return true end}
        modules['KnoxBuildworks/Admin/BuildableRules']={revision=1,effectiveStage=function(d,s) return s end}
    """)
    table_util = lua.execute((LUA / "shared/KnoxBuildworks/Util/Table.lua").read_text())
    lua.globals().modules["KnoxBuildworks/Util/Table"] = table_util
    return lua


class WorkspaceTests(unittest.TestCase):
    def test_main_catalog_activation_always_direct_builds(self):
        lua = runtime()
        source = (LUA / "client/KnoxBuildworks/UI/Catalog.lua").read_text(encoding="utf-8")
        callbacks = source[source.index("function KBWCatalog:onCardSelected"):source.index("function KBWCatalog:rawSelectedStage")]
        lua.execute("""
            KBWCatalog={}; Readiness={select=function(o) o.readinessSelections=(o.readinessSelections or 0)+1 end}
        """ + callbacks)
        lua.execute("""
            local definition={id='chair'}
            local owner={builds=0,plans=0}
            owner.refreshSelectionControls=function(s) s.refreshes=(s.refreshes or 0)+1 end
            owner.onBuild=function(s) s.builds=s.builds+1 end
            owner.onPlan=function(s) s.plans=s.plans+1 end
            setmetatable(owner,{__index=KBWCatalog})
            owner:onCardActivated(definition)
            assert(owner.selected==definition and owner.plans==0 and owner.builds==1)
        """)

    def test_catalog_icon_percentage_and_legacy_values(self):
        lua = runtime()
        source = (LUA / "client/KnoxBuildworks/UI/BuildCardGrid.lua").read_text(encoding="utf-8")
        scale = source[source.index("local function catalogIconScale"):source.index("local function hoverPreviewPixels")]
        lua.execute("""
            value=100
            Options={getOption=function() return {getValue=function() return value end} end}
        """ + scale + "\nfunction testedScale() return catalogIconScale() end")
        lua.execute("""
            value=75; assert(testedScale()==.75)
            value=125; assert(testedScale()==1.25)
            value=175; assert(testedScale()==1.75)
            value=2; assert(testedScale()==1.32)
            value=500; assert(testedScale()==1.75)
        """)

    def test_main_catalog_keeps_grid_as_the_default_view(self):
        source = (LUA / "client/KnoxBuildworks/UI/Catalog.lua").read_text(encoding="utf-8")
        self.assertIn('o.viewMode = data.viewMode == "list" and "list" or "grid"', source)

    def test_magnifier_is_available_without_thumbnail_hover(self):
        lua = runtime()
        source = (LUA / "client/KnoxBuildworks/UI/BuildCardGrid.lua").read_text(encoding="utf-8")
        preview = source[source.index("function KBWBuildCardGrid:previewIndexAt"):source.index("function KBWBuildCardGrid:pinIndexAt")]
        lua.execute("""
            KBWBuildCardGrid={}
        """ + preview)
        lua.execute("""
            local grid={viewMode='grid',gap=10,cardWidth=124,cardHeight=142,favoriteSize=18,compactMode=false}
            grid.indexAt=function() return 1 end
            grid.columns=function() return 1 end
            setmetatable(grid,{__index=KBWBuildCardGrid})
            assert(grid:previewIndexAt(110,40)==1, 'magnifier should work when hover previews are off')
            assert(grid:previewIndexAt(30,30)==0, 'thumbnail must never trigger the enlarged preview')
        """)

    def test_compact_cards_use_whole_card_hover_for_details(self):
        source = (LUA / "client/KnoxBuildworks/UI/BuildCardGrid.lua").read_text(encoding="utf-8")
        move = source[source.index("function KBWBuildCardGrid:onMouseMove"):source.index("function KBWBuildCardGrid:onMouseMoveOutside")]
        render = source[source.index("function KBWBuildCardGrid:prerender"):]
        self.assertIn("self.compactMode and hoverIndex", move)
        self.assertIn("local previewsEnabled = not self.compactMode", render)

    def test_possible_items_use_equivalent_available_counts_and_ready_border(self):
        source = (LUA / "client/KnoxBuildworks/UI/IngredientDrawer.lua").read_text(encoding="utf-8")
        self.assertIn("availableByKey[possibleKey]", source)
        self.assertIn("availableByKey[key] or 0", source)
        self.assertNotIn("not availablePossibleKeys[key]", source)
        self.assertIn("available and Theme.ready or Theme.borderSoft", source)

    def test_custom_scroll_views_apply_one_scroll_transform_and_stencils(self):
        grid = (LUA / "client/KnoxBuildworks/UI/BuildCardGrid.lua").read_text(encoding="utf-8")
        ingredients = (LUA / "client/KnoxBuildworks/UI/IngredientDrawer.lua").read_text(encoding="utf-8")
        requirements = (LUA / "client/KnoxBuildworks/UI/RequirementPanel.lua").read_text(encoding="utf-8")
        access = (LUA / "client/KnoxBuildworks/UI/AccessPanel.lua").read_text(encoding="utf-8")
        # clampStencilRectToParent installs the stencil itself in B42. Calling
        # setStencilRect a second time leaves an extra stencil active and
        # clips every sibling control rendered after the list.
        self.assertIn("self:clampStencilRectToParent(0, 0, safeWidth, self.height)", grid)
        self.assertNotIn("self:setStencilRect(stencilX, stencilY, stencilW, stencilH)", grid)
        self.assertNotIn("y = y - (self.getYScroll and self:getYScroll() or 0)", grid)
        self.assertNotIn("y = viewY", grid)
        self.assertIn("local viewY = y + scroll", grid)
        self.assertIn("self:clampStencilRectToParent(", ingredients)
        self.assertNotIn("self:setStencilRect(stencilX, stencilY, stencilW, stencilH)", ingredients)
        self.assertIn("local headerY = -scroll", ingredients)
        self.assertIn("local y = headerHeight + 8", ingredients)
        self.assertNotIn("local y = headerHeight + 8 + scroll", ingredients)
        self.assertIn("self:clampStencilRectToParent(", requirements)
        self.assertNotIn("self:setStencilRect(stencilX, stencilY, stencilW, stencilH)", requirements)
        self.assertIn("local y = 4", requirements)
        self.assertIn("local viewY = y + scroll", requirements)
        self.assertNotIn("local y = 4 + scroll", requirements)
        self.assertIn("self:clampStencilRectToParent(", access)
        self.assertNotIn("self:setStencilRect(stencilX, stencilY, stencilW, stencilH)", access)
        self.assertIn("local y = 4", access)
        self.assertIn("local viewY = y + scroll", access)
        self.assertNotIn("local y = 4 + scroll", access)
        # B42 keeps the drawer title in the viewport while only its rows move.
        # A translated header both loses the close button and can paint over
        # the inspector after the first wheel event.
        self.assertIn("local headerY = -scroll", ingredients)

    def test_category_panes_use_virtual_rows_and_balanced_inspector(self):
        workspace = (LUA / "client/KnoxBuildworks/UI/CatalogWorkspace.lua").read_text(encoding="utf-8")
        requirements = (LUA / "client/KnoxBuildworks/UI/RequirementPanel.lua").read_text(encoding="utf-8")
        access = (LUA / "client/KnoxBuildworks/UI/AccessPanel.lua").read_text(encoding="utf-8")
        self.assertIn("owner.categoryList.useStencilForChildren = false", workspace)
        self.assertIn("owner.compactGroups.useStencilForChildren = false", workspace)
        self.assertIn('require("KnoxBuildworks/UI/VirtualListBox")', workspace)
        self.assertIn("owner.categoryList:replaceItems(rows)", workspace)
        self.assertIn("math.floor(paneSpace * .45)", workspace)
        self.assertIn("owner.requirements:contentHeight(detailWidth)", workspace)
        self.assertIn("if #rows > 0 then return math.max(8, total - 6) end", requirements)
        self.assertIn("if #rows > 0 then total = total - 6 end", access)

    def test_ui_controls_copy_theme_colors_before_assignment(self):
        source = (LUA / "client/KnoxBuildworks/UI/BlueprintAccessWindow.lua").read_text(encoding="utf-8")
        self.assertIn("button.borderColor = Theme.color(selected and Theme.accent or Theme.borderSoft)", source)
        self.assertNotIn("button.borderColor = selected and Theme.accent or Theme.borderSoft", source)

    def test_world_lookup_preserves_variant_and_painted_finish(self):
        lua = runtime()
        lua.execute("""
            modules['KnoxBuildworks/Core']={Runtime={loaded=true}}
            modules['KnoxBuildworks/UI/Catalog']={open=function() end}
            modules['KnoxBuildworks/I18n'].optionName=function(o) return o.label or o.id or 'finish' end
            modules['KnoxBuildworks/UI/CatalogVisibility'].definitionEnabled=function() return true end
            modules['KnoxBuildworks/Definitions/StageConfig']={sprite=function() return {} end,placement=function() return {} end}
            modules['KnoxBuildworks/Validation/Placement']={windowShapeOf=function() return nil end,hasWallFrame=function() return false end}
            modules['KnoxBuildworks/Validation/WallFinishes']={
                entriesFor=function() return {{actionType='wallFinish',paintType='red',label='Red'}} end,
                isWallFinish=function() return true end,
                plannedFinishSignature=function(f) return 'paint:'..f.paintType end,
                previewSprite=function(f,n,d,s) return s.cellsByFace.W[1].sprite..'_red' end
            }
            local function stage(sprite) return {id='built',cellsByFace={W={{dx=0,dy=0,sprite=sprite}}}} end
            local definition={id='door',stages={stage('base')},variants={{id='brown',stages={stage('brown')}}}}
            local memberStage=stage('base'); memberStage.member=definition
            catalogue={list={{id='group',stages={memberStage}}}}
            modules['KnoxBuildworks/UI/CatalogIndex']={get=function() return catalogue end}
            IsoObjectType={doorN=1,doorW=2}; IsoFlagType={cutN=1,cutW=2}
            function getSprite(name) return {getType=function() return 0 end,getName=function() return name end,
                getProperties=function() return {has=function() return false end} end} end
            Events={OnFillWorldObjectContextMenu={Add=function() end}}
            function getSpecificPlayer() return {} end
            options={}
            ISContextMenu={getNew=function() return {addOption=function(s,label,player,callback,target) options[#options+1]=target end} end}
            context={addOption=function() return {} end,addSubMenu=function() end}
            worldSprite='brown'
            local objects={size=function() return 1 end,get=function() return {getSprite=function() return getSprite(worldSprite) end} end}
            local square={getObjects=function() return objects end}
            worldObjects={{getSquare=function() return square end}}
        """)
        lua.globals().world = lua.execute((LUA / "client/KnoxBuildworks/UI/WorldCatalog.lua").read_text())
        lua.execute("""
            world.onContextMenu(0,context,worldObjects,false)
            assert(#options==1 and options[1].state.variantIndex==2)
            assert(options[1].state.buildableId=='door' and options[1].state.stageId=='built')
            options={}; worldSprite='brown_red'
            world.onContextMenu(0,context,worldObjects,false)
            assert(#options==1 and options[1].state.variantIndex==2)
            assert(options[1].state.finishSignature=='paint:red')
        """)

    def test_optional_frame_is_not_a_required_stage(self):
        lua = runtime()
        source = (LUA / "shared/KnoxBuildworks/Validation/Placement.lua").read_text()
        validate = source[source.index("function Placement.validate("):source.rindex("return Placement")]
        lua.execute("""
            Placement={previousStageOf=function(s) return s.required end,
                optionalReplacementStageOf=function(s) return s.optional end,
                findPrevious=function(square,id,name) return square.previous end}
            StageConfig={placement=function() return {kind='wall',requiresFloor=false} end,sprite=function() return {} end}
            function isClient() return false end; function isServer() return false end
            cursor={character={getX=function() return 0 end,getY=function() return 0 end},
                definition={id='doorframe'},stage={optional={'WoodenWallFrame'}},canPassThrough=true,
                getFootprint=function() return {} end}
            square={getX=function() return 0 end,getY=function() return 0 end}
        """ + validate)
        lua.execute("""
            assert(Placement.validate(cursor,square)==true)
            cursor.stage.required={'WoodenWallFrame'}
            local ok,reason=Placement.validate(cursor,square)
            assert(not ok and reason=='previous stage missing')
            square.previous={}
            local accepted,_,previous=Placement.validate(cursor,square)
            assert(accepted and previous==square.previous)
            cursor.stage.required=nil
            local replaced,_,optional=Placement.validate(cursor,square)
            assert(replaced and optional==square.previous)
        """)

    def test_fixed_viewports_and_actions_at_supported_sizes(self):
        lua = runtime()
        lua.globals().workspace = lua.execute((LUA / "client/KnoxBuildworks/UI/CatalogWorkspace.lua").read_text())
        lua.execute("""
            function ownerFor(w,h)
                local o={width=w,height=h,categories={'Walls','Doors'},selectedCategories={},categoryButtons={},finishValues={{}},
                    selected={id='sample',variants={{}},materialOptions={{}}}}
                local names={'search','searchMode','sortCombo','scopeAll','scopeFav','scopeRecent','viewButton',
                    'subcategoryFilter','materialFilter','skillFilter','showAllTickBox','grid','compactGroups',
                    'categoryPrev','categoryNext','plansButton','appearanceButton','sizeButton','stage','variant',
                    'material','finish','stagePrevButton','stageNextButton','favoriteButton','recipePinButton',
                    'requirements','accessPanel','ingredientDrawer','buildButton','planButton'}
                for i=1,#names do o[names[i]]=control() end
                o.ingredientDrawer.visible=false
                o.addChild=function() end
                o.resizeWidgetHeight=function() return 16 end
                o.effectiveDefinition=function(s) return s.selected end
                o.selectedStage=function() return {id='built'} end
                o.rawSelectedStage=o.selectedStage
                o.stageCountForSelection=function() return 2 end
                o.ensureResizeWidgets=function() end; o.bringChromeToTop=function() end
                workspace.create(o)
                return o
            end
            for _,size in pairs({{900,650},{1120,780},{1500,1000}}) do
                for _,font in pairs({16,22,28}) do
                    fontHeight=font
                    local o=ownerFor(size[1],size[2])
                    workspace.layout(o,24,false)
                    assert(o.requirements.height >= 40, 'requirements viewport too small')
                    assert(o.requirements.y+o.requirements.height < o.accessPanel.y)
                    assert(o.accessPanel.y+o.accessPanel.height < o.buildButton.y)
                    assert(o.buildButton.y+o.buildButton.height <= o.height-16)
                    assert(o.categoryList.x+o.categoryList.width < o.grid.x)
                    assert(o.grid.x+o.grid.width < o.requirements.x)
                    assert(not o.stage.visible and o.stagePrevButton.visible and o.stageNextButton.visible)
                    assert(o.requirements.visible and o.accessPanel.visible)
                    assert(not o.materialsTab.visible and not o.skillsTab.visible)
                    assert(not o.filtersButton.visible and o.clearFiltersButton.visible and o.readyButton.visible)
                    assert(o.searchMode.visible and o.sortCombo.visible and not o.subcategoryFilter.visible)
                    assert(o.materialFilter.visible and o.skillFilter.visible and o.showAllTickBox.visible)
                    assert(o.compactGroups.visible and o.favoriteButton.visible and o.recipePinButton.visible)
                    assert(o.sizeButton.visible)
                    o.ingredientDrawer.visible=true
                    workspace.layout(o,24,false)
                    assert(o.clearFiltersButton.visible)
                    assert(o.readyButton.x+o.readyButton.width < o.clearFiltersButton.x)
                    assert(o.categoryList.y >= o.showAllTickBox.y+o.showAllTickBox.height)
                    assert(o.grid.visible, 'ingredient details must not cover the buildable list')
                    assert(o.grid.x+o.grid.width <= o.ingredientDrawer.x)
                    assert(o.grid.width >= 180, 'ingredient details must leave a usable buildable list')
                    if o.drawerBesideInspector then
                        assert(o.requirements.visible and o.accessPanel.visible)
                        assert(o.accessPanel.x+o.accessPanel.width <= o.ingredientDrawer.x)
                    else
                        assert(not o.requirements.visible and not o.accessPanel.visible)
                        assert(o.ingredientDrawer.x == o.buildButton.x)
                    end
                end
            end
            local compact=ownerFor(720,520)
            compact.compact=true
            workspace.layout(compact,24,false)
            assert(compact.grid.visible and compact.compactGroups.visible and compact.categoryList.visible)
            assert(not compact.requirements.visible and not compact.accessPanel.visible)
            assert(not compact.favoriteButton.visible and not compact.recipePinButton.visible)
            assert(not compact.recipeSummary.visible and compact.workspacePreview==nil)
            assert(compact.buildButton.visible and compact.planButton.visible)
            assert(compact.viewButton.y+compact.viewButton.height < compact.readyButton.y)
            assert(compact.grid.x+compact.grid.width <= compact.width-10)
            assert(compact.grid.y+compact.grid.height < compact.buildButton.y)
            assert(compact.sizeButton.visible)
        """)

    def test_cancelled_placement_reopens_catalogue_on_the_next_tick(self):
        source = (LUA / "client/KnoxBuildworks/UI/Catalog.lua").read_text(encoding="utf-8")
        process = source[source.index("function KBWCatalog.processDragReturn"):source.index("function KBWCatalog.onSetDragItem")]
        callback = source[source.index("function KBWCatalog.onSetDragItem"):source.index("if not KBWCatalog.eventsInstalled")]
        self.assertIn("KBWCatalog.open(player, state)", process)
        self.assertIn("Events.OnTick.Add(KBWCatalog.processDragReturn)", callback)
        self.assertIn("KBWCatalog.pendingDragReturn = state", callback)
        self.assertNotIn("KBWCatalog.open", callback)

    def test_rule_sync_keeps_the_static_catalogue_index(self):
        client = (LUA / "client/KnoxBuildworks/Client.lua").read_text(encoding="utf-8")
        index = (LUA / "client/KnoxBuildworks/UI/CatalogIndex.lua").read_text(encoding="utf-8")
        refresh = client[client.index("local function refreshBuildableRuleConsumers"):client.index("BuildableRules.addListener")]
        self.assertIn("CatalogIndex.refreshRules()", refresh)
        self.assertNotIn("CatalogIndex.invalidate()", refresh)
        self.assertIn("function CatalogIndex.refreshRules()", index)
        self.assertIn("record.requirementText = nil", index)

    def test_appearance_slider_initialisation_does_not_overwrite_saved_value(self):
        source = (LUA / "client/KnoxBuildworks/UI/CatalogSettings.lua").read_text(encoding="utf-8")
        self.assertIn("self.iconSizeSlider:setValues(75, 175, 5, 10, true)", source)
        self.assertIn("if self.syncingOptions then return end", source)

    def test_appearance_changes_restyle_live_without_refiltering_catalogue(self):
        settings = (LUA / "client/KnoxBuildworks/UI/CatalogSettings.lua").read_text(encoding="utf-8")
        catalog = (LUA / "client/KnoxBuildworks/UI/Catalog.lua").read_text(encoding="utf-8")
        appearance = catalog[catalog.index("function KBWCatalog:onAppearanceChanged"):catalog.index("function KBWCatalog:onToggleSize")]
        self.assertIn("self.target:onAppearanceChanged(livePreview, relayout)", settings)
        self.assertIn("self:notifyTarget(true, true)", settings)
        self.assertIn("Theme.applyList(self.categoryList)", appearance)
        self.assertIn("Theme.applyScrollbar(panel.vscroll)", appearance)
        self.assertLess(appearance.index("self.backgroundColor ="), appearance.index("if livePreview then"))
        self.assertNotIn("self:refreshGrid()", appearance)

    def test_readiness_is_bounded_and_uses_full_allocator(self):
        lua = runtime()
        lua.execute("""
            evaluations=0; fullEvaluations=0; revision=1
            modules['KnoxBuildworks/Validation/Requirements']={
                inventoryRevision=function() return revision end,
                snapshot=function() return {} end,
                evaluateReadiness=function(p,d,s) evaluations=evaluations+1; return {ok=s.fast} end,
                evaluate=function(p,d,s) fullEvaluations=fullEvaluations+1; return {ok=s.full} end
            }
        """)
        lua.globals().readiness = lua.execute((LUA / "client/KnoxBuildworks/UI/CatalogReadiness.lua").read_text())
        lua.execute("""
            local stages={}
            for i=1,12 do stages[i]={id='stage'..i,fast=true,full=i==9} end
            local definition={id='group',stages=stages}
            owner={readyOnly=true,player={getSquare=function() return {} end},search=control(),
                refreshGrid=function(s) s.refreshes=(s.refreshes or 0)+1 end}
            readiness.reset(owner)
            assert(#readiness.filter(owner,{definition})==0)
            readiness.update(owner)
            assert(evaluations<=4 and fullEvaluations<=4)
            assert(owner.readyResults.group==nil)
            for i=1,4 do readiness.update(owner) end
            assert(owner.readyResults.group.stageId=='stage9')
            assert(#readiness.filter(owner,{definition})==1)
            revision=2
            readiness.update(owner)
            assert(owner.readyResults.group==nil, 'inventory changes must invalidate readiness')
        """)

    def test_restore_resolves_filtered_member_before_options(self):
        lua = runtime()
        source = (LUA / "client/KnoxBuildworks/UI/Catalog.lua").read_text()
        helpers = source[source.index("local function selectedFilterValue"):source.index("function KBWCatalog:rememberDragReturn")]
        restore = source[source.index("function KBWCatalog:restoreState"):source.index("-- Requirement evaluation does recursive")]
        lua.execute("""
            KBWCatalog={}
            Groups=modules['KnoxBuildworks/Definitions/Groups']
            function copyCategorySet(t) return t or {} end
            function hasSelectedCategories() return false end
            function firstSelectedCategory() return 'All' end
            WallFinishes={plannedFinishSignature=function(f) return f.paintType end}
        """ + helpers + restore)
        lua.execute("""
            local wanted={id='built',member={id='window8'}}
            local o={scope='All',categoryButtons={},grid=control(),variant=control(),material=control(),
                stage=control(),finish=control(),requirements=control(),accessPanel=control()}
            o.grid.items={{id='windows'}}; o.grid.selectedIndex=1; o.grid.setItems=function() end
            o.filteredDefinitions=function() return o.grid.items end
            o.refreshSelectionControls=function(s) s.selected=o.grid.items[1]; s.visibleStages={wanted}; s.stage.selected=1 end
            o.refreshVariantMaterialControls=function(s) assert(s.visibleStages[s.stage.selected]==wanted); s.variant.options={'base','brown'} end
            o.refreshStageAndFinish=function() end
            o.refreshFinishOptions=function(s) s.finishValues={{paintType='blue'},{paintType='red'}}; s.finish.options={'blue','red'} end
            o.effectiveDefinition=function(s) return s.selected end
            o.selectedStage=function(s) return s.visibleStages[s.stage.selected] end
            o.selectedFinish=function(s) return s.finishValues[s.finish.selected] end
            o.requirements.setSelection=function() end; o.accessPanel.setSelection=function() end
            for _,name in pairs({'updateScopeButtons','refreshFilterOptions','refreshCompactGroups','layoutCategoryButtons','updateActions','layout'}) do o[name]=function() end end
            KBWCatalog.restoreState(o,{selectedId='windows',stageIndex=7,buildableId='window8',stageId='built',variantIndex=2,finishSignature='red'})
            assert(o.stage.selected==1 and o.variant.selected==2 and o.finish.selected==2)
        """)


if __name__ == "__main__":
    unittest.main()
