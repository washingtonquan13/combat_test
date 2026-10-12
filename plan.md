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
  two decks within 1.5 m (`TWIN_STEP`; was 0.4 m `STEP_MAX`, changed in
  step 4) over 80 % of their shared length.
- `merges` / `splits` from shared end nodes between ways of the deck set.
- Hand edits live in this file; `source: "hand"` entries are never overwritten
  by a re-seed (re-seed merges, does not replace).

Verify: per-way height profiles plotted LiDAR vs solver for the five known
interchanges; clearance report (every crossing under 7 m, by coordinate) — a
list to edit, not a thing to solve.

Seeded 2026-10-11 (`decks_seed.py`, `bridges.py` split into
`read` / `solve` / `draw` so the seed reuses the solve; the `nola_test_c`
rebuild from the refactored `bridges.py` is byte-identical to `nola_test_p2d`):

- `data/blockouts/nola_spline` (copy of `nola_test_c`) now has `decks.json`
  and `decks_report.json`. Seeding takes about 6 min, mostly the solve.
  Deck set in the region: **193 ways** (133 bridges), **15307 nodes**.
  Node `src`: lidar 11210, solver 1394 (< 20 returns), interp 143 (a gap of
  60 m or less between measured nodes on one way). Records: lidar 144,
  solver 49.
- Departures from the format above:
  - `twin_of` is a list, because a carriageway pairs with several ways along
    its length.
  - Each node also carries `src` and `hs` (the solver height).
  - Merges and splits also give `into_s` / `from_s`.
  - A `continues` list holds shared end nodes where the two ways meet at the
    same height and direction.
  - The steep, join, twin, shift and clearance lists are in
    `decks_report.json`.
- Occlusion: the solve stacks a lower deck under I-10, and LiDAR sees only
  the top deck. Each node therefore masks the footprint of every deck the
  solve puts more than 2 m above it, and drops candidates within 1.5 m of that
  deck's measured height. Without this, Claiborne under I-10 measured
  I-10's 10 m.
- Layers: a Viterbi pass per way picks one LiDAR layer per node, with a grade
  penalty, so stacked decks do not swap.
- x,z: **79 nodes on 7 ways** moved onto the measured deck centroid (most
  5.5 m). A node moves only where the OSM line has fewer than 10 deck returns
  within 1.5 m. Moves are tapered over 20 m, and shared nodes are pinned.
- Heights: LiDAR reads I-10 at K1 as 5–8 m above ground; the solve had
  14–30 m. Measured raised nodes (h > 3 m): median 8.2 m, 10th–90th
  percentile 5.4–12.2 m.
- `twin_of`: 130 pairs seeded from `_couple`, **75 kept**. The 55 rejected
  pairs mostly differ by 0.3–1.2 m (crossfall and superelevation), so a
  0.4 m tolerance is strict.
- Relations: merges 27, splits 27, continues 258.
- GRADE_MAX: **91** stretches steeper than 0.12 are listed, not moved. 67 of
  them are seams where measured LiDAR hands over to a solver toe; 24 are
  measured only. **4** shared nodes have heights more than 0.4 m apart. The
  worst is 12.6 m at (−1292, 1416): ways 122263297/8, the
  Claiborne/Pontchartrain knot.
- Clearance report: **96 crossings under 7 m**, 35 of them deck over deck.
  1 is under 1 m and 5 are under 3 m, all in the Claiborne/Pontchartrain
  interchange around (−1190, 1490), where hidden lower decks fall back to
  solver heights. Most of the rest are 6.5–7 m streets under I-10.
- Re-seed: records marked `source: "hand"` are kept in place by way id, and
  orphans are appended. Tested with one marked way plus one way that has no
  OSM match: 2 kept.
- Plots: S7 (−115, −28), the ramp pair (−88, −63), K1 (−812, 2040), H2
  (−669, 882) and the gap (−2333, 1213) via `--plot name,x,z,r --png-dir`.
  They are in the scratchpad, not the repo.
- Sabotage (each went red, counts read):
  - Occlusion mask off: clearance under 1 m 1 → 44, joins 4 → 17,
    measured-only steep 24 → 41.
  - Viterbi off (highest layer): steep 91 → 164.
  - Twin agreement off: kept 75 → 126.
  - Hand match broken: 2 → 0 kept.
  - LiDAR moved 10 m east near H2: moved nodes 79 → 145 on 11 ways.
  - LiDAR moved 3 m east: only 79 → 84, because a 3 m misregistration stays
    on an 8–12 m deck and is below what the shift can detect.

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

Status 2026-10-12: built, measured and committed. Rule layer deleted from
`bridges.py` (1669 to 597 lines). Bar met: 0 stubs, 0 rail discontinuities,
flicker only at a split mouth.

- Built: `decks_mesh.py` meshes `nola_spline` into 193 records, 66 chains,
  67 pieces, 246 rail runs, 464 piers, 226354 triangles in 13 tiles.
  `world/nola_spline` is built and installed in `city_overworld`
  (scn 16.4 MB). `osm_city.py` runs `decks_seed.py` and then `decks_mesh.py`.
  The full 13-minute `osm_city.py` run has not been re-run end to end.
- Twins are now one surface:
  - `decks_seed.py` keeps a pair where LiDAR puts the two within
    `TWIN_STEP 1.5 m` over 80 % of their shared length (`STEP_MAX 0.4` was
    stricter than the crossfall). Kept: 75 to **110** of 130.
  - The mesher draws a kept pair as one profile. The seam is at the mean, so
    the surface slopes across (crossfall), with no step and no median rail.
    Where a twin stretch meets a real step, a fade leans the edges apart
    over `FADE_GRADE 0.1` (at least `FADE_MIN 5 m`).
  - A twin is drawn wherever its pair is: a piece's `high` test uses the
    larger of its own and its pair's height. One carriageway dipping to the
    ground beside the other is crossfall, not a ramp toe.
  - Stepped seam samples (> 0.5 m): **861 to 424**. 419 of them are between
    non-twins, which is correct. 5 are between twins at a toe, where one
    carriageway leaves the deck and the other carries on:
    - 1050679315/316 at (-2330, 1196): 4 samples, up to 1.75 m. The data
      ends are staggered; 315 ends free at 1.9 m. Hand pass in step 6.
    - 31678150/118807768 at (-2062, 814): 1 sample, 0.51 m, just over the
      0.5 m weld.

    A twin toe keeps its step and rail: drawing it as crossfall leaves a
    0.91 m GAP at (-2330, 1198).
  - Crossfall: 1488 samples, 12 of them leaning off it towards a step.
- Measures on `nola_spline`:
  - `stubs.py`: 0.
  - `gaps.py`: 0 discontinuities, 0 m (open 50271 m, of it guarded
    50270 m).
  - FLICKER: 1, at a split/merge mouth only. It is 2.71 m at (-879.05,
    1104.42), the split mouth of 118807820 off 161590919. It moves to
    step 5 as gore work.
  - Clearance: 88 crossings under 7 m. Steep stretches listed: 54
    (step 3 had 91).
- Rule-layer trim: the full seed with the untrimmed `bridges.py` and the
  full seed with the trimmed one produce the same `decks.json`. The trimmed
  seed is also byte-identical to the cached-solve seed. Meshing with either
  `bridges.py` gives byte-identical tiles.
- Departures from the plan:
  - A continue's height comes from the record.
  - `_over_it` is re-run after `_shift`.
  - Twin seams end in a kerb at the exact crossing.
  - `heights.py` and the solve are kept, because the `decks_seed` fallback
    needs them.
  - `edge.bin` was re-baked.
  - E8 has no recorded coordinates; the SEAM pair was shot instead.
  - Twin agreement is `TWIN_STEP 1.5`, not `STEP_MAX 0.4`.
- Sabotage on the final mesher and seed (each fix removed in turn, counts
  read):

  | Fix removed | Result |
  | --- | --- |
  | rail at a genuine non-twin step | 19 discontinuities, 293.9 m |
  | meet | stubs 95 faces at 16 sites; FLICKER 1 to 7 (14.3 m) |
  | fade | 1 DANGLING, 2.4 m |
  | square rail inward | 2 GAP_FALL, 10.4 m |
  | lone | stubs 2 faces at 1 site |
  | pair rule | twin-toe steps 5 to 22; A (-1640, 1180) comes back, 2.0 m |
  | twin toe exclusion | GAP 0.91 m at (-2330, 1198) |

  - Twin forced 1 m apart: all nodes of 682521418 raised 1.0 m. The pair
    draws 206 welded samples and **0 stepped**; crossfall rises from 1488
    to 1695, and `gaps.py` stays 0/0. `twin_of` wins, by design.
- Shots: the sign-off list plus S7, H2, K1, the seam pair, the flicker
  mouth and the twin-toe spots. K1's long median rail is gone: that LiDAR
  step was a twin, and it is now crossfall. The short K1 rails that remain
  are non-twin steps. TB (-2330, 1196) is past the fog edge, and A1 to A3
  show only fog. TC (-2062, 814) shows its short toe rail at ground level.
  D2, D3, S7 and the flicker mouth are unchanged.

Status 2026-10-12 (review fixes): the step-4 review's 10 findings were fixed
at their cause, rebuilt, re-measured, re-shot and sabotage-checked.

- Departures, now declared:
  - The rail post-pass (`_rail_runs`) is kept. Rails are not part of the
    profile, because whether an edge carries a rail depends on what lies
    beside it, and that is only known after the seams are decided.
  - There is no kerb. A 0.15 m kerb would put a lip on every welded seam,
    and steps below WELD are already drawn as one surface.
  - `bridges.py` keeps `_couple`, `_twins`, `_level_junctions`, `SPLIT_COS`,
    `FOOT` and `SMOOTH`. They are live: `solve()` uses them, and
    `decks_seed.py`'s fallback calls `solve()`.
  - `RAIL_DROP 1.0`: a rail run whose edge nowhere stands 1 m above the
    ground is not drawn. Rail runs go from 275 to 250; none of the six
    near-ground pieces (12687193, 24784028, 24784033, 27763857, 27763887,
    181653842, h max 0.36-0.81 m) keeps a rail.
- Seams are decided once per pair (`_pair_seams`):
  - One shared polyline of knots. Each seam sample of either deck is
    inserted into the other's edge, and samples closer than `KNOT_SNAP 0.5`
    merge.
  - Weld/step uses hysteresis `WELD 0.5 +- WELD_HYST 0.15`. Each
    weld-to-step change is a doubled point.
  - Knot order: consecutive knots closer than `KNOT_SNAP`, or stepping back
    along either deck in that deck's own order, are put at one place.
  - `_resample` reads a point that only the other side placed off its own
    side's line.
  - `pc.toe` is carried through `_cut`, `_trim` and `_resample`.
- Third-deck rule (`_across_third`, `BETWEEN 1.0`): there is no seam across
  a third deck whose centre line passes between the two at a similar height.
  This does not apply within half the third deck's width of its own end. A
  ramp starting at a split mouth is not between the two decks, and dropping
  the seam there left 3 rail-stub faces at 2 sites, (-1364, 1380) and
  (-602, 2198).
- Measures on the final build. Totals are 67 pieces, 223 rail runs, 465
  piers and 253054 triangles.
  - `stubs.py` 0; `gaps.py` 0 discontinuities, FLICKER 1 (the step-5 mouth).
  - The independent `cracks.py` (deck-top boundary edges probed outward):
    - Crack length: 3374.7 m (step-4 commit), then 537.9, now **428.5 m**.
    - Clusters: 157, then **99**.
    - Smallest bins (0.05 / 0.1 m): 8159 / 3183, now 462 / 414.
  - Folds (seam segments stepping back over 5 cm): 246 without the order
    rule, 7 with it (each at most 0.1 m).
  - `weldscan`, welded edge gaps of 0.05-1 m: 580, now 3. Stepped blips
    under 3 m: 4, now 0.
  - Unequal-width twins, synthetic, widths 8/14 m at 9.5/11/12.5 m apart:
    - The seam is on the midline: 5.34-5.50 m from both centres at 11 m.
    - 230 of 236 seam vertices are shared with the other deck.
    - The 6 unshared vertices are at the toe steps, as in the equal-width
      control.
- Sabotage. Each fix was removed in turn and the counts read. All rows but the last were measured against the build before the end exclusion.

  | Fix removed | Result |
  | --- | --- |
  | Order rule | folds 7 to 246 |
  | `RAIL_DROP` | rail runs 250 to 275 |
  | Hysteresis | weld/step transitions 28 to 77; blips 0 to 5; steps 231 to 307 |
  | Own-point interpolation | folds 7 to 40 |
  | Third-deck rule | seams 5091 to 5344; 4 pairs one-sided |
  | Toe carry | toe samples 230 to 218; seam samples at a toe 57 to 45 |
  | Third-deck end exclusion | stubs 0 to 3 faces at 2 sites |

- Shots: R1-R6, S01-S11, B1-B3, the sign-off list and the two stub sites.
  - R5 has no rails or U stub.
  - The B1 sparkling seam is gone.
  - The stub sites show continuous seams.
- Residuals, open:
  - `_meet` and `_trim` still act per piece. They leave unshared points at
    toe steps and coplanar overlap outlines at trimmed merge ends:
    - R1 2.6 m;
    - (-2067.6, 822.3) 8.5 m;
    - faint dotted lines at B1, S05, S07 and S10.
  - weldscan has 3 gaps of 0.76-0.96 m: (95, -121), (-1018, 1351) and
    (-1332, 1201).
  - R5's staggered toes leave a ground notch and a water sliver.

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

Status, 2026-10-12: built (`decks_mesh.py` `_gores`).

- Departures from the plan above:
  - The gore is not `over` long. It runs from the apex, where the branch's
    inner edge leaves the trunk, to the nose, where the two edges are
    `GORE_NOSE` (= `NEAR_GAP`, 2 m) apart, or `GORE_DH` (= `WELD`,
    0.5 m) apart in height, or `GORE_MAX` (120 m) along, or a third deck
    is met. `over` is the overlap before the apex, already drawn by step 4.
  - The nose is searched along both edges and the earlier one wins. A step
    in the trunk's edge beside the gore parts the two as surely as one in
    the branch's.
  - The gore's edges are the two pieces' own edge points: apex and nose
    are inserted into both edges, so the heights are theirs, not sampled.
  - Where the edges cross at the apex, the apex has two heights. Each edge
    gets its own first triangle and a wall closes the step between them.
  - The gore has no outer rail; a rail across the nose closes it. Inner
    rails start at the nose because the gore is a deck to the rail probe.
  - A join with no V is listed and skipped, not forced: 19 of 54. 14 are
    a step of 0.76-8.03 m at the apex (a ramp still above or below the
    trunk), 4 have the branch end off the trunk (end-to-end runs on), 1
    never leaves the trunk, 1 has its apex off the trunk's edge.
- Measures (`nola_spline`, scripted `verify.py`):
  - 35 gores, 336 probes at edge vertices and midpoints: worst gore/ribbon
    height difference **0.0174 m**; 0 gores over 0.05 m or unprobed.
  - Twist (one edge against the other beside it): worst 0.510 m, 0 over
    `GORE_DH` + 0.02.
  - Rail triangles within 0.5 m of a gore, apex side of its nose: **0**.
  - Rail runs 223 to 258 (+35 nose rails); piers 465, unchanged;
    triangles 253054 to 255240.
  - Stubs 0; rail discontinuities 0; FLICKER 1, the same site
    (-879.05, 1104.42). Cracks 428.5 m in 99 clusters to 285.3 m in 67.
- Sabotage. Each fix was removed in turn and the counts read.

  | Fix removed | Result |
  | --- | --- |
  | One `merges` entry (31678110 into 1076293558) | gores 35 to 34; the notch and its inner rails are back in the shot |
  | Gore heights from the branch alone | gores over 0.05 m 0 to 28; worst 0.017 to 0.510 m |
  | Nose searched on the trunk's edge | twist over limit 0 to 2 (0.556 m) |
  | Apex split | gores over 0.05 m 0 to 6; worst 0.293 m |
  | Gores in the rail probe | rail triangles at gores 0 to 618, at 34 of 35 gores |

- Shots: all 54 joins, two yaws each, in the installed overworld; top-down
  before/after pairs of all 35 gores. j45 and j47 are fogged in the 3D
  shots (the map-edge wall); their top-downs are fine.
- Step-6 candidates, worst first:
  - j29, 89752721 into 1076357014 (-640.5, 2190.7): a hexagonal hole
    between three decks, railed round. It was there before step 5.
  - j50, 929869791 into 1076321093 (433.4, -533.4): a closed railed slot
    between the branch end and the trunk. It was there before step 5.
  - j49, 682521447 / 118807749 (-1362.7, 1194.6): the V is left open; the
    apex falls off the trunk's edge.
  - j31, 118807820 / 161590919 (-877.2, 1097.6): the FLICKER site; the
    branch end is off the trunk.
  - Also complex but not a gore: j10, 12688778 (-1191.3, 1641.6), an 8 m
    step between levels.

### 6. Hand pass on the interchanges (½–1 session each)

From the step-3 report and the shots, expect four to six: Pontchartrain
Expressway / I-10, Claiborne (I-10 over N Claiborne), the Crescent City
Connection approaches (both banks), I-610 / Elysian Fields, Chef Menteur /
I-510. For each: fix heights and `twin_of` / `merges` in `decks.json`, mark
`source: "hand"`, rebuild, shoot. Where a junction needs a shape no gore can
give, place a hand-made mesh in `city_overworld.tscn` and note it in the
record (`"junction_scene": "res://world/junctions/<name>.tscn"`).

**Status: done 2026-10-12.** Edits live in `nola_spline/decks.json`, versioned
as `tools/blockout/decks_nola.json` (data/blockouts is not committed).

- Departures, declared:
  - **Fills, not junction scenes.** Every hole no gore closes was an
    enclosed gap between decks, not a shape a gore lacks. A top-level
    `"fills"` list of seeds `{id, x, z, note}` replaces the hand `.tscn`:
    `decks_mesh` unions the deck tops within 80 m, takes the enclosed ring
    (≤ 3000 m²) holding the seed, and triangulates it, each corner at the
    height of the nearest top vertex. Fills are tops to the rail probe
    (the island rails go) and close a gore's nose rail they cover. They
    rebuild with the decks, so a height edit cannot leave a stale mesh.
    6 fills: j29, j50a, j50b, i10_20, I1, C2.
  - **Heights by one rule, applied by hand.** The cause at j10 and the
    knot: the solve raised at-grade, non-bridge, layer-0 motorway_links
    over bare ground; one "lidar" node (-1171.2, 1649.4, h 12.00) was read
    off the deck overhead. LiDAR class 2 shows ground at 0-0.5 m along
    them. 19 records set to `source: "hand"` (changed nodes `src: "hand"`,
    a `hand` note per record): a node with ≥ 3 ground returns under 0.8 m
    goes to h 0; a lidar node with its own class-17 support keeps its h;
    the rest interpolate along the way under a ramp envelope (grade 0.08)
    from the unchanged records they share nodes with. Shared-node heights
    checked: 0 joins broken.
  - `decks_seed` now keeps `fills` on a re-seed and computes its report
    with the hand heights, so the report lists what is drawn.
- Interchanges. In the map: Pontchartrain / I-10 (the knot, j10, j49),
  Claiborne (K1, j29), the east CCC approach (C1, C2, R1; fogged at the
  south edge), Elysian Fields at the fog edge. Skipped, outside the built
  map (z ±2315 + 60), not widened: I-610 (z -3457 to -2844), Chef Menteur
  (z ≤ -4184), I-510 (x ≈ 12800), the CCC river span and west bank.
- Measures, before → after (`verify.py`, cracks, `holes6`, `clearance.py`
  = 1 m grid points where two deck tops stack 0.4-4.5 m apart):

  | Measure | Before | After |
  | --- | --- | --- |
  | Stubs / rail discontinuities | 0 / 0 | 0 / 0 |
  | FLICKER | 1 | 1 (same site, j31) |
  | Cracks | 285.3 m, 67 clusters | 220.1 m, 52 clusters |
  | Gores (worst dh, twist, rails inside) | 35 (0.0174, 0.510, 0) | unchanged |
  | Enclosed holes | 50 | 30 |
  | Low-headroom points | 832 in 18 clusters | 72 in 8 clusters |
  | Rail runs / piers / triangles | 258 / 465 / 255240 | 230 / 465 / 244650 |

  Fills: every seed on deck; worst step across a fill's rim 0.090 m (j29),
  others 0.003-0.037 m; rail triangles over the six holes 90/108/44/0/10/0
  → 0. The j10 clusters, 0.43 m at (-1190, 1641) and 1.66 m at
  (-1224, 1618), are gone.
- Sabotage:

  | Fix removed | Result |
  | --- | --- |
  | The j29 fill | j29 a hole again (53.4 m²), 90 rail triangles; rail runs 233 |
  | Fills left out of the rail probe | fills drawn, island rails back (90/108/44/10); rail runs 239 |
  | Four knot ways reverted to the seed | low-headroom 72 → 445; the two j10 clusters back (184, 175 points) |
  | Report override in `decks_seed` (the re-seed before it) | report lists j10 crossings at 0.25 m (-1157.9, 1653.2) and 1.08 m (-1199.1, 1636.1) |

  Re-seed into a copy: 19/19 hand records identical, 6 fills kept.
  With the override the report has 0 joins and its lowest clearance is
  4.40 m over a street; (-1199.1, 1636.1) reads 6.47 m and (-1157.9,
  1653.2) is not listed.
- Shots: 22 spots, two yaws, before and after in the installed overworld,
  plus the I1 and i10_20 fills after. Islands gone at j29, j50, C2; the
  knot ramps lie on the ground under the decks; K1's slit rails gone.
- Residuals, not fixed here:
  - C1 (-2119.4, 894.2): 38 points at 1.97 m, ramp 181653821 descending
    beside the 10.2-10.5 m decks. There before.
  - (1165.4, -1491.7): 16 points at 0.41 m.
  - (-834.6, 2018.1): 8 points at 2.95 m, new: the toe of 104572168 now
    runs under the edge of 595991564.
  - j31 FLICKER (-879.05, 1104.42) and j49's open V: unchanged.
  - Judged real and kept: the K1 slits (a level step, 4 vs 1.9 m), the
    (-1332.8, 1405.5) slot, the medians at (1137.7, -1438.6) and
    (1280.1, -1574.7), the knot's gaps between levels.
- Open (the cause, at seed level): the solver should pin at-grade nodes
  where class 2 shows bare ground, so a re-seed of a fresh city does not
  need the hand rule.

### 7. Fresh-eyes sweep, suites, commit, flyover (½ session)

Pass-3 as agreed: sign-off sheet, overworld suites, commit, record and send
the flyover MP4, re-rate the map against the step-1 baseline.

Done 2026-10-12 (no geometry change since 7473b96):

- Overworld suites: **90** checks across **6** suites, rc=0, no script
  errors - the same count as step 1.
- Mesh numbers (step 6, unchanged): stubs **0** (p2d 107 at 13 sites), rail
  discontinuities **0** (p2d 13, 87.4 m); cracks 220.1 m in 52 clusters,
  30 holes, 1 FLICKER (j31). Hidden seam segments with no partner: 17,
  32.3 m, largest 1.13 m at (-634.3, 2183.2). Reversed side segments: 6,
  0.1 m, piece 16 near (1710, -2005).
- Sweep: the sign-off list plus 10 random elevated spots (seed 20261012,
  h > 3 m, 300 m apart), two yaws each, all looked at. Clean except:
  - R01 (1574.4, -1913.6): a dark opening under the structure where an
    embankment side wall ends (struct/embankment transition, 3.1 m
    clearance). 47 of the 51 transitions have under 2 m below the
    structure, so this is the visible case. Cosmetic, not fixed.
  - R04 (1227.2, -1542.8): dark parallelograms on the median wall; no
    transition within 70 m; cause not found.
  - R05 (-2004.7, 723.0): dark crack line from the gore nose across the
    deck. R02 sparkle dots, R07 shadow aliasing on the median rail, G1
    hairline crack. A1-A3 fogged as designed.
- Flyover: `tools/_probe/step7/flyover` (the old `city_tour` still loads
  `nola_test_overworld`, a different frame), 66 s, 1280x720 H.264.
- Rating as a base for the SMT IV-style ruin: **8.5/10** (baseline 8). Up
  for stubs and rail falls gone and every deck now a record in
  `decks.json` that the mesher draws, so a collapsed span is a data edit;
  held back by the crack clusters, R04 unexplained, no ground relief and
  box buildings.

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
