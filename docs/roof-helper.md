# Roof Helper: how roofs are planned

Developer notes for `RoofPlanner.lua`, `RoofAtlas.lua`, `RoofHelper.lua` and
`RoofModelView.lua`. Player-facing behaviour is in the changelog.

## 1. Footprint

`RoofPlanner.regionsFromRooms` merges the rooms of one storey and removes the
squares covered by the storey above. Edges against that upper storey are
*abut* edges: the roof leans on its wall there, and `region.ceiling` (storeys
stacked above) limits how tall the roof may grow. An overhang dilates the
footprint by 1-2 tiles without entering covered squares.

## 2. Roof surface

The surface is a height field sampled every half tile. Height is the
L-infinity distance from the nearest **eave** edge, walking only over the
roof. For rectilinear footprints this is exactly the straight-skeleton roof:
hips leave convex corners at 45 degrees in plan, valleys leave re-entrant
corners, and ridges settle where opposite eaves meet. Any shape works,
including holes (courtyards).

Edge labels change the surface without special cases:

| label  | effect                                                         |
|--------|----------------------------------------------------------------|
| eave   | seeds height 0 (default)                                       |
| gable  | not a seed: the slope runs past it, the edge gets an end wall  |
| wall   | high side of a lean-to: a full-height wall                     |
| abut   | against an upper storey: no seed, no wall                      |

A lean-to uses a plane instead (`planarField`). A height cap (user rise,
upper storey, or world top) clamps the field and turns the top into flat
crown tiles one storey up per cap level.

Units: one *step* is the rise of one tile of run. A 45 degree set rises 3
steps per storey, a 30 degree set 6.

## 3. Choosing a tile for each cell

Each cell is classified by its four corner heights (plus edge-midpoint and
centre heights for odd spans):

| high corners          | piece                                   |
|-----------------------|-----------------------------------------|
| two on one side       | slope; **Facing** = the low side        |
| one                   | outer (convex hip) corner               |
| three                 | valley at the low corner                |
| none, centre higher   | odd-span ridge (axis from mid-points) or peak |
| none, centre level    | flat (crown)                            |

`Facing` means what the tile property means on furniture: the direction the
surface points, i.e. downhill. A slope facing S is low on its south edge.

## 4. Sprite atlas (`RoofAtlas.lua`)

Pieces are recognised from the sprite itself, never from the build face
(W/N/E/S) that a definition files it under. Layouts follow the BuildingEd
tile tables and were checked against the joins in `media/seams.txt`:

* 45 degree sheets (`roofs_01`..`05`, two 32-tile families each): S and E
  slopes, SE/SW/NE outer corners, SE valley, ridge halves, eaves and flats,
  as in BuildingEd's `roof_slopes` table (TileZed `BuildingTiles.txt`). There
  is no tile for north- or west-facing slopes: the camera cannot see them, so
  the ceiling deck keeps those squares dry. A south-west or north-east valley
  uses the matching south or east slope tile, which draws the visible half.
* Per-sheet extras (`STEEP_EXTRAS`), read from BuildingEd, the art and the
  vanilla map: odd-span ridges sit half a step above the slopes beside them.
  The ridge half (14/15, 46/47) is the 1.5-step piece (one square south-east
  it draws 0.5); `TwoPt5` (70/71, 78/79, 102/103) draws 2.5 steps in place.
  `innerHalf` (67..69, 75..77) is the junction where two odd-span ridges meet
  over a south-east valley; `outerHalf` (64..66, 72..74) ends an odd-span hip
  and stays catalogue-only. roofs_03/04 add alternate ridge art and
  `raisedFlat` tiles (flat roof 1 or 2 steps up), which a flat sitting part-way
  up a storey uses instead of rounding.
* Shallow sets (`roofs_0x` 80..87 and 112..119, `roofs_shallow_01` in blocks
  of 24): two rows per side, eave 1/6 storey up, 1/12 storey per row. They
  decode as pitch `shallow` with 12 steps per storey and `maxStep = 2`; the
  planner rejects layouts taller than two rows and odd spans (no ridge tile),
  which leaves gables up to four wide, lean-tos up to two deep and flats.
* 30 degree sheets (`roofs_30_xx`): all four slopes, all outer corners and
  valleys, ridges along both axes and peaks for every step. Note the visible
  south-east valley is 32..37 and the hidden north-west one 48..53.
* Gable walls: 30 degree gable sheets use a fixed 48-tile layout; 45 degree
  gable runs are 18-tile blocks whose first tile is found per family.

Sprites from unknown sheets (custom tile packs) fall back to the authored
`faceByEdge` / `partsByFace` metadata.

## 5. Layout candidates and ranking

`RoofPlanner.prepare` returns a resumable search: it does no work itself and
lists candidates lazily. `step(ctx, budget)` advances it by about `budget`
units (a slice of height-field cells, one tile pass, or a batch of plan
checks), so a large footprint is spread across frames; `results` returns the
layouts found so far, best first (`suggest` runs a search to completion):

* rectangles: gable along, gable across, hip;
* irregular footprints: the footprint is covered by rectangular wings; each
  wing ends in gables or hips (all combinations for two wings, the four usual
  ones beyond that);
* lean-tos facing every visible direction whose low edge is one straight
  line; a lean-to whose high side is an upper storey is preferred;
* flat;
* a flat-crowned variant of any layout taller than two storeys.

Scores start from a shape-aware prior (long rectangles prefer a gable along
their length, near-squares a hip, simple wings a cross gable) and are lowered
for stand-in tiles, missing tiles, odd-span ridges without a ridge tile,
height above two storeys, crowns, and footprints that are mostly one tile
wide. Layouts that produce identical pieces are listed once, and a layout is
named by its eaves (one eave side is a lean-to). The helper's `accept`
check marks layouts that collide with the plan; they stay listed below the
valid ones with their reason. `accept` is either a function over a whole
layout or `{ start = fn(layout), each = fn(piece) }`, which checks a few
pieces per step and stops at the first conflict.

On odd spans the ridge line is shifted forward (south or east) and up so its
end tile stays on the roof instead of hiding behind the gable wall. At 45
degrees a 2.5-step ridge uses the family's `TwoPt5` tile in place, and a cell
where two odd-span ridges meet over a south-east valley uses its `innerHalf`
tile. An odd-span pyramid apex still has no tile; a ridge tile stands in, is
counted as approximate, and lowers the score.

## 6. Gable walls

Each roof edge labelled gable or wall gets wall pieces along the building's
own wall line (with an overhang the wall sits inside the roof edge). The
heights at the two ends and the middle of the edge pick the piece: a rise
from the low end, a peak, or full-height fill walls for the storeys below.

The helper can dress every end-wall piece through `options.decorateGable`:
a variant that all pieces of the family share (old brick, ...) and a wall
finish (plaster, paint, plaster + paint or wallpaper) that every piece of
that variant accepts. The look is stored on each placement as `variantId`
and `finish`, exactly like a wall planned from the catalogue, so ghosts,
requirements and building treat it the same way.

## 7. Roof accents

`roofs_accents_01` (45 degree and shallow) and `roofs_accents_30_01` (30
degree) hold white trim. `RoofAtlas.accentPiece` decodes them by index; the
30 degree sheet uses the 30 degree gable-wall layout. With `options.accents`,
`placeAccents` follows the vanilla map, measured from the shipped lotpacks with
`tools/analyze_roof_accents.py` (152 of 241 rectangular 30 degree gables match
tile for tile; the rest differ only where the mapper left fascia out or picked
the other board variant):

* only what the camera sees is trimmed: gable edges facing east or south and
  the south and east eaves;
* rakes sit at roof height on the gable wall's square and carry its key
  (`rake:30:W:lowS:2`), so they share `edgeHeights`/`edgeShape` with the walls;
  they follow the roof edge, so an overhang carries them outward;
* everything along the eave hangs one level below the roof (z - 1) on the
  square just outside it: fascia boards (45 on south eaves, 22 on east eaves),
  the corner piece in inner corners, a corner block on south-east outside
  corners, and under each rake's front end an end return (45 degree) or a
  corner block (30 degree);
* 30 degree rakes also get a rake foot under each eave end (z - 1, same square).

Accents never fail a layout; missing pieces are counted in
`metrics.accentMissing`. Shallow roofs get the low (1/6 storey) fascia boards
on the roof's own level and the shallow rakes on their visible gables, as the
vanilla map pairs them. The downpipe shoe stays catalogue-only. Definitions
come from `tools/configure_roof_accents.py`.

## 8. Preview

`RoofModelView` draws each layout as a shaded isometric model with the
game's projection (a storey is three half-tiles tall). Hovering a layout
renders its real tiles in the world through `GhostRenderer`.

The window uses carousels (family, gable walls, gable finish, and small
steppers for the options) like the catalogue's stage selector. Only families
the helper can lay out completely are offered (`KBWRoofHelper.isAutomatic`:
a full slope sequence, or flat tiles only); shallow sets are offered for the
small layouts they can cover, tents are placed from the catalogue. A two-line summary under the Layouts title shows
the footprint and the chosen layout (or why none fits); the how-to sits in the
"?" tooltip. Each choice
of family and options has its own cached search; the shown one gets about
4 ms per frame, and when it is finished the families either side are
searched in the background so stepping the carousel shows them at once.
The layout list clips everything it draws (rows, text, and the model
polygons themselves) to its viewport.

## Checking changes

* `python -m unittest discover tools/tests` (roof tests are in
  `test_building_improvements.py`, `test_roof_rendering.py` and
  `test_planning_performance.py`; the seam test runs when the game is
  installed at the default path).
* `python tools/roof_preview.py --profile black:30 --gable white_clapboard:30 --shape U`
  renders the top layouts with the real 2x tiles and reports tile joins that
  disagree with `seams.txt`.
