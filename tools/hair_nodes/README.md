# Hair with Blender's procedural hair nodes

Notes from building four test hairstyles in Blender 5.2 on the CC base bodies.
Everything here was checked by rendering, not taken from docs. Results are in
`renders/` (`sheet_female.jpg`, `sheet_male.jpg`).

## Files

| File | What it is |
|---|---|
| `hairkit.py` | Toolkit: scalp + hairline, guide growing, modifier stack, material, camera/lights/shot |
| `styles.py` | The four styles (`F1` long side part, `F2` bob with fringe, `M1` side-part crop, `M2` swept back) |
| `renders/` | Three views per style and two contact sheets |

Use inside a running Blender (scene needs collections `F` and `M` with the CC
bodies, a camera `Cam` and area lights `Key`, `Fill`, `Rim`):

```python
hk = {}; exec(open("hairkit.py").read(), hk)
st = {"hk": hk}; exec(open("styles.py").read(), st)
st["build"]("F2")                                   # scalp, guides, stack, material
hk["shot"]("F", "front34", r"C:\out\F2.png", dist=1.05)
```

## How the tool works

Hair is a **Curves object attached to a surface mesh** (the scalp). You author a
few hundred **guide curves**, then a stack of geometry-node modifiers (the
"Hair" asset node groups that ship with Blender) turns them into tens of
thousands of strands. The guides decide the style; the nodes only fill in and
roughen. Nearly every problem we hit was a guide problem.

### Stack order that works

1. **Interpolate Hair Curves** – makes the children on the scalp surface
2. **Clump Hair Curves** – pulls children toward their guide (the big locks)
3. **Clump Hair Curves** again with `Existing Guide Map` off and a small
   `Guide Distance` (3–5 mm) – small locks inside the big ones
4. **Hair Curves Noise / Frizz Hair Curves** – tiny irregularity only
5. **Trim Hair Curves** with `Random Offset` – uneven ends (skip for a blunt cut)
6. **Set Hair Curve Profile** – radius and taper, always last

### Settings that matter

| Node | Input | Value | Why |
|---|---|---|---|
| Interpolate | Density | 450k–520k | It is strands **per m²**. A scalp is about 0.06 m², so this gives 22–35k strands |
| Interpolate | Density Mask | attribute `hair_density` | Per-vertex 0..1 on the scalp, fading over about 7° at the hairline, gives a soft hairline |
| Interpolate | Interpolation Guides | **1** | See "strands across the face" below |
| Interpolate | Part by Mesh Islands | on for a parted style | Children never blend across a split in the scalp mesh |
| Clump | Shape | 0.45–0.7 | Low values clump from the root and open gaps in the scalp |
| Clump | Factor | 0.45–0.8 | 0.8 for defined locks in long hair, 0.45 for a smooth bob |
| Noise / Frizz | Distance | **0.001–0.002** | Not a max displacement. 0.012 threw hair 16 cm out |
| Profile | Radius | 0.00009 | Thinner needs far more strands for the same coverage |
| Profile | Factor Min | 0.25–0.5 | Tips thinner than this glow blond/orange |

### Python API quirks (5.2)

- Modifier inputs: `getattr(md.properties.inputs, identifier)`, then `.value`.
- To drive an input from an attribute: `inp.type = 'ATTRIBUTE'; inp.attribute_name = "hair_density"`. There is no `use_attribute`.
- Input identifiers are `Input_15` style, not names. `hairkit.stack()` maps names to identifiers.
- **Never name a mesh attribute `density`.** Cycles reserves it (volumes) and a
  shader Attribute node reads 0. Our tinted scalp shell was invisible for the
  whole first day because of this.
- An imported FBX armature in pose mode can tip the body in renders:
  `armature.data.pose_position = 'REST'`.

## Making good hair

### Scalp
- Cut the scalp from the head skin with a hairline table of (azimuth, elevation)
  points per character. A hairline 3° too high reads as balding.
- Add a second copy of the scalp 1.2 mm above the skin, tinted near-black
  (about 0.006 linear, far darker than the hair looks) and faded by the same
  density attribute. Without it, skin shows as pale streaks wherever hair
  diverges. A brown tint lights up orange under the key light.

### Guides (where the style is decided)
- 420–520 guides, about 8 mm apart, 24 points each.
- Each guide is marched from its root: comb direction, lift off the scalp,
  gravity that ramps in over a few steps, collision with the head.
- **Direction must change smoothly between neighbouring roots.** Any jump
  (fringe forward next to sides going sideways) opens a part line. Blend with a
  smooth weight; only length and cut height may jump.
- **Lift**: 0.08–0.2 for anything that should lie down. 0.3–0.5 makes locks
  rise off the head and fall back, which reads as spikes on top of the head.
- **Collision**: when gravity points into the skull, slide along the surface and
  keep the last heading. Stopping the strand there makes tangles.
- Only push hair off the face when it is within about 5 cm of the skin, or it
  gets thrown sideways.
- Two smoothing passes over each guide remove kinks where hair lands on shoulders.
- **Waves belong in the guides**, as one S-wave with a shared phase across the
  head. Wave from the node stack is either invisible or fuzz.
- **Crown whorl**: a purely radial whorl bares the centre. Rotate the direction
  near the centre (spiral, about 65°), lay those roots flat, skip guides within
  12 mm of the centre, and put the whorl 8 cm behind the top of the head.
- **Side part**: split the scalp mesh along the part and turn on Part by Mesh Islands.

### Strands across the face
Children are placed between guides. With 4 interpolation guides, a child
between a guide going left and one going right goes straight down the middle,
over the face. Measured on the bob: 4 guides, 133 strands crossing the face;
2 guides, 71; 1 guide, 0. Use 1 and get softness from guide count and the
second clump instead.

### Colour and light
- Principled Hair BSDF, melanin 0.75–0.93 for brown to near-black. Thin hair
  with low melanin always looks blond.
- A strong rim light turns any tuft that stands up into a white spot. Fix the
  tuft, do not hide it with the light.

### Short hair
Length 1–5 cm, lift 0.08–0.3, short stiffness, some gravity. High lift with low
gravity gives spiky fluff.

## Where the four styles stand

| Style | State |
|---|---|
| F2 bob with fringe | Best of the four. Clean cut line, fringe, covered crown. Faint sheen spot at the whorl |
| F1 long, side part | Good from side and back. A few thin strands still lie on the forehead near the part |
| M1 side-part crop | Reads as a crop. The part line is a little too sharp and the sides are uniform, no fade |
| M2 swept back | Reads as shaggy rather than groomed. The back is fuzzy and there is a pale tuft at the front top |

## Not done

- **None of this is in the game.** These are Cycles renders of strand curves.
  Godot needs hair cards or a baked shell; that conversion is its own job.
- No physics, no fit to other head shapes (hairlines are per character tables).
- Curls, braids, buns and tied styles were not tried. The Curl and Braid nodes
  exist in the same asset set.
- Guides are generated by code. Hand-combing in Blender's curve sculpt mode on
  top of these guides is the obvious next quality step.
