# Plan: New Orleans as a hand-composed SMT diorama

Rebuild the overworld as a small set of recognisable places, arranged by hand
closer together than reality, joined by a few roads, with ruin and water
walls between them and the fog wall around the outside. Build one district
slice first, walk it, and only then expand.

This reverses the 2026-10-13 decision to cover the whole parish
(`e7e265f`, 245 km², and the 2026-10-15 schematic at the same size). That
map is correct everywhere and memorable nowhere: except the CBD towers, the
river and the Crescent City Connection, nothing tells you where you are, and
at that area nothing can be composed. The user agreed with this diagnosis
on 2026-10-15. Nothing from the parish work is deleted by this plan; the
live map stays `world/city_overworld.tscn` until the user promotes the
diorama.

## Pillars

1. **Composed, not generated.** Every place on the map is there because
   someone chose it and gave it a job. Tools cut and draw; they do not
   decide what the map contains.
2. **Dense.** From anywhere, something with an identity is seconds away.
   Distance between places is a design number, not a fact about New
   Orleans.
3. **Walls over width.** New Orleans is flat and low; its streets read as
   paving from the overworld camera. The ruin layer supplies what Tokyo's
   towers supply for free: levees, flood walls, rubble, collapsed overpasses,
   cemetery walls and water block sightlines and funnel movement.
4. **New Orleans as SMT material.** Cities of the dead, voodoo, the
   Superdome as a dome, the Quarter as a sacred core, water held above the
   streets, swamp all round, the drowned-city history. Each destination is
   built on one of these, never on "it is a real neighbourhood".
5. **Editable in the editor.** Everything that is composition (where things
   sit, walls, gates, doors, landmarks, districts) lives in the `.tscn` as
   ordinary Godot nodes. Tools only produce the things that are tedious by
   hand (street grids, building masses, water, baked fields).
6. **Reversible.** New files beside the old ones; promotion is one line in
   `data/areas/overworld.tres`, with the user's say-so.

## Non-goals

- Geographic accuracy. OSM is a tracing reference for the inside of a
  destination; placement between destinations is invented.
- Full-parish coverage. The East, the lake shore between landmarks,
  Jefferson, most of the West Bank: fog.
- Procedural filler as content. Nothing between destinations is "city"; it
  is wall, rubble, water or fog, and it is there to shape the walk.
- Finished assets. Everything is masses and placeholders; the user said they
  want a strong expandable base, not detail.
- Nav-grid work. The overworld is direct avatar control; the nav grid is a
  combat-area concern.

## Scale and walk-time budget

These are tunables with a starting value, not facts about SMT IV.

| Target | Starting value | Why |
|---|---|---|
| Neighbour to neighbour (gate to gate) | 10-20 s | the "seconds from identity" pillar |
| Across one destination | 10-15 s | long enough to be a place, short enough to never be filler |
| Across the whole map, straight line | 2-3 min | a CRPG world map crossed in one sitting |
| Destinations | 12-15 | the IV reading in COMPRESSION_PLAN.md gave 8-12 districts; a few more because ours are smaller |

Distance follows from speed. The live overworld runs the avatar at 64 m/s
(`move_speed` 6 x `avatar_speed_scale` 10.67, `9782f60`). At that speed
15 s is about 1 km, so destinations sit roughly 1 km apart centre to centre
and the whole map is about **4 x 3 km of playable ground, 12-16 km²** with
the fog ring outside. If Phase 1 shows 64 m/s is too fast for a dense map
(likely: the Quarter is 1 km long), the speed drops and the spacing shrinks
with it; the walk-time budget is the invariant, not the metres.

Inside a destination, geometry stays at 1x (the 2026-10-10 "uniform true
proportions" decision holds within a piece). Compression happens only in
the gaps between pieces, which are not street fabric and so cannot shear.
That is what makes this different from `compress.py` and `parish_warp.py`:
there are no seams to reconcile, because nothing between two pieces is a
street grid.

## The destinations

Fourteen. Phase 1 builds the first three. Placement is on a compressed
layout that keeps the real bearings loosely (river south-east of the
Quarter, lake north, CBD upriver, the Ninth downriver, Algiers across the
water) and throws away the distances.

| # | Place | SMT role / identity | Silhouette (what you see from the gate) | Inside (hooks) | Phase |
|---|---|---|---|---|---|
| 1 | **Jackson Square / French Quarter** | the sacred core and hub; the one intact place | cathedral spire over the square; the river levee as a raised wall along one side | Start spawn; `StLouisCathedral` door -> `cathedral_of_shadows`; later the first terminal | 1 |
| 2 | **St. Louis Cemetery No. 1** | city of the dead; necromancy, the Laveau tomb | a walled rectangle of tomb rows, one gate on Basin St | one door to a new combat area (tomb rows at tactical scale) | 1 |
| 3 | **Treme / Congo Square** | voodoo, drums, the spirits' side of Rampart | Rampart as a wall with gates; Armstrong Park's oaks; the I-10 Claiborne deck as the far wall | `CongoSquare` door -> `test_arena` (keep as placeholder) | 1 |
| 4 | **Superdome / CBD** | the dome (Tokyo's ceiling has a cousin here); shelter of the powerful | the dome and the tower cluster, the only tall silhouette on the map | terminal; a door into a CBD combat area; `LafayetteSquare` door -> `test_area_3` | 2 |
| 5 | **Lee Circle / expressway knot** | the collapsed interchange; a rubble gate between CBD and uptown | fallen I-10 spans, one deck still up and walkable | a deck-walk; later a door | 2 |
| 6 | **Marigny / Bywater (Frenchmen St)** | music; the Quarter's shadow | low shotgun rows behind Esplanade's rubble line | `WashingtonSquare` door -> `test_area_2` (keep) | 3 |
| 7 | **Industrial Canal / Lower Ninth** | the breach; the drowned district | a flood wall with one broken panel, the lock as a gate, water higher than the street beyond | a flooded combat area; the Ninth's standalone marsh (2026-10-15 water rule) | 3 |
| 8 | **Crescent City Connection / Algiers Point** | the skyway over the river; the far shore as the end of the world | bridge towers; the ferry landing | the deck walk; Algiers as a small piece with a door; fog past it | 3 |
| 9 | **City Park** | wilderness inside the city; live oaks, lagoons, NOMA | canopy masses and water, no streets | a wilderness combat area (BG3-style variety) | 4 |
| 10 | **Bayou St John** | the water road north; Laveau's rituals | a bayou corridor with one footbridge | corridor-destination between 9 and 11 | 4 |
| 11 | **Lakefront** | the lake runs into fog; the levee holds it above you | Lakeshore Dr on the levee crest, the lighthouse, water to the horizon | terminal; a lakefront combat area | 4 |
| 12 | **Garden District / Lafayette Cemetery** | old money and its dead; the second city of the dead | mansion masses under oaks; a second walled cemetery | a door; St Charles as the corridor to 5 | 5 |
| 13 | **Six Flags (Jazzland) / marsh edge** | the abandoned park at the swamp's edge | the Ferris wheel and coaster frames over marsh | a door; the map's east end in fog | 5 |
| 14 | **Audubon Park / Uptown end** | the river bend's far end; the zoo | oaks and the river's other crescent | optional; cut if 13 already gives the map its wild edge | 5 |

Why these and not others: each has a silhouette the camera can read at
120 m, each maps to one SMT idea, and together they cover every kind of
wall the ruin layer needs (levee, flood wall, cemetery wall, collapsed deck,
water, canopy). Canal St, St Charles, Esplanade, Rampart, Claiborne/I-10 and
the river road are corridors, not destinations.

### Rough layout (metres, diorama frame, all tunable)

```
                 [11 Lakefront] ~~~~ lake into fog ~~~~
                        |
        [9 City Park]--[10 Bayou St John]
              |                |
 [12 Garden]--[5 Knot]--[4 CBD/Dome]--[2 Cemetery]--[3 Treme]--I-10 wall
      |           |         |  Canal St     |  Rampart  |
      |           |    [1 French Quarter / Jackson Sq]--[6 Marigny]--[7 Canal/Ninth]--[13 Six Flags]
      |           |         |  levee
 ~~~~ river ~~~~~~[8 CCC bridge]~~~~~~~~~~~~~~~~~~~~~~~~~~~~ river ~~~~
                  [8 Algiers]
```

| Piece | Centre (x, z) | Footprint | Note |
|---|---|---|---|
| 1 Quarter | 0, 0 | 1000 x 600 | 1x; the frame origin |
| 2 Cemetery | -300, -500 | 150 x 120 | across Rampart from the Quarter's upriver end |
| 3 Treme | 200, -600 | 700 x 400 | Rampart to Claiborne |
| 4 CBD/Dome | -1100, -200 | 900 x 700 | real gap to the Quarter is ~0; here a rubble band of 150 m across Canal St |
| 5 Knot | -1900, -300 | 400 x 400 | |
| 6 Marigny | 1000, 0 | 600 x 500 | |
| 7 Canal/Ninth | 2100, -100 | 700 x 600 | real distance 4 km, here 1 km |
| 8 Bridge/Algiers | -600, 900 | deck 700 long; Algiers 300 x 300 | river 250-300 m wide |
| 9 City Park | -800, -1600 | 700 x 600 | real distance 4 km |
| 10 Bayou | 0, -1500 | 150 x 700 | |
| 11 Lakefront | -300, -2400 | 1200 x 300 | the lake fills the top edge |
| 12 Garden | -2600, 200 | 600 x 500 | |
| 13 Six Flags | 3000, -200 | 400 x 400 | |

Overall about 5.5 x 3.5 km including the water; the walk from the Quarter
to any neighbour is 700-1100 m, 11-17 s at 64 m/s.

## Connective tissue

**Corridors.** One road per neighbouring pair, named after the real one so
the label and the player's memory agree: Canal St (1-4), Rampart (1-2, 1-3,
gated), Esplanade (1-6), St Claude (6-7), St Charles (5-12), Poydras/Loyola
(4-5), Orleans Ave/Bayou (4-10-9), Elysian Fields or Wisner (10-11), the CCC
deck (4-8), Chef Menteur (7-13). A corridor is a road with walls on both
sides; nothing opens off it except its two ends and at most one side gate.

**Walls.** Every edge of a destination that is not a corridor mouth is a
wall, and the wall is a New Orleans thing:

| Wall | Where it belongs | How it is built |
|---|---|---|
| Levee | river side of the Quarter, Marigny, Algiers; the lakefront | trapezoid profile extruded along a Path3D (`CSGPolygon3D`, Path mode), crest 4-6 m; walkable on top where a corridor runs along it |
| Flood wall | Industrial Canal, the canal stubs, the Rampart line in Phase 1 | thin tall profile on a Path3D; a broken panel is the gate |
| Rubble berm | every closed street end, the bands between pieces | jagged profile on a Path3D, plus `ProtoBlock` piles for corners; impassable |
| Collapsed overpass | the Knot, the I-10 over Claiborne | the real deck from `decks.json` where it stands; fallen spans as tilted `ProtoBlock` slabs on the ground |
| Cemetery wall | both cemeteries | a wall-vault profile on a Path3D round the piece; one gate |
| Water | river, lake, canal, bayou, lagoons, the Ninth's marsh | the pipeline's water (solid collision, `city_water.gdshader`); kept per the 2026-10-15 water rule, nothing else |
| Canopy | City Park, Audubon, Armstrong Park | tall green masses; impassable like buildings |

**Sightline rules.**

- In the follow view (pitch 60, range 120 m) the player sees about 200 m
  ahead. Standing at a corridor mouth, they must see the next destination's
  wall and its gate, never open ground. Walls are placed to that test, in
  the editor, by walking it.
- In the tactical view (O key, 400-2400 m) the map is the subject. Every
  destination needs one mass tall or wide enough to be told apart from
  there: spire, dome, tower cluster, bridge towers, cemetery rectangle,
  Ferris wheel, canopy. This is where the user checks the "where am I"
  read, and it is free: the tactical view already exists.
- The district label (`OverworldDistrict`) names the destination the
  player is in and nothing in the gaps: gaps belong to no district, so the
  label going quiet means "between places".

**The fog wall** sits 150-250 m outside the outermost wall, on a boundary
polygon the cut tool writes into `city.json`, so the existing edge field
(`shore_field.py`, `city_edge_fog.gdshaderinc`) and the three fog sheets
work unchanged. Water runs into it (lake, river ends); decks may run into
it. The 2026-10-11 rule stands: nothing reads clearly past the line.

## Authoring split

### Tools make the tedious part

A new, small tool, `tools/blockout/diorama_cut.py`, reads a layout file
`data/blockouts/diorama/diorama.json` and writes a raw dir in the format
`compress.py` already writes, so `osm_city.py` -> `shore_field.py` ->
`city_gltf.py` run unchanged after it. numpy/shapely-first, no per-feature
Python loops; it is a clip-and-transform, the same vectorised shapely calls
`compress.py` uses.

`diorama.json` holds, per piece: a source polygon in lat/lon (traced on the
parish raw), a placement (translation and rotation in the diorama frame),
and a name. Plus: the water polygons (hand-drawn in the diorama frame, the
river as one smooth arc), the boundary ring, the marks (landmark lat/lon ->
diorama position, written to the raw's `warp.json` so `osm_city.py`
carries them into `city.json` and `city_gltf.py` puts Start at Jackson
Square as it does today), and **injections**: synthetic footprints the raw
does not have. The first injection is tomb rows over a cemetery polygon
(OSM draws cemeteries as ground, not tombs), generated as a numpy grid of
small footprints with lanes, so they become building masses with collision
and the blocks shader for free, no new node type.

Decks: left out of Phase 1 (`--drop-ways` / no LiDAR crop). From Phase 2
the cut tool crops and moves `lidar_decks.npz` per piece the way
`compress.py`'s `move_lidar` does, and `decks_seed.py` solves the rest.

### The editor holds the composition

`world/diorama_overworld.tscn`, written once by `city_gltf.py --scene`
(exactly as today, so Start, camera, fog sheets and light come for free),
then owned by hand. Rebuilding the geometry never touches it.

```
DioramaOverworld            overworld.gd (unchanged)
  CityGeometry              instance of world/diorama/city.tscn, city_geometry.gd   <- generated
  BoundaryFog/Sheet0..2                                                              <- generated once
  Walls/                    Path3D + CSGPolygon3D (Path mode, use_collision) per wall
    LeveeRiver, FloodWallRampart, RubbleCanalEnd, RubbleEsplanadeEnd, CemeteryWall ...
  Ruins/                    ProtoBlock piles, fallen slabs
  Landmarks/                placeholder hero masses: Cathedral, Dome, BridgeTowers ...
  SpawnPoints/              Start, doors (overworld_door.tscn + AreaExit child), terminals later
  Districts/                OverworldDistrict polygons (one per piece)
  OverworldCamera, WorldEnvironment, DirectionalLight3D
```

Walls use `CSGPolygon3D` in Path mode along an editor-drawn `Path3D`: a
built-in node, a profile the user can reshape, a curve they can drag point
by point, and collision from `use_collision`. No script. The nav grid
cannot see CSG collision, which does not matter here (no nav grid on the
overworld) and is the reason the same trick is not for combat areas. A
`world/ruin_kit/` folder holds a few saved scenes (levee, flood wall,
rubble berm, cemetery wall) that are just a Path3D with a pre-set profile
and material, so a new wall is "instance, drag the curve". Hero landmarks
are `ProtoBlock` stacks or a `CSGPolygon3D` spire until assets exist.

Doors keep the existing pattern (door instance + its own `AreaExit`
child); the four existing doors are re-placed, not re-made. Districts: in
Phase 1 three polygons drawn by hand; from Phase 2 the cut tool emits them
once per piece (the write-once rule `districts.py` already follows) because
each piece is a district by construction.

### Reuse and retire

| Keep, unchanged | Keep, used later | New | Park (not deleted) |
|---|---|---|---|
| `osm_city.py`, `shore_field.py`, `city_gltf.py` | `decks_seed/mesh/simplify.py`, `bridges.py`, `heights.py`, `lidar` npz (Phase 2+) | `diorama_cut.py`, `diorama.json` | `compress.py`, `parish_*.py`, `junctions.py`, `districts.py` |
| all `world/*.gdshader`, `world/materials/*`, `city_geometry.gd`, edge fog, fog sheets | the parish raw (`new_orleans_parish_raw`, the tracing source) | `world/ruin_kit/*.tscn` | the schematic mockup (keep its avenue/landmark list as reference) |
| `overworld.gd`, avatar, camera, door, `OverworldDistrict`, `ProtoBlock` | terminal scene (Phase 6) | `world/diorama_overworld.tscn`, `world/diorama/` | `world/nola_*`, `world/city_overworld/` (live until promotion) |

`build_osm_blockout.gd` (per-building CSG, `jackson_square.tscn`) stays
the combat-area builder; it is the right LOD for a tactical area, not for
the overworld.

## Phase 1: the Quarter, the cemetery and Treme

One contiguous cut from the parish raw: Canal St to Esplanade, the river to
Claiborne. About 1.5 x 1.0 km at 1x. No compression yet; Phase 1 tests
pillars 1, 3, 4 and 5 (composition, walls, identity, editability) on real
ground. Pillar 2 (compression between places) is Phase 2's test.

### Contents

| Piece | What is in it | Walls and gates |
|---|---|---|
| French Quarter | the real grid at 1x as block masses; Jackson Square open; a placeholder cathedral spire (hero mass, ~40 m); Start in the square | river levee along Decatur/the Moonwalk (crest 5 m, walkable); rubble across the Canal St end (future gate to the CBD) and the Esplanade end (future gate to Marigny); the Rampart wall with two gates: St Louis St -> cemetery, Orleans/St Peter -> Congo Square |
| St. Louis Cemetery No. 1 | injected tomb rows with two lanes | cemetery wall all round, one gate on Basin St; a door in the middle to a new combat area (reuse `test_area_2.tres` contents as the placeholder target if no new area exists yet) |
| Treme / Congo Square | Armstrong Park canopy, Congo Square open, Treme's block masses north of it | the I-10 Claiborne line as a wall (hand, a tall rubble/deck-edge profile; the real deck returns in Phase 2); rubble closing the Esplanade and Canal ends |

Doors: `StLouisCathedral` -> `cathedral_of_shadows` (moved onto the square's
cathedral end), `CongoSquare` -> `test_arena` (unchanged target), a new
`StLouisCemetery` door. `WashingtonSquare` and `LafayetteSquare` are
outside the slice and wait for Phases 2 and 3.

### Build steps

1. **Layout file.** Write `diorama.json` with the one source polygon, an
   identity placement, the boundary ring 200 m out, the river arc along the
   levee's far side, the Jackson Square mark, and the tomb injection over
   the cemetery polygon.
2. **`diorama_cut.py`, minimal.** Clip + transform + boundary + marks +
   injection. Output: a raw dir under `data/blockouts/diorama/raw/`
   (untracked, like every build dir; `.gdignore`).
3. **Build.** `osm_city.py` (no decks) -> `city_gltf.py data/blockouts/diorama
   world/diorama`, which writes `world/diorama_overworld.tscn` once. Open in
   the editor; confirm fog, shore and Start.
4. **Ruin kit.** Four saved scenes under `world/ruin_kit/`: levee, flood
   wall, rubble berm, cemetery wall. Each is a `Path3D` with a `CSGPolygon3D`
   child in Path mode, profile set, `use_collision` on, a flat material.
5. **Compose.** In the editor: place the walls and gates from the table,
   the hero spire, the three doors, three district polygons. Check every
   corridor mouth against the follow-view sightline rule by walking it in
   the editor's camera, then in-game.
6. **Tune presentation.** Avatar speed, camera range, icon scale, the
   fog-sheet heights, until the slice feels dense. These are scene
   properties (`avatar_speed_scale`, `OverworldCamera.distance/height`),
   not rebuilds.
7. **Hand over for the walk.**

### Acceptance: the user walks it

Judged by feel, in game, with these questions in hand:

- Can you tell where you are, at every moment, without the label?
- From any gate, do you see the next place's wall or silhouette, and
  nothing that reads as open paving?
- Is anything more than ~20 s from the nearest thing with an identity?
- Do the walls read as New Orleans (levee, cemetery, Rampart, I-10) and
  not as generic barriers?
- Is the Quarter still the Quarter at this camera, or does its grid read
  as a slab from above? (If yes: either the camera comes down, or the
  Quarter gets interior walls on Royal/Bourbon, both cheap.)
- Did composing the walls in the editor feel like level design, or like
  fighting the tools?

Sign-off means "yes, more of this". Anything else means the plan changes
here, not after five more districts.

## Later phases

Each gated on the user's walk of the previous one.

| Phase | Adds | What it tests | Pipeline change |
|---|---|---|---|
| 2 | CBD/Superdome, Canal St corridor, Lee Circle knot | the first compressed gap (a 150 m rubble band where reality has none); the first collapsed deck; the dome as a tactical-view anchor | LiDAR crop per piece; decks back on; district emission from the cut tool |
| 3 | river at full width, CCC deck, Algiers, Marigny, Industrial Canal / Lower Ninth | water walls; a long deck walk; the flood wall gate; the standalone marsh | the river as a drawn arc replacing OSM water; the lock as a hand gate |
| 4 | City Park, Bayou St John, Lakefront | wilderness-in-city variety; the lake into fog; the levee with water above the street | canopy injection (tall green masses over park polygons) |
| 5 | Garden District / Lafayette Cemetery, St Charles, Six Flags, optional Audubon | the map's two ends; whether 14 is too many | none expected |
| 6 | terminals, the ruin generator if hand-placing has become the bottleneck, promotion, minimal tests | the whole map as one walk | `data/areas/overworld.tres` -> the diorama (user approval); one small test that the scene loads and Start lands on ground, written last |

The ruin generator (a `ruin.py` pass filling every gap between pieces and
corridors with rubble masses, hand overrides kept) is deliberately not in
Phase 1. If three pieces' worth of walls is pleasant to place by hand, the
generator may never be needed; if it is tedious, Phase 2 is the moment to
know. Either way it stays a layer over the intact pieces, per the
2026-10-11 note.

## Risks and open questions for the user

1. **Islands plus corridors was rejected once.** On 2026-10-13 the user
   turned down "districts, ribbons and rubble" because the map had to fill
   one continuous shape. This plan is that idea with the gaps authored as
   walls and rubble instead of left empty, and it follows from the
   diagnosis they agreed with on 2026-10-15. It needs saying out loud: is
   the continuous-shape requirement withdrawn, or must the gaps also read
   as city (which puts the parish problem straight back)?
2. **1x inside destinations, or miniature?** IV shrinks its buildings and
   widens its roads as well as deleting ground. The plan keeps 1x inside a
   piece because the 2026-10-10 decision chose true proportions and the
   avatar/camera are tuned to them. Changing this changes every piece, so
   it should be decided from the Phase 1 walk, not later.
3. **Avatar speed.** 64 m/s was set for a 245 km² map. The plan expects it
   to come down; if the user wants it kept, the spacing roughly doubles and
   the map grows to about 8 x 6 km. Decide during Phase 1 tuning.
4. **Door targets.** The four doors keep their test areas as placeholders.
   The cemetery door needs a target: a new area, or a placeholder for now?
5. **The Superdome as a dome.** The most SMT-specific idea here (Tokyo's
   ceiling, with the dome as its local cousin) only pays off if the CBD gets
   story weight later. If the user does not want that reading, the CBD is
   still a destination, just a plainer one; nothing else moves.
6. **Fourteen may be too many** for a solo dev to compose by hand. The
   phases are ordered so the map is complete and walkable after Phase 3
   (seven places, river to Claiborne); 4 and 5 are expansion.

## Constraints

- Everything new lives beside the old: `world/diorama_overworld.tscn`,
  `world/diorama/`, `world/ruin_kit/`, `tools/blockout/diorama_cut.py`,
  `data/blockouts/diorama/`. `world/city_overworld/` and
  `data/areas/overworld.tres` are not touched until the user says promote.
- Build dirs under `data/blockouts/` stay untracked with a `.gdignore`;
  `diorama.json` is source and is committed.
- Tests last and minimal: none until Phase 6, then one.
- New Python is numpy/scipy/shapely-first; `diorama_cut.py` is clip,
  transform and grid generation, all vectorisable. If an injection ever
  needs a per-item loop, say so before writing it.
- No installs, no downloads: the parish raw already on disk is the whole
  source. Overpass is not touched.
- Commit verified points as the commit policy says, scoped to the new
  files; never push.
