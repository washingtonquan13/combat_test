# BG3 foliage study: findings, ranked

Studied 2026-11-21. The BG3 assets were read from the installed game's paks
for reference only. None of them are, or will be, in this project. Measured
with offline scripts (the scratchpad `bg3study/` set: `glbstat.py`,
`trunkstat.py`, `raster.py`). Nothing here is built yet.

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
