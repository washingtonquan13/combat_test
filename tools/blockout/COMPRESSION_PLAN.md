# Plan: compress all of Orleans Parish, unattended

Turn the whole parish download into one SMT IV-style overworld: true-scale
streets and buildings, much less ground between the places that matter, and
no seams a player can point at. A single command should run it from end to end.
A human should never need to place a cut, a seam or a door.

`compress.py` stays, as the fallback (see the end), but it is not the engine
for this. Its bands span the whole map, so a band crossing a grid at an angle
shears every street it meets, and a band lying along an artery turns it into
a chord. The pilot showed both effects: Loyola's median was gone and the I-10
interchange was knotted. New Orleans has half a dozen grids fanned around the
river bend, so no set of straight cuts works for all of them at once.

## The idea in one paragraph

Split the city into **patches**, each a run of blocks that share one street
grid. Inside a patch, remove whole **block rows**: everything between two
neighbouring parallel streets. Then slide the rest of the patch over. The
streets crossing that row are perpendicular to it, so they only get shorter.
They never shear and never become chords, which makes a removal inside a
patch exact by construction. Patches are then rigid pieces in a global
layout. The only places where invented geometry appears are the **seams**
between patches, and real New Orleans already puts something there: an
arterial, a canal, a rail line or a neutral ground. The pipeline rebuilds that
boundary feature between the two shrunken patches and checks every seam
against hard limits. When a check fails, the pipeline retries with gentler
parameters. If it keeps failing, it falls back to leaving that patch
uncompressed, or hiding it behind the fog.

## Facts the plan relies on

- **Source:** the parish download, persisted 2026-10-12 to
  `data/blockouts/new_orleans_parish_raw/` (188 MB, never committed). It
  holds 16 `bld_I_J.json` tiles, `features.json`, `coast.json`, and
  `boundary.json` ("Orleans Parish").
  - The parish bbox is 29.865–30.199 N, −90.140 to −89.625 W, about 37 × 50 km,
    with about 440 km² of land.
  - LiDAR lives in `data/blockouts/new_orleans_lidar/lidar_decks.npz`: 20.8 M
    points over the whole parish, 1035 deck ways.
- **Size:** 211,702 buildings and 38,971 features.
  - Road km: residential 2870, service 1617, tertiary 650, secondary 322,
    primary 247, motorway 170, motorway_link 103, trunk 56.
- **Landmark signal already in the download:**
  - Features: wikidata 520, leisure 659, landuse 1191, waterway 462,
    railway 929, bridge 845.
  - Buildings: name 1258, wikidata 97, tourism 177, historic 61, amenity 546,
    height 19,348.
  - So landmarks can be scored without a new fetch.
- **Downstream contract:** compression writes a raw dir in the same format
  the fetcher does. `osm_city.py` → `decks_seed` / `decks_mesh` → `city_gltf.py`
  then run unchanged, exactly as they do after `compress.py` today.
- **Python environment:** numpy 2.5 and shapely 2.2. There is no scipy and no
  networkx, and installing them needs the user's OK, so every solver below is
  numpy-only. The layout system is small enough for that (a few hundred
  patches × 3 DOF).
- **Doors:** the 4 doors are hand transforms under `SpawnPoints/*` in
  `world/city_overworld.tscn`, at Congo Square, St Louis Cathedral,
  Washington Square and Lafayette Square. Suites hard-code metre positions,
  for example `test_the_city_is_solid.gd`'s START_XZ and DECK_XZ.

## Pipeline

```
new_orleans_parish_raw ─► segment ─► score ─► target ─► thin (per patch)
     ─► layout (global) ─► seams ─► expressways / water / lidar ─► anchors
     ─► checks ──fail──► adjust params, retry (bounded) ─► fallback per patch
             └─pass──► raw dir ─► osm_city.py … city_gltf.py (tiled) ─► suites
```

The new tool is `tools/blockout/parish.py`, a driver with one module per
stage. Each stage writes a JSON product and a debug PNG to the output dir, so
a stage can be rerun alone, and the final report can point at the exact stage
where a patch fell back.

### 1. Segment into patches

- Build the planar street graph from `features.json`. A **block** is a face
  of that graph.
- Give each block a grid bearing: the length-weighted mode of its edge
  bearings, taken mod 90°.
- Grow regions over adjacent blocks whose bearings agree within **7°**.
- A region may never grow across a **hard boundary**:
  - primary or larger, motorway, trunk
  - rail
  - water, canal, levee (`man_made=dyke`)
  - the parish boundary
  These boundaries become the seams later. That is deliberate, because a seam
  is meant to sit on a feature that already reads as a divider.
- Merge any region under **4 ha** into its best-matching neighbour.
  - A region that is irregular (bearing spread over 15°, typical of the East's
    curvilinear suburbs) is marked **irregular**. It is never strip-thinned.
- Expected result: on the order of 150–400 patches, many of them matching
  named neighbourhoods. The Quarter, the CBD, the Uptown fans and Mid-City
  should each come out as one or a few patches.

### 2. Score interest

Each block and each way gets a score from tags. No hand list is needed.

- **Landmark (protected):**
  - anything carrying `wikidata`, `historic` or `tourism`
  - `leisure=park|stadium` over 1 ha
  - cemeteries
  - buildings taller than 40 m, or in the top 0.1% by footprint (the top
    1% is 1383 m2 here, every corner pharmacy, and blocked nearly every
    Uptown row in phase 2's first count)
  - every deck and bridge
  A protected item's block row can never be removed.
  A block an arterial runs through (a median polygon) is flagged
  `arterial`, not protected: a strip the arterial crosses square-on only
  shortens it, and the 10° crossing rule below already covers it.
- **Arterial (protected):** secondary and above, plus every named boulevard
  with a median polygon. This is the Loyola lesson.
- **Filler:** everything else, scored by named-building density and by
  footprint variety, so that rows of near-identical houses score lowest.
- **Patch score:** the sum of its block scores, divided by its area.

### 3. Size target (SMT IV's Tokyo, by content)

The map is sized to match SMT IV's Tokyo by **content**, not by walk time.
Walk speed is a feel setting that will keep changing, and the map should not
change size when it does. Speed is tuned to the finished map, not the other
way round.

"The same size as IV" has to mean the same content, because IV and this map
are built at different scales. IV shrinks its city (miniature buildings, wide
roads, a large avatar) as well as deleting ground. This map stays at a
uniform 1×. A footprint copied in metres would therefore delete far more of
New Orleans than IV deleted of Tokyo. So the target is taken from IV as
measures that do not depend on scale:

- **N**, the number of districts. A district is a named area with its own
  landmarks, the unit IV's map is built from.
- **ρ**, the ratio of connective ground to district ground: how much city
  lies between IV's districts compared with how much lies inside them.
- **The district span in blocks**: how many blocks a typical IV district
  measures across. This checks that our districts aren't drawn far larger or
  smaller than IV's.

These come from one measurement of a full IV overworld map image (phase 0b).
Until then they are **unmeasured**, and the code takes them as parameters
with placeholder values, never as constants.

How the target is applied:

- **Pick the districts.** Group the protected landmarks into districts by
  patch adjacency and score, then keep the top N. The Quarter, CBD, Marigny
  and Tremé are always among them. A kept district's landmark blocks are at
  keep ratio 1, and its filler is thinned lightly.
- **Pick the connective ground.** Keep the patches lying on the shortest
  routes between kept districts (the river, the arterials, the expressways),
  and thin them hard, at about 0.5–0.6 per axis.
- **Hit the footprint.** The footprint is A = (kept district area) × (1 + ρ).
  A bisection on one global thinning multiplier brings the connective ground
  to that share.
- **Everything else is frontier.** Patches that are neither district nor
  connective ground, including irregular patches that would need thinning,
  become **frontier**. A frontier patch is kept at scale 1 if it borders a
  district, and otherwise goes behind the fog wall, which is the map edge the
  user already wants. The lake shore and most of New Orleans East are
  expected to land there.
- **Crossing time is reported, not constrained.** The report prints the
  crossing time at the current avatar speed as information only, as the
  starting point for tuning speed and camera afterwards.

### 4. Thin each patch (strip removal)

The patch has two axes, u and v, along its grid bearing. In each axis:

- The candidate strips are the gaps between consecutive parallel streets: one
  block row plus one street.
- A strip is **eligible** only if all of these hold:
  - It has no protected item.
  - No hard-boundary way runs inside it.
  - Every way crossing it does so within **10°** of perpendicular.
  - No building straddles both of its edge streets.
- Remove the lowest-score eligible strips until the patch meets its keep
  ratio.
  - Never remove more than 2 of any 3 consecutive rows, so the grid keeps its
    rhythm.
  - Never remove a row that touches the patch boundary. The seam stage needs
    real streets there.
- The removal is a 1D compaction along the axis, a pure shift per row. Every
  removed piece is recorded, so anchors and LiDAR can be mapped through it.

### 5. Global layout

Each patch is now a rigid piece with a new size. The pieces must be
re-assembled without gaps that read as holes and without overlaps.

- Unknowns: a rigid transform per patch, (x, z, θ).
- Energy:
  - The squared distance between paired boundary points of neighbouring
    patches, sampled every 25 m along each shared border.
  - A rotation penalty, with θ held within **±5°**.
  - A heavy penalty for overlap, measured as the signed distance of each
    sampled point into its neighbour's polygon.
  - An anchor term holding the Quarter at its true position.
- Solver: damped Gauss-Newton in numpy, written as a few hundred lines, not
  bought.
- Hard constraints, checked after the solve:
  - Neighbour order around each patch is unchanged. No patch passes another.
  - No patch inverts.
  - The river stays on the same side of everything.
- What remains between patches after the solve is the **seam ground**. Its
  width is expected to vary from 0 to about 60 m along each border.

### 6. Seams

For every pair of neighbouring patches:

- **The divider is rebuilt, not warped.** The hard-boundary feature that
  separated the two patches (arterial, rail, canal) is re-splined along the
  medial line of the seam ground, with its true cross-section: lanes, median,
  rail bed. Its width comes from OSM, not from the gap.
- **Street ends are matched.**
  - The street ends on each side are put in order along the seam.
  - They are paired by an order-preserving alignment with no crossings, the
    same dynamic program as sequence alignment. The cost is the offset
    between the two ends, and the maximum offset is half a block.
  - Paired ends join through the divider as smooth connectors, using a
    clothoid or cubic segment with a minimum turning radius per class.
  - An unpaired end becomes a T-junction onto the divider. It is never left
    as a stub.
- **Ground fill.** Leftover seam ground becomes the divider's own verge or
  median. If it is wider than 30 m, it becomes a park strip, a plaza or a
  vacant lot, whichever the neighbouring patch already has the most of. The
  ruin layer can later turn the same land into rubble at no extra cost.

### 7. Expressways, water, LiDAR

- **Interchanges are landmarks.** Each cluster of `motorway_link` is grouped
  into one rigid unit, which carries its decks, its LiDAR points and its
  ramps whole. The pilot's tangle came from cutting through one, and this
  removes that whole class of problem.
- **Mainlines between interchanges are re-splined.**
  - Each mainline gets a smooth curve through the new positions of its kept
    nodes.
  - Heights move by **arc-length fraction, not by position**: a node at 40%
    of the old span takes the height found at 40% of the new span. This
    sidesteps the pilot's "LiDAR loss along a chord" entirely, because no
    point has to be looked up where no deck ever stood.
  - Then the existing grade limit and the 0.4 m step check run as before.
- **Points move with their patch.** LiDAR points move rigidly with the patch
  or interchange that contains them. Points in removed strips are dropped.
  `decks_seed` then solves only the true gaps it already knows how to solve.
- **The Mississippi** is rebuilt between its two bank patches: the bank lines
  come from the moved patches, and the water is the region between them. Its
  width must stay at **≥ 70%** of the real width, so the bend still reads as
  the Mississippi. The CCC bridges are interchange-class rigid units.
- **The lake shore** is the fog edge. Nothing is rebuilt there.
- **Canals** (Industrial, 17th Street, London Ave, Orleans) are hard
  boundaries, so they are already seams. Step 6 rebuilds them, like rail.

### 8. Anchors instead of metres

- Doors, spawn points and test probes are stored by **OSM id plus a local
  offset**. For example, St Louis Cathedral is a way id with a (0, 12 m)
  offset.
- After compression, `anchors.json` maps every id to its new position.
- `city_gltf.py` writes the door transforms from `anchors.json`, and the
  suites read their probe points from it, instead of hard-coded coordinates
  like `START_XZ` and `DECK_XZ`. This is the only change to the Godot side,
  and the current single-square city can use it first.

## Automatic acceptance checks

Every check produces a number and a pass or fail. Each failure has a fixed
response, so no step needs a human.

| Check | Limit | On failure |
|---|---|---|
| New dead ends | 0 outside the fog edge | re-run the seam alignment with a wider max offset; then make the end a T |
| Road planarity | 0 crossings between centrelines at grade that share no node | narrow the seam's connector fan; then drop the shorter connector |
| Building overlap | 0 overlaps above 1 m²; 0 buildings on a carriageway | drop the smaller building (seam ground only; patches can't overlap by construction) |
| Connector radius | ≥ 15 m residential, 60 m primary, 300 m motorway | add seam ground (layout penalty up) and re-solve |
| Chord length | no connector over 1.5 × the local block size | lower the patch's thinning by one row near that seam |
| Deck grade / step | existing decks_seed grade limit; 0.4 m step | lengthen the mainline span (lower thinning of the patches it crosses) |
| Landmark geometry | for each pair of the top 60 landmarks within 3 km: bearing change ≤ 20°, distance ratio within 0.35–1.0 | raise both patches' keep ratio |
| Order | river order of riverfront landmarks preserved; neighbour order of patches preserved | raise keep ratio, re-solve layout |
| Landmark scale | every landmark block at exactly scale 1 | (cannot fail by construction; asserted anyway) |
| Size target | N districts kept; non-fog footprint within 5% of A | bisection on the multiplier continues; if it cannot converge, the lowest-score connective patch goes frontier |
| Existing suites | all overworld suites green, using anchors | stop, report; this is a real bug, not tuning |

- The retry loop is bounded at **6 rounds per patch**. A patch that still
  fails is kept at scale 1. If being kept breaks its neighbours, it goes
  frontier instead.
- Every fallback is listed in `report.json` with the check that caused it.
  The run then counts as a **success with fallbacks**, not a failure. The
  aim is a run that always finishes and tells the user exactly where it gave
  ground.
- **The contact sheet is optional, and no one has to look at it.** One GL
  render per seam, from the play camera (`tools/_probe/nola_snap.tscn`
  shots, so it reuses the existing tool), is tiled into one image for the
  user if they want to look.

## Phases and gates

Each phase ends at a gate measured by the checks above. The pipeline goes no
further until the gate passes.

| # | Phase | Gate |
|---|---|---|
| 0 | Persist the raw download | **Done 2026-10-12**: `data/blockouts/new_orleans_parish_raw/` |
| 0b | Measure IV's Tokyo from one full overworld map image: N, ρ, district span in blocks | the three numbers written into the plan, with the image's source and how each was counted |
| 1 | Segment + score, debug PNG only | ≥ 90% of street length within 8 km of Jackson Square in non-irregular patches (the parish-wide share is reported, not gated: the East is expected to be irregular and go frontier); the Quarter, CBD, Lower Garden District and Mid-City come out as recognisable patches; ≥ 95% of the wikidata items inside the parish flagged protected. **Passed 2026-10-12**: core 92.3%, parish 85.6%, wikidata 145/145, 291 patches (122 irregular); the Quarter shares a patch with Tremé (same grid) |
| 2 | **Go/no-go:** thin one patch (an Uptown grid), build it in a 5 km square, GL renders vs uncompressed | 0 chords, 0 new dead ends, every landmark intact, decks untouched. **If this gate fails, stop and fall back.** The core claim is that strip removal is exact |
| 3 | Two patches and one seam (CBD ↔ Lower Garden District across the Pontchartrain Expressway, the hardest real case) | every seam check passes with no fallback |
| 4 | Whole-parish layout, expressways, river, anchors; build only the 5 km square around the core first | all checks pass; existing suites green with anchors |
| 5 | Tiled glTF export and streaming; full parish build | see risks; overworld loads and walks on the dev PC |
| 6 | Ruin layer over the compressed city | separate plan (built as its own generator layer over the intact city) |

## Risks

- **Size.** `city.glb` is 73 MB for 26 km², about 2.8 MB/km². Once phase 0b
  fixes A, multiplying the two gives the size of the export before any build.
  The previous walk-time guess of 60–80 km² would be about 170–230 MB as one
  file. The dev PC is the target
  hardware, so phase 5 has to split the export into tiles (one glb per
  1 km cell, with visibility ranges) before the full build. It can't be done
  afterwards.
- **Nav grid.** The scan-everything fallback already hits `bad_alloc` with
  today's city resident. A larger overworld must not reach that path. Fix it
  at the cause before phase 5. That is the existing open item in
  the city-overworld promotion work.
- **Segmentation quality** is where the "no human" goal is decided. If the
  7° and 4 ha rules misread a district, everything downstream is wrong while
  still passing its checks. Phase 1's gate, wikidata coverage plus named
  districts, is the guard. Look at its PNG once.
- **Seam density.** Hard boundaries are close together in Mid-City (rail,
  canals, the I-10), so seams can run into each other. The layout's overlap
  penalty covers this in principle, and phase 4 measures it in practice.
- **IV's numbers are a reading, not a spec.** District boundaries on IV's
  map are partly a judgement call, so N and ρ carry some error. The pipeline
  only consumes them as parameters, so a recount costs one rerun.
- **New Orleans isn't spread out like Tokyo.** Central Tokyo has dense
  districts everywhere. Here the interest is packed along the river, so N
  districts at 1× will crowd the river and leave a thin ring behind them. The
  frontier will be large, and that is expected.
- **Re-fetch.** If the raw dir is lost, the parish has to be re-fetched as 16
  tiles from Overpass, slowly and politely, with slot waits. The persisted
  copy exists to avoid that.

## Fallback: automated bands

If phase 2's gate fails, `compress.py` stays the engine. A new search picks
band angles and centres automatically:

- It scores each candidate band from the existing report: chords, loose ends,
  and landmarks deleted.
- It never places a band within 25° of a motorway, and never through an
  interchange.

It is cheap and unattended, but it can't reach zero inconsistencies, because
straight bands over fanned grids always shear somewhere. Expect a pilot-like
result in every band.

## Non-goals

- Survey accuracy. Positions are chosen to be plausible, not true.
- Ruins or destruction. That is a separate layer, applied afterwards.
- Terrain relief and other parishes. Jefferson and the West Bank beyond
  Algiers stay behind the fog.
