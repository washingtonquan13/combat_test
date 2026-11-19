"""Fits a static armour glTF onto the CC body by a mesh deformer.

The armour was made for another body. The CC body is posed into the
armour's pose (arms down its sleeves, legs and feet to its boots) and its
arm bones lengthened to its sleeves; the armour is bound to that body with
Surface Deform, and the bones go back to the CC proportions (the pose stays),
so the armour follows the skin it was bound to. It is then skinned by the
posed body's weights, smoothed over the skin so stacked layers move together,
pushed a few mm off the skin, and each piece under another (padding under a
pauldron) pushed back under it. Last it is unposed by inverse skinning and
written as a .glb for tools/characters/cc_wearable.gd.

Run: blender -b --python fit_armour.py -- <args>
Args: body.glb armour.gltf out.glb preview.png S DZ DY ARM LEG YAW
      [UPPER FORE SHOULDER SPINE]   (bone length factors, 0 = measure)
body.glb is the CC male base (skinned, at rest) as glTF. Leather Armor:
  ... leather_armor/scene.gltf leather_armor.glb prev.png 0.84 0.84 0.02 48 7 20"""
import bpy, sys, math, collections
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

argv = sys.argv[sys.argv.index("--")+1:]
body_glb, armour_gltf, out_glb, preview = argv[:4]
S, DZ, DY, ARM, LEG, YAW = map(float, argv[4:10])
extra = list(map(float, argv[10:14])) + [0.0] * (4 - len(argv[10:14]))
UPPER, FORE, SHOULDER, SPINE = extra
CUFF = 0.015      # sleeve past the wrist
ARM_R = 0.14      # sleeve radius taken as the sleeve
MARGIN, NEAR = 0.004, 0.08

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=body_glb)
cc = set(bpy.data.objects)
arm = next(o for o in cc if o.type == 'ARMATURE')
body = next(o for o in cc if o.type == 'MESH' and o.name.startswith("CC_Base_Body"))
vl = bpy.context.view_layer
def rest():
    for pb in arm.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    vl.update()
rest()
assert any(m.type == 'ARMATURE' for m in body.modifiers), "body has no armature modifier"
W = arm.matrix_world

def world(name):
    vl.update()
    return W @ arm.pose.bones[name].matrix

def set_world(name, m):
    arm.pose.bones[name].matrix = W.inverted() @ m
    vl.update()

def turn(name, deg, axis='Y'):
    w = world(name); h = w.translation.copy()
    set_world(name, Matrix.Translation(h) @ Matrix.Rotation(math.radians(deg), 4, axis) @ Matrix.Translation(-h) @ w)

def slide(name, d):
    """Moves a bone (and what hangs from it) by world vector d."""
    set_world(name, Matrix.Translation(d) @ world(name))

def head(name):
    return world(name).translation.copy()

def pose():
    turn("LeftUpperArm", ARM); turn("RightUpperArm", -ARM)
    turn("LeftUpperArm", -YAW, 'Z')  # the source's left arm reaches forward
    turn("LeftUpperLeg", -LEG); turn("RightUpperLeg", LEG)

# --- the armour, scaled and placed, one mesh -------------------------------
bpy.ops.import_scene.gltf(filepath=armour_gltf)
pieces = [o for o in bpy.data.objects if o not in cc and o.type == 'MESH']
top = pieces[0]
while top.parent:
    top = top.parent
top.scale = tuple(v * S for v in top.scale)
top.location = (0, DY, DZ)
vl.update()
for p in pieces:
    mw = p.matrix_world.copy(); p.parent = None; p.matrix_world = mw
bpy.ops.object.select_all(action='DESELECT')
for p in pieces:
    p.select_set(True)
vl.objects.active = pieces[0]
if len(pieces) > 1:
    bpy.ops.object.join()
armour = vl.objects.active
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
armour.name = armour.data.name = "leather_armor"
AV = [v.co.copy() for v in armour.data.vertices]

# --- the body made to the armour's proportions -----------------------------
pose()
print("BONES", [b.name for b in arm.pose.bones if "Arm" in b.name or "Spine" in b.name or "Chest" in b.name or "Shoulder" in b.name])

def sleeve(side):
    """The sleeve's verts past the shoulder, by distance along the arm."""
    sh, wr = head(side + "UpperArm"), head(side + "Hand")
    ax = (wr - sh).normalized()
    ts = []
    for p in AV:
        t = (p - sh).dot(ax)
        if t > 0.05 and (p - sh - ax * t).length < ARM_R and (p.x > 0) == (sh.x > 0):
            ts.append(t)
    return max(ts), len(ts)

# Arms: aim each upper arm down its sleeve's axis (principal axis of the
# sleeve's verts), starting from the ARM/YAW guess.
def principal(pts):
    n = len(pts); c = sum(pts, Vector()) / n
    m = [[sum((p[i] - c[i]) * (p[j] - c[j]) for p in pts) for j in range(3)] for i in range(3)]
    v = Vector((1, 1, 1))
    for _ in range(60):
        v = Vector([sum(m[i][j] * v[j] for j in range(3)) for i in range(3)]).normalized()
    return v
for side in ("Left", "Right"):
    for _ in range(3):
        sh, wr = head(side + "UpperArm"), head(side + "Hand")
        ax = (wr - sh).normalized()
        pts = [p for p in AV if 0.08 < (p - sh).dot(ax) and (p - sh - ax * (p - sh).dot(ax)).length < ARM_R and (p.x > 0) == (sh.x > 0)]
        d = principal(pts)
        if d.dot(ax) < 0: d = -d
        q = ax.rotation_difference(d)
        print("AIM", side, "off by", round(math.degrees(ax.angle(d)), 2), "verts", len(pts))
        w = world(side + "UpperArm"); h = w.translation.copy()
        set_world(side + "UpperArm", Matrix.Translation(h) @ q.to_matrix().to_4x4() @ Matrix.Translation(-h) @ w)
# Legs: the source stands with one leg a step back. Each upper leg swings
# about X until the body's heel sits where the boot's heel does.
def body_pts():
    return [body.matrix_world @ v.co for v in body.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh().vertices]
for side in ("Left", "Right"):
    sx = 1 if head(side + "Foot").x > 0 else -1
    fy = [p.y for p in body_pts() if p.z < 0.04 and p.x * sx > 0.02]
    by = [p.y for p in AV if p.z < 0.04 and p.x * sx > 0.02]
    heel, bootheel = (min(fy) + max(fy)) / 2, (min(by) + max(by)) / 2  # sole middles
    hip = head(side + "UpperLeg").z
    deg = math.degrees(math.atan2(bootheel - heel, hip))
    print("LEG", side, "heel", round(heel, 3), "boot heel", round(bootheel, 3), "swing", round(deg, 2))
    turn(side + "UpperLeg", deg, 'X')
# Feet: the source's feet turn out by their own amount. Each foot yaws about
# its ankle until the body's sole points the way the boot's sole does
# (principal axis of the sole's footprint).
def sole_angle(pts):
    n = len(pts); mx = sum(p.x for p in pts) / n; my = sum(p.y for p in pts) / n
    sxx = sum((p.x - mx) ** 2 for p in pts); syy = sum((p.y - my) ** 2 for p in pts)
    sxy = sum((p.x - mx) * (p.y - my) for p in pts)
    a = 0.5 * math.atan2(2 * sxy, sxx - syy)   # major axis
    return math.degrees(a)
for side in ("Left", "Right"):
    sx = 1 if head(side + "Foot").x > 0 else -1
    fb = sole_angle([p for p in body_pts() if p.z < 0.03 and p.x * sx > 0.02])
    fa = sole_angle([p for p in AV if p.z < 0.03 and p.x * sx > 0.02])
    print("FOOT", side, "body sole", round(fb, 1), "boot sole", round(fa, 1))
    turn(side + "Foot", (fa - fb + 90) % 180 - 90, 'Z')  # axes are lines: mod 180
# The pose is done; what follows only changes proportions, and is undone
# after the bind. The armour is skinned in this pose (the source's), so a
# body near it in game wears the armour as it was made.
POSE = {pb.name: pb.matrix_basis.copy() for pb in arm.pose.bones}
for side in ("Left", "Right"):
    sh, el, wr = head(side + "UpperArm"), head(side + "LowerArm"), head(side + "Hand")
    up, fo = (el - sh).length, (wr - el).length
    end, n = sleeve(side)
    k = (end - CUFF) / (up + fo)
    ku = UPPER or k; kf = FORE or k
    print("ARM", side, "upper", round(up, 3), "fore", round(fo, 3), "sleeve", round(end, 3), "verts", n, "k", round(k, 3), "used", ku, kf)
    if SHOULDER:
        out = Vector((1 if sh.x > 0 else -1, 0, 0))
        slide(side + "UpperArm", out * SHOULDER)
    slide(side + "LowerArm", (el - sh).normalized() * up * (ku - 1))
    slide(side + "Hand", (wr - el).normalized() * fo * (kf - 1))
if SPINE:
    nk = head("Neck"); sp = head("Spine")
    slide("Neck", (nk - sp) * (SPINE - 1))

# How the made-to-fit body sits in the armour: skin poking out of it, by
# region (the body vert's heaviest bone).
dg = bpy.context.evaluated_depsgraph_get()
def evaluated_tris(obj):
    e = obj.evaluated_get(bpy.context.evaluated_depsgraph_get()); m = e.to_mesh()
    m.calc_loop_triangles()
    v = [obj.matrix_world @ x.co for x in m.vertices]
    t = [x.vertices[:] for x in m.loop_triangles]
    n = [x.normal.copy() for x in m.vertices]
    e.to_mesh_clear()
    return v, t, n
atree = BVHTree.FromPolygons(AV, [t.vertices[:] for t in (armour.data.calc_loop_triangles() or armour.data.loop_triangles)])
names = {g.index: g.name for g in body.vertex_groups}
def report(tag):
    bv, _, _ = evaluated_tris(body)
    out, near = collections.Counter(), collections.Counter()
    for i, p in enumerate(bv):
        g = body.data.vertices[i].groups
        if not g: continue
        hit, n, _, d = atree.find_nearest(p)
        if hit is None or d > 0.06: continue
        r = names[max(g, key=lambda x: x.weight).group]
        near[r] += 1
        if (p - hit).dot(n) > 0.002: out[r] += 1
    rows = sorted(((out[r] / near[r], r, out[r], near[r]) for r in near if near[r] > 40), reverse=True)
    rows = [r for r in rows if not any(k in r[1] for k in ('Head','Jaw','Hand','Thumb','Index','Middle','Ring','Little','Eye'))]
    print(tag, " ".join("%s:%d/%d" % (r, o, n) for _, r, o, n in rows[:14]))
report("POKE_FIT")

# --- bind, then back to the CC body ----------------------------------------
sd = armour.modifiers.new("fit", 'SURFACE_DEFORM'); sd.target = body; sd.falloff = 4.0
with bpy.context.temp_override(object=armour, active_object=armour):
    bpy.ops.object.surfacedeform_bind(modifier="fit")
vl.update(); armour.evaluated_get(bpy.context.evaluated_depsgraph_get())
assert sd.is_bound, "surface deform did not bind"
for pb in arm.pose.bones:
    pb.matrix_basis = POSE[pb.name]
vl.update()
with bpy.context.temp_override(object=armour, active_object=armour):
    bpy.ops.object.modifier_apply(modifier="fit")
AV = [v.co.copy() for v in armour.data.vertices]
atree = BVHTree.FromPolygons(AV, [t.vertices[:] for t in (armour.data.calc_loop_triangles() or armour.data.loop_triangles)])
report("POKE_POSED")

# --- weights from the posed body: a field smoothed over the skin, read at
# each vertex's nearest skin point. Layers stacked over one spot (a panel
# over the padding) read the same weights there and move together.
pv, tris, _ = evaluated_tris(body)
tree = BVHTree.FromPolygons(pv, tris)
from mathutils.kdtree import KDTree
kd = KDTree(len(pv))
for i, p in enumerate(pv):
    kd.insert(p, i)
kd.balance()
pw = [{g.group: g.weight for g in v.groups} for v in body.data.vertices]
BLUR = 0.03
dst = {g.index: armour.vertex_groups.new(name=g.name) for g in body.vertex_groups}
for v in armour.data.vertices:
    hit, nrm, ti, dist = tree.find_nearest(v.co)
    acc = {}; tot = 0.0
    for _, j, d in kd.find_range(hit, BLUR * 2):
        f = math.exp(-(d / BLUR) ** 2)
        tot += f
        for gi, w in pw[j].items():
            acc[gi] = acc.get(gi, 0.0) + w * f
    if tot == 0.0:
        _, j, _ = kd.find(hit); acc = dict(pw[j]); tot = 1.0
    top4 = sorted(acc.items(), key=lambda x: -x[1])[:4]
    s4 = sum(w for _, w in top4)
    for gi, w in top4:
        if w / s4 > 1e-3:
            dst[gi].add([v.index], w / s4, 'REPLACE')

# --- a small margin off the skin, only where it touches --------------------
_, _, bn = evaluated_tris(body)
pushed = 0
for v in armour.data.vertices:
    hit, nrm, ti, dist = tree.find_nearest(v.co)
    if hit is None or dist > NEAR: continue
    d = (v.co - hit).dot(nrm)
    if d < MARGIN:
        v.co = v.co + nrm * (MARGIN - d); pushed += 1
print("PUSHED", pushed, "of", len(armour.data.vertices))
atree = BVHTree.FromPolygons([v.co.copy() for v in armour.data.vertices], [t.vertices[:] for t in armour.data.loop_triangles])
report("POKE_PUSHED")

# --- layers: a piece of the armour under another (padding under a pauldron)
# is pushed back under it where it pokes through. Pieces are loose parts;
# which is under which is voted along the skin's normal.
import bmesh
LGAP, LREACH = 0.003, 0.03
parent = list(range(len(armour.data.vertices)))
def find(i):
    while parent[i] != i:
        parent[i] = parent[parent[i]]; i = parent[i]
    return i
for e in armour.data.edges:
    a, b = find(e.vertices[0]), find(e.vertices[1])
    if a != b: parent[a] = b
isl = [find(i) for i in range(len(armour.data.vertices))]
armour.data.calc_loop_triangles()
lt = [t.vertices[:] for t in armour.data.loop_triangles]
co = [v.co.copy() for v in armour.data.vertices]
ltree = BVHTree.FromPolygons(co, lt)
print("PIECES", len(set(isl)))
def above(i):
    """[(piece, distance along the skin normal)] first hit of each other piece."""
    p = co[i]
    hit, nrm, _, _ = tree.find_nearest(p)
    h = (p - hit).dot(nrm)
    out = {}
    o = hit + nrm * 0.0005; travelled = 0.0005
    while travelled < h + LREACH:
        r = ltree.ray_cast(o, nrm, h + LREACH - travelled)
        if r[0] is None: break
        q = isl[lt[r[2]][0]]
        if q != isl[i] and q not in out: out[q] = travelled + r[3]
        o = r[0] + nrm * 0.0005; travelled += r[3] + 0.0005
    return hit, nrm, h, out
vote = collections.Counter(); seen = []
for i in range(len(co)):
    hit, nrm, h, out = above(i)
    seen.append((hit, nrm, h, out))
    for q, d in out.items():
        if abs(d - h) < LREACH:
            vote[(isl[i], q)] += 1 if d > h else -1
moved = 0
for i, (hit, nrm, h, out) in enumerate(seen):
    lim = None
    for q, d in out.items():
        if vote[(isl[i], q)] > 0 and d < h + LGAP and h - d < LREACH:
            lim = d if lim is None else min(lim, d)
    if lim is not None and lim - LGAP > MARGIN:
        armour.data.vertices[i].co = hit + nrm * (lim - LGAP); moved += 1
print("LAYERED", moved)

# Unpose: each vertex goes back through the inverse of its blended skin
# matrix, so skinning it in this pose gives exactly the fitted shape.
vl.update()
W = arm.matrix_world
skin = {pb.name: W @ pb.matrix @ pb.bone.matrix_local.inverted() @ W.inverted() for pb in arm.pose.bones}
gname = {g.index: g.name for g in armour.vertex_groups}
for v in armour.data.vertices:
    m = Matrix(((0,0,0,0),(0,0,0,0),(0,0,0,0),(0,0,0,0))); tot = 0.0
    for g in v.groups:
        n = gname[g.group]
        if n in skin and g.weight > 0:
            m = m + skin[n] * g.weight; tot += g.weight
    if tot > 0:
        v.co = (m * (1.0 / tot)).inverted() @ v.co
rest()
armour.parent = arm
armour.matrix_parent_inverse = arm.matrix_world.inverted()
am = armour.modifiers.new("arm", 'ARMATURE'); am.object = arm
bpy.ops.object.select_all(action='DESELECT')
armour.select_set(True); arm.select_set(True)
bpy.ops.export_scene.gltf(filepath=out_glb, use_selection=True, export_format='GLB',
    export_animations=False, export_morph=False, export_yup=True, export_skins=True)
print("EXPORTED", out_glb, len(armour.data.vertices))

s = bpy.context.scene; s.render.engine = 'BLENDER_WORKBENCH'
s.display.shading.color_type = 'OBJECT'; armour.color = (0.8, 0.45, 0.25, 1)
s.render.resolution_x = 1000; s.render.resolution_y = 1000
cam = bpy.data.cameras.new("c"); cam.type = 'ORTHO'; cam.ortho_scale = 2.0
co = bpy.data.objects.new("c", cam); s.collection.objects.link(co); s.camera = co
def shot(tag, loc, rot):
    co.location = loc; co.rotation_euler = rot
    s.render.filepath = preview.replace(".png", "_%s.png" % tag); bpy.ops.render.render(write_still=True)
shot("rest", (0, -10, 0.95), (1.5708, 0, 0))
shot("restside", (10, 0, 0.95), (1.5708, 0, 1.5708))
