"""Renders a hairstyle grown by hairstyle.py on a baked character, in Cycles
as real hair, beside the character's current hair, to judge the style's
shape before it is cut into cards.

    blender -b -P tools/characters/preview_hairstyle.py -- <character.glb> <style.json> <out_dir> [tag]

Writes <out_dir>/<tag>_<view>.png for the front, three-quarter, side and back
views, and with OLD=1 <tag>_old_<view>.png with the character's current hair
(as Cycles sees it: the groom's cards without their game shader).
MELANIN sets the hair's colour (0 blond .. 1 black), REDNESS its warmth.
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hairstyle  # noqa: E402

argv = sys.argv[sys.argv.index("--") + 1:]
glb, style_path, out_dir = argv[:3]
tag = argv[3] if len(argv) > 3 else os.path.splitext(os.path.basename(style_path))[0]
views = (argv[4] if len(argv) > 4 else "front,three,side,back").split(",")
MELANIN = float(os.environ.get("MELANIN", "0.85"))
REDNESS = float(os.environ.get("REDNESS", "0.6"))
OLD = os.environ.get("OLD", "0") == "1"

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
name = os.path.splitext(os.path.basename(glb))[0]
body = bpy.data.objects[name]
eyes = next(o for o in bpy.data.objects if o.name.endswith("high-poly"))
for o in bpy.data.objects:
    if o.name.startswith("Icosphere"):
        o.hide_render = True
old = [o for o in bpy.data.objects if o.type == "MESH" and (o.name.endswith(".groom") or o.name.endswith("hair_shell"))]

head = hairstyle.Head(body, eyes)
style = hairstyle.Style(style_path, head)
S, radius, G = hairstyle.grow(head, style)
print("STRANDS", S.shape)

curves = bpy.data.hair_curves.new("hairstyle")
curves.add_curves([S.shape[1]] * len(S))
curves.attributes["position"].data.foreach_set("vector", S.reshape(-1).astype(np.float32))
r = curves.attributes.get("radius") or curves.attributes.new("radius", "FLOAT", "POINT")
r.data.foreach_set("value", radius.reshape(-1).astype(np.float32))
hair = bpy.data.objects.new("hairstyle", curves)
bpy.context.scene.collection.objects.link(hair)

mat = bpy.data.materials.new("hair")
mat.use_nodes = True
nt = mat.node_tree
nt.nodes.clear()
bsdf = nt.nodes.new("ShaderNodeBsdfHairPrincipled")
bsdf.parametrization = "MELANIN"
bsdf.inputs["Melanin"].default_value = MELANIN
bsdf.inputs["Melanin Redness"].default_value = REDNESS
bsdf.inputs["Roughness"].default_value = 0.5
bsdf.inputs["Radial Roughness"].default_value = 0.6
bsdf.inputs["Random Roughness"].default_value = 0.1
bsdf.inputs["Random Color"].default_value = 0.0
bsdf.inputs["Coat"].default_value = 0.0
out = nt.nodes.new("ShaderNodeOutputMaterial")
nt.links.new(bsdf.outputs[0], out.inputs["Surface"])
curves.materials.append(mat)

# The scalp under the hair takes its colour, as the game's scalp texture
# (CharacterLook.scalp_texture) does: short hair reads as the tint, not as
# separate strands.
from mathutils.kdtree import KDTree  # noqa: E402

kd = KDTree(len(S))
for i, p in enumerate(S[:, 0]):
    kd.insert(Vector(p), i)
kd.balance()
mw = body.matrix_world
cover = np.zeros(len(body.data.vertices))
for v in body.data.vertices:
    w = mw @ v.co
    if abs(w.x) < 0.14 and w.z > head.eye_z - 0.13:
        cover[v.index] = len(kd.find_range(w, 0.004))
cover = np.clip(cover / 3.0, 0.0, 1.0)
tint = body.data.color_attributes.new("scalp", "FLOAT_COLOR", "POINT")
tint.data.foreach_set("color", np.repeat(cover, 4).astype(np.float32))
pale = (1 - MELANIN) ** 1.5
scalp_rgb = ((0.6 + 0.15 * REDNESS) * pale + 0.01, 0.4 * pale + 0.007, 0.27 * pale + 0.005, 1)
for slot in body.material_slots:
    m = slot.material
    if not (m and m.use_nodes and m.name.endswith("body")):
        continue
    bs = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    src = bs.inputs["Base Color"].links[0].from_socket if bs.inputs["Base Color"].links else None
    mix = m.node_tree.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    attr = m.node_tree.nodes.new("ShaderNodeAttribute")
    attr.attribute_name = "scalp"
    a_in, b_in = (next(x for x in mix.inputs if x.name == n and x.type == "RGBA") for n in ("A", "B"))
    m.node_tree.links.new(attr.outputs["Fac"], next(x for x in mix.inputs if x.name == "Factor" and x.type == "VALUE"))
    if src:
        m.node_tree.links.new(src, a_in)
    else:
        a_in.default_value = bs.inputs["Base Color"].default_value
    b_in.default_value = scalp_rgb
    m.node_tree.links.new(next(x for x in mix.outputs if x.type == "RGBA"), bs.inputs["Base Color"])
    shine = m.node_tree.nodes.new("ShaderNodeMath")
    shine.operation = "MULTIPLY_ADD"
    m.node_tree.links.new(attr.outputs["Fac"], shine.inputs[0])
    shine.inputs[1].default_value = -0.9 * bs.inputs["Specular IOR Level"].default_value
    shine.inputs[2].default_value = bs.inputs["Specular IOR Level"].default_value
    m.node_tree.links.new(shine.outputs[0], bs.inputs["Specular IOR Level"])

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = 48
scene.cycles.use_denoising = True
scene.render.resolution_x = scene.render.resolution_y = 700
scene.render.film_transparent = False
scene.view_settings.view_transform = "AgX"
world = bpy.data.worlds.new("w")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.35, 0.37, 0.4, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.6
scene.world = world


def light(kind, loc, energy, size=1.0):
    ld = bpy.data.lights.new(kind, kind)
    ld.energy = energy
    if kind == "AREA":
        ld.size = size
    o = bpy.data.objects.new(kind, ld)
    scene.collection.objects.link(o)
    o.location = loc
    o.rotation_euler = (Vector(head.c) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()


c = head.c
light("AREA", c + np.array([-0.8, -1.0, 0.7]), 120, 0.8)
light("AREA", c + np.array([1.0, -0.4, 0.2]), 40, 1.0)
light("AREA", c + np.array([0.2, 1.0, 0.8]), 80, 0.6)

cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
cam.data.lens = 85
scene.collection.objects.link(cam)
scene.camera = cam
ANGLES = {"front": 0, "three": 35, "side": 90, "back": 180}
target = c + np.array([0, 0, -0.03])

for hide_new in ((False, True) if OLD else (False,)):
    hair.hide_render = hide_new
    for o in old:
        o.hide_render = not hide_new or o.name.endswith("hair_shell")
    for v in views:
        a = math.radians(ANGLES[v])
        d = np.array([math.sin(a), -math.cos(a), 0.12])
        cam.location = target + d / np.linalg.norm(d) * 0.95
        cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(out_dir, "%s%s_%s.png" % (tag, "_old" if hide_new else "", v))
        bpy.ops.render.render(write_still=True)
        print("WROTE", scene.render.filepath)
