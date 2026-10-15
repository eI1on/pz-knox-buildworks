"""Add the world pieces Building Capture found with no buildable.

Every piece below was reported by a capture of real map buildings
(Zomboid/Lua/KnoxBuildworks/captures/*.txt). Run from the repo root:

    python tools/add_world_pieces.py

Geometry comes from the game's tile definitions, read the way
IsoWorld.LoadTileDefinitions reads them (".patch.tiles" adds to a sprite, any
other file redefines it): every facing of a moveable group (same sheet,
CustomName and GroupName) becomes a face, tile Facing E/S/W/N -> Knox face
W/N/E/S, and SpriteGridPos "x,y" -> rows[y][x].

Requirements are never invented per piece. A piece either:
  * copies requirements, construction, object flags and native object from an
    existing Vanilla Expanded "analog" buildable of the same kind, so balancing
    matches the rest of the catalogue; or
  * is laid from the very item the tile names as CustomItem (the deer hide
    rug is the hide itself).
Pieces with no analog carry explicit inputs. Electronics (radios, TVs,
phones, appliances) are built from parts modelled on the base game's radio
recipes, never from the finished item - picking that up and placing it is
what the movables menu already does.

Re-running replaces the pieces it generated before; a sprite another
buildable already draws is an error, so nothing is defined twice.
"""
import copy
import json
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kbw_paths  # noqa: E402

ROOT = kbw_paths.ROOT
VE_MEDIA = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media"
DEFINITIONS = VE_MEDIA / "KnoxBuildworks/definitions"
MANIFEST = VE_MEDIA / "KnoxBuildworks/manifest.json"
NAMES = VE_MEDIA / "lua/shared/Translate/EN/IG_UI.json"
TOOLTIPS = VE_MEDIA / "lua/shared/Translate/EN/Tooltip.json"
MODS = ROOT / "Contents/mods"
VE = "kbw.vanillaexpanded."
GENERATED_TAG = "capture-gap"

TILE_FILES = [
    "newtiledefinitions.tiles", "tiledefinitions_erosion.tiles", "tiledefinitions_overlays.tiles",
    "tiledefinitions_b42chunkcaching.tiles", "tiledefinitions_noiseworks.patch.tiles",
    "jumbo_trees_big.tiles", "jumbo_trees.tiles",
]
FACE_FOR_FACING = {"E": "W", "S": "N", "W": "E", "N": "S"}
# Sprites of one moveable set sit within a few indices of each other.
SET_GAP = 8


def tool(id_, tags, flags=("Prop1", "MayDegradeVeryLight")):
    return {"id": id_, "role": "tool", "mode": "keep", "resourceType": "Item", "tags": list(tags), "amount": 1,
            "flags": list(flags)}


def item(id_, full_type, amount):
    return {"id": id_, "role": "material", "mode": "consume", "resourceType": "Item", "items": [full_type],
            "amount": amount}


def tagged(id_, tags, amount):
    return {"id": id_, "role": "material", "mode": "consume", "resourceType": "Item", "tags": list(tags),
            "amount": amount}


def component(id_, full_type, amount):
    return {"id": id_, "role": "component", "mode": "consume", "resourceType": "Item", "items": [full_type],
            "amount": amount}


def knowledge(recipe, source, alternative):
    """Learned from a magazine, or skilled enough to work it out."""
    return {"recipes": [recipe], "hideUntilLearned": True, "needToBeLearned": True,
            "sources": [{"type": "magazine", "item": source}],
            "skillAlternatives": [{"mode": "all", "skills": alternative}]}


def build_time(time, xp):
    return {"time": time, "timedAction": "BuildWallMetal", "completionSound": "BuildMetalStructureSmall",
            "canWalk": False, "category": "Electrical", "xp": xp}


SCREWDRIVER = tool("tool_screwdriver", ["base:screwdriver"])
HAMMER = tool("tool_hammer", ["base:hammer"])
PLIERS = tool("tool_pliers", ["base:pliers"], ("MayDegradeLight",))
WRENCH = tool("tool_wrench", ["base:wrench"])

# Electronics are built from parts, not placed from the finished item (that is
# what the movables menu is for). The parts follow the base game's own radio
# recipes (CraftMakeshiftRadio / CraftMakeshiftHAMRadio in recipes_radio.txt:
# receiver, transmitter, amplifier, bulbs, scrap, wire, aluminum), with more of
# them, a case, speakers and higher skill for a factory-made set. Knowledge is
# the same as the base game's: Radio magazines (or the Electricity level the
# game auto-learns those recipes at, plus one), and Knox's Home Appliances
# magazine for appliances, like the Vanilla Expanded fridges.
RADIO_KNOWLEDGE = knowledge("CraftMakeshiftRadio", "Base.RadioMag1", {"Electricity": 7})
HAM_KNOWLEDGE = knowledge("CraftMakeshiftHAMRadio", "Base.RadioMag3", {"Electricity": 9})
APPLIANCE_KNOWLEDGE = knowledge("KBWKnowledge_PopularMechanics_HomeAppliances",
                                "KnoxBuildworks.PopularMechanics_HomeAppliances", {"Electricity": 7})
ON_FLOOR = {"kind": "object", "requiresFloor": True}
ON_WALL = {"kind": "object", "needToBeAgainstWall": True, "requiresFloor": False}
# No lamp template: its own screwdriver row, lighting tags and Lighting
# magazine must not ride along.
ELECTRONIC = dict(extends=None, material="Electronics", materialTags=["Electronics", "Metal"],
                  tags=["vanilla-b42", "electrical"])

# fmt: off
PIECES = [
    # Lighting -----------------------------------------------------------------
    dict(file="lighting", key="black_table_lamp", name="Black Table Lamp", seed="lighting_indoor_02_10",
         analog=VE + "lighting.indoor.gray_lamp", sub="Table Lamps"),
    dict(file="lighting", key="grey_table_lamp", name="Grey Table Lamp", seed="lighting_indoor_02_2",
         analog=VE + "lighting.indoor.gray_lamp", sub="Table Lamps"),
    dict(file="lighting", key="blue_table_lamp", name="Blue Table Lamp", seed="lighting_indoor_02_26",
         analog=VE + "lighting.indoor.gray_lamp", sub="Table Lamps"),
    dict(file="lighting", key="fluorescent_wall_light", name="Fluorescent Wall Light", seed="lighting_indoor_02_44",
         analog=VE + "lighting.indoor.pink_wall_lamp", sub="Wall Lights"),
    dict(file="lighting", key="modern_outdoor_lamp", name="Modern Outdoor Wall Lamp", seed="lighting_outdoor_01_32",
         analog=VE + "lighting.indoor.pink_wall_lamp", sub="Outdoor Lights"),
    dict(file="lighting", key="oval_outdoor_lamp", name="Oval Outdoor Wall Lamp", seed="lighting_outdoor_01_41",
         analog=VE + "lighting.indoor.pink_wall_lamp", sub="Outdoor Lights"),
    # Appliances ---------------------------------------------------------------
    dict(file="appliances", key="valutech_radio", name="ValuTech Radio", seed="appliances_radio_01_0",
         analog=VE + "lighting.indoor.gray_lamp", native="radio", category="Appliances", sub="Radios & TVs",
         tooltip="Tooltip_KBWVE_World_Radio", placement=ON_FLOOR, knowledge=RADIO_KNOWLEDGE,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False},
         construction=build_time(400, {"Electricity": 25}),
         inputs=[SCREWDRIVER, PLIERS, component("radio_receiver", "Base.RadioReceiver", 1),
                 component("amplifier", "Base.Amplifier", 1), component("speaker", "Base.Speaker", 1),
                 component("light_bulb", "Base.LightBulb", 1), item("electronics", "Base.ElectronicsScrap", 6),
                 item("electric_wire", "Base.ElectricWire", 3), tagged("aluminum", ["base:aluminum"], 2),
                 item("sheet_metal", "Base.SmallSheetMetal", 1), item("screws", "Base.Screws", 6)],
         skills={"Electricity": 5}, **ELECTRONIC),
    dict(file="appliances", key="army_ham_radio", name="US Army Ham Radio", seed="appliances_com_01_8",
         analog=VE + "lighting.indoor.gray_lamp", native="radio", category="Appliances", sub="Radios & TVs",
         tooltip="Tooltip_KBWVE_World_HamRadio", placement=ON_FLOOR, knowledge=HAM_KNOWLEDGE,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False},
         construction=build_time(600, {"Electricity": 40}),
         inputs=[SCREWDRIVER, PLIERS, component("radio_receiver", "Base.RadioReceiver", 1),
                 component("radio_transmitter", "Base.RadioTransmitter", 1), component("amplifier", "Base.Amplifier", 1),
                 component("speaker", "Base.Speaker", 1), component("microphone", "Base.Microphone", 1),
                 component("light_bulb", "Base.LightBulb", 1), component("light_bulb_green", "Base.LightBulbGreen", 1),
                 item("electronics", "Base.ElectronicsScrap", 10), item("electric_wire", "Base.ElectricWire", 5),
                 tagged("aluminum", ["base:aluminum"], 4), item("sheet_metal", "Base.SmallSheetMetal", 2),
                 item("screws", "Base.Screws", 8)],
         skills={"Electricity": 7}, **ELECTRONIC),
    dict(file="appliances", key="premium_ham_radio", name="Premium Technologies Ham Radio", seed="appliances_com_01_7",
         analog=VE + "lighting.indoor.gray_lamp", native="radio", category="Appliances", sub="Radios & TVs",
         tooltip="Tooltip_KBWVE_World_HamRadio", placement=ON_FLOOR, knowledge=HAM_KNOWLEDGE,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False},
         construction=build_time(600, {"Electricity": 40}), faces={"N": [["appliances_com_01_7"]]},
         inputs=[SCREWDRIVER, PLIERS, component("radio_receiver", "Base.RadioReceiver", 1),
                 component("radio_transmitter", "Base.RadioTransmitter", 1), component("amplifier", "Base.Amplifier", 1),
                 component("speaker", "Base.Speaker", 1), component("microphone", "Base.Microphone", 1),
                 component("light_bulb", "Base.LightBulb", 1), component("light_bulb_green", "Base.LightBulbGreen", 1),
                 item("electronics", "Base.ElectronicsScrap", 10), item("electric_wire", "Base.ElectricWire", 5),
                 tagged("aluminum", ["base:aluminum"], 4), item("sheet_metal", "Base.SmallSheetMetal", 2),
                 item("screws", "Base.Screws", 8)],
         skills={"Electricity": 7}, **ELECTRONIC),
    dict(file="appliances", key="valutech_television", name="ValuTech Television", seed="appliances_television_01_4",
         analog=VE + "lighting.indoor.gray_lamp", native="television", category="Appliances", sub="Radios & TVs",
         tooltip="Tooltip_KBWVE_World_Television", placement=ON_FLOOR, knowledge=RADIO_KNOWLEDGE,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False},
         construction=build_time(500, {"Electricity": 30}),
         inputs=[SCREWDRIVER, PLIERS, component("radio_receiver", "Base.RadioReceiver", 1),
                 component("amplifier", "Base.Amplifier", 1), component("speaker", "Base.Speaker", 2),
                 component("screen", "Base.GlassPanel", 1), component("light_bulb", "Base.LightBulb", 1),
                 item("electronics", "Base.ElectronicsScrap", 12), item("electric_wire", "Base.ElectricWire", 4),
                 tagged("aluminum", ["base:aluminum"], 3), item("sheet_metal", "Base.SmallSheetMetal", 2),
                 item("screws", "Base.Screws", 8)],
         skills={"Electricity": 6}, **ELECTRONIC),
    dict(file="appliances", key="tv_antenna", name="Rooftop TV Antenna", seed="appliances_com_01_81",
         analog=VE + "lighting.indoor.gray_lamp", native=None, category="Appliances", sub="Radios & TVs",
         tooltip="Tooltip_KBWVE_World_Antenna", placement=ON_FLOOR, knowledge=None,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False},
         construction=build_time(300, {"Electricity": 15}),
         inputs=[SCREWDRIVER, PLIERS, item("metal_bars", "Base.MetalBar", 2), tagged("aluminum", ["base:aluminum"], 3),
                 item("electronics", "Base.ElectronicsScrap", 1), item("electric_wire", "Base.ElectricWire", 3),
                 item("screws", "Base.Screws", 4)],
         skills={"Electricity": 3}, **ELECTRONIC),
    dict(file="appliances", key="coffee_machine", name="X-press Coffee Machine", seed="appliances_cooking_01_57",
         analog=VE + "lighting.indoor.gray_lamp", native="stove", category="Appliances", sub="Kitchen Appliances",
         tooltip="Tooltip_KBWVE_World_CoffeeMachine", placement=ON_FLOOR, knowledge=APPLIANCE_KNOWLEDGE,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False},
         construction=build_time(350, {"Electricity": 20}),
         inputs=[SCREWDRIVER, PLIERS, component("light_bulb", "Base.LightBulb", 1),
                 item("electronics", "Base.ElectronicsScrap", 5), item("electric_wire", "Base.ElectricWire", 3),
                 item("sheet_metal", "Base.SmallSheetMetal", 2), component("rubber_seal", "KnoxBuildworks.RubberSeal", 1),
                 item("screws", "Base.Screws", 6)],
         skills={"Electricity": 4}, **ELECTRONIC),
    dict(file="appliances", key="water_dispenser", name="Water Dispenser", seed="location_business_office_generic_01_48",
         analog=VE + "lighting.indoor.gray_lamp", native=None, category="Appliances", sub="Kitchen Appliances",
         tooltip="Tooltip_KBWVE_World_WaterDispenser", placement=ON_FLOOR, knowledge=APPLIANCE_KNOWLEDGE,
         object={"isProp": True, "dismantable": True, "blockAllSquare": True},
         construction=build_time(350, {"Electricity": 20}),
         inputs=[SCREWDRIVER, PLIERS, component("dispenser_bottle", "Base.WaterDispenserBottle", 1),
                 component("rubber_tube", "KnoxBuildworks.SmallRubberTube", 1),
                 item("electronics", "Base.ElectronicsScrap", 3), item("electric_wire", "Base.ElectricWire", 2),
                 item("sheet_metal", "Base.SmallSheetMetal", 3), item("screws", "Base.Screws", 6)],
         skills={"Electricity": 3}, **ELECTRONIC),
    dict(file="appliances", key="modern_phone", name="White Modern Telephone", seed="location_business_office_generic_02_17",
         analog=VE + "lighting.indoor.gray_lamp", native=None, category="Appliances", sub="Radios & TVs",
         tooltip="Tooltip_KBWVE_World_Telephone", placement=ON_FLOOR, knowledge=None,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False},
         construction=build_time(250, {"Electricity": 15}),
         inputs=[SCREWDRIVER, PLIERS, component("microphone", "Base.Microphone", 1), component("speaker", "Base.Speaker", 1),
                 item("electronics", "Base.ElectronicsScrap", 3), item("electric_wire", "Base.ElectricWire", 2),
                 item("screws", "Base.Screws", 2)],
         skills={"Electricity": 3}, **ELECTRONIC),
    dict(file="appliances", key="air_conditioner", name="Wall Air Conditioner", seed="rooftop_furniture_34",
         analog=VE + "lighting.indoor.pink_wall_lamp", native=None, category="Appliances", sub="Climate",
         tooltip="Tooltip_KBWVE_World_AirConditioner", placement=ON_WALL, knowledge=APPLIANCE_KNOWLEDGE,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False, "canPassThrough": True},
         construction=build_time(700, {"Electricity": 30, "MetalWelding": 15}),
         inputs=[SCREWDRIVER, WRENCH, component("compressor", "KnoxBuildworks.RefrigeratorCompressor", 1),
                 {"id": "refrigerant", "role": "component", "mode": "drain", "resourceType": "Item",
                  "items": ["KnoxBuildworks.RefrigerantBottle"], "amount": 1, "uses": 2},
                 component("copper_pipe", "KnoxBuildworks.ThinCopperPipe", 2),
                 item("sheet_metal", "Base.SheetMetal", 2), item("small_sheet_metal", "Base.SmallSheetMetal", 2),
                 item("electronics", "Base.ElectronicsScrap", 6), item("electric_wire", "Base.ElectricWire", 3),
                 item("screws", "Base.Screws", 10)],
         skills={"Electricity": 5, "MetalWelding": 3}, **ELECTRONIC),
    dict(file="appliances", key="pay_phone", name="Pay Phone", seed="street_decoration_01_38",
         analog=VE + "lighting.indoor.pink_wall_lamp", native=None, category="Appliances", sub="Radios & TVs",
         tooltip="Tooltip_KBWVE_World_Telephone", placement=ON_WALL, knowledge=None,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False, "canPassThrough": True},
         construction=build_time(450, {"Electricity": 25}),
         inputs=[SCREWDRIVER, PLIERS, component("microphone", "Base.Microphone", 1), component("speaker", "Base.Speaker", 1),
                 item("electronics", "Base.ElectronicsScrap", 6), item("electric_wire", "Base.ElectricWire", 3),
                 item("sheet_metal", "Base.SheetMetal", 1), item("small_sheet_metal", "Base.SmallSheetMetal", 2),
                 item("screws", "Base.Screws", 8)],
         skills={"Electricity": 4}, **ELECTRONIC),
    # Furniture ----------------------------------------------------------------
    dict(file="furniture", key="wooden_chair", name="Wooden Chair", seed="furniture_seating_indoor_02_5",
         analog=VE + "furniture.chairs.furniture_seating_indoor_02_12", tooltip="Tooltip_KBWVE_World_WoodenChair",
         inputs=[HAMMER, item("lumber", "Base.Plank", 3), item("fasteners_nails", "Base.Nails", 4)],
         skills={"Woodwork": 2}),
    dict(file="furniture", key="plastic_chair", name="Plastic Chair", seed="furniture_seating_outdoor_01_16",
         analog=VE + "furniture.chairs.furniture_seating_indoor_02_12",
         inputs=[HAMMER, item("plastic_sheet", "KnoxBuildworks.PlasticSheet", 2), item("screws", "Base.Screws", 2)],
         skills={"Woodwork": 1}),
    dict(file="furniture", key="office_desk", name="Office Desk", seed="location_business_office_generic_01_42",
         analog=VE + "furniture.large_tables.location_business_office_generic_01_43", category="Furniture",
         sub="Desks"),
    dict(file="furniture", key="cardboard_box", name="Cardboard Box", seed="trashcontainers_01_24",
         analog=VE + "containers.crates.trashcontainers_01_26"),
    dict(file="furniture", key="empty_pallet", name="Empty Pallet", seed="construction_01_5",
         analog=VE + "containers.crates.location_shop_greenes_01_35", category="Furniture", sub="Pallets",
         tooltip="Tooltip_KBWVE_World_Pallet",
         inputs=[HAMMER, item("lumber", "Base.Plank", 3), item("fasteners_nails", "Base.Nails", 6)],
         skills={"Woodwork": 1}, faces={"N": [["construction_01_5"]]}),
    dict(file="furniture", key="brick_pallet", name="Pallet With Bricks", seed="construction_01_4",
         analog=VE + "containers.crates.location_shop_greenes_01_35", category="Furniture", sub="Pallets",
         tooltip="Tooltip_KBWVE_World_Pallet",
         inputs=[HAMMER, item("lumber", "Base.Plank", 3), item("fasteners_nails", "Base.Nails", 6),
                 item("clay_bricks", "Base.ClayBrick", 12)],
         skills={"Woodwork": 1}, faces={"N": [["construction_01_4"]]}),
    # Wall and floor decor -----------------------------------------------------
    dict(file="decor", key="deer_trophy", name="Mounted Deer Trophy", seed="camping_01_17",
         analog=VE + "containers.wall_cabinets.wall_cabinet_oakwood", category="Decorations", sub="Wall Decor",
         tooltip="Tooltip_KBWVE_World_WallDecor", object={"isThumpable": False, "canPassThrough": True, "blockAllSquare": False},
         inputs=[HAMMER, item("lumber", "Base.Plank", 1), item("fasteners_nails", "Base.Nails", 2),
                 item("hide", "Base.DeerLeather_Fur_Tan", 1)],
         skills={"Woodwork": 2}),
    dict(file="decor", key="deer_hide_rug", name="Dapple Deer Hide Rug", seed="rugs_animals_2",
         analog=VE + "decorations.rugs.floors_rugs_01_0", fromItem=True, category="Decorations", sub="Rugs"),
    dict(file="decor", key="first_aid_cabinet", name="First Aid Wall Cabinet", seed="location_community_medical_01_88",
         analog=VE + "containers.wall_cabinets.wall_cabinet_oakwood", sub="Wall Cabinets",
         inputs=[HAMMER, SCREWDRIVER, item("lumber", "Base.Plank", 3), item("fasteners_screws", "Base.Screws", 4),
                 item("mirror", "Base.Mirror", 1)]),
    dict(file="decor", key="usa_map", name="Map of the USA", seed="location_community_school_01_22",
         analog=VE + "decorations.posters.walls_decoration_01_32", sub="Posters & Paintings"),
    dict(file="decor", key="usa_flag", name="Stars and Stripes Flag", seed="walls_decoration_01_17",
         analog=VE + "decorations.posters.walls_decoration_01_65", sub="Flags & Bunting"),
    dict(file="decor", key="large_mirror", name="Large Wall Mirror", seed="walls_decoration_01_5",
         analog=VE + "decorations.posters.walls_decoration_01_32", sub="Mirrors",
         tooltip="Tooltip_KBWVE_World_WallDecor",
         inputs=[HAMMER, item("lumber", "Base.Plank", 1), item("fasteners_nails", "Base.Nails", 2), item("mirror", "Base.Mirror", 1)],
         skills={"Woodwork": 1}),
    dict(file="decor", key="lakeside_painting", name="Lakeside Painting", seed="walls_decoration_01_52",
         analog=VE + "decorations.posters.walls_decoration_01_32", sub="Posters & Paintings"),
    dict(file="decor", key="framed_picture_1", name="Framed Picture (Style 1)", seed="walls_decoration_02_16",
         analog=VE + "decorations.posters.walls_decoration_01_32", sub="Posters & Paintings",
         faces={"N": [["walls_decoration_02_16"]]}),
    dict(file="decor", key="framed_picture_2", name="Framed Picture (Style 2)", seed="walls_decoration_02_17",
         analog=VE + "decorations.posters.walls_decoration_01_32", sub="Posters & Paintings",
         faces={"N": [["walls_decoration_02_17"]]}),
    dict(file="decor", key="framed_picture_3", name="Framed Picture (Style 3)", seed="walls_decoration_02_24",
         analog=VE + "decorations.posters.walls_decoration_01_32", sub="Posters & Paintings",
         faces={"W": [["walls_decoration_02_24"]]}),
    dict(file="decor", key="framed_picture_4", name="Framed Picture (Style 4)", seed="walls_decoration_02_25",
         analog=VE + "decorations.posters.walls_decoration_01_32", sub="Posters & Paintings",
         faces={"W": [["walls_decoration_02_25"]]}),
    dict(file="decor", key="framed_picture_5", name="Framed Picture (Style 5)", seed="walls_decoration_02_28",
         analog=VE + "decorations.posters.walls_decoration_01_32", sub="Posters & Paintings",
         faces={"W": [["walls_decoration_02_28"]]}),
    dict(file="decor", key="ranger_station_sign", name="Ranger Station Sign", seed="signs_one-off_08_269",
         analog=VE + "containers.crates.location_shop_greenes_01_35", category="Decorations", sub="Signs",
         tooltip="Tooltip_KBWVE_World_Sign", object={"blockAllSquare": True},
         inputs=[HAMMER, tool("tool_paintbrush", ["base:paintbrush"], ()), item("lumber", "Base.Plank", 4),
                 item("fasteners_nails", "Base.Nails", 6),
                 {"id": "finish_paint", "role": "consumable", "mode": "drain", "resourceType": "Item",
                  "items": ["Base.PaintBrown"], "amount": 1, "uses": 2}],
         skills={"Woodwork": 2}, faces={"N": [["signs_one-off_08_269", "signs_one-off_08_270"]]}),
    # Construction pieces ------------------------------------------------------
    dict(file="construction", key="attic_floorboards", name="Attic Floorboards", seed="ceilings_01_0",
         analog=VE + "floors.wooden.floors_interior_tilesandwood_01_41", sub="Attic Floors",
         tooltip="Tooltip_KBWVE_World_AtticFloor", faces={"N": [["ceilings_01_0"]]}),
    dict(file="construction", key="white_baseboard_2", name="White Baseboard (Style 2)", seed="walls_interior_detailing_01_12",
         analog=VE + "architecture_plus.floor_molding.white_simple_trim",
         faces={"W": [["walls_interior_detailing_01_12"]], "N": [["walls_interior_detailing_01_13"]]}),
    dict(file="construction", key="wooden_fascia_board", name="Wooden Fascia Board", seed="industry_01_29",
         analog=VE + "roofing.roof_accents.fascia_top",
         faces={"N": [["industry_01_29"]], "W": [["industry_01_30"]]}),
    dict(file="construction", key="trailer_wall_panel", name="Trailer Wall Panel", seed="location_trailer_01_4",
         analog=VE + "architecture_plus.wall_panels.white_wood_panneling", faces={"W": [["location_trailer_01_4"]]}),
    dict(file="construction", key="chimney_pots", name="Chimney Pots", seed="fixtures_fireplaces_01_72",
         analog=VE + "survival.chimney.orange_brick", tooltip="Tooltip_KBWVE_World_ChimneyPots",
         faces={"N": [["fixtures_fireplaces_01_72"]]}),
    dict(file="construction", key="wooden_post", name="Wooden Post", seed="carpentry_02_103",
         analog=VE + "containers.crates.location_shop_greenes_01_35", category="Structural", sub="Posts",
         tooltip="Tooltip_KBWVE_World_WoodenPost", object={"blockAllSquare": False, "canPassThrough": False},
         inputs=[HAMMER, item("lumber", "Base.Plank", 1), item("fasteners_nails", "Base.Nails", 2)],
         skills={"Woodwork": 1}, faces={"N": [["carpentry_02_103"]]}),
    dict(file="construction", key="curb_edge", name="Curb Edge", seed="street_curbs_01_43",
         analog=VE + "road_work.sidewalk_edge.sidewalk_edge", faces={"N": [["street_curbs_01_43"]]}),
    dict(file="construction", key="pipe_stack", name="Stacked Steel Pipes", seed="industry_01_43",
         analog=VE + "containers.crates.location_shop_greenes_01_35", category="Structural", sub="Industrial",
         tooltip="Tooltip_KBWVE_World_Pipes", object={"blockAllSquare": True},
         inputs=[item("metal_pipe", "Base.MetalPipe", 6)], skills={}, knowledge=None,
         faces={"W": [["industry_01_43"]], "N": [["industry_01_45"]]}),
    dict(file="construction", key="pipe_pile", name="Steel Pipe Pile", seed="industry_01_44",
         analog=VE + "containers.crates.location_shop_greenes_01_35", category="Structural", sub="Industrial",
         tooltip="Tooltip_KBWVE_World_Pipes", object={"blockAllSquare": True},
         inputs=[item("metal_pipe", "Base.MetalPipe", 4)], skills={}, knowledge=None,
         faces={"N": [["industry_01_44"]]}),
    dict(file="construction", key="wall_cables", name="Wall Cables", seed="industry_02_209",
         analog=VE + "lighting.indoor.pink_wall_lamp", category="Structural", sub="Industrial",
         tooltip="Tooltip_KBWVE_World_Cables", native=None,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False, "canPassThrough": True},
         placement=ON_WALL, knowledge=None, construction=build_time(200, {"Electricity": 10}),
         inputs=[SCREWDRIVER, PLIERS, item("electric_wire", "Base.ElectricWire", 4), item("screws", "Base.Screws", 2)],
         skills={"Electricity": 2}, faces={"W": [["industry_02_209"]]}, **ELECTRONIC),
    dict(file="construction", key="junction_box", name="Electrical Junction Box", seed="industry_02_221",
         analog=VE + "lighting.indoor.pink_wall_lamp", category="Structural", sub="Industrial",
         tooltip="Tooltip_KBWVE_World_Cables", native=None,
         object={"isProp": True, "dismantable": True, "blockAllSquare": False, "canPassThrough": True},
         placement=ON_WALL, knowledge=None, construction=build_time(250, {"Electricity": 15}),
         inputs=[SCREWDRIVER, PLIERS, item("electronics", "Base.ElectronicsScrap", 3), item("electric_wire", "Base.ElectricWire", 3),
                 item("sheet_metal", "Base.SmallSheetMetal", 1), item("screws", "Base.Screws", 4)],
         skills={"Electricity": 3}, faces={"W": [["industry_02_221"]]}, **ELECTRONIC),
    dict(file="construction", key="drainpipe", name="Metal Drainpipe", seed="industry_02_238",
         analog=VE + "roofing.roof_accents.downpipe_shoe", faces={"N": [["industry_02_238"]]}),
    dict(file="construction", key="drainpipe_elbow", name="Metal Drainpipe Elbow", seed="industry_02_260",
         analog=VE + "roofing.roof_accents.downpipe_shoe", faces={"N": [["industry_02_260"]]}),
    dict(file="construction", key="rusty_pipe", name="Rusty Standing Pipe", seed="industry_02_34",
         analog=VE + "roofing.roof_accents.downpipe_shoe", faces={"N": [["industry_02_34"]]}),
]
# fmt: on

TOOLTIP_TEXT = {
    "Tooltip_KBWVE_World_Radio": "A working table radio, assembled from a receiver, an amplifier, a speaker and spare electronics. It receives broadcasts like any radio found in the world.",
    "Tooltip_KBWVE_World_HamRadio": "A working ham radio set that transmits as well as receives, built around a receiver, a transmitter and a microphone.",
    "Tooltip_KBWVE_World_Television": "A working television, assembled from a receiver, speakers and a glass screen.",
    "Tooltip_KBWVE_World_Antenna": "A rooftop television antenna on a two-tile mast.",
    "Tooltip_KBWVE_World_CoffeeMachine": "A countertop coffee machine that heats like the world's own coffee makers.",
    "Tooltip_KBWVE_World_WaterDispenser": "An office water dispenser built around a water dispenser bottle.",
    "Tooltip_KBWVE_World_Telephone": "A wired telephone for decoration.",
    "Tooltip_KBWVE_World_AirConditioner": "A wall-mounted air conditioning unit.",
    "Tooltip_KBWVE_World_Pallet": "A wooden shipping pallet, as found on building sites.",
    "Tooltip_KBWVE_World_WallDecor": "A wall decoration mounted on a wooden backing board.",
    "Tooltip_KBWVE_World_Sign": "A freestanding two-tile wooden sign.",
    "Tooltip_KBWVE_World_AtticFloor": "Plain boards laid over the ceiling joists of an attic or upper storey.",
    "Tooltip_KBWVE_World_ChimneyPots": "Clay chimney pots set on top of a chimney stack.",
    "Tooltip_KBWVE_World_WoodenPost": "A thin upright wooden post.",
    "Tooltip_KBWVE_World_Pipes": "Spare steel pipes stacked on the ground.",
    "Tooltip_KBWVE_World_WoodenChair": "A plain wooden chair, nailed together from planks.",
    "Tooltip_KBWVE_World_Cables": "Exposed electrical wiring fixed to a wall.",
}

WINDOW_SHAPES = [
    "arched_window_wall_1", "arched_window_wall_2", "arched_full_window_wall_1", "arched_full_window_wall_2",
    "square_window_wall_1", "square_window_wall_2", "square_window_wall_3", "full_window_wall",
    "framed_window_wall_1", "framed_window_wall_2", "double_door_wall_1", "double_door_wall_2",
    "wide_window_wall_1", "wide_window_wall_2", "wide_window_wall_3", "round_window_wall",
]


def read_tiles():
    """Sprite name -> properties, with the game's load order and patch rule."""
    media = kbw_paths.GAME_MEDIA
    if media is None:
        sys.exit("PZ_GAME_DIR is not configured (see tools/paths.example.env)")
    tiles = {}
    for name in TILE_FILES:
        path = Path(media) / name
        if not path.exists():
            continue
        data = path.read_bytes()
        offset = 4

        def i32():
            nonlocal offset
            value = struct.unpack_from("<i", data, offset)[0]
            offset += 4
            return value

        def line():
            nonlocal offset
            end = data.index(b"\n", offset)
            value = data[offset:end].decode("latin-1")
            offset = end + 1
            return value

        i32()
        patch = name.endswith(".patch.tiles")
        for _ in range(i32()):
            sheet = line().strip()
            line()
            i32(); i32(); i32()
            for index in range(i32()):
                props = {}
                for _ in range(i32()):
                    key = line()
                    props[key] = line()
                sprite = f"{sheet}_{index}"
                if patch:
                    if sprite in tiles:
                        tiles[sprite].update(props)
                elif True:
                    tiles[sprite] = props
    return tiles


def key_part(value):
    """I18n.keyPart: non-alphanumeric runs become one underscore."""
    part = re.sub(r"[^A-Za-z0-9]+", "_", str(value or "")).strip("_")
    return part or "General"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def save(path, data):
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    path.write_bytes(text.replace("\n", "\r\n").encode("utf-8"))


def all_buildables():
    found = {}
    for path in MODS.glob("*/42/media/KnoxBuildworks/definitions/**/*.json"):
        data = load(path)
        if isinstance(data, dict):
            for buildable in data.get("buildables", []):
                found[buildable["id"]] = (path, buildable)
    return found


def sprites_of(buildable):
    return set(re.findall(r'"([a-z][A-Za-z0-9_\-]*_\d+)"', json.dumps(buildable.get("stages", []))))


def group_faces(tiles, seed):
    """Every facing of the moveable set the seed sprite belongs to.

    A sheet can hold several sets with the same CustomName and GroupName (a
    two-tile and a three-tile office desk, two air-conditioner styles). Sets
    are laid out in index order, so walking the sheet in order and starting a
    new set whenever a facing/grid slot repeats separates them; the seed's set
    wins."""
    props = tiles[seed]
    sheet = seed.rsplit("_", 1)[0]
    custom, group = props.get("CustomName"), props.get("GroupName")
    members = []
    for name, other in tiles.items():
        base, _, index = name.rpartition("_")
        if base != sheet or not index.isdigit():
            continue
        if other.get("CustomName") != custom or other.get("GroupName") != group:
            continue
        if other.get("Facing") not in FACE_FOR_FACING:
            continue
        members.append((int(index), name, other))
    members.sort()
    sets, current, previous = [], {}, None
    for index, name, other in members:
        x, y = (int(v) for v in other.get("SpriteGridPos", "0,0").split(","))
        slot = (FACE_FOR_FACING[other["Facing"]], x, y)
        # A repeated slot, or a jump past the next tile block, starts a new set.
        if slot in current or (previous is not None and index - previous > SET_GAP):
            sets.append(current)
            current = {}
        current[slot] = name
        previous = index
    if current:
        sets.append(current)
    chosen = next((cells for cells in sets if seed in cells.values()), {})
    faces = {}
    for (face, x, y), name in chosen.items():
        faces.setdefault(face, {})[(x, y)] = name
    result = {}
    for face, cells in faces.items():
        width = max(x for x, _ in cells) + 1
        height = max(y for _, y in cells) + 1
        result[face] = [[cells.get((x, y)) for x in range(width)] for y in range(height)]
    return result


def geometry(faces):
    return {"faces": {face: {"layers": [{"rows": rows}]} for face, rows in faces.items()}}


def build_piece(spec, tiles, buildables):
    analog_path, analog = buildables[spec["analog"]]
    faces = spec.get("faces") or group_faces(tiles, spec["seed"])
    if not faces:
        raise SystemExit(f"{spec['key']}: no facings found for {spec['seed']}")
    for rows in faces.values():
        for row in rows:
            if None in row:
                raise SystemExit(f"{spec['key']}: incomplete sprite grid {rows}")
    stage = copy.deepcopy(analog["stages"][0])
    stage["geometry"] = geometry(faces)
    for key in ("previousStage", "callbacks", "entityCompat"):
        stage.pop(key, None)
    requirements = stage.setdefault("requirements", {})
    if spec.get("fromItem"):
        custom_item = tiles[spec["seed"]].get("CustomItem")
        if not custom_item:
            raise SystemExit(f"{spec['key']}: {spec['seed']} names no CustomItem")
        requirements.pop("materials", None)
        requirements["inputs"] = [item("placed_item", custom_item, 1)]
        requirements["skills"] = {}
        requirements.pop("knowledge", None)
    if "inputs" in spec:
        requirements.pop("materials", None)
        requirements["inputs"] = spec["inputs"]
    if "skills" in spec:
        requirements["skills"] = spec["skills"]
    if "knowledge" in spec:
        if spec["knowledge"] is None:
            requirements.pop("knowledge", None)
        else:
            requirements["knowledge"] = copy.deepcopy(spec["knowledge"])
    if "construction" in spec:
        stage["construction"] = copy.deepcopy(spec["construction"])
    if "native" in spec:
        if spec["native"]:
            stage["nativeObject"] = {"type": spec["native"]}
        else:
            stage.pop("nativeObject", None)
    if "object" in spec:
        stage["object"] = spec["object"]
    first = next(iter(faces.get("N") or faces.get("W") or next(iter(faces.values()))))[0]
    piece_id = f"{VE}world.{spec['file']}.{spec['key']}"
    piece = {"id": piece_id}
    for key in ("extends", "category", "subcategory", "material", "materialTags", "placement"):
        if key in analog:
            piece[key] = copy.deepcopy(analog[key])
    piece["translationKey"] = f"IGUI_KBWVE_Buildable_world_{spec['file']}_{spec['key']}"
    piece["displayName"] = spec["name"]
    piece["tooltipKey"] = spec.get("tooltip") or analog.get("tooltipKey")
    if spec.get("category"):
        piece["category"] = spec["category"]
    if spec.get("sub"):
        piece["subcategory"] = spec["sub"]
    for key in ("placement", "material", "materialTags"):
        if key in spec:
            piece[key] = copy.deepcopy(spec[key])
    if "extends" in spec and spec["extends"] is None:
        piece.pop("extends", None)
    piece["iconSprite"] = first
    tags = list(spec["tags"]) if "tags" in spec else list(analog.get("tags") or [])
    piece["tags"] = sorted(set(tags + [GENERATED_TAG]))
    piece["stages"] = [stage]
    return piece


def old_wood_window_walls(buildables):
    """The Old Wood Panel window/door walls: sheet 13 sprites 64-95, the block
    window_walls.json had no family for, cloned from Red Barn Wood (same
    exterior-board rules, sprites 0-31)."""
    pieces = []
    family = load(DEFINITIONS / "walls/old_wood_panel.json")["buildables"][0]
    for shape in WINDOW_SHAPES:
        source_path, source = buildables[f"{VE}walls.red_barn_wood.red_barn_wood_{shape}"]
        text = json.dumps(source)
        text = re.sub(r'walls_exterior_house_13_(\d+)', lambda m: f"walls_exterior_house_13_{int(m.group(1)) + 64}", text)
        piece = json.loads(text.replace("red_barn_wood", "old_wood_panel").replace("Red Barn Wood", "Old Wood Panel"))
        piece["subcategory"] = family.get("subcategory", piece.get("subcategory"))
        piece["tags"] = sorted(set((piece.get("tags") or []) + [GENERATED_TAG]))
        pieces.append(piece)
    return pieces


def main():
    tiles = read_tiles()
    buildables = all_buildables()
    generated = {bid for bid, (_, b) in buildables.items() if GENERATED_TAG in (b.get("tags") or [])}
    claimed = {}
    for bid, (_, buildable) in buildables.items():
        if bid in generated:
            continue
        for sprite in sprites_of(buildable):
            claimed.setdefault(sprite, bid)
    for spec in PIECES:
        if spec["analog"] not in buildables:
            raise SystemExit(f"{spec['key']}: analog {spec['analog']} does not exist")
        if spec["seed"] not in tiles:
            raise SystemExit(f"{spec['key']}: sprite {spec['seed']} is not in the game's tile definitions")
    files = {}
    names = {}
    for spec in PIECES:
        piece = build_piece(spec, tiles, buildables)
        for sprite in sprites_of(piece):
            owner = claimed.get(sprite)
            if owner:
                raise SystemExit(f"{piece['id']}: {sprite} is already drawn by {owner}")
            claimed[sprite] = piece["id"]
        files.setdefault(spec["file"], []).append(piece)
        names[piece["translationKey"]] = piece["displayName"]

    manifest = load(MANIFEST)
    for file, pieces in files.items():
        relative = f"media/KnoxBuildworks/definitions/world_pieces/{file}.json"
        path = VE_MEDIA.parent / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        save(path, {"schemaVersion": 1, "buildables": pieces})
        if relative not in manifest["definitions"]:
            manifest["definitions"].append(relative)
    save(MANIFEST, manifest)

    windows_path = DEFINITIONS / "walls/window_walls.json"
    windows = load(windows_path)
    windows["buildables"] = [b for b in windows["buildables"] if GENERATED_TAG not in (b.get("tags") or [])]
    for piece in old_wood_window_walls(buildables):
        for sprite in sprites_of(piece):
            owner = claimed.get(sprite)
            if owner and owner != piece["id"]:
                raise SystemExit(f"{piece['id']}: {sprite} is already drawn by {owner}")
        windows["buildables"].append(piece)
        names[piece["translationKey"]] = piece["displayName"]
    save(windows_path, windows)

    # Category and subcategory labels go through I18n.keyPart; add the ones
    # these pieces introduce unless a provider already translates them.
    core = load(ROOT / "Contents/mods/KnoxBuildworks/42/media/lua/shared/Translate/EN/IG_UI.json")
    translations = load(NAMES)
    for pieces in files.values():
        for piece in pieces:
            for kind, value in (("Category", piece.get("category")), ("Subcategory", piece.get("subcategory"))):
                if not value:
                    continue
                key = f"IGUI_KBW_{kind}_{key_part(value)}"
                if key not in core and key not in translations:
                    names[key] = value
    translations.update(names)
    save(NAMES, translations)
    tooltips = load(TOOLTIPS)
    tooltips.update(TOOLTIP_TEXT)
    save(TOOLTIPS, tooltips)
    total = sum(len(p) for p in files.values()) + len(WINDOW_SHAPES)
    print(f"wrote {total} buildables: " + ", ".join(f"{k}={len(v)}" for k, v in files.items())
          + f", window_walls+={len(WINDOW_SHAPES)}")


if __name__ == "__main__":
    main()
