"""Makes the face's bony and soft forms by rule, as MakeHuman targets a recipe
can pick.

    blender -b --factory-startup --python tools/characters/bake_bone_shapes.py -- \\
        <parts_dir> [debug.glb]

Needs MPFB, as bake_character.py does (BLENDER_USER_RESOURCES).

No scan: each form is a soft region placed from landmarks every MPFB human
has (the eye joints, the lips, the ear's widest point, the nose tip) and moved
the way the bone under it would move the skin:

    brow_ridge     the brow bone over the eyes and between them, out and down
    cheekbones     the cheekbone under the outer eye and its arch to the ear
    cheek_hollows  the hollow under the cheekbone, in (lean faces)
    jaw            the jaw's corner under the ear and its line to the chin
    chin           the chin's point and its two corners, forward

and the fat and folds over them, the forms age and weight change:

    temples        the hollow behind the eye socket's outer rim, in
    malar_fat      the cheek's fat pad under the eye, out and up (full,
                   young cheeks)
    nasolabial     the cheek's roll beside the line from the nose's wing to
                   the mouth's corner, forward: the fold beside the mouth
    tear_trough    the groove from the eye's inner corner down and out, in
    jowls          the fat over the jaw line in front of its corner, down
    submental      the fat under the chin, down (a double chin)

each written to <parts_dir>/bone/<form>.target or <parts_dir>/soft/<form>.target,
at 1 a strong but plausible amount (3 to 6 millimetres at most). A recipe
picks them as parts from "bone" or "soft":
"parts": {"cheekbones": ["bone", 0.6], "jowls": ["soft", 0.5]}. A negative
amount works too: temples at -0.5 fill them out. A target is a change from MakeHuman's
base, so it goes on over any macros; it is made on the default human, and a
few millimetres sit as well on any other.

With debug.glb it also writes the head plain and with each form at 1, for a
look.
"""
import os
import sys

import addon_utils
import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_fit

args = sys.argv[sys.argv.index("--") + 1:]
parts_dir = args[0]
debug_glb = args[1] if len(args) > 1 else None
MM = 0.001

addon_utils.enable("bl_ext.user_default.mpfb", default_set=True)
from bl_ext.user_default.mpfb.services.humanservice import HumanService
from bl_ext.user_default.mpfb.services.targetservice import TargetService

for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)
basemesh = HumanService.create_human(scale=0.1, macro_detail_dict=TargetService.get_default_macro_info_dict())
TargetService.bake_targets(basemesh)
mesh = basemesh.data


def group(name):
    idx = basemesh.vertex_groups[name].index
    return np.array([any(g.group == idx and g.weight > 0 for g in v.groups) for v in mesh.vertices])


skin = group("body")
head = scan_fit.Head(mesh, use=skin)
k = head.k
V, N = head.v, head.n
eye = {int(np.sign(c[0])): c for c in (V[group("joint-%s-eye" % s)].mean(0) for s in "lr")}
lips = V[group("lips") & (np.abs(V[:, 0]) < 0.004)]
mouth_z = lips[:, 2].mean()
eye_z = eye[1][2]

skin_idx = np.where(skin)[0]
tree = BVHTree.FromPolygons([Vector(v) for v in V],
                            [tuple(p.vertices) for p in mesh.polygons if all(skin[p.vertices])])


def front(x, z):
    """The skin's point seen from straight ahead at (x, z)."""
    hit = tree.ray_cast(Vector((x, head.nose[1] - 0.3, z)), Vector((0, 1, 0)))
    return np.array(hit[0])


def side(sx, y, z):
    """The skin's point seen from the side sx at (y, z)."""
    hit = tree.ray_cast(Vector((sx * 0.3, y, z)), Vector((-sx, 0, 0)))
    return np.array(hit[0])


# Bone shapes are broad: every region's radii are this much larger than the
# numbers below, and full within CORE of them.
SIZE = 1.6
CORE = 0.4


def ramp(d):
    t = np.clip((d - CORE) / (1 - CORE), 0, 1)
    return 1 - t * t * (3 - 2 * t)


def blob(c, radii):
    """1 near c, fading to 0 over an ellipsoid of radii (hero metres, times
    SIZE), smooth; on the side of the head c is on."""
    d = np.linalg.norm((V - c) / (np.array(radii) * SIZE * k), axis=1)
    w = ramp(d)
    return w * skin * (np.sign(V[:, 0]) * np.sign(c[0]) >= 0 if abs(c[0]) > 0.003 else 1)


def tube(a, b, r):
    """1 on the segment a-b, fading to 0 at r (hero metres)."""
    ab = b - a
    t = np.clip(((V - a) @ ab) / (ab @ ab), 0, 1)
    d = np.linalg.norm(V - (a + t[:, None] * ab), axis=1) / (r * SIZE * k)
    return ramp(d) * skin * np.sin(np.pi * np.clip(t, 0.05, 0.95)) ** 0.5


def along(w, direction, mm):
    """A move of mm at full weight, along the normal bent towards direction."""
    dvec = N + np.array(direction)[None, :] if np.ndim(direction) == 1 else N + direction
    dvec /= np.linalg.norm(dvec, axis=1)[:, None]
    return dvec * (w * mm * MM * k)[:, None]


def soft(d, passes=2):
    return head.smooth(d, head.zramp, passes) * head.zramp[:, None]


# Below the brow the lids stay: they ride the eyeball, which does not move.
above_lids = np.clip((V[:, 2] - (eye_z + 0.004 * k)) / (0.008 * k), 0, 1)
forms = {}

w = blob(front(0, eye_z + 0.012 * k), (0.016, 0.03, 0.012)) * 0.7
for sx in (-1, 1):
    ex = eye[sx][0]
    w = np.maximum(w, blob(front(ex, eye_z + 0.016 * k), (0.026, 0.035, 0.011)))
    w = np.maximum(w, blob(front(ex + sx * 0.014 * k, eye_z + 0.012 * k), (0.012, 0.03, 0.012)))
forms["brow_ridge"] = soft(along(w * above_lids, (0, -0.6, -0.25), 6.0))

w = np.zeros(len(V))
for sx in (-1, 1):
    ex = eye[sx][0]
    bone = front(ex + sx * 0.016 * k, eye_z - 0.022 * k)
    arch = side(sx, head.ear[1] - 0.03 * k, eye_z - 0.02 * k)
    w = np.maximum(w, blob(bone, (0.02, 0.025, 0.014)))
    w = np.maximum(w, tube(bone, arch, 0.011) * 0.6)
forms["cheekbones"] = soft(along(w, (0, 0, 0.15), 5.0))

w = np.zeros(len(V))
for sx in (-1, 1):
    ex = eye[sx][0]
    hollow = side(sx, head.nose[1] + 0.07 * k, mouth_z + 0.008 * k)
    w = np.maximum(w, blob(hollow, (0.016, 0.026, 0.02)))
# not the mouth's corners or the nasolabial fold's ridge
w *= head.keep_away(np.array([0, lips[:, 1].min(), mouth_z]), 0.03, 0.045)
forms["cheek_hollows"] = soft(along(w, (0, 0, 0), -4.0))

w = np.zeros(len(V))
chin_z = mouth_z - 0.042 * k
for sx in (-1, 1):
    corner = side(sx, head.ear[1] + 0.004 * k, mouth_z - 0.03 * k)
    chin_side = front(sx * 0.016 * k, chin_z)
    w = np.maximum(w, blob(corner, (0.016, 0.022, 0.02)))
    w = np.maximum(w, tube(corner, chin_side, 0.009) * 0.5)
lateral = np.zeros((len(V), 3))
lateral[:, 0] = np.sign(V[:, 0]) * 0.6
lateral[:, 2] = -0.3
forms["jaw"] = soft(along(w, lateral, 8.0))

point = front(0, chin_z)
w = blob(point, (0.018, 0.022, 0.014))
for sx in (-1, 1):
    w = np.maximum(w, blob(front(sx * 0.012 * k, chin_z - 0.002 * k), (0.01, 0.02, 0.012)) * 0.7)
forms["chin"] = soft(along(w, (0, -0.7, -0.2), 7.0))

# The soft forms. As above the lids, the lids themselves stay still.
below_lids = np.clip(((eye_z - 0.011 * k) - V[:, 2]) / (0.006 * k), 0, 1)
soft_forms = {}

w = np.zeros(len(V))
for sx in (-1, 1):
    w = np.maximum(w, blob(side(sx, eye[sx][1] + 0.016 * k, eye_z + 0.004 * k), (0.014, 0.018, 0.02)))
soft_forms["temples"] = soft(along(w, (0, 0, 0), -4.5))

w = np.zeros(len(V))
for sx in (-1, 1):
    w = np.maximum(w, blob(front(eye[sx][0] * 1.1, eye_z - 0.03 * k), (0.017, 0.02, 0.014)))
soft_forms["malar_fat"] = soft(along(w * below_lids, (0, -0.4, 0.35), 5.0))

w = np.zeros(len(V))
for sx in (-1, 1):
    wing = front(sx * 0.024 * k, head.nose[2] - 0.006 * k)
    corner = front(sx * 0.032 * k, mouth_z - 0.006 * k)
    w = np.maximum(w, tube(wing, corner, 0.008))
w *= head.keep_away(np.array([0, lips[:, 1].min(), mouth_z]), 0.016, 0.024)
soft_forms["nasolabial"] = soft(along(w, (0, -0.8, 0), 5.0))

w = np.zeros(len(V))
for sx in (-1, 1):
    inner = front(eye[sx][0] - sx * 0.011 * k, eye_z - 0.017 * k)
    outer = front(eye[sx][0] + sx * 0.006 * k, eye_z - 0.027 * k)
    w = np.maximum(w, tube(inner, outer, 0.007))
soft_forms["tear_trough"] = soft(along(w * below_lids, (0, 0, 0), -6.0))

w = np.zeros(len(V))
for sx in (-1, 1):
    w = np.maximum(w, blob(front(sx * 0.037 * k, mouth_z - 0.03 * k), (0.015, 0.016, 0.016)))
down = np.zeros((len(V), 3))
down[:, 0] = np.sign(V[:, 0]) * 0.3
down[:, 1] = -0.2
down[:, 2] = -0.6
soft_forms["jowls"] = soft(along(w, down, 6.0))

under = np.array(tree.ray_cast(Vector((0, point[1] + 0.035 * k, chin_z - 0.05 * k)), Vector((0, 0, 1)))[0])
w = blob(under, (0.028, 0.024, 0.016))
soft_forms["submental"] = soft(along(w, (0, -0.3, -1.0), 6.0))

print("LANDMARKS eye", np.round(eye[1], 4), "mouth z", round(float(mouth_z), 4), "ear", np.round(head.ear, 4),
      "chin", np.round(point, 4), "under chin", np.round(under, 4))
for source, deltas in (("bone", forms), ("soft", soft_forms)):
    scan_fit.write_targets(basemesh, head, skin, deltas, os.path.join(parts_dir, source),
                           TargetService.shape_key_info_as_target_string)
forms.update(soft_forms)

if debug_glb:
    import bmesh
    low = head.at(0, 0, -0.16)[2]
    bpy.ops.object.select_all(action='DESELECT')
    for name, d in [("plain", np.zeros_like(V))] + list(forms.items()) + [("all", sum(forms.values()))]:
        m = mesh.copy()
        m.vertices.foreach_set("co", (V + d).ravel())
        bm = bmesh.new()
        bm.from_mesh(m)
        bm.verts.ensure_lookup_table()
        bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.where(~skin | (V[:, 2] < low))[0]], context='VERTS')
        bm.to_mesh(m)
        bm.free()
        for p in m.polygons:
            p.use_smooth = True
        o = bpy.data.objects.new(name, m)
        bpy.context.scene.collection.objects.link(o)
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=debug_glb, use_selection=True, export_format='GLB')
print("WROTE", parts_dir)
