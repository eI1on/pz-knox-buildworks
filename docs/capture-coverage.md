# Capture coverage

Every sprite the first six building captures (October 2026) reported with no
buildable, and what happens to it now. Regenerate the new pieces with
`python tools/add_world_pieces.py`; capture logic lives in
`media/lua/client/KnoxBuildworks/Planning/BuildingCapture.lua`.

## New buildables

Facings and multi-tile cells come from the game tile definitions. Requirements copy a
matching Vanilla Expanded piece. Electronics are built from parts modelled on the base
game's radio recipes (receivers, transmitters, amplifiers, speakers, microphones, bulbs),
gated by the Radio magazines or Popular Mechanics: Home Appliances. The deer hide rug
is laid from the hide itself.

| Buildable | Name | Captured sprites |
|---|---|---|
| `walls.old_wood_panel.old_wood_panel_wide_window_wall_1` | Old Wood Panel Wide Window Wall 1 | `walls_exterior_house_13_88`, `walls_exterior_house_13_89` |
| `walls.old_wood_panel.old_wood_panel_wide_window_wall_2` | Old Wood Panel Wide Window Wall 2 | `walls_exterior_house_13_90`, `walls_exterior_house_13_91` |
| `walls.old_wood_panel.old_wood_panel_wide_window_wall_3` | Old Wood Panel Wide Window Wall 3 | `walls_exterior_house_13_92`, `walls_exterior_house_13_93` |
| `world.appliances.air_conditioner` | Wall Air Conditioner | `rooftop_furniture_34`, `rooftop_furniture_35` |
| `world.appliances.army_ham_radio` | US Army Ham Radio | `appliances_com_01_8` |
| `world.appliances.coffee_machine` | X-press Coffee Machine | `appliances_cooking_01_57` |
| `world.appliances.modern_phone` | White Modern Telephone | `location_business_office_generic_02_17` |
| `world.appliances.pay_phone` | Pay Phone | `street_decoration_01_38` |
| `world.appliances.premium_ham_radio` | Premium Technologies Ham Radio | `appliances_com_01_7` |
| `world.appliances.tv_antenna` | Rooftop TV Antenna | `appliances_com_01_80`, `appliances_com_01_81` |
| `world.appliances.valutech_radio` | ValuTech Radio | `appliances_radio_01_0` |
| `world.appliances.valutech_television` | ValuTech Television | `appliances_television_01_4` |
| `world.appliances.water_dispenser` | Water Dispenser | `location_business_office_generic_01_48` |
| `world.construction.attic_floorboards` | Attic Floorboards | `ceilings_01_0` |
| `world.construction.chimney_pots` | Chimney Pots | `fixtures_fireplaces_01_72` |
| `world.construction.curb_edge` | Curb Edge | `street_curbs_01_43` |
| `world.construction.drainpipe` | Metal Drainpipe | `industry_02_238` |
| `world.construction.drainpipe_elbow` | Metal Drainpipe Elbow | `industry_02_260` |
| `world.construction.junction_box` | Electrical Junction Box | `industry_02_221` |
| `world.construction.pipe_pile` | Steel Pipe Pile | `industry_01_44` |
| `world.construction.pipe_stack` | Stacked Steel Pipes | `industry_01_43`, `industry_01_45` |
| `world.construction.rusty_pipe` | Rusty Standing Pipe | `industry_02_34` |
| `world.construction.trailer_wall_panel` | Trailer Wall Panel | `location_trailer_01_4` |
| `world.construction.wall_cables` | Wall Cables | `industry_02_209` |
| `world.construction.white_baseboard_2` | White Baseboard (Style 2) | `walls_interior_detailing_01_12` |
| `world.construction.wooden_fascia_board` | Wooden Fascia Board | `industry_01_29`, `industry_01_30` |
| `world.construction.wooden_post` | Wooden Post | `carpentry_02_103` |
| `world.decor.deer_hide_rug` | Dapple Deer Hide Rug | `rugs_animals_0`, `rugs_animals_1`, `rugs_animals_10`, `rugs_animals_11`, `rugs_animals_2`, `rugs_animals_3`, `rugs_animals_8`, `rugs_animals_9` |
| `world.decor.deer_trophy` | Mounted Deer Trophy | `camping_01_17` |
| `world.decor.first_aid_cabinet` | First Aid Wall Cabinet | `location_community_medical_01_88` |
| `world.decor.framed_picture_1` | Framed Picture (Style 1) | `walls_decoration_02_16` |
| `world.decor.framed_picture_2` | Framed Picture (Style 2) | `walls_decoration_02_17` |
| `world.decor.framed_picture_3` | Framed Picture (Style 3) | `walls_decoration_02_24` |
| `world.decor.framed_picture_4` | Framed Picture (Style 4) | `walls_decoration_02_25` |
| `world.decor.framed_picture_5` | Framed Picture (Style 5) | `walls_decoration_02_28` |
| `world.decor.lakeside_painting` | Lakeside Painting | `walls_decoration_01_52`, `walls_decoration_01_53` |
| `world.decor.large_mirror` | Large Wall Mirror | `walls_decoration_01_5` |
| `world.decor.ranger_station_sign` | Ranger Station Sign | `signs_one-off_08_269`, `signs_one-off_08_270` |
| `world.decor.usa_flag` | Stars and Stripes Flag | `walls_decoration_01_17` |
| `world.decor.usa_map` | Map of the USA | `location_community_school_01_22`, `location_community_school_01_23`, `location_community_school_01_30`, `location_community_school_01_31` |
| `world.furniture.brick_pallet` | Pallet With Bricks | `construction_01_4` |
| `world.furniture.cardboard_box` | Cardboard Box | `trashcontainers_01_24` |
| `world.furniture.empty_pallet` | Empty Pallet | `construction_01_5` |
| `world.furniture.office_desk` | Office Desk | `location_business_office_generic_01_42` |
| `world.furniture.plastic_chair` | Plastic Chair | `furniture_seating_outdoor_01_16` |
| `world.furniture.wooden_chair` | Wooden Chair | `furniture_seating_indoor_02_5`, `furniture_seating_indoor_02_7` |
| `world.lighting.black_table_lamp` | Black Table Lamp | `lighting_indoor_02_10` |
| `world.lighting.blue_table_lamp` | Blue Table Lamp | `lighting_indoor_02_26` |
| `world.lighting.fluorescent_wall_light` | Fluorescent Wall Light | `lighting_indoor_02_44` |
| `world.lighting.grey_table_lamp` | Grey Table Lamp | `lighting_indoor_02_2` |
| `world.lighting.modern_outdoor_lamp` | Modern Outdoor Wall Lamp | `lighting_outdoor_01_32`, `lighting_outdoor_01_33` |
| `world.lighting.oval_outdoor_lamp` | Oval Outdoor Wall Lamp | `lighting_outdoor_01_41`, `lighting_outdoor_01_45` |

The Old Wood Panel family also gains its whole window and door wall set
(sheet `walls_exterior_house_13`, sprites 64-95), the one block `window_walls.json`
had no family for.

## Already defined, missed by the old capture

| Sprite | Buildable | Why it was missed |
|---|---|---|
| `fixtures_doors_01_18` | `doors.wooden_doors.tan_door` | door standing open (open sprite = closed + 2) |
| `fixtures_doors_01_2` | `doors.wooden_doors.white_door` | door standing open (open sprite = closed + 2) |
| `location_business_office_generic_01_43` | `furniture.large_tables.location_business_office_generic_01_43` | second tile of the office desk |
| `walls_exterior_house_02_35` | `walls.white_clapboard.white_clapboard_pillar` | painted pillar: one sprite for both edges was never indexed |

## Walls and corners

| Sprite | Now planned as |
|---|---|
| `walls_interior_detailing_01_38` | its two halves from `CornerWestWall` / `CornerNorthWall` (architecture_plus.floor_molding.brown_simple_trim + architecture_plus.floor_molding.brown_simple_trim) |
| `walls_interior_detailing_01_6` | its two halves from `CornerWestWall` / `CornerNorthWall` (architecture_plus.floor_molding.white_simple_trim + architecture_plus.floor_molding.white_simple_trim) |
| `walls_interior_house_03_32` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_03_33` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_03_34` | its two halves from `CornerWestWall` / `CornerNorthWall` (parts approximated by PaintingType) |
| `walls_interior_house_03_35` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_03_40` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_03_42` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_03_43` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_06_142` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_06_143` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_06_80` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |
| `walls_interior_house_06_81` | Good wooden wall piece of the same wall type + frame + plaster (no paint or wallpaper reproduces this exact surface) |

Painted and papered map walls that the vanilla paint tables do reproduce become
wooden wall frame, Good wooden wall, plaster, then paint or wallpaper.

## Not planned on purpose

- Furniture clutter the game adds at load (`TileOverlay` tiles, see `TileOverlays.java`): `appliances_01_21`, `fixtures_01_16`, `fixtures_01_26`, `fixtures_01_27`, `fixtures_overlay_counters_01_14`, `seating_01_29`, `seating_01_33`.
- Litter and wreckage, listed in its own report section: `d_generic_1_15`, `d_generic_1_18`, `d_generic_1_23`, `d_generic_1_26`, `d_generic_1_52`, `d_generic_1_9`, `fencing_damaged_01_128`, `fencing_damaged_01_129`, `fencing_damaged_01_130`, `fencing_damaged_01_131`, `trash_01_0`, `trash_01_10`, `trash_01_11`, `trash_01_17`, `trash_01_25`, `trash_01_29`, `trash_01_30`, `trash_01_4`, `trash_01_6`, `trash_01_8`, `trash_01_9`, `trash_walls_01_2`, `trash_walls_01_7`, `walls_house_wood_01_MIRRORED_11`, `walls_house_wood_01_MIRRORED_30`.

