"""Cuts a head scan into face parts a recipe can pick: MakeHuman targets.

    blender -b --factory-startup --python tools/characters/bake_scan_parts.py -- \\
        <scan.glb> <out_dir> [macro=value ...]

Needs MPFB, as bake_character.py does (BLENDER_USER_RESOURCES).

The scan is fitted (scan_fit.py) to an MPFB human made with the given macros,
which should say what the scanned person is (gender=1 caucasian=1 for a white
man), so that a part carries what is the person's own, not what is merely
male or white. The fitted head minus the MPFB one is then cut, with soft edges,
into parts:

    nose, mouth, chin, cheeks, brow, ears, and skull (the rest of the head)

each written to <out_dir>/<part>.target. All of them at 1 make the scan's whole
head; any one alone puts that feature on an MPFB face and blends into it. A
target is a change from MakeHuman's base, so it goes on over any macros.

The eyes and lids are left as MPFB's (the scan's are shut), and helper
geometry (teeth, tongue, eyes, hair) moves with the skin nearest it, so all of
it still fits. The rig's joint cubes stay put: the bones are MPFB's.
"""
import os
import sys

import addon_utils
import bpy
import numpy as np
from mathutils.kdtree import KDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_fit

args = sys.argv[sys.argv.index("--") + 1:]
scan_glb, out_dir = args[0], args[1]

addon_utils.enable("bl_ext.user_default.mpfb", default_set=True)
from bl_ext.user_default.mpfb.services.humanservice import HumanService
from bl_ext.user_default.mpfb.services.targetservice import TargetService

for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)

macros = TargetService.get_default_macro_info_dict()
for pair in args[2:]:
    key, value = pair.split("=")
    if key in macros["race"]:
        macros["race"][key] = float(value)
    elif key in macros:
        macros[key] = float(value)
    else:
        sys.exit("bake_scan_parts: unknown macro '%s'" % key)
basemesh = HumanService.create_human(scale=0.1, macro_detail_dict=macros)
TargetService.bake_targets(basemesh)
mesh = basemesh.data

body_group = basemesh.vertex_groups["body"].index
skin = np.array([any(g.group == body_group and g.weight > 0 for g in v.groups) for v in mesh.vertices])
head = scan_fit.Head(mesh, use=skin)
scan = scan_fit.load_scan(scan_glb)
scan_fit.align(scan, head)
cur, good = scan_fit.wrap(scan, head)
delta = (cur - head.v) * head.eyes()[:, None]

# The parts, in hero metres from the nose tip (y backwards): spheres with a
# soft edge. Where they overlap they share; what is left of the head is skull.
PARTS = {
    "nose": [((0, 0.018, 0.012), 0.020, 0.036)],
    "mouth": [((0, 0.014, -0.038), 0.020, 0.032)],
    "chin": [((0, 0.030, -0.074), 0.022, 0.042)],
    "cheeks": [((sx * 0.046, 0.050, -0.004), 0.022, 0.042) for sx in (-1, 1)],
    "brow": [((0, 0.040, 0.066), 0.030, 0.052)] +
            [((sx * 0.032, 0.040, 0.060), 0.016, 0.030) for sx in (-1, 1)],
    "ears": [],
}
weights = {}
for name, spheres in PARTS.items():
    w = np.zeros(len(head.v))
    for centre, r0, r1 in spheres:
        w = np.maximum(w, head.falloff(head.at(*centre), r0, r1))
    weights[name] = w
weights["ears"] = np.maximum(*[head.falloff(head.ear * (sx, 1, 1), 0.028, 0.044) for sx in (-1, 1)])
total = sum(weights.values())
over = np.maximum(total, 1)
for name in weights:
    weights[name] = weights[name] / over
weights["skull"] = np.clip(1 - sum(weights.values()), 0, 1)

# Helpers are not skin: each follows its nearest skin vertex. The joint cubes
# the rig is fitted to stay: a nose or a brow must not move the head's pivot,
# or every animation would turn the head differently.
kd = KDTree(int(skin.sum()))
skin_index = np.where(skin)[0]
for j, i in enumerate(skin_index):
    kd.insert(head.v[i], j)
kd.balance()
follow = np.arange(len(head.v))
for i in np.where(~skin)[0]:
    follow[i] = skin_index[kd.find(head.v[i])[1]]
joint_group = basemesh.vertex_groups["JointCubes"].index
joints = np.array([any(g.group == joint_group for g in v.groups) for v in mesh.vertices])

os.makedirs(out_dir, exist_ok=True)
scale = 0.1  # MakeHuman targets are in decimetres
for name, w in weights.items():
    d = (delta * w[:, None])[follow] / scale
    d[joints] = 0
    moved = np.where(np.abs(d).max(1) > 0.0005)[0]
    info = {"name": name, "vertices": [(int(i), *d[i]) for i in moved]}
    path = os.path.join(out_dir, name + ".target")
    with open(path, "w", newline="\n") as f:
        f.write(TargetService.shape_key_info_as_target_string(info))
    print("PART", name, "vertices", len(moved), "max mm", round(float(np.abs(d).max()) * 100, 2))
print("WROTE", out_dir)
