"""Regression checks for the concrete B42 player-report data fixes."""
import json
from pathlib import Path
import unittest

import kbw_runtime as k

from lupa import LuaRuntime
from test_catalog_workspace import runtime


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Contents/mods/KnoxBuildworks/42/media"
EXPANDED = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media"


def bundle(root, relative):
    return json.loads((root / relative).read_text(encoding="utf-8-sig"))["buildables"]


def find(buildables, buildable_id):
    return next(item for item in buildables if item["id"] == buildable_id)


class ReportDefinitionTests(unittest.TestCase):
    def test_core_window_frame_has_no_expanded_material_dependency(self):
        buildable = find(
            bundle(CORE, "KnoxBuildworks/definitions/vanilla/windows.json"),
            "kbw.vanilla.woodenwindowframelvl3",
        )
        requirements = buildable["stages"][0]["requirements"]
        self.assertNotIn("materials", requirements)
        self.assertEqual(
            {row["id"] for row in requirements["inputs"]},
            {"tool_hammer", "lumber", "fasteners_nails"},
        )
        self.assertTrue(buildable["translationKey"].startswith("IGUI_KBW_"))

    def test_timber_posts_are_passable(self):
        posts = bundle(EXPANDED, "KnoxBuildworks/definitions/structural/timber_framing.json")
        post_ids = {
            "kbw.vanillaexpanded.structural.post",
            "kbw.vanillaexpanded.structural.post_short",
            "kbw.vanillaexpanded.structural.post_braced",
            "kbw.vanillaexpanded.structural.post_braced_reversed",
            "kbw.vanillaexpanded.structural.post_braced_double",
        }
        selected = [item for item in posts if item["id"] in post_ids]
        self.assertEqual({item["id"] for item in selected}, post_ids)
        for post in selected:
            self.assertIs(post["stages"][0]["object"]["canPassThrough"], True)
            self.assertIs(post["stages"][0]["object"]["blockAllSquare"], False)

    def test_large_white_window_accepts_exterior_arched_frame_family(self):
        windows = bundle(EXPANDED, "KnoxBuildworks/definitions/windows.json")
        window = find(windows, "kbw.vanillaexpanded.windows.wooden.large_white_windoww")
        supports = window["placement"]["windowSupportSprites"]
        self.assertIn("walls_exterior_house_03_*", supports)

    def test_square_bathroom_rug_uses_native_grid_order(self):
        rug = find(
            bundle(EXPANDED, "KnoxBuildworks/definitions/decorations/rugs.json"),
            "kbw.vanillaexpanded.decorations.rugs.floors_rugs_01_53",
        )
        faces = rug["stages"][0]["geometry"]["faces"]
        self.assertEqual(faces["W"]["layers"][0]["rows"], [["floors_rugs_01_52", "floors_rugs_01_53"]])
        self.assertEqual(faces["N"]["layers"][0]["rows"], [["floors_rugs_01_55"], ["floors_rugs_01_54"]])

    def test_roof_slope_five_has_full_finish_set(self):
        walls = bundle(EXPANDED, "KnoxBuildworks/definitions/walls/white_clapboard.json")
        slope = find(
            walls,
            "kbw.vanillaexpanded.walls.white_clapboard.white_clapboard_roof_slope_wall_5",
        )
        paints = slope["finishes"]["mapping"]["directPaints"]
        self.assertEqual(
            set(paints),
            {"PaintWhite", "PaintBlue", "PaintBrown", "PaintLightBrown", "PaintPink", "PaintTurquoise"},
        )
        for mapping in paints.values():
            self.assertEqual(set(mapping), {"W", "N"})

    def test_water_well_accepts_bucket_tag(self):
        survival = bundle(EXPANDED, "KnoxBuildworks/definitions/survival.json")
        well = find(survival, "kbw.vanillaexpanded.survival.water_well.water_well")
        inputs = well["stages"][0]["requirements"]["inputs"]
        bucket = next(row for row in inputs if row["id"] == "well_bucket")
        self.assertEqual(bucket["tags"], ["base:bucket"])
        self.assertNotIn("items", bucket)

    def test_white_clapboard_accepts_matching_vanilla_frame(self):
        walls = bundle(EXPANDED, "KnoxBuildworks/definitions/walls/white_wide_clapboard.json")
        for buildable in walls[:5]:
            self.assertEqual(
                buildable["stages"][0]["previousStage"],
                ["WoodenWallFrame", "MetalWallFrame"],
            )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("""
            function require() return {} end
            function instanceof(object, className)
                return className == 'IsoThumpable' and object.thumpable == true
            end
        """)
        lua.globals().placement = lua.execute(
            (CORE / "lua/shared/KnoxBuildworks/Validation/Placement.lua").read_text(encoding="utf-8-sig")
        )
        lua.execute("""
            local frame={thumpable=true, getName=function() return 'WoodenWallFrame' end,
                getNorth=function() return true end, getModData=function() return {} end}
            local objects={size=function() return 1 end, get=function() return frame end}
            local square={getSpecialObjects=function() return objects end}
            local stages={'WoodenWallFrame','MetalWallFrame'}
            assert(placement.findPrevious(square,'white_wide_clapboard_wall',stages,true)==frame)
            assert(placement.findPrevious(square,'white_wide_clapboard_wall',stages,false)==nil)
        """)

    def test_wall_bin_and_vault_are_decorations(self):
        cases = (
            (
                "KnoxBuildworks/definitions/containers/lockers.json",
                "kbw.vanillaexpanded.containers.lockers.location_business_bank_01_40",
            ),
            (
                "KnoxBuildworks/definitions/containers/metal_containers.json",
                "kbw.vanillaexpanded.containers.metal_containers.trashcontainers_01_32",
            ),
        )
        for relative, buildable_id in cases:
            item = find(bundle(EXPANDED, relative), buildable_id)
            self.assertEqual((item["category"], item["subcategory"]), ("Decorations", "Wall Decorations"))
            self.assertNotIn("container", item["stages"][0]["object"])

    def test_cut_only_and_doorwall_openings_remain_passable(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("""
            IsoFlagType={solid='solid',solidtrans='solidtrans',cutN='cutN',cutW='cutW',
                collideN='collideN',collideW='collideW',WallN='WallN',WallW='WallW',WallNW='WallNW',
                WindowN='WindowN',WindowW='WindowW',HoppableN='HoppableN',HoppableW='HoppableW',
                doorN='doorN',doorW='doorW',DoorWallN='DoorWallN',DoorWallW='DoorWallW'}
            sprites={}
            function sprite(flags)
                local values={}
                for i=1,#flags do values[flags[i]]=true end
                return {getProperties=function() return {has=function(_,flag) return values[flag]==true end} end}
            end
            function getSprite(name) return sprites[name] end
            sprites.openN=sprite({'cutN','DoorWallN'})
            sprites.openW=sprite({'cutW','DoorWallW'})
            sprites.solid=sprite({'cutN','solid'})
            sprites.wall=sprite({'cutN','WallN'})
            sprites.window=sprite({'cutN','WindowN'})
            sprites.door=sprite({'cutN','doorN'})
        """)
        collision = lua.execute(
            (CORE / "lua/shared/KnoxBuildworks/World/Collision.lua").read_text(encoding="utf-8-sig")
        )
        lua.globals().collision = collision
        lua.execute("""
            assert(collision.isPassableOpening('openN',true))
            assert(collision.isPassableOpening('openW',false))
            assert(not collision.isPassableOpening('openN',false))
            assert(not collision.isPassableOpening('solid',true))
            assert(not collision.isPassableOpening('wall',true))
            assert(not collision.isPassableOpening('window',true))
            assert(not collision.isPassableOpening('door',true))
        """)

    def test_full_height_arches_are_open_and_shape_three_four_windows_match_their_face(self):
        walls = bundle(EXPANDED, "KnoxBuildworks/definitions/walls/family_window_walls.json")
        arches = [b for b in walls if "Arched Full Height Window Wall" in b.get("displayName", "")
                  and b["stages"][0]["geometry"]["faces"]["W"]["layers"][0]["rows"][0][0]
                  .startswith(("walls_interior_house_16_", "walls_interior_house_18_"))]
        self.assertEqual(10, len(arches))
        for arch in arches:
            config = arch["stages"][0]["object"]
            self.assertTrue(config["canPassThrough"])
            self.assertFalse(config["blockAllSquare"])

        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("""
            function require() return {} end
            IsoFlagType=setmetatable({}, {__index=function(_,key) return key end})
            IsoPropertyType=setmetatable({}, {__index=function(_,key) return key end})
            function instanceof() return false end
            local function list(items)
                return {size=function() return #items end,get=function(_,index) return items[index+1] end}
            end
            function arch(name,shape)
                local properties={has=function(_,flag) return flag=='WallSE' end,
                    get=function(_,key) return key=='WindowShape' and shape or nil end}
                local sprite={getName=function() return name end,getProperties=function() return properties end}
                return {getSprite=function() return sprite end}
            end
            function square(object)
                return {getSpecialObjects=function() return list({}) end,
                    getObjects=function() return list({object}) end}
            end
        """)
        lua.globals().placement = lua.execute(
            (CORE / "lua/shared/KnoxBuildworks/Validation/Placement.lua").read_text(encoding="utf-8-sig")
        )
        lua.execute("""
            assert(placement.hasWallFrame(square(arch('walls_interior_house_18_4','3')),false,true,nil,'3'))
            assert(not placement.hasWallFrame(square(arch('walls_interior_house_18_4','3')),true,true,nil,'3'))
            assert(placement.hasWallFrame(square(arch('walls_interior_house_18_5','3')),true,true,nil,'3'))
            assert(not placement.hasWallFrame(square(arch('walls_interior_house_18_5','3')),false,true,nil,'3'))
            assert(not placement.hasWallFrame(square(arch('walls_interior_house_18_5','3')),true,true,nil,'4'))
            assert(placement.hasWallFrame(square(arch('walls_interior_house_18_7','4')),true,true,nil,'4'))
        """)

    def test_planned_arch_and_window_of_same_shape_can_share_an_edge(self):
        lua = runtime()
        lua.execute("""
            IsoFlagType=setmetatable({}, {__index=function(_,key) return key end})
            IsoPropertyType=setmetatable({}, {__index=function(_,key) return key end})
            IsoObjectType={doorW=1,doorN=2,doorFrW=3,doorFrN=4}
            function getCell() return nil end
            local function sprite(name, flags, shape)
                local set={}; for i=1,#flags do set[flags[i]]=true end
                return {getName=function() return name end,getType=function() return 0 end,
                    getProperties=function() return {has=function(_,flag) return set[flag]==true end,
                        get=function(_,key) return key=='WindowShape' and shape or nil end} end}
            end
            local sprites={
                walls_interior_house_18_4=sprite('walls_interior_house_18_4',{'WallSE'},'3'),
                walls_interior_house_18_5=sprite('walls_interior_house_18_5',{'WallSE'},'3'),
                fixtures_windows_wood_4=sprite('fixtures_windows_wood_4',{'windowW'},'3'),
                fixtures_windows_wood_5=sprite('fixtures_windows_wood_5',{'windowN'},'3'),
                fixtures_windows_wood_6=sprite('fixtures_windows_wood_6',{'windowW'},'4')}
            function getSprite(name) return sprites[name] end
            local frame={id='arch',placement={kind='wall'},stages={{id='built',
                sprites={W='walls_interior_house_18_4',N='walls_interior_house_18_5'}}}}
            local window={id='pane',placement={kind='object',needWindowFrame=true},stages={{id='built',
                sprites={W='fixtures_windows_wood_4',N='fixtures_windows_wood_5'}}}}
            function resolve(id) return (id=='arch' and frame or window) end
            modules['KnoxBuildworks/Definitions/Resolver']={resolveStage=function(id)
                local d=resolve(id); return d,d.stages[1] end}
            modules['KnoxBuildworks/Definitions/StageConfig']={
                placement=function(d) return d.placement end,sprite=function() return {} end}
            modules['KnoxBuildworks/Geometry/Matrix']={getFaceCells=function() return nil end,
                getFaceSprite=function(stage,direction)
                return stage.sprites[(direction==2 or direction==4) and 'N' or 'W'] end}
        """)
        lua.globals().modules["KnoxBuildworks/Validation/Placement"] = lua.execute(
            (CORE / "lua/shared/KnoxBuildworks/Validation/Placement.lua").read_text(encoding="utf-8-sig")
        )
        lua.globals().blueprints = lua.execute(
            (CORE / "lua/shared/KnoxBuildworks/Planning/Blueprints.lua").read_text(encoding="utf-8-sig")
        )
        lua.execute("""
            local frameW={id='frame-w',buildableId='arch',stageId='built',x=1,y=2,z=0,direction=1}
            local paneW={id='pane-w',buildableId='pane',stageId='built',x=1,y=2,z=0,direction=1}
            assert(blueprints.hasRequiredFrame({}, {placements={frameW}}, paneW))
            assert(#blueprints.findIntersections({placements={frameW}},paneW)==0)
            local frameN={id='frame-n',buildableId='arch',stageId='built',x=1,y=2,z=0,direction=2}
            local paneN={id='pane-n',buildableId='pane',stageId='built',x=1,y=2,z=0,direction=2}
            assert(blueprints.hasRequiredFrame({}, {placements={frameN}}, paneN))
            assert(#blueprints.findIntersections({placements={frameN}},paneN)==0)
            assert(not blueprints.hasRequiredFrame({}, {placements={frameW}}, paneN))
        """)

    def test_new_report_paths_use_native_and_attached_object_behaviour(self):
        building = (CORE / "lua/server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua").read_text(
            encoding="utf-8-sig"
        )
        placement = (CORE / "lua/shared/KnoxBuildworks/Validation/Placement.lua").read_text(
            encoding="utf-8-sig"
        )
        client = (CORE / "lua/client/KnoxBuildworks/Client.lua").read_text(encoding="utf-8-sig")
        attached = (CORE / "lua/shared/KnoxBuildworks/World/AttachedSprites.lua").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn('"double_door_wall"', building)
        self.assertIn('or (o.canPassThrough == true and kind ~= "overlay" and kind ~= "floor")', building)
        self.assertIn("providesDoorFrame", building)
        self.assertIn("isDeclaredDoorFrame", placement)
        self.assertIn('placement.kind == "overlay" and placement.needToBeAgainstWall == true', building)
        self.assertIn('and isWallDecorationSprite(tile.sprite) then', building)
        self.assertIn("setAttachedAnimSprite", attached)
        self.assertIn("RemoveAttachedAnim", attached)
        self.assertIn('"RemoveAttachedSprite"', client)
        self.assertNotIn("lightSwitchContextMenu", client)
        self.assertIn("NativeObjectFactory.resolve(self.nativeObject, tile.sprite)", building)

    def test_dedicated_build_action_supplies_authoritative_player(self):
        building = (CORE / "lua/server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn("function KBWBuildingObject:refreshPlayerContext(authoritativePlayer)", building)
        self.assertIn("local runtimePlayer = authoritativePlayer or self.player", building)
        self.assertIn("self:refreshPlayerContext(action and action.character or nil)", building)

    def test_gather_area_scanner_unregisters_when_idle(self):
        pinned = (CORE / "lua/client/KnoxBuildworks/UI/PinnedRecipes.lua").read_text(encoding="utf-8-sig")
        ensure_panel = pinned[pinned.index("function PinnedRecipes.ensurePanel()") :]
        self.assertNotIn("Events.OnTick.Add(PinnedRecipes.updateAreaScans)", ensure_panel)
        self.assertIn("Events.OnTick.Add(PinnedRecipes.updateAreaScans)", pinned)
        self.assertIn("Events.OnTick.Remove(PinnedRecipes.updateAreaScans)", pinned)

    def test_planning_open_does_not_request_redundant_full_sync(self):
        planning = (CORE / "lua/client/KnoxBuildworks/UI/PlanningMode.lua").read_text(encoding="utf-8-sig")
        self.assertNotIn('"BPRequest"', planning)
        server = (CORE / "lua/server/KnoxBuildworks/Server.lua").read_text(encoding="utf-8-sig")
        self.assertIn("Blueprints.serverSyncAll(player)", server)

    def test_pinned_hud_removes_orphaned_recipe_order_entries(self):
        pinned = (CORE / "lua/client/KnoxBuildworks/UI/PinnedRecipes.lua").read_text(encoding="utf-8-sig")
        self.assertIn("if data.pinnedRecipes[key] == nil then", pinned)
        self.assertIn("table.remove(order, orderIndex)", pinned)

    def test_world_highlights_draw_in_the_persistent_world_pass(self):
        ghost = (CORE / "lua/client/KnoxBuildworks/Planning/GhostRenderer.lua").read_text(encoding="utf-8-sig")
        planner = (CORE / "lua/client/KnoxBuildworks/Planning/Planner.lua").read_text(encoding="utf-8-sig")
        self.assertNotIn("addAreaHighlightForPlayer(", ghost)
        self.assertIn("local areaQueue = {}", ghost)
        self.assertIn("GhostRenderer.PLAN_COLOR_DIM =", ghost)
        self.assertIn("function GhostRenderer.flushWorldAreaHighlights(playerIndex, throughZ)", ghost)
        self.assertNotIn("function GhostRenderer.flushAreaHighlights()", ghost)
        self.assertNotIn("lastAreaQueue", ghost)
        self.assertEqual(planner.count("Events.OnPostRender.Add(Planner.renderWorldPreview)"), 1)
        self.assertNotIn("Events.RenderOpaqueObjectsInWorld.Add", planner)
        self.assertNotIn("Events.OnPreUIDraw.Add", planner)

    def test_build_42_21_moveable_placement_passes_authoritative_character(self):
        building = (CORE / "lua/server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn("self.character, target, instanceItem(\"Base.Plank\"), tile.sprite", building)
        self.assertNotIn("placeMoveableInternal(target,", building)
        vanilla = k.kbw_paths.game_file("lua/shared/Moveables/ISMoveableSpriteProps.lua")
        if vanilla is not None:
            source = vanilla.read_text(encoding="utf-8-sig")
            self.assertIn("function ISMoveableSpriteProps:placeMoveableInternal(_character, _square, _item, _spriteName)", source)

    def test_single_tile_walls_record_consumed_materials_for_dismantling(self):
        building = (CORE / "lua/server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn("recordWallBuildMaterials(self, footprint)", building)
        self.assertIn('if StageConfig.placement(object.definition, object.stage).kind ~= "wall" then return end', building)
        self.assertIn('local key = "need:" .. fullType', building)
        self.assertIn("object.modData[key] = (object.modData[key] or 0) + 1", building)
        self.assertIn("buildUtil.setInfo(part, self)", building)
        start = building.index("local function recordWallBuildMaterials(object, footprint)")
        helper = building[start : building.index("\nend\n", start) + len("\nend\n")]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("StageConfig = { placement = function() return { kind = 'wall' } end }")
        lua.execute(helper + """
            local function recipe(items)
                return { getAllRecordedConsumedItems = function()
                    return {
                        size = function() return #items end,
                        get = function(_, index)
                            return { getFullType = function() return items[index + 1] end }
                        end
                    }
                end }
            end
            local wall = { dismantable = true, isProp = false, definition = {}, stage = {}, modData = {} }
            wall.craftRecipeData = recipe({ 'Base.Plank', 'Base.Plank', 'Base.Nails' })
            recordWallBuildMaterials(wall, { {} })
            assert(wall.modData['need:Base.Plank'] == 2)
            assert(wall.modData['need:Base.Nails'] == 1)
            wall.craftRecipeData = recipe({ 'Base.Plank' })
            recordWallBuildMaterials(wall, { {} })
            assert(wall.modData['need:Base.Plank'] == 1)
            assert(wall.modData['need:Base.Nails'] == nil)
            wall.modData = {}
            wall.isProp = true
            recordWallBuildMaterials(wall, { {} })
            assert(wall.modData['need:Base.Plank'] == nil)
        """)
        vanilla = k.kbw_paths.game_file("lua/shared/Moveables/ISMoveableSpriteProps.lua")
        if vanilla is not None:
            self.assertIn('object:hasBuildMaterials()', vanilla.read_text(encoding="utf-8-sig"))

    def test_entity_backed_builds_attach_at_construction(self):
        building = (CORE / "lua/server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn("EntityCompat.attach(part, self.stage, true)", building)
        self.assertFalse((CORE / "lua/shared/KnoxBuildworks/World/EntityRepair.lua").exists())

    def test_native_light_switch_is_refreshed_after_insertion(self):
        factory = (CORE / "lua/server/KnoxBuildworks/BuildingObjects/NativeObjectFactory.lua").read_text(
            encoding="utf-8-sig"
        )
        switch_start = factory.index('register("lightSwitch"')
        switch_end = factory.index('register("mannequin"', switch_start)
        switch = factory[switch_start:switch_end]
        self.assertIn("IsoLightSwitch.new", switch)
        self.assertIn("object:addLightSourceFromSprite()", switch)
        # A switch in a map room pushes the room state to clients; the old
        # setPower/update refresh did nothing for wall switches.
        self.assertIn("object:switchLight(object:isActivated())", switch)
        self.assertNotIn("setPower", switch)


if __name__ == "__main__":
    unittest.main()
