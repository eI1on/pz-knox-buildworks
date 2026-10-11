# Building tools and magazine progression

Development changes dated 4–5 October 2026. These changes are local and have not
been published to Steam. Automated checks cover Lua behavior and data contracts;
the rendering, pickup animations and multiplayer transfer path still need a game session.

## Using the additions

- In Planning Mode, select a buildable and click an empty quickbar slot to save it.
  Click a filled slot, or press its number (1–9), to place its saved stage, variant, material and finish. Number shortcuts yield to text entry and the roof window.
  Right-click a slot to replace or clear it. Slots persist in the player's save data.
  The bar wraps into columns to fit between the planning panels.
- In Plans, use **World preview settings** for blueprint tint, original textures or
  a solid-looking 100% preview. Opacity buttons now control actual sprite opacity.
  Choose the current level, adjacent levels, current and lower levels, or all levels.
  Roofs, walls and room zones can be hidden independently. Preferences restore after loading
  and are applied separately for each split-screen player. These controls affect planned
  sprites, not real world objects or collision.
- In Rooms, use **Draw room** for the initial rectangle. To make an L-shaped or other irregular room, select the
  room, click **Extend room**, and drag an overlapping or edge-adjacent rectangle.
  Repeat for each wing. The world preview draws one continuous outline around the
  occupied footprint; erase and selection respect the exact tiles, including insets.
  The blueprint preview and roof helper use that same footprint. Existing rectangular
  rooms and saved blueprints continue to work.
- In Rooms, select a room and open **Roof helper**. Adjacent rooms on one level form
  one exposed roof area; an upper room masks the corresponding lower tiles. **Auto fit roof**
  chooses a pitched layout for a simple rectangle or clean wing junction and a continuous
  flat roof when the authored pitched pieces would cross on a complex footprint. It leaves
  the preview for review before adding it to the blueprint. Select a
  family/pitch, flat, shed, gable, hip, cross-gable or gabled-wing layout, low edge
  where relevant, and 0–2 tile overhang. Choose the starting level
  relative to the room and an optional maximum rise for a matching flat cap. Add a ceiling deck, gable walls and eaves where the chosen family provides them. **Suggest layouts** marks the first buildable suggestion and explains why other layouts are unavailable. Only families the helper can lay out completely are listed; individual roof pieces are placed from the Planning catalogue. Adding a roof creates ordinary blueprint placements with their real
  recipes, requirements and server validation.
  The footprint map shows surface pieces in green, ceiling-only support in blue,
  exposed room tiles without a roof piece in grey, and a conflicting preview in red.
  The installed game's tile definitions can be checked against the roof JSON with
  `python tools/audit_roof_definitions.py` (or pass `--tiles` for another game location).
- In Pieces, **Pipette** picks one piece at a time: hover a planned ghost or a built
  piece in the world (anything with a Knox recipe), press the rotate key to step through
  the pieces on that tile, and click. Planning continues with exactly that piece - recipe,
  stage, variant, material, direction and paint, plaster or wallpaper - without searching
  the catalogue. **Select ghosts** drags a box to select planned ghosts (Shift adds);
  **Delete selected** or the Delete key removes them in one request, and Ctrl/Shift-click
  in the Pieces list also builds a selection. The Planning catalogue's hover details
  (picture, materials, tools, skills) open beside the panel.
- In Rooms, **Cut from room** is the reverse of **Extend room**: drag an area to clear it
  out of the selected room; a room cut down to nothing is removed.
- The magazines, building components, their crafting recipes and their loot are
  part of the core mod. Enable the **Knox Buildworks - Vanilla Expanded** companion
  for the expanded catalogue that uses them. The old Buildables Expansion and Better
  Building Plus mods are not dependencies.

## Supplies

The queue and planner now discover bags inside storage and bags on the ground,
including nested bags. Discovery deduplicates containers; transfers retain the
actual source container while walking uses the outer world container or dropped
bag. Fetches prefer nearby storage and reserve backpack/main-inventory capacity
for the whole trip. Floor pickups batch items on the same square while reserving
main-inventory space. A floor item without a loot container uses the native world
pickup action. Native transfer actions still check live access and capacity.

Materials lying beside a planned build are included in its requirement evaluation
and can be consumed there without being carried. Tools still follow the carried
tool rule. Shared allocation prevents a single physical item from being counted
twice across blueprint requirements. Native server recipe discovery now includes
deep carried bags instead of stopping at a fixed nesting depth.

Supplies in unloaded squares remain unknown. A matching material count does not
promise a traversable path; the game checks walking and build access at execution.

## Progression, magazines and building components

All 17 magazines, from the author's supplied Buildables Expansion art, teach distinct
Knox knowledge tokens. The mapping in [magazine-progression.json](magazine-progression.json)
currently covers 2,189 stages. Unlocking can come from the matching magazine or
the authored higher skill alternative. Normal build skills remain required.
Locked stages are hidden by default; **Show all versions** reveals them without
granting permission to build. Server construction still checks the knowledge gate.

Eight specialist materials supply refrigeration and plumbing recipes:
compressors, refrigerant, plastic sheets, small plastic sheets, insulation foam,
rubber tubing, thin copper pipe and rubber seals. Existing structural materials
and tools remain in those recipes. All eight occur in the core mod's storage
loot tables (`lua/server/Items/KnoxBuildworksDistributions.lua`); plastic-sheet cutting, rubber-tube preparation and compressor assembly
provide additional crafting routes. Magazines appear in bookshops, libraries,
mixed magazine racks and mechanic book shelves. Existing explored loot containers
are not retroactively refilled by these distributions.

Items, models and recipes live in the core mod's own scripts
(`knox_buildworks_items.txt`, `knox_buildworks_models.txt`, `knox_buildworks_recipes.txt`)
under the `KnoxBuildworks` module and core `KBW` names: icons are
`textures/Item_KBW_*.png`, world textures and meshes `WorldItems/KBW*`. The original
Base items and both source mods are untouched. The exact asset inventory and ownership
note are in [building-items.json](building-items.json); `tools/import_building_items.py`
regenerates them. No third-party Lua was copied.

## Roof data and deliberate limits

Stages now declare `roof.family`, `pitch`, `role`, and, for slopes,
`step`, `stepsPerLevel` and `faceByEdge`. Physical low roof edges map explicitly to
authored sprite faces: a tile's catalogue rotation label is not necessarily the
roof's low edge. The helper never relies on Matrix's opposite-face fallback.

Flat tiles are shared within a material family. Standard 45-degree families use
their authored three-step sequences; 30-degree families use six-step sequences
and their four authored faces. Shallow geometry is marked `shallow`, without
inventing an angle or automatically repeating an unverified pitch. Detail, valley,
hip, trim and ridge pieces remain individually buildable in the catalogue.

The automatic helper supports flat, shed, gable and hip roofs over rectangular rooms;
standard 45-degree gables include odd spans with authored ridges. Connected L, T, U
and cross-shaped room areas support flat roofs and 45-degree cross-gables, hips and
gabled wings with authored valleys and corner pieces. Irregular 30-degree areas can
use a shed when its low edge runs continuously along one outside boundary; these
roofs also use the authored north/west faces. Thirty-degree even-span gables remain
available on rectangles. Maximum rise adds a matching flat cap.
Gable infill uses the chosen wall family's rising/falling/end pieces and full walls
below the sloped end. Eaves use separate edge and corner parts one level below the
roof. Unavailable/locked infill or trim rejects the combination instead of dropping
that option silently. Gable walls require Gable, Cross gable or Hip with gabled wings.

Thirty-degree hips, uncapped odd-span 30-degree gables, compound 30-degree valleys
and automatic shallow layouts remain manual: their specialized transitions have not
been verified as a complete layout.
Every family's authored detail pieces, including 30/45-degree fascia, shallow sheets and specialized tent roofs, are placed from the Planning catalogue; the helper no longer lists them.
The helper checks existing plans AND the other pieces in its candidate roof, along
with access, knowledge, height, range and placement limits before adding. The footprint
including overhang is limited to 576 cells; total pieces also obey the blueprint limit.
The game still validates construction/support at execution. Multiplayer edits made by
someone else between preview and submission can cause authoritative rejection.

The helper now starts with an unlocked pitched family when one is available.
**Auto fit roof** chooses a complete candidate from the selected material's
authored parts and checks the full room union. It avoids pitched junctions for
footprints with more than three crossing runs or a visible concave valley for
which the tile set has no sprite. In those cases it tries a coherent shed and
then covers every occupied tile with a flat roof. This keeps arbitrary connected
room shapes roofable without inventing missing 45-degree valley orientations.
The footprint map distinguishes slopes, ridges, valleys, hips, raised caps and
ceiling-only squares. A turquoise world outline marks the roof's selected start
level, separate from the room boundary on its floor level.
Suggestions discard incompatible gable walls when considering other shapes and
show the same permission, knowledge, range, placement-limit or overlap reasons
used by Apply. Editing or deleting the source room while the
window is open refreshes or closes the preview. Shallow, trim and tent sets are not
listed, because they lack a complete automatic slope sequence (the shallow sheets
have only two rows of tiles per side).
Flat layouts disable direction, cap, ceiling and eave controls, since those do
not create extra parts on a flat roof. A shed eave on an invisible north/west
edge is rejected instead of silently placing no trim.

Standard steep roofs intentionally omit invisible north/west facets; a ceiling deck
provides continuous physical coverage. Visual slopes alone are not a promise of weather
sealing. Check rain, supports and orientation in game before release.

## Native building rendering without a framework dependency

`World/BuildingRender.lua` is a Knox implementation using B42's own metagrid and FBO
APIs. It does not require, load or bundle RCStructureFramework or Better Building Plus.
The temporary RCSF room-assignment adapter was removed.

B42's `WorldRegionToMetaGrid` already derives native buildings from enclosed player
structures. Knox repairs loaded squares from those current records: the room ID,
exact room object, exterior state and roof cutaway building, then invalidates the
object/cutaway render cache. Reconnecting navigation alone does not update those
fields in the installed B42 source.

Discovery covers every local split-screen player. Jobs are deduplicated per loaded
8×8 B42 chunk and process at most 192 square positions per tick. Building changes,
chunk replacement/reload and load events invalidate the nearby cache; disappearance
of a building schedules cleanup of its former square associations. The cache retains
only nearby jobs. No room definitions or save records are fabricated, and no server
command or client authority over construction is introduced. Existing completed player
buildings can benefit when their native metadata is present, without rebuilding them.

This repairs metadata-backed player buildings. It does not force an open plan to become
an indoor room, add custom basements, or override the game's handling of additions
abutting predefined map buildings. Those cases require separate native-room design;
they are not claimed as complete custom room registration.

Blueprint ghosts sort their expanded cells by actual Z, then floor layer and isometric
diagonal, with deterministic ties. They no longer pack large world coordinates into
one weighted number or sort stairs solely by their anchor. The order is cached per
blueprint revision, including temporary roof and moved-blueprint previews. Opaque
preview mode remains a sprite preview, not temporary collidable world objects.
Persistent blueprint ghosts and roof-helper previews render in B42's per-player
`OnPostRender` world pass. B42 may skip `RenderOpaqueObjectsInWorld` while the
pointer is over UI; the earlier preview disappeared between those frames. Room,
zone and range colours now use clipped floor-cursor tiles with light interiors
for small rooms and borders for larger areas. This avoids the lifetime of B42's
timestamped area-highlight FBO, which caused colour flicker. Queued highlights
are flushed only for their own split-screen player, and room opacity follows
the selected preview opacity without the earlier excessive multiplier. Room
colours are interleaved with ghost objects by Z level, keeping upper rooms above
lower-storey pieces while leaving walls and furniture above same-level floors.
The callback takes its player index from the current `getPlayer():getPlayerNum()`;
Java sets that player before each render pass. Kahlua cannot index the public
`IsoCamera.frameState.playerIndex` field, which caused the repeated render error.

## Cleanup and scope

Removed the unused tag-conversion helpers from `BuildQueue` and the obsolete
weighted/incremental anchor sorting path. Restored the dim preview colour still
used by the erase and build cursors; its absence caused the reported Lua error.
Active tools,
legacy blueprint migration and saved buildable IDs are retained. These changes do not
port every BBP feature: plan undo/redo, renovation capture,
a rug-specific tool and temporary native preview objects are not newly implemented.

## Source anchors

Inspected BetterBuildingPlus at the supplied Workshop path: `AutonomousBuilder`,
`FloorPile`, `RoofPlanner`, `GhostRenderer`, `UI/BuildQuickbar`, and `UI/RoofHelper`.
Useful patterns were source-aware fetching, exact saved selections and explicit
preview/roof options. RCStructureFramework by RedChili was also inspected for native room and cutaway behaviour. The new code is original Knox code using verified game APIs; no third-party implementation is bundled. Planning uses Knox's existing blueprint protocol.

Verified against local B42 sources:

- `media/lua/shared/luautils.lua`: walking to containers and adjacent floor squares.
- `media/lua/client/TimedActions/ISInventoryTransferAction.lua`: source membership,
  nested containers, removal permissions and capacity checks.
- `media/lua/shared/TimedActions/ISInventoryTransferUtil.lua`: native transfer factory.
- Java `ItemContainer`: outer container/square lookup, capacity and bag behavior.
- Java `IsoSprite.RenderGhostTileColor`, `IngameState` and `FBORenderCell`:
  per-player world render, skipped picked-tile callbacks and timestamped highlights.
- Java `WorldRegionToMetaGrid`, `IsoGridSquare`, `RoomDef.getIsoRoom`, `IsoCell`,
  and `FBORenderChunk`: native building creation, exact room references, 8-tile chunks
  and render invalidation flags.
- Java `Item`, `Literature`, `IsoGameCharacter` and `Translator`: `LearnedRecipes`,
  native reading, actually-known recipe tokens and JSON translation keys.
- `media/newtiledefinitions.tiles.txt`: existing roof sprites, roof/eave/floor flags.

## Validation and game checks

Run `python -m unittest discover -s tools/tests`. Behavioral tests cover nested
discovery and source walking, carried capacity reservations, deep server bags,
knowledge visibility and cached filtering, server requirements, opacity and level
filters, cell-level draw order and caches, chunk reload/demolition repair budgets,
per-player saved preferences, actual roof family gables/hips/infill/eaves/caps, quickbar
permission checks, large-font roof window bounds and hook cleanup, all magazine
mappings and imported assets.
Validate all definition bundles against `buildables.schema.json` and parse changed
Lua with `luaparser`.

Before release, test in single player and on a hosted/dedicated server:

1. Build from a crate containing nested bags and from a dropped bag; move or empty
   the bag during pickup. Test full backpacks, restricted containers and vehicles.
2. Build using a large loose pile beside the target with an almost-full inventory.
3. Read each magazine; check the same stage is hidden, revealed and constructible
   at the intended skill threshold. Test Show all and a rejected locked build.
4. Save/reload quickbar variants and finishes, then disable a saved recipe via server
   rules. Check narrow screens and large fonts.
5. Inspect 30- and 45-degree roof slopes at each low edge, multi-level spans, even
   and odd gables, hips, gable wall families, eave corners, capped roofs, starting levels and flat overhangs; verify supports
   and rain sealing. Unsupported layouts
   must produce an explanation, not a partial roof.
6. Close/reopen the roof helper and planning UI; ensure temporary previews disappear.
   Inspect all preview styles and filters on multi-level plans.
7. With RCStructureFramework and BBP disabled, build a roofed room across a chunk
   boundary. Enter/exit it and change levels. Leave/reload the area, save/reload,
   remove a roof/wall, and repeat with two split-screen players and an MP client.
   Check lighting, upper-storey cutaways and restored outdoor visibility.
8. Press quickbar 1–9 while planning, typing a search/name, and using chat. Typing
   must not select recipes; planning shortcuts must not equip vanilla hotbar items.
