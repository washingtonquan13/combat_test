"""Makes the face's fine skin detail by rule, no scan, as a normal map in the
UV layout every MPFB human shares: what bake_scan_detail.py takes from a head
scan, grown here instead.

    blender -b --factory-startup --python tools/characters/bake_skin_detail.py -- \\
        <out.png> [debug_dir]

Needs MPFB, as bake_character.py does (BLENDER_USER_RESOURCES).

1. the default MPFB human's head; Cycles bakes, for every texel of its UVs,
   the surface's position, its normal and a few vertex groups (lips, ears);
2. a height is grown at each texel from its 3D position, so nothing stretches
   with the UVs and their seams meet. What it is made of depends on where on
   the face the texel is, placed from landmarks (eyes, nose, lips, crown):
     pores       dimples on a jittered grid: coarse and deep on the nose and
                 the middle of the cheeks, medium on the forehead and chin,
                 fine round the eyes, none on the lips;
     grain       the skin's criss-cross of fine grooves, everywhere;
     lip lines   the lips' vertical lines;
     unevenness  very gentle bumps a few millimetres across;
     age lines   forehead lines, crow's feet, lines under the eyes: as deep
                 as AGE says;
3. <out.png>: RGB the height's tangent-space normal (OpenGL, as Godot reads
   it), A where it applies (the head, fading out down the neck). The same
   format as the scan's, so CharacterLook's face_detail takes either.

Its UVs are every MPFB human's, so one map serves every character:
assets/characters/skin/procedural_face_detail.png is this at the defaults.
AGE much past 0.3 is not ready: the lines round the eyes read as rings.

AGE (env, default 0.2): 0 no expression lines, 1 an old face's.
STRENGTH (env, default 3): scales every slope; at 3 they spread about as
the scan map's do.
SEED (env, default 1): another skin.
"""
import os
import sys

import addon_utils
import bmesh
import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_fit

argv = sys.argv[sys.argv.index("--") + 1:]
out_png = os.path.abspath(argv[0])
debug_dir = argv[1] if len(argv) > 1 else None
RES = int(os.environ.get("RES", "4096"))
AGE = float(os.environ.get("AGE", "0.2"))
STRENGTH = float(os.environ.get("STRENGTH", "3"))
SEED = int(os.environ.get("SEED", "1"))
MM = 0.001

addon_utils.enable("bl_ext.user_default.mpfb", default_set=True)
from bl_ext.user_default.mpfb.services.humanservice import HumanService
from bl_ext.user_default.mpfb.services.targetservice import TargetService

for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)
basemesh = HumanService.create_human(scale=0.1, macro_detail_dict=TargetService.get_default_macro_info_dict())
TargetService.bake_targets(basemesh)


def weights(obj, name):
    idx = obj.vertex_groups[name].index
    w = np.zeros(len(obj.data.vertices))
    for v in obj.data.vertices:
        for g in v.groups:
            if g.group == idx:
                w[v.index] = g.weight
    return w


V0 = np.array([v.co for v in basemesh.data.vertices])
eye = {}
for s in "lr":
    c = V0[weights(basemesh, "joint-%s-eye" % s) > 0].mean(0)
    eye[int(np.sign(c[0]))] = c

# low: the head's skin, with MPFB's UVs
low = basemesh.copy()
low.data = basemesh.data.copy()
low.name = "low"
bpy.context.scene.collection.objects.link(low)
low.modifiers.clear()
skin = weights(low, "body") > 0
head = scan_fit.Head(low.data, use=skin)
k = head.k
cut = head.at(0, 0, -0.17)[2]
lips_w = weights(low, "lips")
ears_w = weights(low, "ears")
col = low.data.color_attributes.new("groups", 'FLOAT_COLOR', 'POINT')
col.data.foreach_set("color", np.column_stack([lips_w, ears_w, np.zeros_like(lips_w),
                                               np.ones_like(lips_w)]).astype(np.float32).ravel())
bm = bmesh.new()
bm.from_mesh(low.data)
bm.verts.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not skin[v.index] or v.co.z < cut], context='VERTS')
bm.to_mesh(low.data)
bm.free()
for p in low.data.polygons:
    p.use_smooth = True
low.data.update()

# bake position, normal and groups per texel
sc = bpy.context.scene
sc.render.engine = 'CYCLES'
sc.cycles.device = 'CPU'
sc.cycles.samples = 1
sc.render.bake.margin = 0
mat = bpy.data.materials.new("bakemat")
mat.use_nodes = True
nt = mat.node_tree
nt.nodes.clear()
out_node = nt.nodes.new("ShaderNodeOutputMaterial")
emit = nt.nodes.new("ShaderNodeEmission")
nt.links.new(emit.outputs[0], out_node.inputs[0])
geo = nt.nodes.new("ShaderNodeNewGeometry")
attr = nt.nodes.new("ShaderNodeAttribute")
attr.attribute_name = "groups"
tnode = nt.nodes.new("ShaderNodeTexImage")
nt.nodes.active = tnode
low.data.materials.clear()
low.data.materials.append(mat)
bpy.ops.object.select_all(action='DESELECT')
low.select_set(True)
bpy.context.view_layer.objects.active = low


def bake(socket):
    nt.links.new(socket, emit.inputs[0])
    img = bpy.data.images.new("b", RES, RES, alpha=True, float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    img.pixels.foreach_set(np.zeros(RES * RES * 4, np.float32))
    tnode.image = img
    bpy.ops.object.bake(type='EMIT')
    a = np.empty(RES * RES * 4, np.float32)
    img.pixels.foreach_get(a)
    bpy.data.images.remove(img)
    return a.reshape(RES, RES, 4)


pos_img = bake(geo.outputs["Position"])
nrm_img = bake(geo.outputs["Normal"])
grp_img = bake(attr.outputs["Color"])
# a bake writes alpha everywhere; a texel it reached has a position (no head
# vertex is at the origin)
covered = np.abs(pos_img[..., :3]).sum(-1) > 1e-6
idx = np.where(covered)
P = pos_img[..., :3][idx].astype(np.float64)
N = nrm_img[..., :3][idx].astype(np.float64)
N /= np.maximum(np.linalg.norm(N, axis=1), 1e-9)[:, None]
lips = grp_img[..., 0][idx]
ears = grp_img[..., 1][idx]
n = len(P)
step = np.linalg.norm(pos_img[..., :3][idx[0], np.minimum(idx[1] + 1, RES - 1)] - P, axis=1)
face = (P[:, 1] < head.nose[1] + 0.05 * k) & (P[:, 2] > head.nose[2] - 0.05 * k)
ok = covered[idx[0], np.minimum(idx[1] + 1, RES - 1)] & face
print("TEXELS", n, "face mm per texel", round(float(np.median(step[ok]) / MM), 3))


# --- noise, on 3D positions ---------------------------------------------------

def hash3(ix, iy, iz, seed):
    h = (ix.astype(np.int64) * 73856093) ^ (iy.astype(np.int64) * 19349663) \
        ^ (iz.astype(np.int64) * 83492791) ^ (seed * 2654435761)
    h = h & 0xFFFFFFFF
    h = (h ^ (h >> 16)) * 0x45d9f3b & 0xFFFFFFFF
    h = (h ^ (h >> 16)) * 0x45d9f3b & 0xFFFFFFFF
    h = h ^ (h >> 16)
    return (h & 0xFFFFFF) / float(0x1000000)


def value_noise(p, cell, seed):
    """Smooth noise in -1..1, features about cell across."""
    q = p / cell
    i = np.floor(q)
    f = q - i
    u = f * f * (3 - 2 * f)
    i = i.astype(np.int64)
    acc = np.zeros(len(p))
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (u[:, 0] if dx else 1 - u[:, 0]) * (u[:, 1] if dy else 1 - u[:, 1]) \
                    * (u[:, 2] if dz else 1 - u[:, 2])
                acc += w * hash3(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz, seed)
    return acc * 2 - 1


def fbm(p, cell, seed, octaves=3):
    acc, amp, tot = np.zeros(len(p)), 1.0, 0.0
    for o in range(octaves):
        acc += amp * value_noise(p, cell / 2 ** o, seed + 17 * o)
        tot += amp
        amp *= 0.5
    return acc / tot


def worley(p, cell, seed, jitter=0.9):
    """Distance to the nearest of points jittered about a grid of cell, and a
    random 0..1 for that point."""
    q = p / cell
    i = np.floor(q).astype(np.int64)
    best = np.full(len(p), np.inf)
    rnd = np.zeros(len(p))
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                c = i + np.array([dx, dy, dz])
                j = np.column_stack([hash3(c[:, 0], c[:, 1], c[:, 2], seed + a) for a in (1, 2, 3)])
                d = np.linalg.norm(q - (c + 0.5 + (j - 0.5) * jitter), axis=1)
                closer = d < best
                best = np.where(closer, d, best)
                rnd = np.where(closer, hash3(c[:, 0], c[:, 1], c[:, 2], seed + 4), rnd)
    return best * cell, rnd


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def gauss(d, w):
    return np.exp(-(d / w) ** 2)


def grooves(coord, spacing, width):
    """0 between, 1 on a set of evenly spaced lines in coord (metres)."""
    t = coord / spacing
    return gauss(np.abs(t - np.round(t)) * spacing, width)


# --- where on the face ---------------------------------------------------------

def near(c, r0, r1):
    return 1 - smoothstep(r0 * k, r1 * k, np.linalg.norm(P - c, axis=1))


front = smoothstep(0.1, 0.5, -N[:, 1])
eye_z = eye[1][2]
nose = near(head.at(0, 0.016, 0.004), 0.012, 0.026)
cheeks = np.zeros(n)
eyes = np.zeros(n)
for sx in (-1, 1):
    c = np.array([eye[sx][0] + sx * 0.006 * k, 0, eye_z - 0.03 * k])
    d2 = np.linalg.norm((P - c)[:, [0, 2]], axis=1)
    on_face = 1 - smoothstep(0.004 * k, 0.012 * k, P[:, 1] - head.at(0, 0.045, 0)[1])
    cheeks = np.maximum(cheeks, (1 - smoothstep(0.016 * k, 0.04 * k, d2)) * front * on_face)
    e2 = np.linalg.norm((P - eye[sx])[:, [0, 2]], axis=1)
    eyes = np.maximum(eyes, (1 - smoothstep(0.018 * k, 0.028 * k, e2)) * smoothstep(0, 0.3, -N[:, 1] + 0.3))
forehead = smoothstep(eye_z + 0.014 * k, eye_z + 0.03 * k, P[:, 2]) * front \
    * (1 - smoothstep(0.035 * k, 0.055 * k, np.abs(P[:, 0])))
lips_r = smoothstep(0.3, 0.7, lips)
ears_r = smoothstep(0.2, 0.6, ears)

# --- the height ------------------------------------------------------------------

h = np.zeros(n)

# pores: three sizes, blended by region
coarse = np.clip(np.maximum(nose, 0.8 * cheeks) * (1 - eyes), 0, 1)
fine = np.clip(np.maximum(eyes, ears_r), 0, 1) * (1 - coarse)
medium = np.clip(1 - coarse - fine, 0, 1)
no_pores = 1 - lips_r
# (the map's texels are about 0.23 mm on the face: anything finer than these
# is the tiling pore map's)
for wgt, cell, radius, depth, seed in ((coarse, 0.9, 0.22, 0.045, 11),
                                      (medium, 0.7, 0.16, 0.03, 23),
                                      (fine, 0.5, 0.12, 0.015, 37)):
    live = wgt * no_pores > 0.01
    if not live.any():
        continue
    dist, rnd = worley(P[live], cell * MM * k, SEED * 101 + seed)
    pit = gauss(dist, radius * MM * k * (0.7 + 0.6 * rnd)) * depth * MM * (0.5 + rnd)
    h[live] -= pit * wgt[live] * no_pores[live]

# grain: two or three families of fine grooves, wavering and broken up
warp = fbm(P, 2.0 * MM * k, SEED * 7 + 1) * 0.25 * MM * k
for a, d in enumerate([(1, 0.3, 1), (1, -0.3, -1), (0.2, 1, 0.1)]):
    d = np.array(d) / np.linalg.norm(d)
    on = grooves(P @ d + warp, 0.55 * MM * k, 0.07 * MM * k)
    patch = smoothstep(-0.2, 0.6, value_noise(P, 1.5 * MM * k, SEED * 13 + a))
    h -= on * patch * 0.008 * MM * (1 - 0.7 * lips_r)

# lip lines: vertical, wavering, deepest across the middle of each lip
lx = P[:, 0] + fbm(P, 3 * MM * k, SEED * 5 + 3) * 0.4 * MM * k
h -= grooves(lx, 0.9 * MM * k, 0.12 * MM * k) * lips_r * 0.02 * MM \
    * (0.6 + 0.4 * value_noise(P, 1.2 * MM * k, SEED * 5 + 4))

# unevenness
h += fbm(P, 4 * MM * k, SEED * 3 + 2) * 0.02 * MM * (1 - lips_r)

# age lines
if AGE > 0:
    # forehead: horizontal, wavering, some stronger than others
    z = P[:, 2] + fbm(P, 20 * MM * k, SEED * 19) * 2.5 * MM * k
    strength = smoothstep(-0.3, 0.6, value_noise(P, 15 * MM * k, SEED * 19 + 1))
    h -= grooves(z, 7 * MM * k, 0.5 * MM * k) * forehead * strength * 0.06 * MM * AGE
    for sx in (-1, 1):
        # crow's feet: fanning out from the eye's outer corner
        o = eye[sx] + np.array([sx * 0.015 * k, 0, 0])
        rx, rz = (P[:, 0] - o[0]) * sx, P[:, 2] - o[2]
        r = np.hypot(rx, rz)
        ang = np.arctan2(rz, np.maximum(rx, 1e-9)) + fbm(P, 6 * MM * k, SEED * 29 + sx) * 0.12
        spread = 0.2
        perp = np.abs(ang / spread - np.round(ang / spread)) * spread * r
        fan = smoothstep(0.003 * k, 0.007 * k, r) * (1 - smoothstep(0.014 * k, 0.022 * k, r)) \
            * (rx > 0) * (1 - smoothstep(0.8, 1.1, np.abs(ang)))
        h -= gauss(perp, 0.35 * MM * k) * fan * 0.05 * MM * AGE
        # under the eye: arcs below the lower lid
        e = eye[sx]
        re = np.linalg.norm((P - e)[:, [0, 2]], axis=1) + fbm(P, 8 * MM * k, SEED * 31 + sx) * 0.6 * MM * k
        below = smoothstep(0.0, 0.006 * k, e[2] - P[:, 2]) * (1 - smoothstep(0.0, 0.012 * k,
                                                                              np.abs(P[:, 0] - e[0]) - 0.008 * k))
        ring = (1 - smoothstep(0.022 * k, 0.03 * k, re)) * smoothstep(0.015 * k, 0.018 * k, re)
        h -= grooves(re, 2.6 * MM * k, 0.35 * MM * k) * ring * below * 0.035 * MM * AGE

# --- height to a tangent-space normal ------------------------------------------------

H = np.zeros((RES, RES))
H[idx] = h
Pf = pos_img[..., :3].astype(np.float64)


def slope(axis):
    fwd = np.roll(H, -1, axis)
    back = np.roll(H, 1, axis)
    cf = np.roll(covered, -1, axis)
    cb = np.roll(covered, 1, axis)
    pf = np.roll(Pf, -1, axis)
    pb = np.roll(Pf, 1, axis)
    both = cf & cb & covered
    dist = np.linalg.norm(pf - pb, axis=-1)
    g = np.where(both, (fwd - back) / np.maximum(dist, 1e-7), 0)
    return g


gx = slope(1)
gy = slope(0)
nx, ny = -gx * STRENGTH, -gy * STRENGTH
nz = np.ones_like(nx)
ln = np.sqrt(nx * nx + ny * ny + nz * nz)
nx, ny, nz = nx / ln, ny / ln, nz / ln
print("SLOPE p50", round(float(np.median(np.hypot(gx, gy)[covered])), 3),
      "p99", round(float(np.quantile(np.hypot(gx, gy)[covered], 0.99)), 3))

# where it applies: the head, fading out down the neck
alpha = np.zeros((RES, RES))
alpha[idx] = smoothstep(cut + 0.0 * k, cut + 0.04 * k, P[:, 2])
img = np.dstack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5, alpha]).astype(np.float32)
img[~covered] = (0.5, 0.5, 1.0, 0.0)

# margin: grow the covered texels outward so mipmaps don't pull in flat ones
have = covered.copy()
for _ in range(8):
    acc = np.zeros_like(img)
    cnt = np.zeros((RES, RES))
    for axis, shift in ((0, 1), (0, -1), (1, 1), (1, -1)):
        hv = np.roll(have, shift, axis)
        acc += np.roll(img, shift, axis) * hv[..., None]
        cnt += hv
    grow = ~have & (cnt > 0)
    img[grow] = acc[grow] / cnt[grow][:, None]
    have |= grow

out = bpy.data.images.new("skin_detail", RES, RES, alpha=True)
out.colorspace_settings.name = "Non-Color"
out.pixels.foreach_set(img.ravel())
out.filepath_raw = out_png
out.file_format = 'PNG'
out.save()

if debug_dir:
    os.makedirs(debug_dir, exist_ok=True)
    hv = np.zeros((RES, RES))
    hv[idx] = h
    lo, hi = np.quantile(h, 0.01), np.quantile(h, 0.99)
    g = np.clip((hv - lo) / (hi - lo), 0, 1)
    dbg = bpy.data.images.new("height", RES, RES)
    dbg.pixels.foreach_set(np.dstack([g, g, g, np.ones_like(g)]).astype(np.float32).ravel())
    dbg.filepath_raw = os.path.abspath(os.path.join(debug_dir, "skin_height.png"))
    dbg.file_format = 'PNG'
    dbg.save()
    reg = np.zeros((RES, RES, 4), np.float32)
    reg[..., 3] = 1
    reg[idx] = np.column_stack([coarse, medium, np.maximum(fine, lips_r), np.ones(n)])
    rg = bpy.data.images.new("regions", RES, RES)
    rg.pixels.foreach_set(reg.ravel())
    rg.filepath_raw = os.path.abspath(os.path.join(debug_dir, "skin_regions.png"))
    rg.file_format = 'PNG'
    rg.save()
print("WROTE", out_png)
