# Armour fitting

How we fit a rigid armour piece (a generated or downloaded mesh made in no particular pose, for no particular body) to a Character Creator base so that it sits on the body and moves with it in game. Two sets are fitted to both CC bases so far:

- **The Meshy leather set** (cuirass, belt with skirt, bracers, greaves), 2026-11-21/22. The output is in `assets/wearables/leather_set/{male,female}/`, one GLB per piece.
- **The Meshy padded set** (sleeveless quilted jack, quilted skirt, upper-arm sleeves, forearm wraps, shin wraps), 2026-11-22. The output is in `assets/wearables/padded_set/{male,female}/padded_armor.glb`, one GLB holding every piece, worn by the single `padded_armor` chest item.

The short version: **align roughly, conform the inside to the skin, copy the body's weights, mirror, export one GLB per piece per body, and rebind at runtime.**

## Pipeline

All Blender steps run headless (Blender 5.2):

```
B="/c/Program Files/Blender Foundation/Blender 5.2/blender.exe"
"$B" -b --factory-startup --python tools/armor_fit/base.py -- assets/characters/cc/female/cc_base_female.fbx W/f_base.blend
"$B" -b --factory-startup W/f_base.blend --python tools/armor_fit/fit.py -- PIECES W/f
"$B" -b --factory-startup W/f.blend --python tools/armor_fit/shoot.py -- W/f_shot          # look before exporting
"$B" -b --factory-startup W/f.blend --python tools/armor_fit/export_piece.py -- greave assets/wearables/leather_set/female/leather_greaves.glb
```

- `W` is any scratch folder.
- `PIECES` holds one folder per piece, `p_<piece>/model.glb`. `meshy_gen.py` produces these from a prompt: it needs `MESHY_API_KEY` in the environment, and **each generation costs Meshy credits**.
- The pieces `fit.py` knows are `cuirass`, `belt`, `greave`, `bracer` and `upsleeve` (its `PIECES` table). A piece with no folder is skipped. A set of pieces costs credits each (5 generations for the padded set).
- `PIECES/prep.json` (optional) fixes a generation before fitting, keyed by piece:

  | Key | Effect | Used for |
  |---|---|---|
  | `"up": "X"` / `"Y"` | Meshy laid the piece along that axis; it is turned upright (Z) | padded bracer (`Y`) |
  | `"cut_below": f` | deletes everything below fraction `f` of the height | padded greave came with a sock foot (`0.13`) |
  | `"albedo": v` | scales the base colour texture so its sRGB mean is `v` | padded set (`0.42`): Meshy's "off-white" came out near 0.7 and the character light rig blew it out to white |

- `export_piece.py`'s first argument may be a comma list (`cuirass,belt,upsleeve,bracer,greave`) to put several pieces in one GLB.

| Script | What it does |
|---|---|
| `base.py` | Imports a CC base FBX in rest pose, drops `Bra` / `Underwear_Bottoms`, adds a camera, and saves the `.blend` that `fit.py` works on. |
| `fit.py` | Aligns, conforms, skins and mirrors every piece. Saves `OUT.blend` and prints `CONFORM … inside N` per round. |
| `shoot.py` | Workbench renders: front, side and back, then a pose (arm raised, knee bent, torso twisted) with and without the armour. |
| `export_piece.py` | Keeps the armature and `Armor_<piece>*` (both sides), applies the armature's transform, and exports a skinned GLB (JPEG textures). |
| `meshy_gen.py` | Meshy text-to-3D (preview, then PBR refine) into an output folder. |

## The technique

### 0. Put the armature in the body's frame

CC's FBX gives the `Armature` object an extra −90° X rotation that its meshes don't have. In rest the skin still deforms to identity, so everything looks right. Any pose, though, rotates about bone heads that sit about 1 m off the body. `fit.py` and `shoot.py` both set the armature's `matrix_world` to the body's while holding every child's world matrix still. Skip this and every posed check lies.

### 1. Rough alignment, from landmarks

Each piece first goes to roughly the right place and size:

- **Cuirass and belt (box pieces):** the piece's bounding box is scaled per axis onto a target box.
- **Greaves and bracers (limb pieces):**
  - The piece's long axis (Z: Meshy pieces come out upright) is rotated onto the limb axis. For the greave that runs knee to ankle; for the bracer, elbow to wrist.
  - The length is scaled to the span.
  - The girth is scaled to the 90th-percentile skin radius around the axis plus 12 mm.

  PCA is not used for the axis, because on a short, wide bracer it picks the diameter.
- **Upper-arm sleeve (`upsleeve`):** a limb piece from just below the shoulder to just past the elbow. Its girth is measured on the upper arm's own skin (`girth_pts`: the vertices weighted to `CC_Base_L_Upperarm` and its twists), since near the shoulder the nearest skin around the axis is the chest.

The box edges are **offsets from bones, scaled by the body's own proportions**, which is why one table fits both bases. The constants were tuned on the CC male (hip 0.997, neck 1.548, upper-arm X 0.185, calf 0.524). Each body's scale factors are:

- `ST = (neck − hip) / 0.551`, for torso height
- `SX = upper-arm X / 0.185`, for shoulder width
- `SL = calf / 0.524`, for shin length

| Base | ST | SX | SL |
|---|---|---|---|
| CC female | 0.915 | 0.814 | 0.964 |

`fit.py` prints a `LANDMARKS` line for each run. A new body should need no new numbers. If it does, change the offset, not a per-body special case.

### 2. Conform the inside to the skin, keep the outside's detail

This is the core step. Shrinkwrap and plain push-out both flatten a piece: straps, buckles and raised edges all collapse onto the skin. Instead, `conform()` runs 6 rounds of the following:

1. For each vertex, find the signed distance `d` to the skin along the nearest point's normal, using a BVH of the evaluated body.
2. Compute `clear` = the **spatial local minimum** of `d − gap`. That is the minimum over a voxel grid with 1.5 cm cells and 27 neighbours. `clear` measures how far the inner face near this vertex sits beyond its target gap (negative means too close).
3. Displacement = `−normal × clear`, smoothed over the mesh edges (8 iterations), and applied at 0.7 (1.0 on the last round).

The neighbourhood is spatial rather than along the mesh graph, because a strap lying on the leather is a separate mesh island. Spatially it "sees" the leather's inner face under it, so it moves with the shell by the same amount instead of being pulled through it. Every vertex in a patch moves together, so the inner face lands at `gap` and the outer detail rides along at its own height.

A last `push_out` (2 mm, 2 passes) moves out anything the smoothing left inside.

Gaps are inner-face clearance off the skin, in metres:

| Piece | Gap |
|---|---|
| cuirass | 0.006 |
| greave | 0.005 |
| bracer | 0.004 |
| belt | 0.006 at the waist, growing by up to +0.03 below `WAIST` (hip − 0.047·ST) over 0.25·SL, so the skirt hangs free instead of shrink-wrapping the thighs |

**Skirts hang (`hang()`, the belt only).** A conform alone lets a skirt follow the buttocks and the backs of the thighs inward, so from behind it clings. Cloth that hangs never moves back inward below its widest point. So, below `WAIST`, the skirt is cut into polar bins around the hips' vertical axis (72 angles × 1 cm of height). In each angle the inner radius becomes the running maximum going down, every vertex in a bin moves out by the same amount, and that displacement is smoothed over the mesh. The quilting rides along unchanged.

**Limb pieces conform only against their own side** (`side_bvh`: the skin with x on the piece's side of the midline). Otherwise the inner thigh's nearest skin can be the other leg, and the greave gets pulled across.

### 3. Weights: copy the body's

`skin()` works in three steps:

1. Create every body vertex group on the piece, then apply a `DATA_TRANSFER` modifier with vertex-group weights, nearest-face interpolated.
2. For limb pieces, drop the other side's groups (`_R_`). Vertices that lose all their weight that way (their nearest skin was the other limb) are refilled from the nearest weighted vertex of the same piece (a KDTree).
3. Normalise the weights, then add an Armature modifier.

Rigid pieces could use one rigid bone each. Body weights are better, because the cuirass then bends with the spine and the skirt with the thighs.

### 4. Mirror

The left limb piece is copied and mirrored in X (faces reversed). Its L and R vertex groups are swapped by first parking every group on a temporary name: a direct rename collides, Blender adds `.001`, and those weights then drive nothing.

### 5. Check before exporting

`fit.py` prints the `inside` count per round, and it should be about 0. A handful of vertices on a buckle tip is fine. The female fit ended at:

| Piece | Inside |
|---|---|
| cuirass | 23 (p95 clearance 3.4 mm) |
| belt | 0 |
| greave | 0 |
| bracer | 16 |

The padded set ended at 0 for everything except the quilted tubes: greave 11 / 9 and upsleeve 17 / 11 (male / female).

Then look at `shoot.py`'s posed render next to the bare posed render. The pieces must follow the arm, knee and twist, with no gap at the knee and no skin through the cuirass.

### 6. Export: one GLB per item per body

`export_piece.py` applies the armature's object transform (scale 0.01 from the FBX), so the bones and the armour share world metres, and exports the pieces with the whole armature. The GLB follows the item:

- The leather set is one file per piece, so each item carries only its own piece: the cuirass item does not load the greaves.
- Padded armour is a single body-armour item, so all five pieces share one file. `CCWear` binds every skinned mesh in a GLB.

## In game

- Each item's `GearItem.wearable` is a `Wearable` whose `meshes` maps a body type to the GLB fitted to that body: `&"cc_male"` and `&"cc_female"` (`CCLook.body_type`, set in `scenes/character_models/cc_{male,female}_model.tscn`).
- `UnitWearables` calls `CCLook.wear(items)` whenever the loadout changes. That calls `CCWear.attach(character, glb)` for each piece:
  - The GLB's binds use CC names (`CC_Base_L_Calf`), but the body's skin uses the import BoneMap's profile names (`LeftLowerLeg`). `CCWear` reads the map from the body FBX's `.import`.
  - The two exports can disagree on mesh space. `CCWear` fits the scale + rotation + offset (Umeyama) that lays the garment's bone origins on the body's, then builds each new bind as `body_bind[bone] × M`.
  - A bone the body mesh doesn't bind is reached through the Waist bind.
  - Each piece becomes a MeshInstance3D beside the Body, on its render layers and light group.
- The leather items map like this:

  | Item | Piece |
  |---|---|
  | `leather_chestpiece` | cuirass |
  | `leather_belt` | belt and skirt |
  | `leather_gloves` | bracers (there is no bracer item) |
  | `leather_boots` | greaves (its MakeHuman shoes stay for the fallback body) |
  | `padded_armor` (chest slot) | the whole padded set |

  Wear padded armour without the leather belt, gloves and boots: those pieces would sit on top of its skirt and wraps.
- `CCLook.wear` takes the old pieces out of the tree before freeing them, so the re-worn pieces keep their `Armor_*` names.

- To check it in game, a throwaway probe scene can do the following (the 11-22 check did exactly this):
  1. Boot MainRoot and start a new game. The hero already wears the leather set from `StartingParty.WORN`.
  2. Equip the set on the townsperson with `unit.equip_item(slot, ItemInstance.new(load(item)))`.
  3. Shoot both units front and back.

  Two gotchas apply:
  - Free the camera's `XRaySilhouettes` and clear every `material_overlay`. Once the game camera is switched off, its depth capture goes stale and tints units blue.
  - To pose the body, disable the unit and set the Skeleton3D bones' pose rotations directly. An AnimationPlayer seek gets overridden by the unit's own animation.

  Use a real window (`--rendering-driver opengl3`), not `--headless`.

## Limits

- **No covers mask.** The skin under a piece still draws. At 4–6 mm gaps nothing shows through in the poses checked, but an extreme pose could poke through. CC bodies have no mask path since the CC clothes were retired.
- **Elbow gap (padded).** At rest a little skin shows between the upper-arm sleeve and the forearm wrap.
- **Heavy pieces.** Meshy refine is about 34–40k vertices per piece with 2k PBR maps: about 33 MB per body for the leather set, 49 MB per body for the padded GLB. Each body's GLBs carry their own copies of the textures. Decimating and sharing the textures is the obvious next saving.
- **Meshy texture blotches** (rust-like stains on the leather) come from the generation, not the fit.
- **Knee bend:** the greave's top lifts slightly off the knee at a deep bend, because it is weighted like the skin under it.

## Sources

- **Conform-to-body with detail preserved, then copy body weights.** This is the standard game approach for rigid and semi-rigid gear:
  - Unreal Engine MetaHuman armour-fitting forum thread;
  - blenderartists, "syncing leggings with character movement";
  - UESP wiki, adapting armour with lattices;
  - the Cyberpunk 2077 modding garment-support guide.
- **Research on automatic garment fitting and retargeting**, for the shape of the problem rather than code:
  - Huang et al. 2025, cims.nyu.edu/gcl/papers/2025-Garment.pdf;
  - Multi-Garment Net, arXiv 1908.06903.
