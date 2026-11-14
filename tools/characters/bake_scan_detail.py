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
import os
import sys

import bpy
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_fit

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
scan = scan_fit.load_scan(scan_glb)

head = scan_fit.Head(body.data)
scan_fit.align(scan, head)
cur, good = scan_fit.wrap(scan, head)
wrap = body.copy(); wrap.data = body.data.copy(); wrap.name = "wrap"
bpy.context.scene.collection.objects.link(wrap)
for i, v in enumerate(wrap.data.vertices):
    v.co = Vector(cur[i])
wrap.data.update()

# mask: well-projected, away from the eyes (the scan's are shut), above the
# neck, and away from shapes too unlike the scan's to share its detail: ears,
# lips, nostrils
away = head.eyes()
for sx in (-1, 1):
    away *= head.keep_away(head.ear * (sx, 1, 1), 0.035, 0.05)
    away *= head.keep_away(head.at(sx * 0.012, 0.012, -0.01), 0.008, 0.014)
away *= head.keep_away(head.at(0, 0.012, -0.036), 0.016, 0.026)
mask = np.clip(head.smooth(good, head.zramp, 6) * 1.5 - 0.25, 0, 1) * head.zramp * away
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
