"""Grows a character's face its creases and folds on a dense copy of its head,
by rule, and bakes them to a normal map in MPFB's UV layout. No scan: every
feature is placed from landmarks every MPFB human has (the eye holes, the lips
group, the mouth and eye joints) and shaped by a few numbers.

    blender -b --factory-startup --python tools/characters/bake_face_shapes.py -- \\
        <recipe.json> <out.png> [debug_dir]

Needs MPFB, as bake_character.py does (BLENDER_USER_RESOURCES).

1. the character from its recipe (macros, targets, parts), as bake_character
   makes it; its head, skin only, is the game mesh ("low");
2. low subdivided twice ("dense", edges of 2-3 mm on the face);
3. features cut into dense along its normals: the upper lid crease and a lower
   lid line, the nasolabial folds, the lip border's roll, the philtrum ridges,
   the groove under the lower lip; and an unsharp pass on the nose and ears
   that deepens the folds MPFB's mesh only hints at;
4. Cycles bakes dense with and without the features onto low; <out.png> is
   the difference, RG a tangent-space normal's change (OpenGL, 0.5 = none),
   so it adds onto whatever normal the skin already has.

FEATURES (env, default 1) scales every depth: creases deepen with age.
"""
import json
import os
import sys

import addon_utils
import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_fit

argv = sys.argv[sys.argv.index("--") + 1:]
recipe_path, out_png = argv[0], os.path.abspath(argv[1])
debug_dir = argv[2] if len(argv) > 2 else None
with open(recipe_path, encoding="utf-8") as f:
    recipe = json.load(f)
RES = 4096
GAIN = float(os.environ.get("FEATURES", "1"))
MM = 0.001

addon_utils.enable("bl_ext.user_default.mpfb", default_set=True)
from bl_ext.user_default.mpfb.services.humanservice import HumanService
from bl_ext.user_default.mpfb.services.targetservice import TargetService

for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)
macros = TargetService.get_default_macro_info_dict()
for key, value in recipe.get("macros", {}).items():
    if key == "race":
        macros["race"].update(value)
    else:
        macros[key] = float(value)
basemesh = HumanService.create_human(scale=0.1, macro_detail_dict=macros)
for name, value in recipe.get("targets", {}).items():
    TargetService.load_target(basemesh, TargetService.target_full_path(name), weight=float(value), name=name)
parts_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "parts")
for part, source in recipe.get("parts", {}).items():
    source, amount = (source, 1.0) if isinstance(source, str) else source
    TargetService.load_target(basemesh, os.path.join(parts_dir, source, part + ".target"),
                              weight=float(amount), name="part-%s-%s" % (source, part))
TargetService.bake_targets(basemesh)


def weights(obj, name):
    idx = obj.vertex_groups[name].index
    w = np.zeros(len(obj.data.vertices))
    for v in obj.data.vertices:
        for g in v.groups:
            if g.group == idx:
                w[v.index] = g.weight
    return w


def centre(name):
    w = weights(basemesh, name) > 0
    return np.array([v.co for v in basemesh.data.vertices])[w].mean(0)


lid_joint = {}
for side in ("l", "r"):
    c = centre("joint-%s-upperlid" % side)
    lid_joint[int(np.sign(c[0]))] = c

# low: the head's skin, the game mesh's own shape and UVs
low = basemesh.copy()
low.data = basemesh.data.copy()
low.name = "low"
bpy.context.scene.collection.objects.link(low)
low.modifiers.clear()
skin = weights(low, "body") > 0
head0 = scan_fit.Head(low.data, use=skin)
cut = head0.at(0, 0, -0.14)[2]
bm = bmesh.new()
bm.from_mesh(low.data)
bm.verts.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not skin[v.index] or v.co.z < cut], context='VERTS')
bm.to_mesh(low.data)
bm.free()
for p in low.data.polygons:
    p.use_smooth = True
low.data.update()
head = scan_fit.Head(low.data)
k = head.k

# dense: low subdivided
dense = low.copy()
dense.data = low.data.copy()
dense.name = "dense"
bpy.context.scene.collection.objects.link(dense)
sub = dense.modifiers.new("sub", 'SUBSURF')
sub.levels = sub.render_levels = 2
bpy.context.view_layer.objects.active = dense
bpy.ops.object.modifier_apply(modifier="sub")
dm = dense.data
D = np.array([v.co for v in dm.vertices])
DN = np.array([v.normal for v in dm.vertices])
E = np.array([e.vertices[:] for e in dm.edges])
lips = weights(dense, "lips")
ears = weights(dense, "ears")
deg = np.bincount(E.ravel(), minlength=len(D)).astype(float)


def smooth(x, passes):
    for _ in range(passes):
        acc = np.zeros_like(x)
        np.add.at(acc, E[:, 0], x[E[:, 1]])
        np.add.at(acc, E[:, 1], x[E[:, 0]])
        x = acc / np.maximum(deg, 1).reshape(-1, *[1] * (x.ndim - 1))
    return x


# The face seen from the front is near enough a height field: curves are
# drawn in (x, z) and dropped onto the surface.
tree = BVHTree.FromObject(low, bpy.context.evaluated_depsgraph_get())
front_y = head.nose[1] - 0.3


def drop(x, z):
    hit = tree.ray_cast(Vector((x, front_y, z)), Vector((0, 1, 0)))
    return None if hit[0] is None else (np.array(hit[0]), np.array(hit[1]))


def bezier(points, n=200):
    t = np.linspace(0, 1, n)[:, None]
    P = [np.array(p, float) + 0 * t for p in points]
    while len(P) > 1:
        P = [P[i] * (1 - t) + P[i + 1] * t for i in range(len(P) - 1)]
    return P[0]


def surface_curve(xz):
    pts, nrm = [], []
    for x, z in xz:
        hit = drop(x, z)
        if hit is not None:
            pts.append(hit[0])
            nrm.append(hit[1])
    return np.array(pts), np.array(nrm)


def near_curve(pts, nrm, reach):
    """For each dense vertex within reach of the curve: its distance, which
    side it is on (+1 / -1 across the curve) and how far along (0..1)."""
    kd = KDTree(len(pts))
    for i, p in enumerate(pts):
        kd.insert(Vector(p), i)
    kd.balance()
    tan = np.gradient(pts, axis=0)
    across = np.cross(tan, nrm)
    across /= np.maximum(np.linalg.norm(across, axis=1), 1e-9)[:, None]
    dist = np.full(len(D), np.inf)
    side = np.zeros(len(D))
    along = np.zeros(len(D))
    for i in np.where(np.linalg.norm(D - pts.mean(0), axis=1) < np.ptp(pts, axis=0).max() + reach)[0]:
        co, j, d = kd.find(Vector(D[i]))
        if d < reach:
            dist[i] = d
            side[i] = np.sign(np.dot(D[i] - pts[j], across[j]))
            along[i] = j / (len(pts) - 1)
    return dist, side, along


def taper(along, ends=0.2):
    t = np.clip(np.minimum(along, 1 - along) / ends, 0, 1)
    return t * t * (3 - 2 * t)


def gauss(d, w):
    return np.exp(-(d / w) ** 2)


h = np.zeros(len(D))
lip_pts = D[lips > 0.5]
mouth_c = lip_pts.mean(0)
mid = np.abs(lip_pts[:, 0]) < 0.003 * k
lip_top, lip_bottom = lip_pts[mid][:, 2].max(), lip_pts[mid][:, 2].min()


def depth(x, z):
    hit = drop(x, z)
    return np.nan if hit is None else hit[0][1]


# subnasale: going down the midline from the nose tip, as the front sees it,
# the surface runs back under the nose and then forward again over the upper
# lip; where it turns (the mouth's slit, further down, is deeper still)
zs = head.nose[2] - np.linspace(0.004, 0.03, 120) * k
ys = np.array([depth(0, z) for z in zs])
turn = np.where(ys[1:] < ys[:-1] - 1e-5)[0]
sub_z = zs[turn[0]] if len(turn) else zs[np.nanargmax(ys)]
subnasale = drop(0, sub_z)[0]
wing_z = sub_z + 0.004 * k

for sx in (-1, 1):
    # mouth corner: the lips' widest point this side
    side_lips = lip_pts[lip_pts[:, 0] * sx > 0]
    corner = side_lips[np.argmax(np.abs(side_lips[:, 0]))]
    # alar wing: across a row just above the subnasale, the steepest step
    # back is the wing's side
    xs = sx * np.linspace(0.006, 0.032, 120) * k
    wing_x = xs[np.nanargmax(np.gradient([depth(x, wing_z) for x in xs]) )]
    wing = np.array([wing_x, 0, wing_z])
    print("LANDMARKS", sx, "corner", np.round(corner, 4), "wing x", round(float(wing_x), 4),
          "subnasale", np.round(subnasale, 4))
    # nasolabial fold: from above the wing, bowing out, to past the mouth corner
    a = (wing[0] + sx * 0.002 * k, wing[2] + 0.006 * k)
    c = (corner[0] + sx * 0.006 * k, corner[2] - 0.009 * k)
    b = (corner[0] + sx * 0.007 * k, (a[1] + c[1]) / 2 + 0.003 * k)
    pts, nrm = surface_curve(bezier([a, b, c]))
    dist, side, along = near_curve(pts, nrm, 9 * MM * k)
    cheek_side = np.sign(np.dot(np.cross(np.gradient(pts, axis=0)[len(pts) // 2], nrm[len(pts) // 2]),
                                pts[len(pts) // 2] - mouth_c))
    # a young face's: shallow and soft, fading out towards the mouth
    w = taper(along, 0.35) * (1 - 0.6 * along)
    fold = -0.4 * MM * gauss(dist, 2.4 * MM) + 0.3 * MM * gauss(dist - 3.0 * MM, 2.6 * MM) * (side == cheek_side)
    h += np.where(np.isfinite(dist), fold * w, 0)

    # eye: the opening, as the front sees it: where rays fall past the lids
    # (the upper lid joint sits ~2 cm before the lid, the socket ~5 cm behind it)
    # into the socket. Its top and bottom, column by column, are the margins.
    ul = lid_joint[sx]
    step = 0.0003
    upper, lower = [], []
    for x in np.arange(ul[0] - 0.02 * k, ul[0] + 0.02 * k, step):
        zs = np.arange(ul[2] - 0.02 * k, ul[2] + 0.008 * k, step)
        deep = np.array([(lambda hit: hit is None or hit[0][1] > ul[1] + 0.03 * k)(drop(x, z)) for z in zs])
        if not deep.any() or deep[0] or deep[-1]:
            continue
        run = np.where(deep)[0]
        upper.append((x, zs[run.max()]))
        lower.append((x, zs[run.min()]))
    m_up, m_lo = np.array(upper), np.array(lower)
    print("EYE", sx, "opening mm", round(float(np.ptp(m_up[:, 0]) / MM), 1),
          "x", round(float(m_up[:, 0].mean()), 4))
    # upper crease: the upper margin lifted, most at its middle, and drawn
    # out a little past the corners
    n = len(m_up)
    t = np.linspace(0, 1, n)
    cx = m_up[:, 0].mean()
    lift = 0.0045 * k + 0.0035 * k * np.sin(np.pi * t)
    xz = [((x - cx) * 1.12 + cx, z + l) for (x, z), l in zip(m_up, lift)]
    pts, nrm = surface_curve(xz)
    dist, side, along = near_curve(pts, nrm, 3 * MM * k)
    h += np.where(np.isfinite(dist), -0.45 * MM * gauss(dist, 0.7 * MM) * taper(along, 0.25), 0)
    # lower lid line: faint, under the lower margin
    xz = [(x, z - 0.0035 * k) for x, z in m_lo]
    pts, nrm = surface_curve(xz)
    dist, side, along = near_curve(pts, nrm, 3 * MM * k)
    h += np.where(np.isfinite(dist), -0.2 * MM * gauss(dist, 0.9 * MM) * taper(along, 0.3), 0)

    # philtrum ridge: from the lip's peak up to beside the subnasale
    peak = lip_pts[(lip_pts[:, 0] * sx > 0.003 * k) & (lip_pts[:, 0] * sx < 0.007 * k)]
    peak = peak[np.argmax(peak[:, 2])]
    pts, nrm = surface_curve(bezier([(peak[0], peak[2] + 0.001 * k),
                                     (sx * 0.0035 * k, subnasale[2] - 0.004 * k)]))
    dist, side, along = near_curve(pts, nrm, 3 * MM * k)
    h += np.where(np.isfinite(dist), 0.3 * MM * gauss(dist, 1.1 * MM) * taper(along, 0.2), 0)

# lip border: a soft rolled edge just outside the lips. It is the upper lip's
# (most of all over the cupid's bow); under the lower lip it is faint, and it
# fades out towards the corners. Even all round, it reads as a drawn outline.
border = smooth(lips, 2)
edge = np.where((border > 0.35) & (border < 0.65))[0]
outside = border < 0.5
kd = KDTree(len(edge))
for j, i in enumerate(edge):
    kd.insert(Vector(D[i]), j)
kd.balance()
half_width = np.abs(lip_pts[:, 0]).max()
slit_z = (lip_top + lip_bottom) / 2
near_mouth = np.where(np.linalg.norm(D - mouth_c, axis=1) < 0.04 * k)[0]
for i in near_mouth:
    if not outside[i]:
        continue
    co, j, d = kd.find(Vector(D[i]))
    upper = np.clip((D[i, 2] - slit_z) / (0.003 * k), 0, 1)
    across = 1 - np.clip((abs(D[i, 0]) / half_width - 0.5) / 0.45, 0, 1)
    h[i] += 0.25 * MM * gauss(d - 1.0 * MM, 1.0 * MM) * (0.15 + 0.85 * upper) * across

# groove under the lower lip
xz = [(x * k, lip_bottom - 0.006 * k - 0.004 * k * (x / 0.014) ** 2) for x in np.linspace(-0.014, 0.014, 60)]
pts, nrm = surface_curve(xz)
dist, side, along = near_curve(pts, nrm, 8 * MM * k)
h += np.where(np.isfinite(dist), -0.45 * MM * gauss(dist, 2.5 * MM) * taper(along, 0.4), 0)

# unsharp: the nose's and ears' own folds, deepened
detail = ((D - smooth(D, 10)) * DN).sum(1)
dn = np.linalg.norm(D - head.at(0, 0.018, 0.004), axis=1)
nose_w = np.clip(1 - (dn - 0.020 * k) / (0.012 * k), 0, 1)
# not above the eyes: deepened there, the hollow between the brows reads as a frown
lid_z = np.mean([c[2] for c in lid_joint.values()])
nose_w *= np.clip((lid_z - D[:, 2]) / (0.006 * k), 0, 1)
h += 0.9 * np.minimum(detail, 0) * nose_w
h += 1.2 * detail * smooth(ears, 3)

h *= GAIN
# fade out at the cut neck
h *= np.clip((D[:, 2] - cut) / (0.03 * k), 0, 1)
print("FEATURES max mm", round(float(h.max() / MM), 2), "min mm", round(float(h.min() / MM), 2))

feat = dense.copy()
feat.data = dense.data.copy()
feat.name = "feat"
bpy.context.scene.collection.objects.link(feat)
for i, v in enumerate(feat.data.vertices):
    v.co = Vector(D[i] + DN[i] * h[i])
feat.data.update()

# bake both onto low; the difference is the features
sc = bpy.context.scene
sc.render.engine = 'CYCLES'
sc.cycles.device = 'CPU'
sc.cycles.samples = 1
bk = sc.render.bake
bk.use_selected_to_active = True
bk.cage_extrusion = 0.004
bk.max_ray_distance = 0.01
bk.margin = 8
mat = bpy.data.materials.new("lowmat")
mat.use_nodes = True
low.data.materials.clear()
low.data.materials.append(mat)
tnode = mat.node_tree.nodes.new("ShaderNodeTexImage")
mat.node_tree.nodes.active = tnode


def bake_from(src):
    img = bpy.data.images.new("n_" + src.name, RES, RES, float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    tnode.image = img
    bpy.ops.object.select_all(action='DESELECT')
    src.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT')
    return np.array(img.pixels[:], np.float32).reshape(RES, RES, 4)


plain = bake_from(dense)
withf = bake_from(feat)
d = (withf[..., :2] - plain[..., :2]) * 2
d = np.clip(d, -0.9, 0.9)
z = np.sqrt(np.clip(1 - (d ** 2).sum(-1), 0, 1))
out = bpy.data.images.new("shapes", RES, RES, alpha=False)
out.colorspace_settings.name = "Non-Color"
out.pixels = np.dstack([d * 0.5 + 0.5, z * 0.5 + 0.5, np.ones_like(z)]).astype(np.float32).ravel()
out.filepath_raw = out_png
out.file_format = 'PNG'
out.save()
if debug_dir:
    bpy.ops.object.select_all(action='DESELECT')
    feat.select_set(True)
    dense.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(debug_dir, "face_shapes_debug.glb"), use_selection=True,
                              export_format='GLB')
print("WROTE", out_png)
