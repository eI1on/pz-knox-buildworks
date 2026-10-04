"""Regression checks for the concrete B42 player-report data fixes."""
import json
from pathlib import Path
import unittest

from lupa import LuaRuntime


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

    def test_world_highlights_flush_once_in_the_same_world_frame(self):
        ghost = (CORE / "lua/client/KnoxBuildworks/Planning/GhostRenderer.lua").read_text(encoding="utf-8-sig")
        planner = (CORE / "lua/client/KnoxBuildworks/Planning/Planner.lua").read_text(encoding="utf-8-sig")
        self.assertIn("addAreaHighlightForPlayer(", ghost)
        self.assertIn("local areaQueue = {}", ghost)
        self.assertIn("function GhostRenderer.flushWorldAreaHighlights()", ghost)
        self.assertNotIn("function GhostRenderer.flushAreaHighlights()", ghost)
        self.assertNotIn("lastAreaQueue", ghost)
        self.assertEqual(planner.count("Events.RenderOpaqueObjectsInWorld.Add"), 2)
        self.assertLess(planner.index("Planner.renderWorldPreview)"), planner.index("Planner.flushWorldHighlights)"))
        self.assertNotIn("Events.OnPreUIDraw.Add", planner)

    def test_build_42_21_moveable_placement_passes_authoritative_character(self):
        building = (CORE / "lua/server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn("self.character, target, instanceItem(\"Base.Plank\"), tile.sprite", building)
        self.assertNotIn("placeMoveableInternal(target,", building)
        vanilla = Path("D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua/shared/Moveables/ISMoveableSpriteProps.lua")
        if vanilla.exists():
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
        vanilla = Path("D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua/shared/Moveables/ISMoveableSpriteProps.lua")
        if vanilla.exists():
            self.assertIn('object:hasBuildMaterials()', vanilla.read_text(encoding="utf-8-sig"))

    def test_entity_backed_builds_have_stream_repair(self):
        repair = (CORE / "lua/shared/KnoxBuildworks/World/EntityRepair.lua").read_text(encoding="utf-8-sig")
        self.assertIn("EntityCompat.attach(object, stage, false)", repair)
        self.assertIn("Events.LoadGridsquare.Add", repair)
        self.assertIn("Events.OnObjectAdded.Add", repair)

    def test_native_light_switch_is_refreshed_after_insertion(self):
        factory = (CORE / "lua/server/KnoxBuildworks/BuildingObjects/NativeObjectFactory.lua").read_text(
            encoding="utf-8-sig"
        )
        switch_start = factory.index('register("lightSwitch"')
        switch_end = factory.index('register("mannequin"', switch_start)
        switch = factory[switch_start:switch_end]
        self.assertIn("IsoLightSwitch.new", switch)
        self.assertIn("object:addLightSourceFromSprite()", switch)
        self.assertIn("object:setPower(2)", switch)
        self.assertIn("object:update()", switch)


if __name__ == "__main__":
    unittest.main()
