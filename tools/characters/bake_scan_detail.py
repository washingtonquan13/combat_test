"""Bake a head scan's fine surface detail into the UV layout every MPFB human shares.

blender -b --factory-startup --python tools/characters/bake_scan_detail.py --     <hero.glb> <scan.glb> <scan_disp.jpg> <out.png> [debug_dir]

1. align the scan to the MPFB head (nose + crown, then similarity ICP);
2. wrap a copy of the MPFB head onto the scan (projection, smoothed offsets);
3. Cycles: bake the scan's normal (its displacement map as bump) onto the
   wrapped copy, whose UVs are MPFB's;
4. keep only the fine detail: the low frequencies are where the scan's shape
   and MPFB's differ, which the character's own mesh already has;
5. write <out.png>: RGB a tangent-space normal (OpenGL, as Godot reads it),
   A where it applies (not the eyes, ears, lips or nostrils, whose shapes are
   too unlike the scan's, nor the neck).

Made for Lee Perry-Smith's head scan (CC BY 3.0, see
assets/characters/skin/CREDITS.md): its mesh is Z up, facing -Y, eyes shut.
BUMP (env) is the displacement's height in metres, HIGHPASS the blur radius
in texels that the low frequencies are taken out at.
"""
import bpy, bmesh, sys, os, math
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

args = sys.argv[sys.argv.index("--") + 1:]
hero_glb, scan_glb, disp_jpg, out_png = args[:4]
debug_dir = args[4] if len(args) > 4 else None
RES = 4096

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=hero_glb)
body = bpy.data.objects["proof_hero"]
for o in list(bpy.data.objects):
    if o is not body:
        bpy.data.objects.remove(o, do_unlink=True)
body.parent = None
body.modifiers.clear()
if body.data.shape_keys:
    body.shape_key_clear()
body.matrix_world = Matrix()
bpy.ops.import_scene.gltf(filepath=scan_glb)
for o in list(bpy.data.objects):
    if o.type != 'MESH':
        bpy.data.objects.remove(o, do_unlink=True)
scan = next(o for o in bpy.data.objects if o is not body)
scan.data.transform(scan.matrix_world)
scan.matrix_world = Matrix()

bv = np.array([v.co for v in body.data.vertices])
bn = np.array([v.normal for v in body.data.vertices])
sv = np.array([v.co for v in scan.data.vertices])

def nose_and_crown(v, zlo, zhi, xtol):
    c = v[(np.abs(v[:, 0]) < xtol) & (v[:, 2] > zlo) & (v[:, 2] < zhi)]
    nose = c[np.argmin(c[:, 1])]
    crown = v[np.argmax(v[:, 2])]
    return nose, crown

h_nose, h_crown = nose_and_crown(bv, 1.65, 1.80, 0.01)
s_nose, s_crown = nose_and_crown(sv, -1.0, 3.0, 0.2)
s = (h_crown[2] - h_nose[2]) / (s_crown[2] - s_nose[2])
print("ALIGN init scale", s, "hero nose", h_nose, "scan nose", s_nose)
# scan -> hero: x' = s R x + t
R = np.eye(3)
t = h_nose - s * s_nose

head = np.where(bv[:, 2] > 1.62)[0]
P = bv[head]

def scan_tree(s, R, t):
    vs = [Vector(s * R @ np.array(v.co) + t) for v in scan.data.vertices]
    polys = [tuple(p.vertices) for p in scan.data.polygons]
    return BVHTree.FromPolygons(vs, polys)

for it in range(40):
    tree = scan_tree(s, R, t)
    Q, ok = [], []
    for p in P:
        hit = tree.find_nearest(Vector(p))
        Q.append(hit[0] if hit[0] is not None else Vector(p))
        ok.append(hit[3] if hit[0] is not None else 1e9)
    Q = np.array(Q); d = np.array(ok)
    keep = d < np.quantile(d, 0.75)
    A, B = Q[keep], P[keep]  # move scan points A toward hero points B
    ma, mb = A.mean(0), B.mean(0)
    A0, B0 = A - ma, B - mb
    U, S_, Vt = np.linalg.svd(B0.T @ A0)
    D = np.eye(3); D[2, 2] = np.sign(np.linalg.det(U @ Vt))
    Ri = U @ D @ Vt
    si = (S_ * np.diag(D)).sum() / (A0 ** 2).sum()
    ti = mb - si * Ri @ ma
    s, R, t = si * s, Ri @ R, si * Ri @ t + ti
    if it % 10 == 0 or it == 39:
        print("ICP", it, "median mm", round(float(np.median(d)) * 1000, 2), "scale", round(s, 5))

M = np.eye(4); M[:3, :3] = s * R; M[:3, 3] = t
scan.data.transform(Matrix(M.tolist()))
scan.data.update()

# wrap a copy of the body onto the scan
wrap = body.copy(); wrap.data = body.data.copy(); wrap.name = "wrap"
bpy.context.scene.collection.objects.link(wrap)
tree = BVHTree.FromObject(scan, bpy.context.evaluated_depsgraph_get())
nbr = [[] for _ in bv]
for e in body.data.edges:
    a, b = e.vertices
    nbr[a].append(b); nbr[b].append(a)

def smooth(f, w, passes):
    for _ in range(passes):
        g = f.copy()
        for i in head:
            if nbr[i]:
                g[i] = f[nbr[i]].mean(0) if f.ndim > 1 else f[nbr[i]].mean()
        f = np.where(w[:, None] > 0, g, f) if f.ndim > 1 else np.where(w > 0, g, f)
    return f

cur = bv.copy()
good = np.zeros(len(bv))
zramp = np.clip((bv[:, 2] - 1.60) / 0.04, 0, 1)
for rnd, (limit, passes) in enumerate([(0.015, 8), (0.008, 4), (0.004, 2)]):
    off = np.zeros_like(cur)
    g = np.zeros(len(bv))
    for i in head:
        hit = tree.find_nearest(Vector(cur[i]))
        if hit[0] is None:
            continue
        if hit[3] < limit and np.dot(bn[i], np.array(hit[1])) > 0.6:
            off[i] = np.array(hit[0]) - cur[i]; g[i] = 1
    off = smooth(off * g[:, None], zramp, passes) / np.maximum(smooth(g, zramp, passes), 1e-3)[:, None]
    cur = cur + off * zramp[:, None]
    if rnd == 0:
        good = g
    print("WRAP round", rnd, "projected", int(g[head].sum()), "of", len(head))
for i, v in enumerate(wrap.data.vertices):
    v.co = Vector(cur[i])
wrap.data.update()

# mask: well-projected, away from the eyes (the scan's are shut), above the neck
eye_c = [np.array([sx * 0.031, -0.14, 1.77]) for sx in (-1, 1)]
eye = np.ones(len(bv))
for c in eye_c:
    r = np.linalg.norm(bv - c, axis=1)
    eye *= np.clip((r - 0.019) / 0.008, 0, 1)
def keep_away(c, r0, r1):
    return np.clip((np.linalg.norm(bv - np.array(c), axis=1) - r0) / (r1 - r0), 0, 1)
# shapes too unlike the scan's to share its detail: ears, lips, nostrils
side = bv[(bv[:, 2] > 1.70) & (bv[:, 2] < 1.80)]
ear_x = np.abs(side[:, 0]).max()
ear = side[np.argmax(np.abs(side[:, 0]))]
away = np.ones(len(bv))
for sx in (-1, 1):
    away *= keep_away((sx * ear_x, ear[1], ear[2]), 0.035, 0.05)
    away *= keep_away((sx * 0.012, h_nose[1] + 0.012, h_nose[2] - 0.01), 0.008, 0.014)
away *= keep_away((0, h_nose[1] + 0.012, h_nose[2] - 0.036), 0.016, 0.026)
print("EAR", ear_x, ear)
mask = np.clip(smooth(good, zramp, 6) * 1.5 - 0.25, 0, 1) * eye * zramp * away
col = wrap.data.color_attributes.new("mask", 'FLOAT_COLOR', 'POINT')
for i, m in enumerate(mask):
    col.data[i].color = (m, m, m, 1)

# scan material: displacement as bump
mat = bpy.data.materials.new("scanmat"); mat.use_nodes = True
nt = mat.node_tree; nodes = nt.nodes
bsdf = nodes["Principled BSDF"]
tex = nodes.new("ShaderNodeTexImage"); tex.image = bpy.data.images.load(disp_jpg)
tex.image.colorspace_settings.name = "Non-Color"; tex.interpolation = 'Cubic'
bump = nodes.new("ShaderNodeBump"); bump.inputs["Distance"].default_value = float(os.environ.get("BUMP", "0.004"))
nt.links.new(tex.outputs["Color"], bump.inputs["Height"])
nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
scan.data.materials.clear(); scan.data.materials.append(mat)

# wrap material: bake targets
def target(name, float_buf=True):
    img = bpy.data.images.new(name, RES, RES, float_buffer=float_buf)
    img.colorspace_settings.name = "Non-Color"
    return img
wm = bpy.data.materials.new("wrapmat"); wm.use_nodes = True
wrap.data.materials.clear(); wrap.data.materials.append(wm)
wn = wm.node_tree.nodes
tnode = wn.new("ShaderNodeTexImage"); wn.active = tnode

sc = bpy.context.scene
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 4
bk = sc.render.bake
bpy.ops.object.select_all(action='DESELECT')

def pixels(img):
    return np.array(img.pixels[:], np.float32).reshape(RES, RES, 4)

nimg = target("normal"); tnode.image = nimg
scan.select_set(True); wrap.select_set(True); bpy.context.view_layer.objects.active = wrap
bk.use_selected_to_active = True; bk.cage_extrusion = 0.004; bk.max_ray_distance = 0.012
bk.margin = 8
bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT')
N = pixels(nimg)[..., :3] * 2 - 1

# mask: the wrap's own vertex colour, emitted
emit = wn.new("ShaderNodeEmission"); attr = wn.new("ShaderNodeVertexColor"); attr.layer_name = "mask"
wm.node_tree.links.new(attr.outputs["Color"], emit.inputs["Color"])
wm.node_tree.links.new(emit.outputs["Emission"], wn["Material Output"].inputs["Surface"])
mimg = target("mask"); tnode.image = mimg
bk.use_selected_to_active = False
bpy.ops.object.select_all(action='DESELECT'); wrap.select_set(True)
bpy.ops.object.bake(type='EMIT')
Mk = pixels(mimg)[..., 0]

def box(x, r):
    for ax in (0, 1):
        c = np.cumsum(np.pad(x, [(r + 1, r) if i == ax else (0, 0) for i in range(x.ndim)], mode='edge'), axis=ax)
        x = (np.take(c, np.arange(2 * r + 1, c.shape[ax]), axis=ax) - np.take(c, np.arange(0, c.shape[ax] - 2 * r - 1), axis=ax)) / (2 * r + 1)
    return x

def blur(x, r):
    for _ in range(3):
        x = box(x, r)
    return x

R = int(os.environ.get("HIGHPASS", "16"))
w = (Mk > 0.01).astype(np.float32)
xy = N[..., :2]
low = blur(xy * w[..., None], R) / np.maximum(blur(w, R), 1e-4)[..., None]
d = (xy - low) * Mk[..., None]
z = np.sqrt(np.clip(1 - (d ** 2).sum(-1), 0, 1))
out = bpy.data.images.new("detail", RES, RES, alpha=True)
out.colorspace_settings.name = "Non-Color"
out.pixels = np.dstack([d * 0.5 + 0.5, z * 0.5 + 0.5, Mk]).astype(np.float32).ravel()
out.filepath_raw = out_png; out.file_format = 'PNG'; out.save()

if debug_dir:
    bpy.ops.object.select_all(action='DESELECT'); wrap.select_set(True); scan.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(debug_dir, "wrap_debug.glb"), use_selection=True, export_format='GLB')
print("WROTE", out_png)
