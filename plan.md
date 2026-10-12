# Plan: authored elevated decks from LiDAR + swept splines

Replace the inference layer in `tools/blockout/bridges.py` (height solver, twin
coupling, split-deck cutting, slab gap fill, rail post-pass) with the way shipped
city games do it: measured heights, one authored record per elevated road, a
mesh swept along a spline, and junction pieces where roads meet. The rest of the
pipeline (`osm_city.py` streets/blocks/buildings, `shore_field.py`, fog edge,
`build_osm_city.gd`) stays as it is.

## Why

Every patch since p2a adds a rule that guesses 3D facts a 2D road graph does
not hold: which lines are one deck, whether two ramps are level, whether a slit
is a gap or a pit. Each rule fixes one interchange and regresses another (p2e
fixed K1 at (-812, 2040) and broke the seam at (-88, -63)). Those facts should
be *data*, written once, and the mesh should be built from the data so the
whole stub / gap / exposed-rail family of bugs cannot occur by construction.

## Non-goals

- Re-doing surface streets, blocks, buildings, water, or the fog edge.
- Terrain relief for the whole map (the DTM makes it possible later; not now).
- Survey accuracy. The map becomes an SMT IV style ruin; heights need to be
  plausible and consistent, not exact.
- Nav-grid or walk checks on the overworld (standing rule).

## Facts the plan relies on

- Map frame: `data/blockouts/new_orleans/city.json` — bbox
  `[29.8655, -90.1399, 30.1995, -89.6252]`, origin `(30.03247, -89.88255)`,
  equirectangular metres (`x` east, `z` south), scale 1, vscale 1. Decks are
  already in true metres, so LiDAR heights drop straight in.
- Godot reads decks as triangle lists per tile (`build_osm_city.gd:130`,
  `_load_tris`), coloured by kind (deck/side/pier/rail). The new mesher writes
  the same tile format; the Godot side does not change.
- LiDAR: USGS 3DEP, public domain, covers Orleans/Jefferson/St Bernard. Use
  the **point cloud**, not the 1 m DEM: the DEM is bare earth with bridges
  removed. 3DEP classifies bridge decks as ASPRS class **17** and ground as
  class **2**, which is exactly the pair we need. Fetch through the Entwine
  (EPT) index on `usgs-lidar-public` (AWS, no key), which lets us pull only
  the octree nodes that intersect a bounding box, so we read a strip around
  the elevated roads rather than the whole 50 × 37 km extent.
- Polite fetching (standing rule): one pass, cache every node on disk under
  the scratchpad, back off on errors, no parallel hammering. Estimated volume:
  elevated roads ~150 km × 40 m strip ≈ 6 km², ≈ 50 M points, a few hundred MB
  of LAZ. Confirm the dataset name and size from the EPT `boundaries` index
  before fetching and report it in the status line.
- Permission to fetch LiDAR was given 2026-10-11.

## Steps

Each step ends with: measure, sabotage-check (break it, see red), commit
(scoped paths only, never push). Baseline for every comparison is step 1.

### 1. Freeze a baseline (½ session)

- Install **p2d** (fewer open regressions than p2e) into
  `world/city_overworld/city_geometry.scn`.
- Run the overworld suites; record `stubs.py` / `gaps.py` numbers for p2d.
- Commit `tools/blockout/bridges.py` + `city_geometry.scn` as "last rule-based
  build". Record the flyover (`tools/_probe/city_tour`) for the before/after.

Baseline recorded 2026-10-11 (p2d; the flyover moved to step 7):

- `bridges.py` is the p2d code: it differs from p2e only in `_couple`'s tie
  width for non-twins (`0.5` m, p2e had `GAP_FILL`). Re-running it and
  `shore_field.py` on a fresh copy of `nola_test_c` reproduces the p2d
  blockout byte for byte (and differs from p2e's deck tiles).
- Committed with it: the rest of the pipeline that built p2d
  (`build_osm_city.gd`, `osm_city.py`, `shore_field.py`, the `city_*`
  shaders, the new `city_ground.gdshader` and `city_edge_fog.gdshaderinc`
  the scene loads), so the committed scene and its sources agree.
- `stubs.py`: **107** stub faces at **13** sites (p2e: 93 at 10).
- `gaps.py`: **13** rail discontinuities, 87.4 m; **12** of them falls
  (86.4 m), 1 plain gap (1.0 m), 0 holes, 0 flicker (p2e: 13 falls, 94.4 m).
- Overworld suites (`tests/run.sh --suite=` arrival_placement,
  a_rebuild_is_not_a_journey, a_split_party_survives_a_save,
  member_reachability, party_split, the_cathedral_is_a_room_not_a_menu):
  **90 checks across 6 suites, all pass**. Sabotage: a blank
  `city_geometry.scn` turns them red (1 of 13 failed in the first two).

### 2. Elevated-road inventory + LiDAR fetch (1 session)

`tools/blockout/lidar_fetch.py <raw> <out>`:

- From `features.json`, collect every way with `bridge=*` or `layer>0` on a
  road, plus `EXPRESS` classes (`motorway*`, `trunk*`) — the same set
  `bridges.py` treats as deck candidates. Buffer each by its width + 10 m,
  union, convert to lat/lon then to the dataset's CRS (3DEP EPT is usually
  UTM 15N / NAVD88; read it from `ept.json`).
- Walk the EPT octree, download nodes intersecting the buffered area to
  `scratchpad/lidar/<dataset>/`, keep classes 2 and 17 only (and 1
  "unclassified" as a fallback where 17 is missing).
- Write `data/blockouts/<name>/lidar_decks.npz`: thinned points
  `(x, z, h, cls)` in map metres. Report count and coverage: which candidate
  ways have < 50 % of their length within 5 m of a class-17 point.

Verify: plot the points over the OSM road lines for three known spots
(Pontchartrain Expressway at K1, the CCC approach, the (-88, -63) ramp pair);
deck returns must sit on the drawn roads and ground returns beside them.

LiDAR fetched 2026-10-11 (`lidar_fetch.py fetch` / `plot`):

- Inventory from the full `new_orleans` raw: **1035** deck ways (275.3 km;
  562 bridge, 563 layer>0, 785 express) plus 636 approach stubs (150 m of
  each road that shares a node with a deck way, 84 km). Strip = width/2 +
  10 m, clipped to the city region + 60 m runout: **8.17 km²**.
- Datasets from `hobuinc/usgs-lidar` `resources.geojson`, newest first:
  **LA_2021GNO_1_C22** covers 7.89 km² of the strip and supersedes
  LA_CoastalLouisiana_1_2020 and ARRA-LA_Coastal-Z16_2011 entirely.
  0.28 km² is in no dataset: the open lake (I-10 Twin Spans, Maestri Bridge).
  SRS is **EPSG:3857** horizontally (not UTM 15N), vertical unstated in
  `ept.json`; reprojected by hand. Heights are plausible: ground median
  −0.5 m, deck median 7.5 m, 99th percentile 50.8 m.
- Depth 11 (0.74 m spacing), 4835 nodes. Estimate printed before the bulk
  download: 1.47 GB (per-depth bytes/point from 34 HEADs). Actual:
  **1472 MB**, 4697 requests, sequential on one kept-alive connection,
  ~17 min, cached under `scratchpad/lidar/`. Rerun from the cache: 0 requests,
  identical npz.
- `data/blockouts/new_orleans_lidar/lidar_decks.npz` (not inside
  `new_orleans`): **20.8 M points**: 17 = 13.0 M (all kept), 2 = 1.60 M
  (lowest per 2 m), 1 = 6.20 M (lowest per 1 m). It is in the
  `new_orleans` frame; `lidar_fetch.load(path, city)` moves it into another
  `city.json` frame (the trouble spots are in `nola_test_c`'s).
- Coverage (`lidar_coverage.json`, within 5 m of a class-17 point):
  length-weighted 52.3 %; 460 ways under half. Most of these are at-grade
  expressways, which correctly have no deck returns. Bridge ways are 89.7 %
  covered; 31 are under half: the lake bridges (no data), part of the
  Westbank Expressway, and short canal bridges classified as ground.
  Step 3 needs the solver for these.
- Plots (`nola_test_c` frame): K1 (−812, 2040), the CCC approach
  (450, 2900) and the (−88, −63) ramp pair all show class 17 on the drawn
  deck lines and ground beside them. At the ramp pair the 17 stops where
  the legs come down to grade.
- Sabotage of the coverage measure: deleting 17 within 150 m of K1 drops
  its three ways from 1.00 to 0.33 / 0.09 / 0.43. Shifting all 17 by
  20 m drops the weighted coverage 52.3 → 37.7 %. A 3 m or 8 m shift is
  **not** visible in the totals (52.2 / 51.0 %) because parallel decks
  cover each other. Coverage is a presence check; registration is checked
  by the plots.

### 3. `decks.json`: one authored record per elevated way (1 session)

`tools/blockout/decks_seed.py <raw> <out> [--from solver|lidar]` writes
`data/blockouts/<name>/decks.json`:

```
{ "way": 1076344867, "name": "Pontchartrain Expressway", "class": "motorway",
  "width": 14.0,
  "nodes": [ {"id": 1234, "x": -812.3, "z": 2040.1, "s": 0.0, "h": 11.6}, ... ],
  "twin_of": 595991564 | null,          # drawn as one wide profile with it
  "merges": [ {"into": 12687616, "at_s": 220.0, "over": 60.0} ],
  "splits": [ ... ],
  "source": "lidar" | "solver" | "hand" }
```

- `h` is deck height above local ground: for each node take the 20th
  percentile of class-17 returns within half the road width of the centreline
  over ±5 m along it (rejects cars, signs, canopy), minus the median class-2
  height within 15 m. Where fewer than 20 deck returns exist, fall back to the
  current solver's height and mark `source: "solver"`.
- Smooth along each way with the existing grade limit (`GRADE_MAX 0.12`) as a
  clamp, not as a solver: a node that would need a steeper grade than that to
  reach its neighbours is listed, not moved.
- `twin_of` seeded from `_couple`'s pairing but only kept where LiDAR shows the
  two decks within 0.4 m (`STEP_MAX`) over 80 % of their shared length.
- `merges` / `splits` from shared end nodes between ways of the deck set.
- Hand edits live in this file; `source: "hand"` entries are never overwritten
  by a re-seed (re-seed merges, does not replace).

Verify: per-way height profiles plotted LiDAR vs solver for the five known
interchanges; clearance report (every crossing under 7 m, by coordinate) — a
list to edit, not a thing to solve.

### 4. Swept-ribbon mesher (2–3 sessions)

`tools/blockout/decks_mesh.py <out>` replaces the drawing half of `bridges.py`:

- Centreline: Catmull-Rom through the way's nodes (chordal parameterisation
  so dense OSM nodes do not kink it), heights interpolated with the same
  spline, sampled every `STEP 5 m` and at every node.
- Profile per sample (one polyline, mirrored): deck top at `width/2`, kerb,
  rail (`RAIL_HEIGHT 2.0`, `RAIL_THICK 0.4`), side down `THICK 1.5`, underside.
  Twins: one profile of combined width. Rails are part of the profile so they
  start and end with the deck; no rail post-pass, no stub rule.
- Ends: the deck meets the ground where `h` reaches `MIN_HEIGHT`; the last
  profile is dropped to ground height (ramp toe), no mid-air ends.
- Piers every `PIER_STEP 40 m` where `h > PIER_MIN`, from the existing
  `_disc` / pier code, unchanged.
- Output: the same per-tile triangle kinds Godot already reads.
- Delete once the ribbon path is green: `_couple`, `_twins`, `_beside`,
  `_pieces`, `_half`, `_fill_gaps`, `_fill_slab`, `_fill_gap`, `_slab`,
  `_rails`, `_despike`, `_level`, `_level_junctions`, the height solve call
  and `heights.py`, and their constants (`SLIVER`, `CLEAR_*`, `SPLIT_COS`,
  `GAP_*`, `HOLE_FILL`, `RAIL_JOIN/PROBE/WELD/GAP/OPEN/SPECK`, `SMOOTH`,
  `LEVEL_SPAN`, `FOOT`). Keep `bridges.py` only as the deck-set filter and
  OSM reader, or fold that into `decks_seed.py`.

Verify: `stubs.py` and `gaps.py` on the build — expected **0** stub faces and
**0** gap stretches (they become regression assertions from here on); shots at
the full sign-off list (`audit/signoff/spots.txt`) plus S7, H2, K1, E8;
underside clearance report unchanged from step 3.

### 5. Junction gores (1–2 sessions)

Where `merges` / `splits` say two ribbons join:

- Over `over` metres before the join, loft a tapered polygon between the two
  ribbons' inner edges (the gore), its heights sampled from both ribbons, its
  rail only on the outer side. The two ribbons' inner rails stop where the
  gore starts.
- Crossings need nothing: with measured heights clearance is a property of
  the data; the report from step 3 is the to-do list.

Verify: shots at every merge (list them from `decks.json`); no inner rail
inside a gore; the gore's edge heights match both ribbons within 0.05 m.

### 6. Hand pass on the interchanges (½–1 session each)

From the step-3 report and the shots, expect four to six: Pontchartrain
Expressway / I-10, Claiborne (I-10 over N Claiborne), the Crescent City
Connection approaches (both banks), I-610 / Elysian Fields, Chef Menteur /
I-510. For each: fix heights and `twin_of` / `merges` in `decks.json`, mark
`source: "hand"`, rebuild, shoot. Where a junction needs a shape no gore can
give, place a hand-made mesh in `city_overworld.tscn` and note it in the
record (`"junction_scene": "res://world/junctions/<name>.tscn"`).

### 7. Fresh-eyes sweep, suites, commit, flyover (½ session)

Pass-3 as agreed: sign-off sheet, overworld suites, commit, record and send
the flyover MP4, re-rate the map against the step-1 baseline.

## Verification policy

- Sabotage every step: feed `decks_mesh.py` a record with a 1 m step between
  twins and confirm `gaps.py` goes red; drop a `merges` entry and confirm the
  gore vanishes in the shot; shift a LiDAR sample by 3 m and confirm the
  coverage report flags it.
- Read the check counts, not just the green (runner prints "ok" through a
  script error).
- One Godot process at a time, always under `timeout`; builds in the
  background (~8 min each).

## Cost and risk

| step | sessions | risk |
|---|---|---|
| 1 baseline | ½ | none |
| 2 LiDAR | 1 | dataset lacks class 17 → fall back to first-return minus ground; more noise |
| 3 decks.json | 1 | OSM centreline off the real deck by > half a width (common on ramps) → use the LiDAR deck centroid, not the OSM line, for `x, z` too |
| 4 ribbon | 2–3 | self-intersection on tight ramps (loop ramps at I-10/I-610) → clamp profile width to local curvature radius |
| 5 gores | 1–2 | gore geometry is where every tool looks worst; accept hand meshes for the ugly three or four |
| 6 hand pass | 3–5 | labour, not risk |
| 7 wrap | ½ | — |

Roughly 9–13 sessions. Against that: the current loop has no end condition.

## Later, not now

- Ground relief from the class-2 DTM (Esplanade Ridge, levees, the Claiborne
  rise) as a heightmap under the city — the data will already be on disk.
- Ruin layer over the decks (collapsed spans are just records with a gap in
  `nodes` and a `broken_end: true` flag — the ribbon mesher can draw the
  torn end profile).
- An in-editor spline tool for `decks.json`; hand edits in JSON are fine at
  five interchanges.

## Standing constraints

Commit verified work without asking, scoped to `tools/blockout/*`,
`world/city_overworld*`, `world/city_*.gdshader*`; never push; never commit
`data/blockouts/*`, `world/nola_test*`, `tools/_probe/*`, stray `.uid`,
`__pycache__`. Never overwrite `data/blockouts/new_orleans`. Python with `-I`.
No comments in `.tscn` / `.tres`. Never `git checkout/stash/reset/restore` on
the uncommitted tree. Fix causes, not symptoms.
