# How this project's grass reaches Baldur's Gate 3 quality

Proposal and spec sheet, 2026-11-21. Companion to `bg3_foliage_study.md` (trees).
Nothing here is built. No project file was changed to write it.

Inputs: seven research reports (Larian sources, AAA grass talks, shading, wind,
Godot ecosystem, Godot performance, and a measurement of BG3's own grass assets
and shader), plus a read of this project's grass code:
`world/goblin_quarry/quarry_grass.gdshader`, `quarry_ground.gdshader`,
`tree_wind.gdshaderinc`, `tools/quarry/bake_goblin_quarry.gd` (`_card_clump`,
`_build_grass`, `_emit_scatter`, `_grass_material`), `tools/quarry/grass_atlas.py`,
`systems/camera_system/crpg_camera.gd`, `project.godot`.

Numbers marked **measured** come from BG3's files or from our atlases. Numbers
marked **computed** are worked out from our bake code, not timed in the game.
Frame time, triangles and overdraw on the dev PC were measured in change 0
(see 5.7 and "Built: change 0").

BG3 assets are reference only. Nothing from them ships.

---

## 1. Executive summary

**What makes BG3 grass look the way it does.** Not blades, not density, not a
clever shader. It is five plain choices:

1. Small bent cards. Each card is a 3-triangle fan from one root point, about
   0.3 m tall (short grass) or 0.7 m (long grass), leaning 35-50 degrees.
   Hundreds of them are welded into patch meshes 2-3.5 m wide.
2. Every normal points straight up. Grass takes exactly the light the ground
   takes, so a field reads as one lit surface, not a pile of clumps.
3. Wind has a direction. One noise texture, sampled in world space, makes gust
   fronts that cross the whole field. Grass leans downwind and holds it; it
   does not rock about its rest pose.
4. It stops at 35-45 m with a dither, and the ground carries the colour beyond.
5. Variety comes from hand painting different plant types (clover, dandelion,
   lupin, brome, thistle, dried and dead variants), not from shader tricks.

It has no translucency, no terrain colour blend, no character bending, and
almost no LODs. Larian said themselves they are "behind the curve" on tech.
The look is art direction on cheap parts.

**How far we are.** Closer than the trees were, and in three places ahead:
our grass takes its root colour from the ground under it (BG3 does not), has
coverage-preserving mips, and has backlight. The gaps are:

- **Geometry is about 10x too heavy.** At full density we lay about 590
  triangles and about 27 m² of card over each 1 m² of ground (computed). One
  BG3 cluster layer is 47-71 triangles and about 2.6 m² of card per m²
  (measured). Three quarters of our card pixels are discarded as empty
  (atlas coverage 0.247, measured).
- **Wind has no direction.** The sway is added in each clump's local space,
  and clumps have random yaw, so every clump sways a different way. No gust
  fronts, no lean, no shared wind with the trees.
- **Normals are a dome**, tipping about 42 degrees outward at the card tops, so
  each clump shades as a mound. From a high camera that is noise.
- **Nothing continues the grass past 44 m.** The ground's grass layer is
  deliberately darkened to act as root shade. The camera zooms out to 60 m. At
  full zoom-out no grass geometry is drawn at all (computed from the fade and
  camera limits), and the field is only the dark under-layer.

**Recommended path.** Shader work first, because it needs no rebake: flatten
the normals, give the wind a world direction and gust texture shared with the
trees, and make the ground take over the grass colour past the fade. Then one
structural step: split grass out of `terrain.scn` so it can be regenerated on
its own, and replace the clumps with BG3-style patch meshes of fitted fan
cards. As with the trees, **matching BG3 is a performance gain, not a cost**:
the target is a quarter of today's triangles and about a fifth of the overdraw.

---

## 2. What BG3-quality grass consists of, layer by layer

### 2.1 Geometry and cards

BG3, measured (Research 7, assets `IP_Vegetation_Grass_Wild_*` and relatives):

| Asset | Tris | Cards | Footprint | Notes |
|---|---|---|---|---|
| Short_A | 38 | 12 | single tuft, 0.62 m | |
| Long_A | 46 | 12 | single tuft, 1.02 m | |
| Short_Cluster_A | 329 | 117 | 2.1 x 2.2 m | about 71 tris/m², 25 cards/m² |
| Long_Cluster_B | 549 | 155 | 3.4 x 3.4 m | about 47 tris/m², about 30 m² card area |
| Brome_C | 334 (LOD1 166) | - | | real curved blade strips |
| Clover_A | 116 | | | |
| Dandelion_A | 199 | | | |
| Lupin_A | 574 | | | |
| Thistle | 16-17 | | | |

- A card is 5 vertices and 3 triangles: a bent fan sharing one root vertex.
  A tuft is V-shaped, so a fan wastes none of the lower corners a quad wastes.
- Median card height 0.30 m (short), 0.72 m (long). Lean 35-50 degrees from
  vertical. A cluster is many small stars of such cards.
- Only Brome has a second LOD. Vertex colour is unused.

Peers: Ghost of Tsushima draws real blades (15 or 7 vertices each, Bezier
curved, grouped in Voronoi clumps) on a compute pipeline (Wohllaib, GDC 2021).
That is a different class of system. For cards, the standing advice is to fit
the card tightly to the silhouette (80.lv Megascans/SpeedTree pieces; Humus's
particle trimmer), because discarded pixels still cost fill rate.

### 2.2 Atlas and texture

BG3: virtual-textured albedo, normal and physical maps
(`IP_Wind_GrassFlowers_AlphaTest_2S_PBR_VT`). Colour variants (green, dried,
dead) are the same mesh with a different atlas. Reflectance 0.5. Atlas sizes
were **not measured**. Texture formats: https://bg3.wiki/wiki/Modding:Texture_formatting.
Sources are SpeedTree (https://gjvandeput.artstation.com/projects/obBL6m).

Peers: alpha-tested mips must preserve coverage or grass thins with distance
(Castano; Golus; lisyarus). Roughness 0.6-0.85.

### 2.3 Colour continuity with the ground

BG3: **none in the shader.** No terrain colour blend. Continuity is authored:
artists pick atlases that match the terrain texture.

Peers do more. Witcher 3 tints grass from a terrain "pigment map" (Gollent,
GDC 2014). HTerrain tints detail layers from its global map. UE uses a runtime
virtual texture for root colour. This is where we are already past BG3.

### 2.4 Lighting, normals, translucency

BG3: normals forced to +Y on common grass and weeds. Accent plants keep bent
or geometric normals. No translucency on grass (only the Gramineae bush-grass
uses the translucency shader). Alpha test, two-sided.

Peers: Ghost of Tsushima blends blade normals to the terrain normal with
distance. Horizon Zero Dawn and Crysis (GPU Gems 3, ch. 16) add a cheap
translucency term. Cast shadows off for grass is near universal; Godot issue
#60364 shows why (alpha-scissor shadow passes fall off a fill-rate cliff on an
RX 580, and turning shadows off restores it).

### 2.5 Wind and interaction

BG3, measured from the shader:

- One noise texture sampled twice in world XZ: at 1/100 scale for large
  movement, and at 1/15 with a time scroll for gusts.
- Phase = noise + position/30, dotted with a **global wind direction**, + time.
- A triangle wave smoothed with x²(3-2x).
- **45% constant lean + 55% oscillation.** Grass leans downwind and stays there.
- Gust = sample³, clamped to [0, 0.5].
- Weight = (local height + offset)³ x a per-material constant.
- **Length preserved**: the offset vertex is renormalised to its original
  distance from the pivot, so blades bend instead of stretching.
- `Soupleness` per material: 1.0 green, 0.5 dried, 0.2 dead, 0.1 water reed.
- No vertex colours used. No character bending. A "glow" variant reads the
  player position; that is the only interaction.

Peers: God of War (Renard, GDC 2019) and Ghost of Tsushima (Rockenbeck, GDC
2021, "vector + noise + vorticles") both drive everything from one shared wind
field. Horizon biases lean downwind. Crysis preserves length and uses triangle
waves. AMD uses `dot(position, windDir)` for phase. All agree on the first
step: one global wind and one scrolling gust texture, shared by all plants.

### 2.6 Density and placement rules

BG3: hand painted with the Instance Painter
(https://docs.larian.com/Instance_painter_panel), batched in 64 x 64 m cells,
with a per-type shadow toggle and a "Remove Floating" tool. Not auto-scattered
(inferred from patch notes about floating grass). Paint density was **not
measured**.

Peers: Witcher 3 ties a vegetation brush to each terrain texture, so grass
follows the paint. Horizon places from density maps in 32 m blocks (van
Muijden, GDC 2017). UE Landscape Grass does the same from layer weights.

### 2.7 Variety and meadow mix

BG3: distinct plant meshes painted in drifts: clover, dandelion, lupin,
thistle, brome, plus dried and dead grass variants. Accent plants are real
geometry at 116-574 triangles, placed sparsely. Each instance type also has
Burn and Destroy visuals.

### 2.8 Distance, LOD and terrain continuation

BG3: `_FadingInterp` 35 -> 45 m on every instance-painter material. The fade
is a screen-space hash dither with an 8-step temporal offset, built for TAA.
Almost no mesh LODs. The "Instance Distance" setting is CPU-bound (ComputerBase
benchmark, https://www.computerbase.de/2023-08/baldurs-gate-3-benchmark-test/).

Peers: Ghost of Tsushima doubles tile size for far tiles, then hands over to
the terrain texture. Breath of the Wild draws geometry in a short radius and
lets the ground texture carry the rest. AMD GPUOpen: when thinning, widen the
survivors so coverage holds.

### 2.9 Performance

Godot evidence (Research 6): issue #79514, 600k grass triangles cost about
2.4 ms in Forward+ on a GTX 1070 at 1024 x 600. #60364, alpha scissor and
shadows are fill-rate bound on an RX 580. Derived budget for a GTX 1060/1650
at 1080p: grass 2.5-3.5 ms, 0.5-1.0 M visible triangles, shadows off, TAA or
FXAA, no MSAA, GI off on grass, no geometry in the far ring. UE's low tier
runs grass density at x0.25.

---

## 3. Gap analysis

| Layer | BG3 / industry | This project today | Gap | Why it matters for the look |
|---|---|---|---|---|
| Card shape | 3-tri bent fan, fitted to a V tuft | Quad strips, 2-6 tris per card, 0.36-0.5 m wide, showing a whole atlas cell | Large | 75% of our card pixels are discarded. All cost, no picture |
| Tris per m² | 47-71 per cluster layer (measured) | about 590 at full density (computed) | Large, 8-12x | About 700k grass tris in a 1200 m² tactical view: the top of the whole budget |
| Card area per m² | about 2.6 m² (measured) | about 27 m² (computed) | Large, about 10x | Overdraw. This is where the frame time goes on low-mid GPUs |
| Instances | Patch meshes, 2-3.5 m | One clump per instance, about 15 per m² | Large | CPU and buffer cost. BG3's own instance setting is CPU-bound |
| Atlas | Albedo + normal + physical | Shading-only albedo, 4x4 cells of 512 px, coverage 0.247 | Small | With up normals the normal map adds little at this camera |
| Root colour | Authored match only | Ground's grass layer at mip 7, same grade as ground shader | **Ahead** | Grass grows out of the ground |
| Valley colour drift | n/a | Ground reads the `variation` texture; grass uses `ground_soil` channels instead | Small, to verify | Field and grass may drift apart in tone over tens of metres |
| Normals | +Y | Dome: up at root, about 42 degrees out at tip | Medium | Clumps shade as mounds; from above this reads as speckle |
| Translucency | None | Backlight 0.25 at tips | **Ahead** | Keep |
| Wind direction | Global direction, world-space noise | Local-space sine on randomly yawed clumps | Large | No gust fronts. The field shivers instead of flowing |
| Wind shape | 45% lean + 55% sway, gust³, length preserved | Symmetric sine, tip², no length preservation | Medium | Rocking about rest pose looks mechanical |
| Shared wind | One wind for all plants | Trees: `tree_wind.gdshaderinc`, own constants, baked into materials. Grass: its own | Medium | Trees and grass disagree on the weather |
| Interaction | None (glow variant only) | None | None | Not needed for parity |
| Burn / destroy | Per-type visuals | None | Medium | Fire surfaces leave grass untouched |
| Placement | Hand painted | Procedural from `_grassiness`, the same function that paints the ground | Small | Ours always agrees with the ground. Missing: an author override |
| Variety | Painted plant types, some real geometry | Meadow layer: clover colonies, flower drifts, stalks, rosettes, all atlas cards | Small | No hero accent plants near the camera |
| Fade | 35 -> 45 m, temporal dither | Thin to 60% from 12 -> 30 m, sink 30 -> 44 m, range end 40-48 m | Small | Equivalent. Sink is cheaper than dither |
| Beyond the fade | Ground carries it | Ground grass layer is darkened as root shade; no far compensation | Large | Camera reaches 60 m. At full zoom-out there is no grass, only its shadow |
| Shadows | Per-type toggle | Cast off | None | |
| Cull margin | n/a | No `extra_cull_margin` | Small | Wind-bent edges of a chunk can pop |
| Mips | n/a | Coverage-preserving (`plant_gen.coverage_texture`) | **Ahead** | |
| Regeneration | Painter | Only through the full quarry bake; grass lives inside `terrain.scn` | Medium (workflow) | Every grass change costs a full rebake |
| Overworld (Morrow) | n/a | No grass geometry, texture layer only, camera at 4-16 m | Large, separate | The closest camera in the game has the least grass |
| Measured cost | Shipped | Measured (change 0): grass 1.8 ms GPU and 1.5 M triangles at station B | Known | See 5.7 |

How the computed numbers were worked out. `tall = _card_clump(6, ..., 3 rows, core 3)`
is 9 cards, 54 triangles, about 2.66 m² of card. `carpet` is 8 cards, 32
triangles, about 1.40 m². `GRASS_STEP = 0.26` gives about 14.8 clumps per m².
At about 35% tall and 65% carpet: 54 x 0.35 x 14.8 + 32 x 0.65 x 14.8 = about
590 triangles, and 2.66 x 0.35 x 14.8 + 1.40 x 0.65 x 14.8 = about 27 m².
These are for full grassiness, before the distance fold removes up to 40%.

One caution on the comparison. BG3's paint overlap is unknown. If artists
stack three cluster layers, BG3 is at about 200 tris and 8 m² per m². We are
still three times heavier.

---

## 4. Options per layer

Scale: effort for one developer plus agents. GPU cost is on low-mid hardware.

### 4.1 Geometry

| Option | Quality ceiling | GPU cost | Effort | Fit |
|---|---|---|---|---|
| A. Keep clumps, shrink and fit the cards | Medium | Medium. Instance count stays at 15/m² | 0.5 day | Good, but leaves the CPU cost |
| **B. BG3-style patch meshes of 3-tri fans** | High (it is the reference) | Low. About 1/4 the tris, 1/5 the fill, 1/10 the instances | 1-2 days | **Best** |
| C. Real blades (Tsushima style, compute or GPU instanced) | Highest up close | High, and needs RD-level work (`multimesh_get_buffer_rd_rid`) | Weeks | Poor. Wrong camera for it |
| D. Adopt an addon (SimpleGrassTextured, Terrain3D instancer, Spatial Gardener) | Medium | Varies | Days of integration | Poor. Our bake already places grass and matches the ground |

**Recommend B.** The camera sits 5-60 m out. Blades are sub-pixel for most of
that range. Cards are right, and BG3 proves the ceiling.

### 4.2 Normals

| Option | Notes |
|---|---|
| **A. Flatten in the shader with a `normal_dome` uniform** | No rebake. One line. Tunable. |
| B. Rebuild meshes with +Y normals | Same look, needs regen. Do it when the meshes change anyway. |

**Recommend A now, B folded into the mesh change.** Start `normal_dome` at 0.25.

### 4.3 Wind

| Option | Quality | Cost | Effort |
|---|---|---|---|
| A. Fix direction only (world-space offset) | Medium | Free | 1 hour |
| **B. BG3 recipe: global direction, gust texture, lean bias, length preservation, shared with trees** | High | One or two texture reads per vertex | 0.5 day |
| C. Wind field with vorticles (Tsushima, God of War) | Highest | A render target and a system to feed it | Days |

**Recommend B.** It is what the reference does and it uses built-in global
shader uniforms.

### 4.4 Interaction (bending under characters)

BG3 does not do it. A single pusher from the existing `player_position` global
is cheap but pushes only for one unit of a party. A trample map is days of
work. **Recommend: skip.** Revisit only together with burn marks (4.7), which
would share the same map.

### 4.5 Colour past the fade

| Option | Notes |
|---|---|
| **A. Ground shader lifts its grass layer toward the grass-top colour between `fade_start` and `fade_end`** | Shader only. Uses values both shaders already hold. |
| B. Extend grass geometry with zoom | Visible area at 60 m is about 4x the tactical view. Cost grows with it. |
| C. Bake a far-field colour map | More data, same result as A. |

**Recommend A.** It is what every reference does.

### 4.6 Placement and authoring

| Option | Notes |
|---|---|
| **A. Keep procedural placement, add an optional paint mask the bake reads** | Small. Keeps ground and grass in agreement. |
| B. Editor painting tool | Large. Not needed for one quarry. |

**Recommend A.**

### 4.7 Burn and destroy

A world-space mask written by the surface system, read by grass (fold and
darken) and ground (scorch). Medium effort. **Recommend: later**, after the
look is right. It is a gameplay-feedback feature more than a look feature.

### 4.8 Atlas normal and roughness maps

With up-facing normals and a high camera the gain is small. **Recommend: skip.**

---

## 5. Spec sheet

### 5.1 Reference camera stations

All measurements use three stations on the quarry's main field, noon light.
Limits come from `crpg_camera.gd` (distance 5-60, pitch 30-65 degrees, full
pitch from 25 m).

| Station | Distance | Use |
|---|---|---|
| A, close | 8 m, low pitch | Worst case for overdraw and wind shimmer |
| B, tactical | 25 m, full pitch | The budget is set here |
| C, far | 60 m | Ground continuation |

### 5.2 Geometry

| Item | Spec | Today |
|---|---|---|
| Card | 5 vertices, 3 triangles, bent fan from one root vertex | quad strips |
| Short card | 0.26-0.36 m tall, 0.18-0.26 m wide at the top, lean 35-50 degrees | 0.34-0.44 x 0.4-0.5 m |
| Long card | 0.6-0.8 m tall, 0.25-0.35 m wide at the top, lean 25-45 degrees | 0.62-0.82 x 0.36-0.46 m |
| Patch mesh | 1.0 x 1.0 m, 20-28 cards in 5-7 stars. 4 short variants, 3 long, 2 mixed | 1 clump |
| Triangles per patch | 60-85 short, up to 110 long | 32 / 54 per clump |
| Triangles per m² of full grass | **<= 150** | about 590 |
| Card area per m² of full grass | **<= 6 m²** short, **<= 9 m²** where tall dominates | about 27 m² |
| Opaque share of card area | **>= 45%** | 24.7% |
| Instances per m² | **<= 1.5** | about 15 |
| Normals | +Y on grass and weeds. Accent plants keep their own | dome |
| Root | Root vertex 0.03 m below the surface. Patch tilted to the terrain normal | 0.05 m offset |

Why 1 m patches and not BG3's 2-3.5 m: a patch is one rigid mesh. On our
relief a 3 m patch floats or sinks at its edges. BG3 needs a "Remove Floating"
tool for exactly that. 1 m keeps the error under about 0.1 m on the slopes
grass is allowed on (`_n_at.y >= 0.84`).

### 5.3 Data formats

- **Mesh vertex data.** UV: point in the card. UV2.x: 0 at root, 1 at tip (as
  today). UV2.y: random per card, used by the density fold (as today).
  CUSTOM0.xyz: the card's root position in patch space, so the shader can take
  ground colour per card and bend each card about its own root.
- **Instance data.** COLOR: tint (as today). INSTANCE_CUSTOM r, g, b: atlas
  rows and column (as today). INSTANCE_CUSTOM.a: local density 0-1, which folds
  cards at the edge of a field. (`a` looks unused in the shader today; confirm
  in `_emit_scatter` before relying on it.)
- **Atlas.** Stay at 2048². Change the tuft atlas from 4 x 4 cells to 8 x 4
  (256 px wide, 512 px tall) of single small tufts. A 0.3 m card at 256 px is
  about 850 px per metre: more than the screen resolves at 5 m. Coverage-
  preserving mips stay. No normal or roughness map.
- **Chunks.** Keep 12 m (tufts) and 16 m (meadow). `cast_shadow` off (as
  today). `gi_mode` disabled. `extra_cull_margin` 0.5 m.
  `visibility_range_end` = `fade_end` + 4 m. No visibility-range fade mode
  (Self fade forces the transparent pipeline).
- **Paint mask (optional, change 8).** `tools/quarry/grass_paint.png`, one
  texel per metre over the quarry extent. R: density multiplier (128 = x1).
  G: tall share bias. B: meadow bias. A missing file means all neutral.
- **Wind globals** in `project.godot` `[shader_globals]`: `wind_direction`
  (vec2, normalised, default 0.8, 0.6 to match the trees today),
  `wind_strength` (float, 0-1, default 0.5), `wind_noise` (sampler2D, one
  tiling 256² noise). Set them once per area. Do not animate them from script
  every frame: script-changed uniforms have no previous-frame value, so motion
  vectors would be wrong (Research 4).

### 5.4 Wind

World-space, applied per card about its root. The recipe is BG3's.

| Item | Spec | Today |
|---|---|---|
| Direction | Global `wind_direction`, same for grass and trees | random per clump |
| Large-scale noise | world XZ / 100 | none |
| Gust noise | world XZ / 15, scrolling downwind at 2-4 m/s | one sine, about 100 m wavelength |
| Phase | noise + dot(position, direction) / 30 + time | sine of position |
| Wave | triangle wave smoothed by x²(3-2x) | sine |
| Lean : sway | 45% constant lean, 55% oscillation | 0 : 100 |
| Gust | sample³ clamped to [0, 0.5] | 0.6-1.0 multiplier |
| Height weight | tip³ | tip² |
| Sway frequency | 0.25-0.4 Hz at `wind_strength` 0.5 | about 0.13 Hz |
| Tip travel, short grass (0.3 m) | 0.03 m at strength 0.5, 0.06 m at 1.0 | up to 0.05 m |
| Tip travel, long grass (0.7 m) | 0.07 m at strength 0.5, 0.14 m at 1.0 | up to 0.05 m |
| Stiffness per type | green 1.0, dried 0.5, dead stalks 0.2, reeds 0.1 | one value |
| Length | Renormalise the offset vertex to its rest distance from the card root | stretches |
| Peak tip speed | <= 0.15 m/s (short) at strength 0.5. Faster shimmers under TAA | - |

Acceptance: in a 10-second capture at station B, gust fronts are visible
crossing the field in the wind direction, and trees and grass lean the same
way. At station A with TAA on, no smearing trails behind moving tips.

One open fact to settle by test, not by argument: whether Godot 4.4 Forward+
writes correct motion vectors for TIME-driven vertex motion. Research 4 says
yes (the vertex function runs twice with the previous time). Research 5 and
the comment in `tree_wind.gdshaderinc` say no. The grass shader's own comment
says yes. Check with the motion-vector debug draw before tuning speeds.

### 5.5 Colour

| Item | Spec |
|---|---|
| Root vs ground | Mean colour of the lowest 15% of the cards vs the ground's grass layer beside them: **delta E (CIE76) <= 3** in an offline render at station A, flat noon light |
| Valley drift | Grass applies the same `variation` drift the ground applies. Same delta E test at three places at least 40 m apart |
| Near vs far | Mean colour of a 10 x 10 m square of full grass seen at station B vs the same square at station C: **delta E <= 4**, and luminance within 8% |
| Edge of a field | No visible line where grass ends: density tapers through INSTANCE_CUSTOM.a over at least 1.5 m |
| Tip colours | Keep `fresh`, `lush`, `sunny`, `dry_tip` as they are. They are not the problem |
| Roughness | 0.85 (as today) |
| Backlight | 0.25 x tip (as today) |
| `normal_dome` | 0.25 to start. 0 is BG3. 1 is today |

### 5.6 Distance

| Item | Spec | Today | BG3 |
|---|---|---|---|
| Density thinning start | 14 m | 12 m | none |
| Density at fade start | 60%, survivors widened x1.25 | 60%, no widening | - |
| Geometry fade | **32 -> 44 m**, by sinking | 30 -> 44 m | 35 -> 45 m dither |
| Ground takes over | Ground's grass layer rises to grass-top colour x coverage over 28 -> 44 m | no | yes (authored) |
| Range end | 48 m | 40-48 m | - |

Sink, not dither: the sink is free in the vertex shader and has no pattern for
TAA to resolve. Keep it unless the offline render shows a visible tide line.

### 5.7 Performance budget

On the dev PC (the target hardware), 1080p, TAA on, the quarry's main field.

| Item | Budget | Today, **measured** (change 0) |
|---|---|---|
| Grass GPU time, station B | **<= 2.0 ms** | 1.8 ms |
| Grass GPU time, station A | **<= 3.0 ms** | 2.65 ms |
| Grass GPU time, station C | 0 ms (nothing in range) | 0.06 ms (88k sunk triangles still drawn) |
| Visible grass triangles, station B | <= 200k | 1.50 M (A 1.32 M, C 88k) |
| Mean grass layers per pixel, station B | **<= 4** | 2.4 kept by the scissor, 8.5 card layers rasterised |
| Mean grass layers per pixel, station A | **<= 8** | 6.5 kept, 25 card layers rasterised |
| Draw calls for grass | <= 60 at station B | 72 (A 58, C 5) |
| Low setting | Global `grass_density` 0.5 folds half the cards (UE's low tier uses 0.25) | none |

Layers are counted over the pixels that grass covers. "Kept" counts the
fragments that pass the alpha scissor (the method below). "Card layers"
counts every fragment the cards cover before the discard: that is the fill
the depth prepass pays, and it is the number the budget should be read
against, since the kept count already passes at both stations.

How to measure. Time: frame GPU time with the grass nodes visible minus the
same view with them hidden, averaged over 300 frames. Overdraw: an offline
render with the grass material swapped for an unshaded additive one that adds
1/16 per fragment, alpha scissor kept; mean pixel value x 16 over the field is
the layer count.

### 5.8 Authoring workflow

1. Tufts are drawn by `tools/quarry/grass_atlas.py` (as today, new cell layout).
2. Patch meshes are built by code (a `_fan_patch()` beside `_card_clump()`).
3. Placement stays procedural from `_grassiness`, slope, water and indoors
   tests. The optional paint mask multiplies it.
4. A grass-only regen (`tools/quarry/regen_grass.gd`, modelled on
   `regen_plants.gd`) rewrites only `world/goblin_quarry/grass.scn` and the
   grass meshes. No terrain, collision, navigation or prop changes.
5. Every change is checked with an offline render from the three stations,
   before and after, as the tree study did.

---

## 6. Changes, cheapest first

"Rebake" means the full quarry bake, which needs the developer's go-ahead.
"Grass regen" means the grass-only script from change 5.

| # | Change | Files | Rebake? | Effort | Done when |
|---|---|---|---|---|---|
| 0 | **Measure the baseline.** Time, triangles, overdraw at stations A, B, C | none (a throwaway tool scene) | No | 2 h | The three "today" numbers in 5.7 are measured, not computed |
| 1 | **Flatten normals.** Add `normal_dome`; blend the card normal toward up | `quarry_grass.gdshader` | No | 0.5 h | Offline render at B: the field reads as one lit surface, no speckle of clump shading. Compare 0, 0.25, 1 |
| 2 | **Wind with a direction.** World-space offset, lean bias, gust noise, length preservation. Add the three wind globals | `quarry_grass.gdshader`, `project.godot`, one noise texture | No | 0.5 day | 5.4 acceptance. Motion-vector question settled |
| 3 | **Trees share the wind.** `tree_wind.gdshaderinc` reads the same globals instead of its own `wind_dir` | `tree_wind.gdshaderinc`; leaf materials re-saved by `regen_plants.gd` if the old constants are baked in | No (plant regen only) | 2 h | Trees and grass lean the same way in one capture |
| 4 | **Ground carries the grass past the fade.** Ground grass layer rises to grass-top colour over 28-44 m. Grass reads the `variation` drift | `quarry_ground.gdshader`, `quarry_grass.gdshader` | No, if the new values are shader defaults or globals. Yes, if they must be set on the baked ground material: then fold into change 5 | 0.5 day | 5.5 near-vs-far test passes. Zooming from 25 m to 60 m shows no darkening of the field |
| 5 | **Grass leaves `terrain.scn`.** Move the grass nodes to `grass.scn`, add `regen_grass.gd`. Set `extra_cull_margin`, `gi_mode` | `bake_goblin_quarry.gd`, new `regen_grass.gd`, quarry scene | **One-time go-ahead**: it rewrites `terrain.scn` once to remove the grass. Placement is unchanged, so the result should be pixel-identical | 0.5-1 day | Before and after offline renders match. A regen run changes only `grass.scn` |
| 6 | **Patch meshes of fitted fan cards.** New `_fan_patch()`, 8 x 4 atlas, CUSTOM0 card roots, density in INSTANCE_CUSTOM.a | `bake_goblin_quarry.gd`, `grass_atlas.py`, `quarry_grass.gdshader` | Grass regen | 1-2 days | 5.2 numbers met. Station A and B renders judged at least as full as today, side by side |
| 7 | **Tune density to the budget.** Thinning curve, widening of survivors, `grass_density` global and a graphics setting | `quarry_grass.gdshader`, `project.godot`, settings UI | No | 0.5 day | 5.7 budgets met on the dev PC |
| 8 | **Paint mask.** The bake reads `grass_paint.png` | `bake_goblin_quarry.gd` | Grass regen | 0.5 day | Painting a bare path through the field and regenerating removes the grass there and nowhere else |
| 9 | **Accent plants with real geometry.** Two or three (a brome-like blade tuft at about 300 tris, a thistle, a tall flower), sparse, near paths and field edges | `plant_gen.gd`, `bake_goblin_quarry.gd` | Grass regen | 1 day | Station A render: at least one accent plant in frame, none closer than 3 m to another of its kind |
| 10 | **Burn and trample mask.** A world-space mask the surface system writes; grass folds and darkens, ground scorches | `systems/surface_system/`, both shaders | No | 1-2 days | A fire surface leaves a scorched, flattened patch that stays after the fire ends |
| 11 | **Grass on the Morrow overworld.** Reuse the patch meshes and shader in a runtime scatter like `morrow_forest.gd` | `world/morrow/` | No | 1-2 days | Overworld paused: do not start without the developer |

Changes 1-4 are shader work and can land in a day with no rebake. They fix the
three things the eye catches first: speckle, directionless wind, and the dark
field at zoom-out. Changes 5-7 are the performance win. 8-11 are optional.

Expected result of 1-7, to be confirmed by change 0's method: about a quarter
of the triangles, about a fifth of the overdraw, a tenth of the instances, and
a field that looks more like BG3's, not less.

---

## 7. Risks and open decisions

**Risks**

- **Thinner grass.** Cutting card area from about 27 to about 6 m² per m² also
  cuts opaque blade area, from about 6.7 to about 3 m² per m². BG3 lives at
  about that level because the ground beneath carries the same colour. Ours
  already does. If the field still looks thin, raise density: the budget has
  room. This is why change 6 is judged side by side, not by numbers alone.
- **Patches on slopes.** A 1 m rigid patch can lift at one edge. Mitigations
  are in the spec (tilt to normal, sink roots 3 cm). If it shows, the fix at
  the cause is a height texture read in the vertex shader, not smaller patches.
- **Motion vectors.** If TIME-driven wind does not get them in this Godot
  version, wind speed must stay low (peak tip speed in 5.4) or grass will
  smear under TAA. Settled by test in change 2.
- **The computed numbers may be off.** Tall share and grassiness vary over the
  quarry. Change 0 replaces them with measurements before any decision rests
  on them.
- **BG3's paint density is unmeasured.** The 47-71 tris/m² figure is one
  cluster layer. The target of 150 leaves room for double layering.

**Decisions for the developer**

1. **Go-ahead for change 5** (one rewrite of `terrain.scn` to move grass out).
   Recommend yes. After it, grass work never needs a quarry rebake again.
2. **Grass at full zoom-out: ground only, or extend the geometry?** Recommend
   ground only (change 4). BG3 stops at 45 m. Extending to 60 m roughly
   quadruples the area in view.
3. **How flat should the normals be?** BG3 is fully flat. Ours has a dome that
   someone chose on purpose. Recommend 0.25, picked from the three renders in
   change 1.
4. **Characters bending grass.** Recommend no. BG3 does not, and a party needs
   a pusher per unit to do it honestly.
5. **Burn marks from fire surfaces (change 10).** Recommend later, as its own
   small feature, once the look is settled.
6. **Overworld grass (change 11).** Overworld work is paused. Flagged here only
   because the patch meshes will make it cheap when it resumes.

---

## Built: change 0 (2026-11-21)

**Tool.** `tools/quarry/grass_bench.tscn` (script `grass_bench.gd`). Run it
windowed: `godot --path . res://tools/quarry/grass_bench.tscn -- <out_dir>`.
It loads `terrain.scn` with the quarry's environment and sun, renders a
1920 x 1080 SubViewport with TAA on (the project's setting), and quits by
itself after about a minute. Nothing in the game uses it.

**Stations.** Anchor at (-4, 30), the densest grass tiles next to the
player's start (about 14.5 clumps per m²). The camera looks toward -Z, as
the quarry camera starts. Pitch follows `crpg_camera.gd`: A 8 m at 35.25
degrees, B 25 m at 65, C 60 m at 65. FOV 75.

**Method.**
- Time: the SubViewport's own GPU time
  (`viewport_get_measured_render_time_gpu`), with the `Grass` node shown and
  hidden in alternating blocks: 2 x 300 frames each, 90 warm-up frames per
  block. Grass time is the difference of the means.
- Triangles and draw calls: the viewport's render info, shown minus hidden.
  A count made from the meshes (chunks inside the frustum and their range)
  gives the same number exactly, so each triangle is counted once.
- Overdraw: each grass material is swapped for a copy of
  `quarry_grass.gdshader` with the same uniforms and vertex code (so the
  fold and sink are the game's), but unshaded, additive, no depth write,
  adding 1.0 per fragment. The ground is drawn black and still occludes;
  trees, rocks and props are hidden. The SubViewport uses an HDR buffer
  and a linear tonemap, so each pixel holds its exact layer count; no 1/16
  scale was needed. Once with the scissor (alpha < 0.5 discarded), once
  without.

**Measured** on the dev PC (AMD Radeon RX 5700 XT, Vulkan Forward+). Two
clean runs agree within 0.03 ms. (A first run left the ground's material
override cleared after the overdraw pass; it was fixed and its B and C
numbers dropped.)

| Station | Grass GPU ms | Frame GPU ms with / without | Grass tris | Grass draws | Kept layers | Card layers | Grass covers |
|---|---|---|---|---|---|---|---|
| A, 8 m | 2.65 | 9.5 / 6.9 | 1,323,136 | 58 | 6.5 | 25.0 | 69% of frame |
| B, 25 m | 1.82 | 7.2 / 5.4 | 1,499,724 | 72 | 2.4 | 8.5 | 46% |
| C, 60 m | 0.06 | 7.5 / 7.4 | 88,284 | 5 | 1.0 | 1.3 | < 0.1% |

Grass costs nothing in the shadow pass (shadow triangles are the same with
and without it). CPU render time rises by about 0.1-0.2 ms with grass.

**What this changes in the plan.**
- Triangles are about 2x the computed 700k: 1.5 M at B. Every chunk in
  range is drawn in full; cards folded or sunk by the vertex shader are
  still submitted. That is also why C draws 88k triangles that cover
  nothing.
- GPU time at B is already about at the 2.0 ms budget on this card. The
  win from changes 5-7 is still real (triangles and card fill are 7x and
  2x over budget), but the frame is not in trouble today.
- The overdraw budget needs a definition. Counted the spec's way (scissor
  kept), today already passes. Counted as card fill, B is 8.5 layers
  against 4. I read the budget as card fill, which is what the cards cost
  the GPU; change 6 should report both.

**Deviations from the spec.**
- Only `terrain.scn` is loaded, not `world/goblin_quarry.tscn`, so units,
  houses, the raid camp and game scripts are absent. They do not change the
  grass delta, but the "without grass" frame times are lower than in game.
- 1920 x 1080 as specified; the game window is 1600 x 900, so in game the
  grass time should be up to about 30% lower where it is fill bound.
- The light is the quarry scene's own sun, not a separate noon setup.
- Overdraw is a real Godot render, not an offline one, and counts exact
  layers rather than 1/16 steps.

**Limits.** One field and one view direction. The 5700 XT is the dev PC
but stronger than the GTX 1060/1650 the budget in 2.9 was derived for.
Wind moves cards slightly between frames; the counts are from one frame.

## Built: change 1 (date 2026-11-21)

**What.** `quarry_grass.gdshader` has a `normal_dome` uniform (0 to 1,
default 0.25). In the fragment shader the card normal, in world space, is
blended toward straight up by it, before the lean from the ground's swell.
0 is BG3 (every card lights like the ground), 1 is the old dome. No rebake:
the baked grass materials do not set it, so they take the default.

**Checked** with real Godot captures of `terrain.scn` (1600 x 900, TAA,
the quarry's sun, grass wind frozen) at stations A and B, for 0, 0.25
and 1. Images are in the scratchpad (`grass_build/dome/`).

| Station | mean pixel change, 1 vs 0 | 0.25 vs 0 | field brightness 0 / 0.25 / 1 | fine speckle (high-pass std) 0 / 0.25 / 1 |
|---|---|---|---|---|
| A | 4.8 / 255 | 1.5 / 255 | 0.362 / 0.361 / 0.348 | 0.0571 / 0.0569 / 0.0577 |
| B | 2.4 / 255 | 1.0 / 255 | 0.340 / 0.339 / 0.332 | 0.0519 / 0.0518 / 0.0520 |

**What the renders say.** The dome was not the speckle. Under a high sun
with wrap lighting it only changes how bright the clumps' far sides are,
and it darkens the field by 2-4%. The fine speckle at B is the same at all
three values: it comes from the atlas shading (the `near` and `t.rgb`
terms in the fragment shader), not from the normals. 0 and 0.25 are hard
to tell apart, so the spec's 0.25 stays as the default: it keeps a hint of
form on the clumps close to the camera at no cost from above.

**Limits.** The speckle the proposal blamed on the dome is still there.
If it needs to go, the lever is the atlas shading's contrast, not this
uniform. That is a look decision for the developer, not part of change 1.

## Built: change 2 (date 2026-11-21)

**What.** A new include, `world/goblin_quarry/wind.gdshaderinc`, holds one
wind for every plant. `quarry_grass.gdshader` includes it and drops its old
`wind` sine. Per vertex: a world direction turned into the clump's space, a
lean of 0.2 x `wind_strength` per metre of height at the tip, 45% constant
and 55% a triangle wave smoothed by x²(3-2x), times (0.5 + gust). The gust
is value noise at world XZ / 15 scrolling downwind at 3 m/s, cubed and
clamped to 0..0.5. The wave's phase is a broad offset, time x 0.2-0.4 Hz
by strength (0.3 Hz at 0.5), and the distance downwind / 30, so crests run
downwind. The offset grows as height x tip², which is tip³ up the card. The
bent vertex is put back at its rest distance from the root. A new
`suppleness` uniform (default 1) scales it per material; dry patches give
half, and the meadow's dead stalks (atlas row 3) give 0.2. Cards that are
folded away or sunk skip the wind.

**Shared values without project.godot.** `wind_direction` (0.8, 0.6) and
`wind_strength` (0.5) are plain uniforms with their defaults in the include,
not shader globals. A `global uniform` that project.godot does not list is a
compile error in the editor, and this change must not edit project.godot.
The baked materials set neither, so every plant gets the same default and
nothing needs a rebake. The cost: changing the weather means setting the two
values on each material, not one global. If weather ever changes at run
time, move them to globals then (one line in the include plus the
project.godot entries). Do not change them from script every frame: a value
set from script has no previous-frame value for the motion vectors.

**Motion vectors: settled.** Godot 4.4 Forward+ writes motion vectors for
TIME-driven vertex motion. Checked with the motion-vector debug draw
(`RenderingServer.VIEWPORT_DEBUG_DRAW_MOTION_VECTORS`), static camera, the
old wind exaggerated 120x so the per-frame motion was visible: grass showed
arrows in many directions, the path and rocks showed none. A moving-camera
run was the control. So the comment in `tree_wind.gdshaderinc` was wrong;
change 3 fixes it. Images: scratchpad `grass_build/mv_old/`.

**Measured.** `tools/quarry/grass_bench.tscn`, same session, same build.

| Station | Grass GPU ms, change 1 | Change 2 as first written (2 noises) | Change 2 as committed |
|---|---|---|---|
| A, 8 m | 2.52 | 2.69 | 2.68 |
| B, 25 m | 1.82 | 2.07 | 2.02 (median 1.99) |
| C, 60 m | 0.06 | 0.07 | 0.07 |

Wind costs about 0.2 ms at B. A run with the noise replaced by one sine
measured 1.93: about half is the noise, half the bend and the length fix.
Skipping hidden cards and a sin-free hash did not move it. Replacing the
second noise (the wave's broad phase) with two sines saved 0.05 ms.

Motion, from 21-frame captures every 0.5 s over 10 s (scratchpad
`grass_build/seqA`, `seqB`, `seqB_s0`, `seqB_s1`):
- Station A: temporal std of the near field 2.05 / 255, frame-to-frame
  change 1.36 / 255. Tufts visibly lean and swing; no smear trails in the
  TAA frames.
- Station B: blurred-field temporal std 0.110 at strength 0.5 and 0.135 at
  1.0, against a noise floor of 0.089 with the wind off.
- Peak tip speed (computed): about 0.03 m/s on 0.3 m grass at strength 0.5,
  well under the 0.15 m/s limit.

**Deviations.**
- The wave's broad phase is two sines about 100 m across, not a second
  noise at XZ / 100. Same job, 0.05 ms cheaper at B, and the gust noise
  still breaks it up.
- The noise is computed in the shader, not a texture: a texture would be a
  new parameter on every baked material, so a rebake.
- Cards bend about the clump root, not each card's root. Per-card roots
  come with the new clump mesh (change 6).
- No new globals in project.godot (see above).

**Limits.**
- At station B the spec amplitude (0.03 m on short grass) is under one
  pixel: B is about 4 cm per pixel. The motion is measurable but gust
  fronts crossing the field are faint even at strength 1.0, so the
  acceptance line "gust fronts visible at B" is not met at the BG3
  amplitude. Raising the amplitude to meet it would break the tip-speed
  limit up close. The spec amplitude is kept; a stronger default is a look
  decision for the developer (`wind_strength` on the grass materials).
- Grass GPU time at B is at the 2.0 ms budget (1.99 median, 2.02 mean).
  Changes 5-7 cut the triangles this runs on.

## Built: change 3 (date 2026-11-21)

**What.** `tree_wind.gdshaderinc` includes `wind.gdshaderinc` and drops its
own `wind_dir`. Trees now take the shared `wind_direction` and
`wind_strength`, and the gust at their root, from the same noise the grass
uses on real time, so a gust front reaches a tree when it reaches the grass
around it. The whole-tree sway is the shared lean (45% constant, 55% the
smoothed triangle wave) at the tree's own slow rate (`wind_speed`, 0.15).
`wind_sway` and `wind_bob` keep their values and now mean the amplitude at
strength 0.5; they scale with strength. `tree_wind()` takes the model
matrix instead of the origin, and `tree_bark.gdshader` and
`tree_leaf.gdshader` pass `MODEL_MATRIX`.

**A bug this fixed.** The old sway pushed along `wind_dir` in the tree's own
space, so every rotated tree swayed a different way. The direction is now
turned from world space into the model's space.

**No regen.** No baked material or generator sets the tree wind uniforms
(checked with grep over the .gd, .tres and .tscn files), so the new
defaults reach every tree as they are. No .res file changed.

**Checked** with a capture: three generated 8 m firs at yaws 0, 2.1 and
4.0 rad, in the quarry's grass, seen across the wind (downwind is screen
right). Rest (`wind_strength` 0) against strong wind (strength 1, tree
`wind_sway` x10, grass `suppleness` 6). All three tree tops moved right by
30-45 px (about 1 m), and so did the quarry's own baked trees behind them.
The grass bands moved right by 0-1 px at that range. Images: scratchpad
`grass_build/trees/` (`trees_rest.png`, `trees_wind.png`, `pair.png`,
`trees_zoom.png`).

At the default strength the motion is close to the old one: the sway
peaks at the same amplitude and moves at about the same top speed
(computed about 0.01 m/s at the top of a 10 m tree). The old sway could
swing slightly upwind; the new one is always a lean downwind with a sway
on top. The TAA comment is corrected: motion vectors do see this motion.

**Limits.**
- Tree motion vectors were not checked on their own. They use the same
  TIME mechanism the grass check confirmed.
- The Morrow overworld trees use the same shaders and now take the same
  wind. Not captured there.

## Built: change 4 (date 2026-11-21)

**What.** Past the cards' fade, the ground's grass layer now shows the
colour a field of blades shows from afar, not the dark root shade. Over
`grass_far_start` to `grass_far_end` (28 to 44 m from the camera) the layer
turns toward the blades' top colour, times `field_shade` (0.5), over
`field_cover` (0.48) of the ground. It only does this where cards grow: grass
paint 0.08 and up, scaled by how dense and tall the cards are there, and a
mesh flat enough for the bake to place them (up 0.84).

The grass colours moved to a new include, `grass_colour.gdshaderinc`, that
both shaders read: the four greens (`fresh`, `lush`, `sunny`, `dry_tip`, same
values), the root grade, the top colour and the valley drift. The ground
reads the top colour from its soil texture at mip 5, the field's average;
each clump reads one point, as before. The cards' roots and tops now take
the same drift as the ground. The roots lose the old per-clump soil
brightness (`macro`), which the drift replaces; the tops keep it.

**Why computed drift, and no globals.** The ground's drift came from the
`variation` texture, which only the ground material has. Giving the grass
materials the texture means a rebake. The drift is now two value noises
computed in the shader (`value_noise.gdshaderinc`, the same noise the wind
already used, now shared). They are fitted to the texture's numbers: the same
spread (std 0.19) and patch sizes (about 5.5 m warm/cool, 1.8 m light/dark).
The pattern is new, so the valley's patches moved, but they are the same size
and strength. The ground keeps `variation` for its tile offsets. All new
values are plain uniforms with defaults in the shader. Nothing touches
`project.godot` or the baked materials, so there is no rebake and the editor
compiles them as they are.

**Measured.** Same 10 x 10 m square at 25 m (B) and 60 m (C), pitch 65,
quarry sun, TAA. Three places at least 40 m apart: (-5, 25), (55, 25),
(75, -45). With the quarry's volumetric fog on, the bare ground darkens by
11-15% from 25 to 60 m. Grass can't change that, so the near-vs-far test is
read with the fog off.

| Place | Before: dE / lum, fog off | After: dE / lum, fog off | After, fog on |
|---|---|---|---|
| (-5, 25) | 5.78 / +1.2% | **3.51 / +5.2%** | 6.71 / -11.7% |
| (55, 25) | 3.55 / -4.1% | **1.64 / -1.2%** | 4.42 / -14.7% |
| (75, -45) | 6.73 / +5.0% | **2.86 / +4.5%** | 6.30 / -11.4% |

The test passes at all three places: delta E <= 4 and luminance within 8%.
Before, the far field turned yellow-brown (the root shade under the cards);
now it stays green. The worst step on the way is at 35-40 m (dE 3.5, -6.6%),
where the cards are sinking.

Root vs ground (5.5): the lowest 15% of the cards against the ground at the
same pixels, 8 m, sun overhead, no shadows.
- Albedo only (unshaded, near-camera root shade off): **dE 3.4 / 3.5 / 3.6**
  (before 4.8 / 5.7 / 6.8). The block-by-block mismatch across the frame
  (std of log brightness ratio in 50 px blocks) fell from 0.17-0.19 to
  0.12-0.14: the roots now follow the ground's drift.
- Lit as in the game: **dE about 21**, before about 23. Not met (see Limits).

GPU, `grass_bench.tscn`: grass at B 2.01 ms (median 1.97), A 2.60, C 0.08.
Change 2 was 2.02 (1.99): no change. The ground's far-field branch runs only
on grass pixels past 28 m.

Images, scratchpad `grass_build/c4/`: `compare_p0.png`, `compare_p1.png`,
`compare_p2.png` (before and after, fog off and on, 25 m and 60 m), runs in
`before*/`, `after2*/`, `roots_*/`, `ru_*/`, `bench/`.

**Deviations.**
- The drift is a computed noise, not the `variation` texture. Same size and
  strength, new pattern.
- `field_cover` and `field_shade` are fitted to captures, not derived. The
  low shade (0.5) stands for the blades' own atlas shading and the shade
  inside the field, which the ground can't see.
- The near-vs-far test is read with fog off. With fog on it fails (dE 4.4 to
  6.7, -11 to -15%), and bare ground fails the same way.

**Limits.**
- Lit root vs ground fails by a wide margin, before and after. The cause is
  the cards' `diffuse_lambert_wrap` at roughness 0.85: a card facing the sun
  gets about half the light the ground's Burley diffuse gives it. The near-
  camera root shade adds to it. Both are older look choices; changing them
  changes the whole field and is the developer's call.
- The far field ignores the bake's other rules: no cards within 0.5 m of
  water or indoors. There the ground still turns green past 28 m.
- Squares of darker, yellower grass the size of a bake chunk show at
  (-5, 25) at 25 m (in the before images too). Not looked into.
- The fog darkening is the environment's (`quarry_environment.tres`,
  density 0.006), not the grass's.

---

## 8. Sources

BG3 and Larian

- Research 7: measurement of BG3 grass meshes (`IP_Vegetation_Grass_Wild_*`,
  Brome, Clover, Dandelion, Lupin, Thistle) and of the shader
  `IP_Wind_GrassFlowers_AlphaTest_2S_PBR_VT`. Reference only.
- Larian, Instance Painter panel: https://docs.larian.com/Instance_painter_panel
- BG3 wiki, non-VT shaders: https://bg3.wiki/wiki/Modding:Non-VT_Shaders
- BG3 wiki, texture formatting: https://bg3.wiki/wiki/Modding:Texture_formatting
- G. J. van de Put, vegetation pipeline (SpeedTree): https://gjvandeput.artstation.com/projects/obBL6m
- ComputerBase, BG3 benchmark (Instance Distance is CPU-bound): https://www.computerbase.de/2023-08/baldurs-gate-3-benchmark-test/
- ASUS ROG, BG3 settings guide (same finding).

Industry

- E. Wohllaib, "Procedural Grass in Ghost of Tsushima", GDC 2021: https://gdcvault.com/play/1027214
- B. Rockenbeck, "Blowing from the West: Simulating Wind in Ghost of Tsushima", GDC 2021.
- R. Renard, "Wind Simulation in God of War", GDC 2019.
- J. van Muijden, "GPU-Based Procedural Placement in Horizon Zero Dawn", GDC 2017.
- M. Gollent, "Landscape Creation and Rendering in REDengine 3", GDC 2014.
- T. Sousa, "Vegetation Procedural Animation and Shading in Crysis", GPU Gems 3, ch. 16.
- AMD GPUOpen, procedural grass rendering (wind phase, width compensation when thinning).
- I. Castano; B. Golus; lisyarus: coverage-preserving mips for alpha-tested textures.
- E. Persson (Humus), particle trimmer: fit cards to silhouettes.
- 80.lv articles on Megascans and SpeedTree card fitting.
- Unreal Engine Landscape Grass documentation (density scaling per quality tier).

Godot

- Godot issue #79514: grass triangle cost in Forward+.
- Godot issue #60364: alpha scissor and shadow fill-rate cost.
- Godot issues #7366 and #59015: discard in the depth prepass.
- Godot 4.4: `multimesh_get_buffer_rd_rid`, `use_indirect`, `extra_cull_margin`, global shader uniforms.
- Terrain3D instancer and particle grass example; HTerrain detail layers;
  SimpleGrassTextured; ProtonScatter; Spatial Gardener; 2Retr0/GodotGrass;
  Hexaquo grass series.

This project

- `docs/plans/bg3_foliage_study.md`
- `world/goblin_quarry/quarry_grass.gdshader`, `quarry_ground.gdshader`, `tree_wind.gdshaderinc`
- `tools/quarry/bake_goblin_quarry.gd`, `grass_atlas.py`, `regen_plants.gd`, `plant_gen.gd`
- `systems/camera_system/crpg_camera.gd`, `project.godot`
- Atlas coverage measured from `grass_tufts.png` (0.247) and `meadow_plants.png` (0.129).
