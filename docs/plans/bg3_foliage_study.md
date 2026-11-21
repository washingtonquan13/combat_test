# BG3 foliage study: findings, ranked

Studied 2026-11-21. The BG3 assets were read from the installed game's paks
for reference only. None of them are, or will be, in this project. Measured
with offline scripts (the scratchpad `bg3study/` set: `glbstat.py`,
`trunkstat.py`, `raster.py`). Changes 1–7 are built (see "Built" at the
end); 8 is not.

## What was compared

| Tree | Height | Leaf tris | Leaf cards | Card area | Bark tris |
|---|---|---|---|---|---|
| BG3 Gnarly_A | 10.1 m | 841 | 88 (+131 moss pieces) | 74 m² | 6384 |
| BG3 Willow_A | 23.6 m | 4511 | 881 hanging strands (~11.6 m² each) | — | 5070 + 903 base |
| BG3 Beech_A | 23.5 m | 6625 | 5381 single triangles (~0.5 m²) | — | 3475 |
| BG3 Hazelnut_A bush | 8.5 m | 627 | 156 | — | 1779 |
| Ours fir (`gen_fir`) | 17.5 m | 19360 | 2420 | 694 m² | 9770 |
| Ours fir, mid (`gen_firm`) | 8.5 m | 8976 | 1122 | 187 m² | 5594 |
| Ours broadleaf (`gen_isle`) | 6.8 m | 13680 | 1710 | 741 m² | 5104 |
| Ours bush (`gen_bush`) | 2.0 m | 4744 | 593 | 67 m² | 1296 |

Our trees cost more than BG3's, not less. The broadleaf is a third of the
gnarly tree's height but has 16× its leaf triangles and 10× its card area
(overdraw). Matching BG3 is a performance gain, not a cost.

## Measured differences

**Trunk shape.** We tracked each trunk's centreline up from the ground
(`trunkstat.py`). Lean is how far the trunk drifts sideways over the tracked
height. Bend is how far its middle strays from a straight line.

| Tree | Lean | Bend | Root flare r(base)/r(1.5 m) |
|---|---|---|---|
| BG3 Gnarly_A | 0.35 | 0.25 | 1.82 |
| BG3 Willow_A | 0.95 | 0.37 | 1.87 |
| Ours fir | 0.02 | 0.03 | 1.67 |
| Ours broadleaf | 0.03 | 0.005 | 1.80 |

Root flare is already about the same. What we lack is lean and an S-bend:
our trunks are plumb lines, BG3's lean and bend about 10× more. This is the
"twist, gnarl, droop" look, and it costs no triangles.

**Leaf albedo.** Measured on texels with alpha above 0.5:

| Atlas | Brightness (p50) | Saturation |
|---|---|---|
| BG3 gnarly / willow / beech / hazel | 0.34–0.47 | 0.18–0.41 (most ~0.2) |
| Ours broadleaf_cards | 0.35 | 0.49, chartreuse |

BG3's leaf textures are a pale sage. Their colour comes from tint and
lighting.

**Leaf normals.** On BG3 leaves the vertex normals sit 6–19° off the face
normals. On our leaf cards they sit 30–84° off, because we bend them toward
a crown sphere. BG3 gets its shading from normal maps baked from 3D twig
clusters; its leaf normal maps are strongly coloured. Ours reads as a soft,
even blob.

**Card layout.** BG3 uses few, large cards. Each card is a whole branch
cluster, and the atlases are cluster renders. The crowns are open: limbs
show through the gaps between leaf masses (Beech). Ours are many small
cards, closed into a ball.

**Vertex colour.** Bark carries wind weights in R and G (the shader is
`ATM_Wind_Vertex_RG`), so the limbs sway too. Leaves use RGBA. The
"ColorVar" materials add young and old leaf tints per material
(`LeavesVariation_01/02`, `LeavesVariationYoung`).

**Base.** Willow and beech have a baked base: flared roots plus a dirt, moss
and leaf-litter skirt in their own atlas region. Gnarly adds a separate moss
layer, 789 triangles of small cards on the bark.

**Scale.** BG3's hero trees are 20 m or more. Our tallest is 17.5 m, and our
broadleaf is 6.8 m.

## Changes, cheapest first

All of these are bake-time changes in `tools/quarry/plant_gen.gd` and the
atlases. None adds runtime cost; 5 and 6 lower it.

1. **Leaf atlas colour.** Desaturate and lighten `broadleaf_cards.png`,
   `fern_fronds.png` and `vine_runs.png` toward saturation ~0.2 and a sage
   hue, and move the colour into `tint_a`/`tint_b`. Texture only.
2. **Per-instance leaf colour.** Young and old tints chosen per instance (or
   per card through COLOR.g, which already picks the tint) instead of one
   mix. Zero cost.
3. **Trunk lean, S-bend and twist.** Add these to `_trunk`, with a per-seed
   strength. Branch droop goes in `_bough`. Same triangle count. This is the
   biggest change in silhouette for the least work.
4. **Flatter leaf normals plus a cluster normal map.** Cut the crown-sphere
   normal blend and add a normal map to the atlas. Costs one more texture
   read in the leaf shader.
5. **Fewer, bigger cluster cards.** Render whole branch clusters into the
   atlas and place tens of cards, not thousands. Cuts overdraw. Needs new
   atlases: moderate work.
6. **Open crowns.** Leaf masses in clumps with gaps, so the limbs show. Goes
   with 5.
7. **Root skirt.** Baked flare roots plus a moss and dirt ring at the base,
   and an optional moss card layer on the bark. A few hundred triangles.
8. **Hero species at full scale.** A 20 m+ gnarled oak, willow or beech
   generator, with hanging strand cards for the willow. This is content work.

Steps 1–3 can be judged in one rebake of the plant meshes alone. That does
not mean a full quarry rebake.

## Built: changes 1–3 (2026-11-21)

`tools/quarry/regen_plants.gd` remakes the plant meshes and leaf atlases in
`world/goblin_quarry/meshes/` in place, from the bake's seeds, heights and
detail levels (`FIR_GEN`, `BROAD_GEN`, `BUSH_GEN`, `FERN_GEN`). No quarry
rebake. `terrain.scn` and `world/morrow/morrow_forest.gd` load these files,
so both change.

**1. Atlas colour.** `leaf_atlas.py`, `fern_atlas.py` and `vine_atlas.py` end
with `grade_atlas`: each texel is pulled toward its luminance (`SAT`), then
lightened (`GAIN`). Measured on opaque texels, as HSV medians:

| Atlas | Before V / S | After V / S | Mean RGB after |
|---|---|---|---|
| broadleaf_cards | 0.39 / 0.66 | 0.42 / 0.40 | (0.39, 0.41, 0.25), BG3 gnarly is (0.38, 0.40, 0.24) |
| fern_fronds | 0.35 / 0.58 | 0.40 / 0.40 | |
| vine_runs | 0.275 / 0.53 | 0.33 / 0.40 | |

On this measure BG3's leaves read 0.34–0.67 (the table above used a
different formula). The fir atlas is Poly Haven's and already sits at 0.43,
so it is left as it is. `tree_leaf.gdshader`'s `tint_a` and `tint_b` were
spread wider, cooler green and warmer yellow.

**2. Per-instance colour.** `tree_leaf.gdshader` hashes each instance's
origin into an age, and mixes `old` (dark, cool) and `young` (fresh
yellow-green) on top of the per-branch tint. Vines are one mesh per tile, so
a tile shares one age.

**3. Shape.** `_build_spine` (firs) adds a lean growing with the square of
height (3–9% of the height at the top), and an S-bend (1.5–4%) whose plane
twists on the way up. Both draw from their own generator, so the firs'
layout is unchanged (same triangle counts). The broadleaf trunk leans
4–14% of the fork height, with the offset growing as the square of height.
`_bough` kinks limbs and their first branches sideways (an S, phase taken
from the branch's wander), and the twig droop grows toward the tip. Changing
a bough's shape changes its children's room, so the broadleaf and bush
crowns reshuffle inside (triangles within ±10%); their height and spread
hold. Ferns are unchanged.

Limits:

- The trunk's bottom 0.5 m is plumb, and the shape eases in by 3 m, because
  the trunk collision (`TREE_TRUNK`, a cylinder 4 m tall) stands over the
  root. A BG3-size lean (0.35) needs collision that follows the trunk, and a
  quarry rebake.
- The broadleaf forks at about 2 m, so its trunk is short and stays near
  plumb. Its new limb kinks are mostly hidden inside the closed crown. They
  show once crowns open (change 6).
- `trunkstat.py` loses the fir trunk at the first whorl (about 3 m), so it
  measures only the plumb base. Use the side renders (`raster.py`) instead.

## Built: changes 5 and 6 (2026-11-21)

For the broadleaf (`gen_isle`) and the bush (`gen_bush`), which share
`broadleaf_cards.png`. The firs and ferns are unchanged.

**5. Cluster atlas.** `leaf_atlas.py` now draws each cell as a whole branch
cluster (`cluster_cell`): a short stem fanning into 7–10 leafy twigs, lit
brighter toward the outside of the cluster. It is graded as in change 1
(`GAIN` 1.32 to make up for the self-shading): median V 0.40, S 0.40, mean
RGB (0.37, 0.40, 0.24), against BG3 gnarly's (0.38, 0.40, 0.24). About 29%
of each cell is leaf.

**6. Open crowns.** `_bough` no longer places cards. It offers places for
leaves (`_cand`), each tagged with its clump: the end of the depth-1 branch
it grows from, with a radius of 0.8 of that branch's length. `_clusters`
then shuffles them and keeps one only if it is inside its clump, out at the
crown's surface (ellipsoid radius 0.35 or more, since the inside is never
seen), and far enough from every card already kept. The spacing is
`_card_l * _gap`, wider toward the clump's edge, and cards shrink there, so
clumps thin out instead of ending in a wall. Between clumps the limbs show.
Card size `_card_l` is 0.22 × height (broadleaf) or 0.42 × height (bush),
1.26× on the far mesh.

| Mesh | Cards before | Cards after | Card area before | After |
|---|---|---|---|---|
| `gen_isle` near (4 seeds) | ~1710 | 59–102 | ~741 m² | 91–171 m² |
| `gen_isle` far | | 33–49 | | 82–124 m² |
| `gen_bush` near | ~593 | 109–116 | ~67 m² | 43–44 m² |
| `gen_bush` far | | 65–71 | | 37–39 m² |
| BG3 Gnarly_A (10 m) | | 88 | | 74 m² |

Leaf triangles on the near broadleaf go from ~13700 to 470–820, the
gnarly tree's range. Bark is unchanged. Measured with a probe in
`tools/_probe` (not committed); renders in the session scratchpad.

Limits:

- Cards reach a little past the old crown: the broadleaf's bounds grow
  about 0.3 m in height, the bush's from 1.8 m to 2.1 m. Collision is the
  trunk cylinder, so play is not affected.
- Leaf normals bent toward the crown sphere here, so a clump shaded as one
  soft mass. Change 4 fixes this.
- Seed 7202 grows a sparser crown (59 cards) than the others; the clumps
  follow its branches.

## Built: change 4 (2026-11-21)

**Cluster normal map.** `leaf_atlas.py` writes a second file next to the
atlas, `broadleaf_cards_surface.png`, which `tree_leaf.gdshader` reads as
`surface` (it already supported one; `surface_relief` 1.0). R and G are the
normal's x and y (y up the image), B is roughness. Each leaf brings its
scan's own normals (`_nor_gl_` and `_arm_` next to the colour scan), turned
with the leaf, and is tilted out from its cluster's middle (`DOME` 0.55 at
the rim, plus a random `TILT` 0.18), so a flat card shades like a dome of
leaves. Twigs and empty texels are flat, so mipmaps don't bend leaf rims.
The tilts draw from their own generator, so the colour atlas is unchanged
(byte for byte). On leaf texels the normal's xy length is 0.34 (p50) and
0.64 (p90); roughness p50 0.60.

**Flatter vertex normals.** `plant_gen.gd`'s `_crown_share` sets how much of a
broad card's normal is the crown's. Broadleaf and bush cards use 0.35
(was 0.8), so the normal map shapes each card. Ferns keep 0.8. The card's
own face is now turned to the crown's outside before the mix; that changes
a few fern meshes slightly (cards that faced inward), which is correct.

`regen_plants.gd` saves the texture as `meshes/broadleaf_cards_surface.res`
and the bake (`_broad_mats`) does the same, so a future rebake agrees.
Triangle counts are unchanged. Cost: one more texture read in the leaf
shader, broadleaf and bush only.

Checked with an offline render (scratchpad `raster4.py`: interpolated
vertex normals plus the surface map, tangents from each triangle's UVs).
Before, a clump lit evenly; after, each leaf catches the light on its own
and the clump is lit on its sunward side and dark underneath.

## Built: change 7 (2026-11-21)

**Roots.** `plant_gen.gd`'s `_skirt()` runs at the end of `broadleaf()`. One
root grows out of each of the bole's buttress lobes (`_lobes`, at the angle
where `_bole_r` is fullest, thicker on the stronger lobes), 0.7·r0 thick
and 3.5–5.5·r0 long, tapering to 0.3. Each starts inside the flare, bends
down to the ground within its first 40%, wanders a little sideways, and
dives below the ground over its last half, so the tip sinks instead of
ending in a cap. Near meshes add 1–3 thinner roots between lobes. Roots
are bark (same tube code, AO 0.85) with UV2 zero, so the wind leaves them
still. The bark shader's own moss (up-facing, near the ground) lands on
their tops.

**Leaf litter.** A ring of flat leaf-cluster cards on the ground around
the trunk (14 near, 7 far), out to the larger of 16% of the height and
6·r0, dipping slightly outward so they sit on gentle slopes. They are leaf
cards (same atlas and material), UV2 zero, with the new `COLOR.b` set to
how dead each is (0.55–1.0). `tree_leaf.gdshader` greys and browns a card
by that amount (`litter`, default (1.25, 0.95, 0.6) on the grey).

The roots and litter draw from their own generator, so the trunk and crown
are unchanged.

| | near bark | near leaf | far bark | far leaf |
|---|---|---|---|---|
| isle 0 | 4552 → 5112 | 696 → 724 | 1552 → 1744 | 90 → 104 |
| isle 1 | 6048 → 6552 | 816 → 844 | 1824 → 1952 | 98 → 112 |
| isle 2 | 3240 → 3800 | 472 → 500 | 1104 → 1296 | 66 → 80 |
| isle 3 | 3696 → 4312 | 728 → 756 | 1104 → 1296 | 88 → 102 |

About +560 triangles near and +170 far, per tree. The study guessed a few
hundred.

**Not built:**
- **The dirt ring.** It would be ground paint around each tree, which means
  a quarry rebake. The litter covers the same seam.
- **The moss card layer on the bark.** `tree_bark.gdshader` already grows
  moss on up-facing, shaded bark near the ground, which now includes the
  roots.

**Limits.**
- Broadleaves only. Firs already get the quarry's `pine_roots` meshes, and
  bushes have no trunk.
- The roots assume flat ground. On a steep slope the downhill roots can
  hover; the bake stands trees on the lowest ground under the trunk, which
  hides most of it.
- Other `gen_*` meshes changed by a few bytes in this regen: they now
  reference `tree_leaf.gdshader` by its new uid. Their geometry is
  unchanged.

Checked with an offline render (scratchpad `raster7.py`, tilted 28°, geometry
below the ground cut away).

