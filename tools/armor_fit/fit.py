"""Fit armour pieces (MESHYDIR/p_<piece>/model.glb) to a CC base, skin them from the body, mirror the limb pieces,
save OUTPREFIX.blend and render it.  blender -b <base>.blend --python fit.py -- MESHYDIR OUTPREFIX
See README.md for the technique and what each number means."""
import bpy, bmesh, json, math, sys, os
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

D, OUT = sys.argv[-2], sys.argv[-1]
PREP = json.load(open(os.path.join(D, "prep.json"))) if os.path.exists(os.path.join(D, "prep.json")) else {}
arm = bpy.data.objects["Armature"]
body = bpy.data.objects["CC_Base_Body"]
# Bases built before base.py carried the retired padded layer: drop it and the masks that hid the skin under it.
for n in ("Gambeson", "PaddedPants"):
    if n in bpy.data.objects:
        bpy.data.objects.remove(bpy.data.objects[n])
for m in [m for m in body.modifiers if m.type == "MASK"]:
    body.modifiers.remove(m)
# The FBX armature object carries a -90 X rotation the meshes don't, so its bones sit ~1 m off the body in world
# space: rest looks right, any pose rotates about the wrong points. Put it in the body's frame, children held still.
kids = {o: o.matrix_world.copy() for o in arm.children_recursive}
arm.matrix_world = body.matrix_world.copy(); bpy.context.view_layer.update()
for o, mw in kids.items():
    o.matrix_world = mw
bpy.context.view_layer.update()
dg = bpy.context.evaluated_depsgraph_get()


def world_co(ob):
    e = ob.evaluated_get(dg); me = e.to_mesh()
    co = np.array([ob.matrix_world @ v.co for v in me.vertices]); e.to_mesh_clear(); return co


def group_pts(ob, prefixes, wmin=0.5):
    co = world_co(ob); idx = {g.index for g in ob.vertex_groups if any(g.name.startswith(p) for p in prefixes)}
    ids = [v.index for v in ob.data.vertices if any(g.group in idx and g.weight > wmin for g in v.groups)]
    return co[ids]


# Under-layers the armour must clear: body, gambeson, pants (evaluated, world).
def bvh_of(obs):
    bm = bmesh.new()
    for ob in obs:
        e = ob.evaluated_get(dg); me = e.to_mesh(); me2 = me.copy(); e.to_mesh_clear()
        me2.transform(ob.matrix_world); bm.from_mesh(me2); bpy.data.meshes.remove(me2)
    return BVHTree.FromBMesh(bm)


SHELL = 0.0
UNDER = bvh_of([body])
bodyco = world_co(body)


def box(pts, pad):
    return pts.min(0) - pad, pts.max(0) + pad


def sel(pts, lo, hi):
    m = np.all((pts >= lo) & (pts <= hi), axis=1); return pts[m]


INF = 9.0
# Left forearm axis: elbow -> wrist.
elbow = group_pts(body, ["CC_Base_L_ElbowShareBone"]).mean(0)
fa2 = group_pts(body, ["CC_Base_L_ForearmTwist02"])
wrist = fa2[fa2[:, 0] > fa2[:, 0].max() - 0.02].mean(0)  # the forearm's hand end
knee = group_pts(body, ["CC_Base_L_KneeShareBone"]).mean(0)
upper_arm = group_pts(body, ["CC_Base_L_Upperarm"])  # the bone and its twists

# Body landmarks from the rig, so one set of numbers fits any CC body. The constants were tuned on the CC male
# (hip 0.997, neck 1.548, upper arm x 0.185, knee 0.524); each box edge is an offset from a bone, scaled by the
# body's own torso / shoulder / leg proportion against that male.
def head(n):
    return np.array(arm.matrix_world @ arm.pose.bones[n].head)


HIP, NECK, UA, CALF = head("CC_Base_Hip")[2], head("CC_Base_NeckTwist01")[2], head("CC_Base_L_Upperarm")[0], head("CC_Base_L_Calf")[2]
ST = (NECK - HIP) / (1.548 - 0.997)   # torso height
SX = UA / 0.185                        # shoulder width
SL = CALF / 0.524                      # shin length
print("LANDMARKS hip %.3f neck %.3f ua %.3f calf %.3f  ST %.3f SX %.3f SL %.3f" % (HIP, NECK, UA, CALF, ST, SX, SL))
torso = sel(bodyco, (-0.2 * SX, -INF, HIP + 0.023 * ST), (0.2 * SX, INF, NECK + 0.012 * ST))
hips = sel(bodyco, (-INF, -INF, HIP - 0.097 * ST), (INF, INF, HIP + 0.063 * ST))
WAIST = HIP - 0.047 * ST               # the skirt starts hanging below here
PIECES = {
    # name: (target box lo, hi) in world, or a limb axis
    "cuirass": dict(lo=(-0.31 * SX, torso[:, 1].min() - 0.02, HIP + 0.043 * ST), hi=(0.31 * SX, torso[:, 1].max() + 0.02, NECK + 0.032 * ST)),
    "belt": dict(lo=(hips[:, 0].min() - 0.015, hips[:, 1].min() - 0.015, HIP - 0.297 * SL), hi=(hips[:, 0].max() + 0.015, hips[:, 1].max() + 0.015, HIP + 0.103 * ST)),
    "greave": dict(lo=None, axis=(np.array([knee[0], 0.0, 0.07 * SL]), knee + np.array([0, 0, 0.05 * SL])), part="CC_Base_L_Calf", mirror=True),
    "bracer": dict(lo=None, axis=(elbow + 0.15 * (wrist - elbow), wrist + 0.03 * (wrist - elbow)), part="CC_Base_L_Forearm", mirror=True, top_at_p0=True),
    # Shoulder to just past the elbow. Its girth is measured on the upper arm's own skin: around the shoulder the
    # torso is within reach of the axis and would count as arm.
    "upsleeve": dict(lo=None, axis=(head("CC_Base_L_Upperarm") + 0.05 * (elbow - head("CC_Base_L_Upperarm")), elbow + 0.04 * (elbow - head("CC_Base_L_Upperarm"))),
                     part="CC_Base_L_Upperarm", mirror=True, top_at_p0=True, girth_pts=upper_arm),
}


def import_piece(name):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(D, "p_" + name, "model.glb"))
    new = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new if o.type == "MESH"]
    for o in new:
        if o.type != "MESH":
            continue
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    mw = ob.matrix_world.copy(); ob.parent = None; ob.matrix_world = mw
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for o in new:
        if o.name in bpy.data.objects and o != ob:
            bpy.data.objects.remove(o)
    ob.name = "Armor_" + name
    # Per-generation fixes from MESHYDIR/prep.json, e.g. {"bracer": {"up": "Y"}, "greave": {"cut_below": 0.13}}:
    # "up" names the piece's long axis when Meshy laid it down (fit_limb expects Z); "cut_below" drops the bottom
    # fraction of its height (a sock foot on a shin wrap).
    prep = PREP.get(name, {})
    if prep.get("up") in ("X", "Y"):
        co = verts(ob)
        co = co[:, [1, 2, 0]] if prep["up"] == "X" else co[:, [0, 2, 1]] * np.array([1, -1, 1])
        set_verts(ob, co)
    if prep.get("cut_below"):
        z = verts(ob)[:, 2]; cut = z.min() + prep["cut_below"] * (z.max() - z.min())
        bm = bmesh.new(); bm.from_mesh(ob.data)
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < cut], context="VERTS")
        bm.to_mesh(ob.data); bm.free()
    if prep.get("albedo"):
        # Scale the base colour texture so its mean (sRGB) is this value. Meshy's "off-white" comes out near
        # 0.7, which the per-unit character light rig (tuned on skin) blows out to white in game.
        for slot in ob.material_slots:
            bsdf = next(n for n in slot.material.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
            img = next(l.from_node.image for l in bsdf.inputs["Base Color"].links if l.from_node.type == "TEX_IMAGE")
            px = np.empty(len(img.pixels), np.float32); img.pixels.foreach_get(px)
            rgb = px.reshape(-1, 4)[:, :3]
            k = prep["albedo"] / rgb.mean()
            rgb *= k; px.reshape(-1, 4)[:, :3] = rgb.clip(0, 1)
            img.pixels.foreach_set(px); img.pack()
            print("ALBEDO", name, img.name, "x%.2f" % k)
    return ob


def verts(ob):
    return np.array([v.co[:] for v in ob.data.vertices])


def set_verts(ob, co):
    ob.data.vertices.foreach_set("co", co.ravel()); ob.data.update()


def fit_box(ob, lo, hi):
    co = verts(ob); a, b = co.min(0), co.max(0)
    lo, hi = np.array(lo), np.array(hi)
    set_verts(ob, lo + (co - a) / (b - a) * (hi - lo))


def fit_limb(ob, p0, p1, part, top_at_p0=False, girth_pts=None):
    co = verts(ob)
    c = co.mean(0)
    # Meshy pieces come out upright: the long axis is Z. (PCA picks the diameter on a short, wide bracer.)
    ax = np.array([0.0, 0.0, -1.0 if top_at_p0 else 1.0])
    # Rotate the piece's long axis onto the limb (top = p1 end for greave: knee; bracer: elbow end is p0).
    d = Vector(p1 - p0).normalized()
    R = Vector(ax).rotation_difference(d).to_matrix()
    R = np.array(R)
    co = (co - c) @ R.T
    t = co @ np.array(d)
    # Length to the limb span, girth to the limb's under-layer radius.
    L = np.linalg.norm(p1 - p0)
    co = co * (L / (t.max() - t.min()))
    t = co @ np.array(d)
    co = co - np.outer(t.min(), np.array(d)) + p0  # start at p0
    # girth: scale radial part to the under-layer radius around the axis + margin
    src = bodyco if girth_pts is None else girth_pts
    rel = src - p0; tt = rel @ np.array(d)
    near = (tt > 0) & (tt < L)
    radial = rel[near] - np.outer(tt[near], np.array(d))
    rmask = np.linalg.norm(radial, axis=1) < 0.09
    target_r = np.percentile(np.linalg.norm(radial[rmask], axis=1), 90) + 0.012
    rel = co - p0; tt = rel @ np.array(d); rad = rel - np.outer(tt, np.array(d))
    cur_r = np.percentile(np.linalg.norm(rad, axis=1), 90)
    axis_c = radial[rmask].mean(0)
    co = p0 + np.outer(tt, np.array(d)) + axis_c + rad * (target_r / cur_r)
    set_verts(ob, co)


def push_out(ob, off=None, iters=4):
    """Move vertices that sit inside (or within off of) the under-layers out along the surface normal,
    smoothing the displacement over the mesh so the shell bends instead of crumpling."""
    off = 0.008 if off is None else off
    bm = bmesh.new(); bm.from_mesh(ob.data); bm.verts.ensure_lookup_table()
    nbr = [[e.other_vert(v).index for e in v.link_edges] for v in bm.verts]; bm.free()
    for _ in range(iters):
        co = verts(ob); disp = np.zeros_like(co)
        for i, p in enumerate(co):
            loc, n, _, dist = UNDER.find_nearest(Vector(p), 0.08)
            if loc is None:
                continue
            s = (Vector(p) - loc).dot(n)
            if s < off:
                disp[i] = np.array(n) * (off - s)
        for _ in range(6):
            disp = 0.5 * disp + 0.5 * np.array([disp[nb].mean(0) if nb else d for nb, d in zip(nbr, disp)])
        set_verts(ob, co + disp * 1.3)


def mesh_nbrs(ob):
    """Edge adjacency as (rows, cols) for numpy averaging."""
    n = len(ob.data.edges); e = np.zeros(n * 2, dtype=np.int64); ob.data.edges.foreach_get("vertices", e); e = e.reshape(-1, 2)
    return np.concatenate([e[:, 0], e[:, 1]]), np.concatenate([e[:, 1], e[:, 0]])


def smooth_field(f, rows, cols, nv, iters):
    deg = np.bincount(rows, minlength=nv).astype(float); deg[deg == 0] = 1
    for _ in range(iters):
        acc = np.zeros_like(f); np.add.at(acc, rows, f[cols]); f = 0.5 * f + 0.5 * acc / deg[:, None]
    return f


def local_min(co, val, cell):
    """Min of val over a ~1.5-cell spatial neighbourhood (voxel grid, 27 cells). Spatial, not graph: a strap lying on
    the leather sees the leather's inner face, so it moves with the shell instead of being pulled through it."""
    k = np.floor(co / cell).astype(np.int64); k -= k.min(0)
    dims = k.max(0) + 3; key = lambda kk: (kk[:, 0] * dims[1] + kk[:, 1]) * dims[2] + kk[:, 2]
    kid = key(k + 1); uk, inv = np.unique(kid, return_inverse=True)
    cmin = np.full(len(uk), np.inf); np.minimum.at(cmin, inv, val)
    out = np.full(len(co), np.inf)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                q = key(k + 1 + np.array([dx, dy, dz])); j = np.searchsorted(uk, q); j[j >= len(uk)] = 0
                hit = uk[j] == q; out[hit] = np.minimum(out[hit], cmin[j[hit]])
    return out


def side_bvh(sign):
    """Body skin on one side of the midline only: a limb piece must conform to its own limb, never the other one."""
    co = bodyco; keep = co[:, 0] * sign > 0.01
    faces = [list(p.vertices) for p in body.data.polygons if all(keep[i] for i in p.vertices)]
    return BVHTree.FromPolygons([Vector(c) for c in co], faces)


def conform(ob, gap, rounds=6, cell=0.015, under=None):
    under = under or UNDER
    """Detail-preserving conform: every vertex moves along the skin normal by (local inner clearance - gap), where the
    local inner clearance is the nearest-to-skin distance of the shell around it. The inner face lands `gap` off the
    skin; the outer face, straps and buckles ride along at their own height. gap(co) may vary per vertex (skirt hem)."""
    rows, cols = mesh_nbrs(ob); nv = len(ob.data.vertices)
    for r in range(rounds):
        co = verts(ob); d = np.empty(nv); nrm = np.empty((nv, 3))
        for i, p in enumerate(co):
            loc, n, _, _ = under.find_nearest(Vector(p))
            v = Vector(p) - loc; s = v.dot(n)
            d[i] = s; nrm[i] = n
        g = gap(co) if callable(gap) else np.full(nv, gap)
        clear = local_min(co, d - g, cell)  # how far this patch's inner face is beyond its target gap (neg = too close)
        disp = -nrm * clear[:, None]
        disp = smooth_field(disp, rows, cols, nv, 8)
        set_verts(ob, co + disp * (0.7 if r < rounds - 1 else 1.0))
        print("CONFORM", ob.name, r, "clear p50/p95 %.4f %.4f" % tuple(np.percentile(clear, [50, 95])), "inside", int((d < 0).sum()), flush=True)


def hang(ob, top, bins=72, dz=0.01):
    """A skirt falls straight from the widest point above it; cloth cannot tuck back in under the seat. Below top,
    around the body's vertical axis, the inner surface's radius in each angle column is raised to the most it reached
    higher up. Each (angle, height) cell moves as one, so straps and quilting ride with the shell."""
    co = verts(ob); c = hips[:, :2].mean(0)
    rel = co[:, :2] - c; r = np.linalg.norm(rel, axis=1); a = np.arctan2(rel[:, 1], rel[:, 0])
    ai = ((a + np.pi) / (2 * np.pi) * bins).astype(int) % bins
    zi = np.floor((top - co[:, 2]) / dz).astype(int)  # 0 at top, growing downward
    below = zi >= 0
    nz = zi[below].max() + 1 if below.any() else 0
    inner = np.full((bins, nz), np.inf)
    np.minimum.at(inner, (ai[below], zi[below]), r[below])
    # Fill empty cells from above so the envelope is continuous, then take the running max downward.
    env = np.copy(inner)
    for k in range(bins):
        last = 0.0
        for j in range(nz):
            last = max(last, env[k, j] if np.isfinite(env[k, j]) else last)
            env[k, j] = last
    push = np.where(np.isfinite(inner), env - inner, 0.0)
    disp = np.zeros_like(co)
    idx = np.where(below)[0]
    dr = push[ai[idx], zi[idx]]
    disp[idx, :2] = (rel[idx] / np.maximum(r[idx], 1e-6)[:, None]) * dr[:, None]
    rows, cols = mesh_nbrs(ob)
    disp = smooth_field(disp, rows, cols, len(co), 4)
    set_verts(ob, co + disp)
    print("HANG", ob.name, "moved", int((dr > 0.002).sum()), "max %.3f" % (dr.max() if len(dr) else 0))


def skin(ob, part=None):
    ob.vertex_groups.clear()
    for g in body.vertex_groups:
        if not g.name.startswith("Mask_"):
            ob.vertex_groups.new(name=g.name)
    m = ob.modifiers.new("wt", "DATA_TRANSFER")
    m.object = body; m.use_vert_data = True; m.data_types_verts = {"VGROUP_WEIGHTS"}
    m.vert_mapping = "POLYINTERP_NEAREST"; m.layers_vgroup_select_src = "ALL"; m.layers_vgroup_select_dst = "NAME"
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=m.name)
    if part:  # a limb piece takes weights only from its own side; nearest-surface lookups near the midline pick the other leg
        bad = [g for g in ob.vertex_groups if "_R_" in g.name]
        for v in ob.data.vertices:
            for g in v.groups:
                if ob.vertex_groups[g.group] in bad:
                    g.weight = 0.0
        for g in bad:
            ob.vertex_groups.remove(g)
        # Vertices whose nearest skin was the other limb are now empty: they follow the nearest weighted vertex of this piece.
        from mathutils.kdtree import KDTree
        ws = [sum(g.weight for g in v.groups) for v in ob.data.vertices]
        good = [v for v, s in zip(ob.data.vertices, ws) if s > 0.5]
        kd = KDTree(len(good))
        for i, v in enumerate(good):
            kd.insert(v.co, i)
        kd.balance()
        empty = [v for v, s in zip(ob.data.vertices, ws) if s <= 0.5]
        for v in empty:
            src = good[kd.find(v.co)[1]]
            for g in src.groups:
                ob.vertex_groups[g.group].add([v.index], g.weight, "REPLACE")
        print("REFILL", ob.name, len(empty))
        for v in ob.data.vertices:
            s = sum(g.weight for g in v.groups)
            if s > 0:
                for g in v.groups:
                    g.weight /= s
    a = ob.modifiers.new("Armature", "ARMATURE"); a.object = arm


def mirror(ob):
    m = ob.copy(); m.data = ob.data.copy(); bpy.context.collection.objects.link(m)
    co = verts(m); co[:, 0] *= -1; set_verts(m, co)
    bm = bmesh.new(); bm.from_mesh(m.data); bmesh.ops.reverse_faces(bm, faces=bm.faces); bm.to_mesh(m.data); bm.free()
    # Both sides' groups exist, so a direct rename collides (Blender makes "….001" and the weights drive nothing).
    # Park every name first, then give each its swapped name.
    swapped = {g.name: g.name.replace("_L_", "_X_").replace("_R_", "_L_").replace("_X_", "_R_") for g in m.vertex_groups}
    for i, g in enumerate(m.vertex_groups):
        g.name = "__tmp%d" % i
    for g, new in zip(m.vertex_groups, swapped.values()):
        g.name = new
    assert [g.name for g in m.vertex_groups] == list(swapped.values()) and not any("_L_" in g.name for g in m.vertex_groups)
    m.name = ob.name.replace("_L", "") + "_R"
    return m


# Inner-face clearance off the skin. The skirt hugs the waist and hangs free toward the hem.
GAP = {"cuirass": 0.006, "greave": 0.005, "bracer": 0.004, "upsleeve": 0.005,
       "belt": lambda co: 0.006 + np.clip((WAIST - co[:, 2]) / (0.25 * SL), 0, 1) * 0.03}
made = []
for name, cfg in PIECES.items():
    if not os.path.exists(os.path.join(D, "p_" + name, "model.glb")):
        print("SKIP", name); continue
    ob = import_piece(name)
    if cfg.get("lo") is not None:
        fit_box(ob, cfg["lo"], cfg["hi"])
    else:
        fit_limb(ob, *cfg["axis"], cfg["part"], cfg.get("top_at_p0", False), cfg.get("girth_pts")); ob.name += "_L"
    conform(ob, GAP[name], under=side_bvh(np.sign(verts(ob)[:, 0].mean())) if cfg.get("part") else None)
    if name == "belt":
        hang(ob, WAIST)
    push_out(ob, off=0.002, iters=2)  # last-mm safety for anything the smoothing left inside
    skin(ob, cfg.get("part"))
    made.append(ob)
    if cfg.get("mirror"):
        made.append(mirror(ob))
    print("FIT", ob.name, len(ob.data.vertices), tuple(round(x, 3) for x in ob.dimensions))

bpy.ops.wm.save_as_mainfile(filepath=OUT + ".blend")
sc = bpy.context.scene; cam = sc.camera
print("ENGINE", sc.render.engine, "transparent", sc.render.film_transparent, "lights", [o.name for o in bpy.data.objects if o.type == "LIGHT"], "world", sc.world)
sc.render.resolution_x, sc.render.resolution_y = 900, 1100


def shoot(tag, ang, el, c=(0, 0, 0.95), scale=2.0):
    c = Vector(c); t = math.radians(ang); e = math.radians(el)
    cam.location = c + Vector((math.sin(t) * math.cos(e), -math.cos(t) * math.cos(e), math.sin(e))) * 4
    cam.rotation_euler = (c - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.type = "ORTHO"; cam.data.ortho_scale = scale
    sc.render.filepath = OUT + "_" + tag + ".png"; bpy.ops.render.render(write_still=True)


print("FITDONE")
