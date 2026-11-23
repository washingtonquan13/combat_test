"""Fit pre-made modular armour to a target character body and armature, skin it, and check it for Godot 4.

The armour pieces live in one collection (soft cloth/leather and rigid plates mixed). The script never
shrinkwraps the armour itself, because that flattens bevels and plate thickness. It deforms the armour
non-destructively instead:

  Case A (SOURCE_BODY_NAME set: the body the armour was modelled on)
      A proxy cage made from the source body, with the armour bound to it by Surface Deform. The cage
      is then morphed onto the target body: a shape key when both bodies share topology, otherwise a
      Shrinkwrap. The armour follows the cage with its thickness kept.
  Case B (no source body)
      The armour's bounding box is aligned to the target body. A proxy cage is built from the target
      body (decimated, then shrinkwrapped back onto it SURFACE_OFFSET out). A per-piece Lattice is then
      solved so that only the vertices sitting inside that cage move out to it. The move is low
      frequency, so outer bevels are carried along rather than crushed.

  Both cases then run the same lattice pass, to clear any clipping left after the cage fit.

The later stages are:
  * mask the body skin hidden under each piece (Mask_<piece> vertex group plus an inverted Mask modifier);
  * parent the pieces to the armature, transfer vertex weights from the body (Data Transfer, Nearest
    Face Interpolated) and bake them;
  * make rigid plates rigid, limit each vertex to 4 bone influences and normalise;
  * print a Godot-readiness report.

Run it from Blender's Text Editor after setting the config below. Headless runs can override any
config name with a JSON object after `--`:
    blender -b scene.blend -P fit_armor.py -- '{"ARMOR_COLLECTION_NAME": "Armor", "APPLY_DEFORM_MODIFIERS": true}'

Generated data is named with a Fit prefix: the FitCages collection, FitCage_* objects, FitLattice_*
lattices, Fit* modifiers and Mask_* groups. Re-running the script removes it all first, so the fit can
be repeated after config tweaks.
Written for the Blender 4.x / 5.x Python API.
"""
import bpy
import json
import math
import os
import sys
import numpy as np
from mathutils import Vector, Matrix, Quaternion
from mathutils.bvhtree import BVHTree

# =============================================================================================== config
SOURCE_BODY_NAME = ""                 # optional: the body the armour was modelled for (Case A)
TARGET_BODY_NAME = "CC_Base_Body"     # the character's skin mesh
TARGET_ARMATURE_NAME = "Armature"     # the character's rig
ARMOR_COLLECTION_NAME = "Armor"       # every mesh in here (nested collections included) is an armour piece
SURFACE_OFFSET = 0.005                # metres kept between the skin and the armour

APPLY_DEFORM_MODIFIERS = False        # True bakes the Surface Deform and Lattice into the pieces;
                                      # False leaves them live, so you can edit the cage or lattice first
APPLY_TRANSFORMS = True               # apply rotation and scale (Ctrl+A) to the pieces, body and rig
RESET_POSE_TO_REST = True             # clear the rig's action and pose: fitting and binding need rest pose

# Case B alignment. The armour's bounding box (all pieces together) is scaled uniformly so its height
# spans ALIGN_Z_RANGE of the target body's height (0 = soles, 1 = top of the head). It is then centred
# on the body in X and Y. None skips alignment, for armour that is already in place.
ALIGN_Z_RANGE = None                  # e.g. (0.0, 0.864): boots on the floor, collar at the neck
ALIGN_OFFSET = (0.0, 0.0, 0.0)        # extra world offset after alignment

# Case B landmark alignment (pose match). When the armour was modelled on a body in a different pose (arms
# lower, legs wider), a box alignment leaves boots and sleeves beside the limbs. With POSE_MATCH the listed
# bones are rotated about their heads, parents first, until the body's skin matches the armour's (rotation-only
# ICP). That posed body becomes the Case A source cage, morphing back to the rest pose with the armour bound.
POSE_MATCH = True
POSE_MATCH_BONES = ["CC_Base_L_Upperarm", "CC_Base_R_Upperarm", "CC_Base_L_Thigh", "CC_Base_R_Thigh",
                    "CC_Base_L_Forearm", "CC_Base_R_Forearm", "CC_Base_L_Calf", "CC_Base_R_Calf",
                    "CC_Base_L_Foot", "CC_Base_R_Foot"]
POSE_MATCH_RADIUS = 0.12              # armour vertices further than this from the skin are ignored
POSE_MATCH_ITERATIONS = 8
POSE_MATCH_MAX_DEG = 35.0             # safety cap on each bone's total rotation
POSE_MATCH_ENCLOSED = ("Hand", "Thumb", "Index", "Mid", "Ring", "Pinky")   # bones matched by enclosure
                                      # instead (hand, finger joints): the skin of the bone's own segment
                                      # swings until it sits inside the skinned piece (glove). Radial
                                      # coverage cannot see a curled glove finger around a straight finger
POSE_MATCH_ENCLOSED_CELL = 0.004      # grid cell (m) of the enclosure field around a hand or finger
POSE_MATCH_ENCLOSED_MAX_DEG = 70.0    # a glove's finger joint may be curled well past a limb's swing
POSE_MATCH_STIFFNESS = 1e-4          # m^2 per rad^2: prefer the smaller swing when the armour is loose either way

# Proxy cage
CAGE_DECIMATE_RATIO = 0.35            # cage density relative to the body (only used without shared topology)
CAGE_EXCLUDE = ("Finger", "Thumb", "Index", "Mid", "Ring", "Pinky", "Toe")  # bones whose skin stays out of
                                      # the proxy cage: fingers and toes attract wrong Surface Deform binds
CAGE_SEARCH = 0.25                    # how far (m) an armour vertex looks for the cage surface

# Lattice pass
LATTICE_CELL = 0.04                   # target lattice cell size in metres (smaller = more local push)
LATTICE_MAX_RES = 32                  # cap on points per axis
LATTICE_ITERATIONS = 16
LATTICE_TOLERANCE = 0.0005            # stop once no vertex is more than this inside its collider

# Layering: pieces fit in ascending layer order, and each layer also clears the pieces fitted before it
# (a breastplate over a tunic, a belt over both). Unlisted pieces are layer 0 and clear only the body.
PIECE_LAYERS = {}                     # {"Cloth": 0, "Chest": 1, "Belt": 2}
LAYER_GAP = 0.002                     # gap kept between layers
LAYER_SEARCH = 0.03                   # an inner layer only pushes outer vertices that are this close

# Body masking
MASK_PROXIMITY = 0.002                # skin closer than this to a piece is hidden
MASK_RAY_DISTANCE = 0.08              # skin is hidden when every ray of the cone hits the piece within this
MASK_RAY_CONE_DEG = 25.0              # half-angle of the 4 extra rays around the skin normal
MASK_ERODE_RINGS = 1                  # keep this many rings of skin at the mask border (no see-through gaps)

# Weights
WEIGHT_MAPPING = "POLYINTERP_NEAREST" # Data Transfer vertex mapping: Nearest Face Interpolated
RIGID_BONE_THRESHOLD = 0.85           # a piece or plate this dominated by one bone is locked to that bone
LOCK_RIGID_PIECES = True              # apply the threshold above
RIGID_ISLANDS = True                  # also test each loose part of a piece (plates inside one object)
RIGID_ISLAND_MAX_DIM = 0.25           # loose parts smaller than this (m) count as plates
RIGID_ISLAND_AVERAGE = True           # plates below the threshold get one averaged weight set (no bending)
RIGID_PIECES = set()                  # piece names always locked to their dominant bone
SOFT_PIECES = set()                   # cloth/leather pieces: fitted by Surface Deform (may bend) and never
                                      # weight-locked; every other piece is cut into rigid parts (below)
SHELL_PIECES = set()                  # stiff pieces that must keep their shape (boots, gauntlets): each side
                                      # (left/right) moves as one solid with clamped per-axis scale, never
                                      # through the cage; skinned smoothly like soft pieces
SKINNED_PIECES = set()                # pieces that bend with the body (gloves): carried from the matched pose
                                      # to rest by the body's own bone skinning, so each finger follows her
                                      # finger and nothing goes through the cage; then the lattice push-out
SPLIT_PARTS = {}                      # {"Cloth": {"Gloves": "Hand"}}: loose parts of a piece that sit on a
                                      # bone whose name contains the keyword become their own piece (gloves
                                      # modelled into the shirt mesh); list the new name in SHELL_PIECES or
                                      # SKINNED_PIECES
SPLIT_SHARE = 0.25                    # share of a part's vertices that must sit on such a bone
SKIN_NEIGHBOURS = 6                   # skin vertices blended for each skinned-piece vertex's weights
SKIN_MATCH_DIST = 0.015               # a skinned-piece vertex trusts a skin vertex this near (m) ...
SKIN_MATCH_ANGLE = 35.0               # ... that faces the same way (deg). The side of one glove finger is
                                      # nearest the next finger's skin, which faces it: those are not matches.
                                      # Unmatched vertices get their weights spread to them along the piece's
                                      # own surface (weight inpainting), so a glove finger is weighted as one
SKIN_FINGER_REACH = 1.3               # a glove finger runs from its tip to this many times the distance
                                      # to the webbing: the finger and a collar of palm around its knuckle
SKIN_WRAP_ITERATIONS = 6              # skinned pieces are shrinkwrapped onto the skin of the enclosure-matched
                                      # bones (hand, fingers); the cuff up the forearm keeps its own shape
SKIN_WRAP_PROJECT = 0.006             # farther than this above the skin, wrap along the piece's own normal
SKIN_PUSH_ITERATIONS = 60             # skinned pieces: passes of the per-vertex push off the skin
SKIN_PUSH_RELAX = 3                   # unpinned smoothing passes of each push, against creases
SKIN_PUSH_SPREAD = 8                  # edge rings a push fades out over, so no vertex pops out alone
SKIN_SMOOTH = 2                      # passes smoothing those weights along the piece's own edges, so the
                                      # webbing between two glove fingers blends instead of tearing
SHELL_SCALE_RANGE = (0.85, 1.15)      # how far a shell may shrink/stretch per axis to fit
SHELL_SNUG = 0.1                      # pull toward the skin where the shell is roomy (0 = only stop poke-through)
SHELL_CELL = 0.012                    # grid cell (m) of the shell's enclosure field
SHELL_TOP_MARGIN = 0.03               # skin this close below the shell's opening is not required to be inside
SHELL_LATTICE_CELL = 0.10             # coarse lattice for the shell's leftover push-out (broad, no dents)

# Cutting rigid pieces. Each loose part of a rigid piece is assigned to one bone (the bone owning most of
# the skin under it), and the piece is split into one object per bone: <piece>_<bone>. Each object is
# moved rigidly by its bone's pose-match transform, pushed out of the skin rigidly, and skinned 100% to
# that bone, so plates never bend or splay. Bones whose name contains a CUT_SKIP word are folded into
# their parent (twist, share and breast helpers into the limb or spine bone, fingers into the hand).
CUT_RIGID_PIECES = True               # False: rigid pieces stay whole and go through the lattice like cloth
FINGER_KEYS = ("Thumb", "Index", "Mid", "Ring", "Pinky")   # finger bones (shell fits ignore their skin)
CUT_SKIP = ("Twist", "Share", "Breast", "Toe", "Thumb", "Index", "Mid", "Ring", "Pinky")
CUT_SMALL_PART = 0.035                # loose parts smaller than this (m: buckles, rivets) follow the
                                      # nearest larger part instead of voting on their own
RIGID_PUSH_ITERATIONS = 24            # rigid push-out steps per cut part
RIGID_SCALE_RANGE = (0.92, 1.25)       # how far a cut plate may shrink/stretch per axis to clear the body
MAX_INFLUENCES = 4                    # Godot 4 skins with 4 bones per vertex by default

FIT_COLLECTION = "FitCages"


# ============================================================================================ utilities
def log(*a):
    print("[fit_armor]", *a)


def ctx(ob, more=()):
    """Context override that makes `ob` the active, selected object for bpy.ops calls."""
    sel = [ob, *more]
    return bpy.context.temp_override(object=ob, active_object=ob, selected_objects=sel,
                                     selected_editable_objects=sel)


def update():
    bpy.context.view_layer.update()


def fit_collection():
    c = bpy.data.collections.get(FIT_COLLECTION)
    if c is None:
        c = bpy.data.collections.new(FIT_COLLECTION)
        bpy.context.scene.collection.children.link(c)
    return c


def eval_world(ob):
    """World-space vertices, vertex normals and polygons of `ob` as evaluated now (modifiers on)."""
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    n = len(me.vertices)
    co = np.empty(n * 3, np.float64); me.vertices.foreach_get("co", co)
    no = np.empty(n * 3, np.float64); me.vertices.foreach_get("normal", no)
    M = np.array(ev.matrix_world)
    R = M[:3, :3]
    co = co.reshape(-1, 3) @ R.T + M[:3, 3]
    no = no.reshape(-1, 3) @ np.linalg.inv(R)          # inverse-transpose, applied row-wise
    no /= np.linalg.norm(no, axis=1, keepdims=True) + 1e-12
    polys = [tuple(p.vertices) for p in me.polygons]
    ev.to_mesh_clear()
    return co, no, polys


def bvh_of(co, polys):
    return BVHTree.FromPolygons([Vector(v) for v in co], polys, all_triangles=False, epsilon=0.0)


def with_modifiers_off(objs, types):
    """Context manager: hide the given modifier types on `objs` from the depsgraph while inside."""
    class _Off:
        def __enter__(self):
            self.saved = []
            for o in objs:
                for m in o.modifiers:
                    if m.type in types and m.show_viewport:
                        self.saved.append(m); m.show_viewport = False
            update()
        def __exit__(self, *exc):
            for m in self.saved: m.show_viewport = True
            update()
    return _Off()


def islands(n, polys):
    """Loose-part label per vertex (union-find over face edges)."""
    parent = list(range(n))
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a
    for p in polys:
        r0 = find(p[0])
        for v in p[1:]:
            r = find(v)
            if r != r0: parent[r] = r0
    return np.array([find(i) for i in range(n)])


# =================================================================================== 1. validation
def get_obj(name, typ):
    ob = bpy.data.objects.get(name)
    if ob is None:
        raise RuntimeError(f"object '{name}' not found")
    if ob.type != typ:
        raise RuntimeError(f"object '{name}' is {ob.type}, expected {typ}")
    return ob


def validate_scene():
    """Look up every configured object and the armour pieces; fail early with a clear message."""
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    body = get_obj(TARGET_BODY_NAME, "MESH")
    arm = get_obj(TARGET_ARMATURE_NAME, "ARMATURE")
    src = get_obj(SOURCE_BODY_NAME, "MESH") if SOURCE_BODY_NAME else None
    coll = bpy.data.collections.get(ARMOR_COLLECTION_NAME)
    if coll is None:
        raise RuntimeError(f"collection '{ARMOR_COLLECTION_NAME}' not found")
    pieces = sorted((o for o in coll.all_objects if o.type == "MESH"), key=lambda o: o.name)
    if not pieces:
        raise RuntimeError(f"collection '{ARMOR_COLLECTION_NAME}' has no meshes")
    for p in pieces:
        if p in (body, src):
            raise RuntimeError(f"'{p.name}' is a body, not an armour piece")
    log(f"target body {body.name}, rig {arm.name}, source {src.name if src else '-'}, "
        f"{len(pieces)} pieces: {', '.join(p.name for p in pieces)}")
    return body, arm, src, pieces


def cleanup(body, pieces):
    """Remove everything a previous run generated, so re-running starts clean."""
    for o in [body, *pieces]:
        for m in list(o.modifiers):
            if m.name.startswith("Fit") or m.name.startswith("Mask_") or m.name == "WeightTransfer":
                o.modifiers.remove(m)
    for g in list(body.vertex_groups):
        if g.name.startswith("Mask_"):
            body.vertex_groups.remove(g)
    c = bpy.data.collections.get(FIT_COLLECTION)
    if c:
        for o in list(c.objects):
            data = o.data
            bpy.data.objects.remove(o)
            if data is not None and data.users == 0:
                (bpy.data.lattices if isinstance(data, bpy.types.Lattice) else bpy.data.meshes).remove(data)
    update()


def reset_pose(arm):
    """Fitting and weight transfer assume the rest pose. Imported rigs often carry an action (a T-pose)."""
    if arm.animation_data:
        arm.animation_data.action = None
        for t in arm.animation_data.nla_tracks:
            t.mute = True
    for pb in arm.pose.bones:
        pb.location = (0, 0, 0); pb.scale = (1, 1, 1)
        pb.rotation_quaternion = (1, 0, 0, 0); pb.rotation_euler = (0, 0, 0); pb.rotation_axis_angle = (0, 0, 1, 0)
    update()


def apply_transforms(body, arm, src, pieces):
    """Ctrl+A. Pieces get location, rotation and scale applied, so all origins sit at the world origin.
    The rig and bodies get rotation and scale only, keeping their origins. Children are kept in place."""
    def make_single_user(o):
        if o.data is not None and o.data.users > 1:
            o.data = o.data.copy()
    for p in pieces:
        if p.parent is not None:                      # leave the armour's original rig, if it had one
            mw = p.matrix_world.copy(); p.parent = None; p.matrix_world = mw
        for m in list(p.modifiers):
            if m.type == "ARMATURE":
                p.modifiers.remove(m)
        make_single_user(p)
        with ctx(p):
            bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for o in [arm, body] + ([src] if src else []):
        make_single_user(o)
        with ctx(o):
            bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    update()


# ========================================================================================= 2. fitting
def align_armor(body, pieces):
    """Case B: uniform scale and translation of all pieces together, onto the body region."""
    if ALIGN_Z_RANGE is None:
        return
    bco, _, _ = eval_world(body)
    aco = np.vstack([eval_world(p)[0] for p in pieces])
    blo, bhi = bco.min(0), bco.max(0)
    alo, ahi = aco.min(0), aco.max(0)
    tz0 = blo[2] + ALIGN_Z_RANGE[0] * (bhi[2] - blo[2])
    tz1 = blo[2] + ALIGN_Z_RANGE[1] * (bhi[2] - blo[2])
    s = (tz1 - tz0) / (ahi[2] - alo[2])
    band = bco[(bco[:, 2] >= tz0) & (bco[:, 2] <= tz1)]
    bc = 0.5 * (band.min(0) + band.max(0))
    ac = 0.5 * (alo + ahi)
    anchor = Vector((ac[0], ac[1], alo[2]))
    target = Vector((bc[0], bc[1], tz0)) + Vector(ALIGN_OFFSET)
    M = Matrix.Translation(target) @ Matrix.Scale(s, 4) @ Matrix.Translation(-anchor)
    for p in pieces:
        p.matrix_world = M @ p.matrix_world
        with ctx(p):
            bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    update()
    log(f"aligned armour: scale {s:.4f}, z {tz0:.3f}..{tz1:.3f}")


def _new_mesh_object(name, src_obj):
    """A world-space copy of `src_obj` as evaluated now, in the FitCages collection."""
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(src_obj.evaluated_get(dg))
    me.transform(src_obj.matrix_world)
    ob = bpy.data.objects.new(name, me)
    fit_collection().objects.link(ob)
    ob.hide_render = True
    return ob


def _dominant_bone(body, arm):
    """Index of the strongest deform bone per body vertex (-1 if none)."""
    deform = {b.name for b in arm.data.bones if b.use_deform}
    gname = {g.index: g.name for g in body.vertex_groups}
    names = sorted(deform); col = {n: i for i, n in enumerate(names)}
    dom = np.full(len(body.data.vertices), -1)
    for v in body.data.vertices:
        best = 0.0
        for ge in v.groups:
            n = gname.get(ge.group)
            if n in col and ge.weight > best:
                best = ge.weight; dom[v.index] = col[n]
    return names, dom


_POSE_INV = None
_FINGERS = {}                             # {"chain": {bone: chain root}, "verts": {piece: chain root per vertex}}


def _coverage_table(A, h, u, e1, e2, L, ds, nth, smax=1.0):
    """Outer radius of the armour around the limb axis, per (slice along the limb, angle) bin. The max radius
    is taken, so double-walled garments (inner and outer shell) count by their outside. Empty angle bins take
    the nearest filled bin in their slice; a slice less than half filled is uncovered (NaN row)."""
    d = A - h; s = d @ u / L
    ns = int(math.ceil(smax / ds)); T = np.full((ns, nth), np.nan)
    si = np.floor(s / ds).astype(int); ok = (si >= 0) & (si < ns)
    ti = (np.floor((np.arctan2(d @ e2, d @ e1) + math.pi) / (2 * math.pi) * nth).astype(int)) % nth
    r = np.hypot(d @ e1, d @ e2)
    for i, t, rr in zip(si[ok], ti[ok], r[ok]):
        if not (T[i, t] >= rr): T[i, t] = rr
    for i in range(ns):
        filled = np.flatnonzero(~np.isnan(T[i]))
        if len(filled) < nth // 2:
            T[i] = np.nan; continue
        for t in np.flatnonzero(np.isnan(T[i])):
            gap = np.minimum(np.abs(filled - t), nth - np.abs(filled - t))
            T[i, t] = T[i, filled[np.argmin(gap)]]
    return T


def _poke_through(P, h, u, e1, e2, L, T, ds, nth):
    """Per skin point: how far it sticks out past the armour's outer radius (0 inside, NaN where uncovered)."""
    d = P - h; s = d @ u / L
    si = np.floor(s / ds).astype(int); ok = (si >= 0) & (si < T.shape[0])
    ti = (np.floor((np.arctan2(d @ e2, d @ e1) + math.pi) / (2 * math.pi) * nth).astype(int)) % nth
    out = np.full(len(P), np.nan)
    ra = T[si[ok], ti[ok]]
    out[ok] = np.maximum(0.0, np.hypot(d[ok] @ e1, d[ok] @ e2) - ra)
    return out


def _axis_angle_matrix(axis, ang):
    k = axis / (np.linalg.norm(axis) + 1e-12)
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + math.sin(ang) * K + (1 - math.cos(ang)) * K @ K


def _pose_match_enclosed(body, arm, pb, bname, ring, own, skinned):
    """Swing one bone (hand, finger joint) about its joint ring until the skin of its own segment sits
    inside the skinned piece (a glove), SURFACE_OFFSET from the wall. Children follow and are matched next,
    so a curled glove finger is met one joint at a time."""
    gap = SURFACE_OFFSET
    total = 0.0; field = None
    for it in range(POSE_MATCH_ITERATIONS):
        with with_modifiers_off([body], {"MASK"}):
            B, _, _ = eval_world(body)
        Mw = arm.matrix_world
        h = B[ring].mean(0); P = B[own]
        far = P[np.argmax(np.linalg.norm(P - h, axis=1))]
        L = np.linalg.norm(far - h); u = (far - h) / L
        e1 = np.cross(u, [0.0, 0.0, 1.0] if abs(u[2]) < 0.9 else [1.0, 0.0, 0.0]); e1 /= np.linalg.norm(e1)
        e2 = np.cross(u, e1)
        P = P[((P - h) @ u / L) >= 0.15]              # the slice at the joint bends with the joint
        if field is None:
            reach = L * 1.2 + 0.02                    # anywhere the segment can swing to
            lo = h - reach; hi = h + reach
            co = []; polys = []; off = 0
            for X, pl, _ in skinned:
                m = np.all((X > lo - 0.02) & (X < hi + 0.02), 1)
                if not m.any():
                    continue
                idx = np.full(len(X), -1); idx[m] = np.arange(m.sum()) + off
                co.append(X[m]); off += int(m.sum())
                polys += [tuple(int(idx[v]) for v in q) for q in pl if all(m[v] for v in q)]
            if not polys:
                log(f"WARNING: no skinned piece around '{bname}', pose match skipped"); return
            field, step = _enclosure_field(np.vstack(co), polys, lo, hi, POSE_MATCH_ENCLOSED_CELL)

        def cost(a, b):
            ang = math.hypot(a, b)
            Q = P if ang < 1e-9 else (P - h) @ _axis_angle_matrix(a * e1 + b * e2, ang).T + h
            d, out = _trilinear(field, lo, step, Q)
            return float((np.maximum(0.0, d + out + gap) ** 2).mean()) + POSE_MATCH_STIFFNESS * (ang + total) ** 2

        best = (0.0, 0.0); bc = cost(0.0, 0.0)
        for st, span in ((math.radians(4), math.radians(40)), (math.radians(0.5), math.radians(4))):
            ca, cb = best
            for a in np.arange(ca - span, ca + span + 1e-9, st):
                for b in np.arange(cb - span, cb + span + 1e-9, st):
                    c = cost(a, b)
                    if c < bc: bc, best = c, (a, b)
        ang = math.hypot(*best)
        if ang < math.radians(0.05):
            break
        if math.degrees(total + ang) > POSE_MATCH_ENCLOSED_MAX_DEG:
            log(f"WARNING: '{bname}' wanted more than {POSE_MATCH_ENCLOSED_MAX_DEG} deg, stopped"); break
        total += ang
        k = best[0] * e1 + best[1] * e2; k = k / np.linalg.norm(k)
        Pv = Vector(h)
        Ma = (Mw.inverted() @ Matrix.Translation(Pv) @ Quaternion(Vector(k), ang).to_matrix().to_4x4()
              @ Matrix.Translation(-Pv) @ Mw)
        pb.matrix = Ma @ pb.matrix
        update()
    log(f"  pose match {bname}: {math.degrees(total):.1f} deg into the glove, {len(P)} skin points")


def _finger_chains(arm, bones):
    """{bone: chain root} for the enclosure-matched bones that form single-file chains (fingers). A bone
    several chains hang off (the hand) is not in a chain."""
    enc = [b for b in bones if any(k in b for k in POSE_MATCH_ENCLOSED)]
    kids = {b: [c for c in enc if arm.data.bones[c].parent and arm.data.bones[c].parent.name == b] for b in enc}
    chain = {}
    for b in enc:
        if len(kids[b]) > 1:
            continue
        r = b
        while True:
            par = arm.data.bones[r].parent
            if par is None or par.name not in kids or len(kids[par.name]) > 1:
                break
            r = par.name
        chain[b] = r
    return chain


def _piece_fingers(co, polys, pivots):
    """Find a glove's fingers from its own shape and pair them with the body's finger chains.

    `pivots` is {chain root: knuckle position}. On each connected part of the piece, the fingertips are the
    peaks of the distance along the surface from the cuff (its open rim); a finger is the
    surface nearer its tip than any other tip, down to a little past the webbing; fingers pair with chains
    by where their bases sit, which does not change however the glove's fingers are curled.
    Returns the chain root per vertex ('' for the palm and cuff)."""
    import heapq, itertools
    key = np.round(co / 1e-5).astype(np.int64)
    _, first, weld = np.unique(key, axis=0, return_index=True, return_inverse=True)
    weld = weld.ravel(); X = co[first]; n = len(X)
    e = np.array([(weld[q[k]], weld[q[(k + 1) % len(q)]]) for q in polys for k in range(len(q))])
    e = np.sort(e[e[:, 0] != e[:, 1]], axis=1)
    ue, cnt = np.unique(e, axis=0, return_counts=True)
    adj = [[] for _ in range(n)]
    for (a, b), l in zip(ue, np.linalg.norm(X[ue[:, 0]] - X[ue[:, 1]], axis=1)):
        adj[a].append((int(b), float(l))); adj[b].append((int(a), float(l)))

    def geo(srcs):
        d = np.full(n, np.inf); h = []
        for v in srcs:
            d[int(v)] = 0.0; h.append((0.0, int(v)))
        heapq.heapify(h)
        while h:
            dv, v = heapq.heappop(h)
            if dv > d[v]:
                continue
            for w, l in adj[v]:
                if dv + l < d[w]:
                    d[w] = dv + l; heapq.heappush(h, (dv + l, w))
        return d

    rim = np.zeros(n, bool); rim[np.unique(ue[cnt == 1])] = True
    comp = np.full(n, -1); nc = 0
    for v in range(n):
        if comp[v] < 0:
            comp[np.isfinite(geo([v]))] = nc; nc += 1
    parts = [c for c in range(nc) if (comp == c).sum() >= 50 and rim[comp == c].any()]
    out = np.full(n, "", dtype=object)
    if not parts:
        return out[weld]
    near = {}                             # chains per part: the part nearest each knuckle
    for r, pv in pivots.items():
        d = [np.linalg.norm(X[comp == c] - pv, axis=1).min() for c in parts]
        if min(d) < 0.05:
            near.setdefault(parts[int(np.argmin(d))], []).append(r)
    for c, roots in near.items():
        m = comp == c
        src = [int(v) for v in np.where(m & rim)[0]]
        d0 = geo(src)                     # a fingertip is a peak of the distance from the cuff
        peaks = [v for v in np.where(m)[0] if all(d0[v] >= d0[w] for w, _ in adj[v])]
        peaks.sort(key=lambda v: -d0[v]); tips = []
        for v in peaks:                   # one peak per fingertip: drop those beside a higher one
            if all(geo([t])[v] > 0.02 for t in tips):
                tips.append(int(v))
        tips = tips[:len(roots)]
        if len(tips) < len(roots):
            log(f"WARNING: {len(tips)} fingertips found for {len(roots)} fingers"); roots = roots[:len(tips)]
        dt = np.stack([geo([t]) for t in tips])
        cell = np.argmin(dt, 0)
        base = []; reach = []
        for k in range(len(tips)):
            edge = [a for a, b in ue if m[a] and cell[a] == k and cell[b] != k]
            edge += [b for a, b in ue if m[b] and cell[b] == k and cell[a] != k]
            R = float(dt[k][edge].min()) if edge else float(dt[k][m].max())
            ringv = m & (cell == k) & (dt[k] > 0.85 * R) & (dt[k] < 1.15 * R)
            base.append(X[ringv].mean(0) if ringv.any() else X[tips[k]]); reach.append(R)
        best = None
        for perm in itertools.permutations(range(len(tips))):
            cst = sum(np.linalg.norm(base[perm[i]] - pivots[r]) for i, r in enumerate(roots))
            if best is None or cst < best[0]:
                best = (cst, perm)
        for i, r in enumerate(roots):
            k = best[1][i]
            out[m & (cell == k) & (dt[k] < SKIN_FINGER_REACH * reach[k])] = r
        log("  fingers: " + ", ".join(f"{r} {reach[best[1][i]] * 100:.1f} cm" for i, r in enumerate(roots))
            + f" (base off by {best[0] / len(roots) * 1000:.0f} mm mean)")
    return out[weld]


def _set_connected(arm, names, value):
    """Connect or disconnect bones from their parents' tails (an edit-mode property)."""
    if not names:
        return
    prev = bpy.context.view_layer.objects.active
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for n in names:
        arm.data.edit_bones[n].use_connect = value
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.objects.active = prev
    update()


def pose_match_source(body, arm, pieces):
    """Landmark alignment: pose the rig so the body matches the armour, then freeze that posed body as a mesh.
    Returns the frozen source body (rig back at rest) or None if no listed bone exists.

    Each listed limb swings about its joint to the angle where its skin pokes least through the wrapping
    armour around it (boot, sleeve, skirt), measured radially around the limb. Comparing centrelines
    instead mistakes an armour that sits a little off the limb (a boot cut roomy at the calf) for a bent
    joint, and the swing that 'fixes' it walks the foot out of the boot."""
    from mathutils.kdtree import KDTree
    bones = [b for b in POSE_MATCH_BONES if b in arm.pose.bones]
    for b in POSE_MATCH_BONES:
        if b not in arm.pose.bones: log(f"WARNING: pose-match bone '{b}' not in the rig, skipped")
    if not bones:
        return None
    # a connected bone only turns about its own head, which drops the slide of a turn about the skin's joint;
    # on a rig whose rest frame is not the skin's (FBX bind), that head is nowhere near the joint
    connected = [b for b in bones if arm.data.bones[b].use_connect]
    _set_connected(arm, connected, False)
    names, dom = _dominant_bone(body, arm)
    # match against pieces that wrap the limbs (cloth, boots): plates such as pauldrons stand off the limb
    # on one side and would pull it toward them
    # (shells such as boots count: a thigh swung for the skirt alone walks the foot out of the boot)
    wrap = ([p for p in pieces if p.name in SOFT_PIECES or p.name in SHELL_PIECES
             or p.name in SKINNED_PIECES]
            or pieces)
    A = np.vstack([eval_world(p)[0] for p in wrap])
    skinned = []                          # (verts, polys) of the pieces hands and fingers are matched into
    for p in pieces:
        if p.name in SKINNED_PIECES:
            co, _, polys = eval_world(p); skinned.append((co, polys, p.name))
    chains = _finger_chains(arm, bones); own_finger = None
    _FINGERS.clear(); _FINGERS.update(chain=chains, verts={})
    stop = set(bones)                     # a matched finger is its own segment, not part of the hand
    seg = np.array([_segment_bone(arm, n, stop) for n in names] + [""])      # dom == -1 -> ""
    gseg = {g.index: _segment_bone(arm, g.name, stop) for g in body.vertex_groups}
    DS, NTH = 0.05, 24

    def joint_ring(bname):
        # joint ring: skin shared about evenly between this limb segment and its parent. Its centre is the
        # pivot in the skin's own space (an imported rig's bone frame need not match its mesh frame, so
        # the bone head can sit far from the joint it drives)
        pb = arm.pose.bones[bname]
        par = _segment_bone(arm, pb.parent.name, stop) if pb.parent else ""
        w_own = np.array([sum(ge.weight for ge in v.groups if gseg.get(ge.group) == bname)
                          for v in body.data.vertices])
        w_par = np.array([sum(ge.weight for ge in v.groups if gseg.get(ge.group) == par)
                          for v in body.data.vertices])
        return (w_own > 0.2) & (w_par > 0.2)            # the joint with the parent, not the far end's joint

    for bname in bones:
        pb = arm.pose.bones[bname]
        ring = joint_ring(bname)
        if ring.sum() < 5:
            log(f"WARNING: no joint ring for '{bname}', pose match skipped"); continue
        if any(k in bname for k in POSE_MATCH_ENCLOSED) and skinned:
            into = skinned
            if bname in chains:
                if own_finger is None:    # hands are matched by now: pair glove fingers with her fingers
                    with with_modifiers_off([body], {"MASK"}):
                        B, _, _ = eval_world(body)
                    piv = {}
                    for r in sorted(set(chains.values())):
                        rr = joint_ring(r)
                        if rr.sum() >= 5: piv[r] = B[rr].mean(0)
                    own_finger = [_piece_fingers(co, polys, piv) for co, polys, _ in skinned]
                    for (_, _, pn), f in zip(skinned, own_finger): _FINGERS["verts"][pn] = f
                into = []                 # a finger goes into its own glove finger only
                for (co, polys, pn), f in zip(skinned, own_finger):
                    mine = f == chains[bname]
                    pl = [q for q in polys if all(mine[v] for v in q)]
                    if pl: into.append((co, pl, pn))
                if not into:
                    log(f"WARNING: no glove finger found for '{bname}', matched into the whole piece")
                    into = skinned
            _pose_match_enclosed(body, arm, pb, bname, ring, seg[dom] == bname, into)
            continue
        # the limb and everything it carries (calf -> foot, toes) swings together
        sub = np.array([n == bname or (n in arm.data.bones
                                       and bname in [x.name for x in arm.data.bones[n].parent_recursive])
                        for n in seg])
        total = 0.0; covered = 0
        for it in range(POSE_MATCH_ITERATIONS):
            with with_modifiers_off([body], {"MASK"}):
                B, _, _ = eval_world(body)
            own = seg[dom] == bname; mine = sub[dom]
            kd = KDTree(len(B))
            for i, x in enumerate(B): kd.insert(x, i)
            kd.balance()
            near = np.array([mine[i] and d <= POSE_MATCH_RADIUS for _, i, d in (kd.find(x) for x in A)])
            h = B[ring].mean(0)
            far = B[own][np.argmax(np.linalg.norm(B[own] - h, axis=1))]    # limb tip side
            L = np.linalg.norm(far - h); u = (far - h) / L
            e1 = np.cross(u, [0.0, 0.0, 1.0] if abs(u[2]) < 0.9 else [1.0, 0.0, 0.0]); e1 /= np.linalg.norm(e1)
            e2 = np.cross(u, e1)
            # the table runs the whole chain (thigh -> calf -> foot), so armour on the far segments counts too
            smax = max(1.0, float(((B[mine] - h) @ u).max() / L))
            T = _coverage_table(A[near], h, u, e1, e2, L, DS, NTH, smax)
            P = B[mine]
            keep = ~np.isnan(_poke_through(P, h, u, e1, e2, L, T, DS, NTH))
            # the slice nearest the joint bends with the joint, not with the limb
            keep &= ((P - h) @ u / L) >= 0.15
            P = P[keep]; covered = len(P)
            if covered < 30:
                log(f"WARNING: '{bname}' has too little armour around it to pose match"); break

            def cost(a, b):
                ang = math.hypot(a, b)
                Q = P if ang < 1e-9 else (P - h) @ _axis_angle_matrix(a * e1 + b * e2, ang).T + h
                pen = np.nan_to_num(_poke_through(Q, h, u, e1, e2, L, T, DS, NTH))
                return float((pen ** 2).mean()) + POSE_MATCH_STIFFNESS * (ang + total) ** 2

            best = (0.0, 0.0); bc = cost(0.0, 0.0)
            for step, span in ((math.radians(3), math.radians(30)), (math.radians(0.5), math.radians(3))):
                ca, cb = best
                for a in np.arange(ca - span, ca + span + 1e-9, step):
                    for b in np.arange(cb - span, cb + span + 1e-9, step):
                        c = cost(a, b)
                        if c < bc: bc, best = c, (a, b)
            ang = math.hypot(*best)
            if ang < math.radians(0.05):
                break
            if math.degrees(total + ang) > POSE_MATCH_MAX_DEG:
                log(f"WARNING: '{bname}' wanted more than {POSE_MATCH_MAX_DEG} deg, stopped"); break
            total += ang
            k = best[0] * e1 + best[1] * e2; k = k / np.linalg.norm(k)
            q = Quaternion(Vector(k), ang)
            Pv = Vector(h); Mw = arm.matrix_world
            Ma = Mw.inverted() @ Matrix.Translation(Pv) @ q.to_matrix().to_4x4() @ Matrix.Translation(-Pv) @ Mw
            pb.matrix = Ma @ pb.matrix
            update()
        log(f"  pose match {bname}: {math.degrees(total):.1f} deg, {covered} covered skin points")
    global _POSE_INV
    _POSE_INV = {}                                      # per deform bone: world matrix taking posed -> rest
    for pb in arm.pose.bones:
        if pb.bone.use_deform:
            posed = arm.matrix_world @ pb.matrix; rest = arm.matrix_world @ pb.bone.matrix_local
            _POSE_INV[pb.name] = np.array(rest @ posed.inverted())
    with with_modifiers_off([body], {"MASK"}):
        src = _new_mesh_object("FitSource_Posed", body)
    reset_pose(arm)
    _set_connected(arm, connected, True)
    return src


def build_target_cage(body):
    """Case B cage: the target body decimated, then shrinkwrapped back onto the body SURFACE_OFFSET out.
    Its modifiers stay live, so the cage can be edited or sculpted before the lattice pass."""
    with with_modifiers_off([body], {"MASK"}):
        cage = _new_mesh_object("FitCage_Target", body)
    dec = cage.modifiers.new("FitDecimate", "DECIMATE"); dec.ratio = CAGE_DECIMATE_RATIO
    sw = cage.modifiers.new("FitShrinkwrap", "SHRINKWRAP")
    sw.target = body; sw.wrap_method = "NEAREST_SURFACEPOINT"; sw.wrap_mode = "OUTSIDE_SURFACE"
    sw.offset = SURFACE_OFFSET
    cage.display_type = "WIRE"
    update()
    return cage


def build_source_cage(src, body, pieces):
    """Case A: cage from the source body, armour bound by Surface Deform, then the cage morphs to the target."""
    shared = len(src.data.vertices) == len(body.data.vertices)
    with with_modifiers_off([body, src], {"MASK"}):
        cage = _new_mesh_object("FitCage_Source", src)
        bco, bno, _ = eval_world(body)
    import bmesh                                        # Surface Deform rejects concave quads: triangulate
    bm = bmesh.new(); bm.from_mesh(cage.data)            # (adds no vertices, so topology stays shared)
    bmesh.ops.triangulate(bm, faces=bm.faces[:]); bm.to_mesh(cage.data); bm.free()
    sco, sno, _ = eval_world(cage)
    cage.display_type = "WIRE"
    # rest surface: the source body pushed out by SURFACE_OFFSET
    me = cage.data
    me.vertices.foreach_set("co", (sco + sno * SURFACE_OFFSET).ravel())
    me.update()
    if shared:
        cage.shape_key_add(name="Basis")
        k = cage.shape_key_add(name="FitTarget")
        k.data.foreach_set("co", (bco + bno * SURFACE_OFFSET).ravel())
        k.value = 0.0
    else:
        dec = cage.modifiers.new("FitDecimate", "DECIMATE"); dec.ratio = CAGE_DECIMATE_RATIO
        sw = cage.modifiers.new("FitShrinkwrap", "SHRINKWRAP")
        sw.target = body; sw.wrap_method = "NEAREST_SURFACEPOINT"; sw.wrap_mode = "OUTSIDE_SURFACE"
        sw.offset = SURFACE_OFFSET; sw.show_viewport = False
    if CAGE_EXCLUDE:                                    # proxy, not the skin: drop fingers and toes
        names, dom = _dominant_bone(body, bpy.data.objects[TARGET_ARMATURE_NAME]) if shared else ([], None)
        if dom is not None:
            drop = np.array([dom[i] >= 0 and any(k in names[dom[i]] for k in CAGE_EXCLUDE)
                             for i in range(len(dom))])
            bm = bmesh.new(); bm.from_mesh(cage.data); bm.verts.ensure_lookup_table()
            bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.where(drop)[0]], context="VERTS")
            bm.to_mesh(cage.data); bm.free()
            log(f"proxy cage: {int(drop.sum())} finger/toe vertices left out")
    update()
    soft = [p for p in pieces if "fit_bone" not in p and p.name not in SHELL_PIECES
            and p.name not in SKINNED_PIECES]
    for p in soft:                                    # bind while the cage still has the source shape
        sd = p.modifiers.new("FitSurfaceDeform", "SURFACE_DEFORM")
        sd.target = cage; sd.falloff = 4.0
        with ctx(p):
            bpy.ops.object.surfacedeform_bind(modifier=sd.name)
        update()
        if not sd.is_bound:
            log(f"WARNING: Surface Deform could not bind '{p.name}' (check the cage for concave n-gons)")
    if shared:
        cage.data.shape_keys.key_blocks["FitTarget"].value = 1.0
    else:
        cage.modifiers["FitShrinkwrap"].show_viewport = True
    update()
    log(f"source cage built ({'shared topology: shape key morph' if shared else 'shrinkwrap morph'})")
    return cage


def _kabsch(A, B, w):
    """Weighted best rotation + translation taking points A onto B."""
    w = w / w.sum(); ca, cb = w @ A, w @ B
    H = (A - ca).T @ ((B - cb) * w[:, None])
    U, _, Vt = np.linalg.svd(H); d = np.sign(np.linalg.det(Vt.T @ U.T))
    Rm = Vt.T @ np.diag([1, 1, d]) @ U.T
    return Rm, cb - Rm @ ca


def _segment_bone(arm, name, stop=()):
    """Fold helper bones (twist, share, breast, fingers, toes) into the nearest ancestor that is not one
    (or that is in `stop`)."""
    b = arm.data.bones.get(name)
    while (b is not None and b.parent is not None and b.name not in stop
           and any(k in b.name for k in CUT_SKIP)):
        b = b.parent
    return b.name if b is not None else name


def cut_rigid_piece(piece, body, arm, sample):
    """Split a rigid piece into one object per bone. Every loose part votes for a bone by the skin nearest
    to its vertices (`sample`: the body as posed when the armour was matched, or the rest body); parts
    smaller than CUT_SMALL_PART follow the nearest larger part. Each new object gets `fit_bone` set, is
    moved rigidly by that bone's pose-match transform, and the original piece is removed.
    Returns the new objects."""
    import bmesh
    from mathutils.kdtree import KDTree
    names, dom = _dominant_bone(body, arm)
    seg = [_segment_bone(arm, n) for n in names]
    sco, _, _ = eval_world(sample)
    kd = KDTree(len(sco))
    for i, c in enumerate(sco): kd.insert(c, i)
    kd.balance()
    X, _, polys = eval_world(piece)
    lab = islands(len(X), polys)
    parts = [np.nonzero(lab == l)[0] for l in np.unique(lab)]
    big = [p for p in parts if (X[p].max(0) - X[p].min(0)).max() >= CUT_SMALL_PART] or parts
    owner = {}
    for ids in big:
        votes = {}
        for i in ids:
            j = dom[kd.find(X[i])[1]]
            if j >= 0:
                votes[seg[j]] = votes.get(seg[j], 0) + 1
        owner[ids[0]] = max(votes, key=votes.get) if votes else arm.data.bones[0].name
    bkd = KDTree(sum(len(p) for p in big)); src_of = []
    for ids in big:
        for i in ids:
            bkd.insert(X[i], len(src_of)); src_of.append(owner[ids[0]])
    bkd.balance()
    groups = {}
    for ids in parts:
        if ids[0] in owner:
            bone = owner[ids[0]]
        else:                                           # small part: the bone of the nearest big part
            best = min((bkd.find(X[i]) for i in ids), key=lambda r: r[2])
            bone = src_of[best[1]]
        groups.setdefault(bone, []).append(ids)
    prefix = _common_prefix(list(groups))
    out = []
    for bone, idlists in sorted(groups.items()):
        keep = np.zeros(len(X), bool)
        for ids in idlists: keep[ids] = True
        ob = piece.copy(); ob.data = piece.data.copy()
        ob.name = f"{piece.name}_{bone[len(prefix):]}"
        for c in piece.users_collection: c.objects.link(ob)
        bm = bmesh.new(); bm.from_mesh(ob.data); bm.verts.ensure_lookup_table()
        bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.nonzero(~keep)[0]], context="VERTS")
        bm.to_mesh(ob.data); bm.free()
        M = _POSE_INV.get(bone) if _POSE_INV else None   # matched pose -> rest, for this bone only
        if M is not None:
            ob.data.transform(ob.matrix_world.inverted() @ Matrix(M.tolist()) @ ob.matrix_world)
        ob["fit_bone"] = bone
        out.append(ob)
        log(f"  {ob.name}: {len(idlists)} parts, {int(keep.sum())} verts -> {bone}")
    me = piece.data; bpy.data.objects.remove(piece)
    if me.users == 0: bpy.data.meshes.remove(me)
    update()
    return out


def _common_prefix(names):
    """Shared leading text of the bone names up to the last '_' (CC_Base_), so part names stay short."""
    if len(names) < 2:
        return ""
    p = names[0]
    for n in names[1:]:
        while not n.startswith(p): p = p[:-1]
    return p[:p.rfind("_") + 1] if "_" in p else ""


def push_out_rigid(piece, colliders):
    """Rigid version of the lattice pass for a cut part: each step finds the rigid transform (Kabsch) that
    best moves the penetrating vertices out while the rest stay put, so the plate moves as one solid.
    Returns the residual max penetration in metres."""
    me = piece.data; mw = np.array(piece.matrix_world)
    X = np.array([v.co[:] for v in me.vertices]) @ mw[:3, :3].T + mw[:3, 3]
    X0 = X.copy(); worst = 0.0
    for it in range(RIGID_PUSH_ITERATIONS):
        push = _penetration(X, colliders)
        mag = np.linalg.norm(push, axis=1)
        worst = float(mag.max()) if len(mag) else 0.0
        if worst <= LATTICE_TOLERANCE:
            break
        w = np.where(mag > 0, 20.0, 1.0)
        A, t = _clamped_affine(X0, X + push, w)
        X = X0 @ A.T + t
    inv = np.linalg.inv(mw)
    me.vertices.foreach_set("co", (X @ inv[:3, :3].T + inv[:3, 3]).ravel()); me.update()
    update()
    log(f"  {piece.name}: rigid push, {it + 1} steps, residual {worst * 1000:.1f} mm")
    return worst


def _clamped_affine(X0, Y, w):
    """Weighted least-squares affine map X0 -> Y whose stretch is clamped to RIGID_SCALE_RANGE per axis.
    A closed plate (a breastplate ring) cannot clear a wider body by moving; it needs to open a little,
    so a cut part may scale within the range but never shear or squash beyond it."""
    sw = np.sqrt(w)[:, None]
    c0 = (X0 * w[:, None]).sum(0) / w.sum(); cy = (Y * w[:, None]).sum(0) / w.sum()
    M, *_ = np.linalg.lstsq((X0 - c0) * sw, (Y - cy) * sw, rcond=None)
    U, S, Vt = np.linalg.svd(M.T)
    if np.linalg.det(U @ Vt) < 0:
        U[:, -1] *= -1; S[-1] *= -1
    A = U @ np.diag(np.clip(S, *RIGID_SCALE_RANGE)) @ Vt
    return A, cy - A @ c0


def _sphere_dirs(n):
    k = np.arange(n) + 0.5; phi = np.arccos(1 - 2 * k / n); th = math.pi * (1 + 5 ** 0.5) * k
    return np.c_[np.cos(th) * np.sin(phi), np.sin(th) * np.sin(phi), np.cos(phi)]


def _enclosure_field(co, polys, lo, hi, cell=None):
    """Signed distance to the shell on a grid over the box lo..hi: negative where the shell surrounds the
    point (most rays from it hit the shell: inside a boot, or inside its leather), positive outside. Rays,
    not normals: double-walled garments (inner and outer leather) flip any normal-based inside test. The
    sign is taken per grid point and the distance is exact, so the zero crossing sits on the wall itself."""
    bvh = bvh_of(co, polys)
    n = np.maximum(2, np.ceil((hi - lo) / (cell or SHELL_CELL)).astype(int) + 1)
    G = np.stack(np.meshgrid(*[np.linspace(lo[k], hi[k], n[k]) for k in range(3)], indexing="ij"), -1)
    G = G.reshape(-1, 3)
    dirs = [Vector(d) for d in _sphere_dirs(14)]
    E = np.empty(len(G)); D = np.empty(len(G))
    for i, g in enumerate(G):
        gv = Vector(g)
        D[i] = bvh.find_nearest(gv)[3]
        E[i] = sum(bvh.ray_cast(gv, d)[0] is not None for d in dirs) / len(dirs)
    return np.where(E >= 0.6, -D, D).reshape(n), (hi - lo) / (n - 1)


def _trilinear(F, lo, step, P):
    """Sample grid F at points P; also returns how far each point lies outside the grid."""
    n = np.array(F.shape)
    g = (P - lo) / step
    gc = np.clip(g, 0, n - 1 - 1e-6)
    i = np.floor(gc).astype(int); f = gc - i
    out = np.zeros(len(P))
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = ((f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1])
                     * (f[:, 2] if dz else 1 - f[:, 2]))
                out += w * F[i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz]
    return out, np.linalg.norm((g - gc) * step, axis=1)


def _nelder_mead(f, x0, steps, iters=900, tol=1e-12):
    X = [x0] + [x0 + np.eye(len(x0))[i] * steps[i] for i in range(len(x0))]
    Fv = [f(x) for x in X]
    for _ in range(iters):
        o = np.argsort(Fv); X = [X[i] for i in o]; Fv = [Fv[i] for i in o]
        if Fv[-1] - Fv[0] < tol:
            break
        c = np.mean(X[:-1], 0); xr = c + (c - X[-1]); fr = f(xr)
        if fr < Fv[0]:
            xe = c + 2 * (c - X[-1]); fe = f(xe)
            X[-1], Fv[-1] = (xe, fe) if fe < fr else (xr, fr)
        elif fr < Fv[-2]:
            X[-1], Fv[-1] = xr, fr
        else:
            xc = c + 0.5 * (X[-1] - c); fc = f(xc)
            if fc < Fv[-1]:
                X[-1], Fv[-1] = xc, fc
            else:
                X = [X[0]] + [X[0] + 0.5 * (x - X[0]) for x in X[1:]]
                Fv = [Fv[0]] + [f(x) for x in X[1:]]
    i = int(np.argmin(Fv)); return X[i], Fv[i]


def carry_skinned_piece(piece, src, body):
    """Carry a piece from the matched pose to rest the way the body's skin goes: every vertex takes the bone
    weights of the source skin around it and is moved by those bones' posed -> rest matrices (linear blend
    skinning). Each segment (forearm, palm, finger) moves near-rigidly with its bone, so the piece keeps its
    shape and follows her joints, unlike a cage that drags it through every bump of the skin between."""
    from mathutils.kdtree import KDTree
    if not _POSE_INV:
        return
    co, no, polys = eval_world(piece)
    with with_modifiers_off([src], {"MASK"}):
        S, SN, _ = eval_world(src)
    gname = {g.index: g.name for g in body.vertex_groups}
    bones = [n for n in _POSE_INV]; col = {n: i for i, n in enumerate(bones)}
    W = np.zeros((len(body.data.vertices), len(bones)))
    for v in body.data.vertices:
        for ge in v.groups:
            j = col.get(gname.get(ge.group))
            if j is not None: W[v.index, j] = ge.weight
    chain = _FINGERS.get("chain", {}); vf = _FINGERS.get("verts", {}).get(piece.name)
    sf = np.array([chain.get(bones[j], "") for j in W.argmax(1)], dtype=object)    # finger of each skin vertex

    def tree(sel):
        t = KDTree(int(sel.sum()))
        for i in np.where(sel)[0]: t.insert(S[i], int(i))
        t.balance()
        return t
    kd = tree(np.ones(len(S), bool))
    kdf = {}                              # per glove finger: the skin without the other fingers
    if vf is not None and len(vf) == len(co):
        for r in set(vf) - {""}:
            kdf[r] = tree((sf == "") | (sf == r))
    M = np.stack([np.array(_POSE_INV[n], float) for n in bones])          # (bones, 4, 4)
    n = len(co)
    WB = np.zeros((n, len(bones))); near = np.zeros((n, len(bones))); known = np.zeros(n, bool)
    cos = math.cos(math.radians(SKIN_MATCH_ANGLE))
    for i, x in enumerate(co):
        hits = (kdf[vf[i]] if kdf and vf[i] else kd).find_n(x, SKIN_NEIGHBOURS)
        j = np.array([h[1] for h in hits]); d = np.array([h[2] for h in hits]); w = 1.0 / (d + 1e-3) ** 2
        near[i] = (W[j] * w[:, None]).sum(0)
        ok = (d < SKIN_MATCH_DIST) & (SN[j] @ no[i] > cos)
        if ok.any():
            WB[i] = (W[j[ok]] * w[ok, None]).sum(0); known[i] = WB[i].sum() > 0
    e = np.array([(q[k], q[(k + 1) % len(q)]) for q in polys for k in range(len(q))])
    e = np.unique(np.sort(e, axis=1), axis=0)
    deg = np.bincount(e[:, 0], minlength=n) + np.bincount(e[:, 1], minlength=n)
    if known.any() and not known.all():   # inpaint: harmonic weights on the piece's own surface
        L = np.zeros((n, n)); L[e[:, 0], e[:, 1]] = -1.0; L[e[:, 1], e[:, 0]] = -1.0
        L[np.arange(n), np.arange(n)] = deg + 1e-9
        u = ~known
        WB[u] = np.linalg.solve(L[np.ix_(u, u)], -L[np.ix_(u, known)] @ WB[known])
    lost = WB.sum(1) < 1e-3               # islands with no match at all
    WB[lost] = near[lost]
    WB /= np.maximum(WB.sum(1, keepdims=True), 1e-12)
    log(f"  {piece.name}: {int(known.sum())} of {n} verts matched to skin, {int(lost.sum())} on unmatched islands")
    for _ in range(SKIN_SMOOTH):
        acc = np.zeros_like(WB)
        np.add.at(acc, e[:, 0], WB[e[:, 1]]); np.add.at(acc, e[:, 1], WB[e[:, 0]])
        WB = 0.5 * WB + 0.5 * acc / np.maximum(deg, 1)[:, None]
    A = np.einsum("nb,bij->nij", WB, M)
    out = np.einsum("nij,nj->ni", A[:, :3, :3], co) + A[:, :3, 3]
    none = WB.sum(1) <= 0
    out[none] = co[none]
    move = np.linalg.norm(out - co, axis=1)
    log(f"  {piece.name}: carried to rest pose by the body's skinning, move {move.mean() * 100:.1f} cm mean, "
        f"{move.max() * 100:.1f} cm max")
    inv = np.linalg.inv(np.array(piece.matrix_world))
    piece.data.vertices.foreach_set("co", (out @ inv[:3, :3].T + inv[:3, 3]).ravel()); piece.data.update()
    update()
def push_out_skinned(piece, body):
    """Skin-tight push-out for a skinned piece (glove), after the lattice. Every vertex under the skin, or
    closer to it than SURFACE_OFFSET, moves out along the skin normal, and the move fades over the next few
    edge rings. A glove finger is pushed off its own finger and the hand only, never a neighbouring finger,
    so the sides of two fingers that sit close cannot shove each other's glove about."""
    with with_modifiers_off([body], {"MASK"}):
        B, _, bpolys = eval_world(body)
    chain = _FINGERS.get("chain", {}); vf = _FINGERS.get("verts", {}).get(piece.name)
    gname = {g.index: g.name for g in body.vertex_groups}
    sf = np.array([chain.get(gname.get(max(v.groups, key=lambda ge: ge.weight).group), "") if v.groups else ""
                   for v in body.data.vertices], dtype=object)
    X, _, polys = eval_world(piece)
    n = len(X)
    if vf is None or len(vf) != n:
        vf = np.full(n, "", dtype=object)
    bvh = {"": bvh_of(B, bpolys)}
    for r in set(vf) - {""}:
        ok = (sf == "") | (sf == r)
        bvh[r] = bvh_of(B, [q for q in bpolys if all(ok[v] for v in q)])
    key = np.round(X / 1e-5).astype(np.int64)             # seams: split vertices move as one
    _, first, weld = np.unique(key, axis=0, return_index=True, return_inverse=True)
    weld = weld.ravel(); nw = len(first)
    e = np.array([(weld[q[k]], weld[q[(k + 1) % len(q)]]) for q in polys for k in range(len(q))])
    e = np.unique(np.sort(e[e[:, 0] != e[:, 1]], axis=1), axis=0)
    deg = np.maximum(np.bincount(e[:, 0], minlength=nw) + np.bincount(e[:, 1], minlength=nw), 1)
    rot = np.linalg.inv(np.array(piece.matrix_world))[:3, :3]
    gap = SURFACE_OFFSET; worst = 0.0

    def smooth(D, passes):
        for _ in range(passes):
            acc = np.zeros_like(D)
            np.add.at(acc, e[:, 0], D[e[:, 1]]); np.add.at(acc, e[:, 1], D[e[:, 0]])
            D = 0.5 * D + 0.5 * acc / deg[:, None]
        return D

    def move(D):
        co = np.empty(n * 3); piece.data.vertices.foreach_get("co", co)
        piece.data.vertices.foreach_set("co", (co.reshape(-1, 3) + D[weld] @ rot.T).ravel())
        piece.data.update(); update()

    def nearest(i, xv, lim):
        # nearest skin point for glove vertex i: its own finger's skin, unless that lands on the edge where
        # the other fingers were cut away (the offset is then not along the skin normal). Such a vertex is
        # over the webbing and takes the whole hand, or it would slide up its finger and leave the web empty
        loc, nrm, _, _ = bvh[vf[i]].find_nearest(xv, lim)
        web = not vf[i]
        if loc is not None and vf[i]:
            off = xv - loc
            if off.length > 1e-4 and abs(off.normalized().dot(nrm)) < 0.8:
                loc, nrm, _, _ = bvh[""].find_nearest(xv, lim); web = True
        return loc, nrm, web

    # shrinkwrap: every vertex over the hand goes to the nearest point of the skin, SURFACE_OFFSET above it.
    # How much a vertex is wrapped is the hand and finger weight of the skin under it, so it fades out
    # over the wrist the same way the hand's own skinning does
    hw = np.array([sum(ge.weight for ge in v.groups
                       if any(k in gname.get(ge.group, "") for k in POSE_MATCH_ENCLOSED))
                   for v in body.data.vertices])
    from mathutils.kdtree import KDTree
    kd = KDTree(len(B))
    for i, c in enumerate(B): kd.insert(c, i)
    kd.balance()
    wgt = smooth(np.clip(np.array([hw[kd.find(X[i])[1]] for i in first]), 0.0, 1.0)[:, None], 6)
    moved = 0.0
    for _ in range(SKIN_WRAP_ITERATIONS):
        X, N, _ = eval_world(piece)
        NW = np.zeros((nw, 3)); np.add.at(NW, weld, N)
        T = np.zeros((nw, 3))
        for w, i in enumerate(first):
            xv = Vector(X[i])
            loc, nrm, web = nearest(i, xv, 0.05)
            if loc is None:
                continue
            if web and (xv - loc).length > SKIN_WRAP_PROJECT and (xv - loc).dot(nrm) > 0:
                # far above the skin (webbing shallower than hers): the nearest point would send one vertex
                # to one finger and its neighbour to the next, so go straight in along the glove's own normal
                d = -Vector(NW[w]).normalized()
                hl, hn, _, _ = bvh[""].ray_cast(xv, d, 0.05)
                if hl is not None and hn.dot(d) < 0:
                    loc, nrm = hl, hn
            T[w] = np.array(loc + nrm * gap) - X[i]
        D = smooth(T * wgt, 1)
        moved = max(moved, float(np.linalg.norm(D, axis=1).max()))
        move(D)
    log(f"  {piece.name}: shrinkwrapped to the skin, {int((wgt > 0.5).sum())} of {nw} verts, "
        f"moved up to {moved * 1000:.1f} mm")
    for it in range(SKIN_PUSH_ITERATIONS):
        X, _, _ = eval_world(piece)
        push = np.zeros((nw, 3))
        for w, i in enumerate(first):
            xv = Vector(X[i])
            loc, nrm, _ = nearest(i, xv, 0.03)
            if loc is None:
                continue
            d = (xv - loc).dot(nrm)
            if d < gap:
                push[w] = np.array(nrm) * (gap - d)
        mag = np.linalg.norm(push, axis=1); hit = mag > 0
        worst = float(mag.max()) if nw else 0.0
        if worst <= LATTICE_TOLERANCE:
            break
        D = push.copy()
        for _ in range(SKIN_PUSH_SPREAD):
            acc = np.zeros_like(D)
            np.add.at(acc, e[:, 0], D[e[:, 1]]); np.add.at(acc, e[:, 1], D[e[:, 0]])
            D = 0.5 * D + 0.5 * acc / deg[:, None]
            D[hit] = push[hit]
        for _ in range(SKIN_PUSH_RELAX):                  # then unpinned: neighbours pushed different ways
            acc = np.zeros_like(D)                        # (webbing between two fingers) settle on one move
            np.add.at(acc, e[:, 0], D[e[:, 1]]); np.add.at(acc, e[:, 1], D[e[:, 0]])
            D = 0.5 * D + 0.5 * acc / deg[:, None]
        co = np.empty(n * 3); piece.data.vertices.foreach_get("co", co)
        piece.data.vertices.foreach_set("co", (co.reshape(-1, 3) + D[weld] @ rot.T).ravel())
        piece.data.update(); update()
    log(f"  {piece.name}: pushed off the skin, {it + 1} passes, residual {worst * 1000:.1f} mm")
    return worst


def carry_shell_piece(piece, src, body):
    """Shells skip the cage, so carry each side from the pose the armour was matched in to the rest pose as
    one solid: the best rigid motion of the skin under it, source body -> target body (shared topology)."""
    if len(src.data.vertices) != len(body.data.vertices):
        log(f"WARNING: '{piece.name}': source and target topology differ, shell not carried"); return
    co, _, polys = eval_world(piece)
    with with_modifiers_off([body, src], {"MASK"}):
        S, _, _ = eval_world(src); B, _, _ = eval_world(body)
    mid = float(np.median(S[:, 0])); lab = islands(len(co), polys); out = co.copy()
    side = np.zeros(len(co), int)
    for l in np.unique(lab):
        side[lab == l] = 1 if co[lab == l, 0].mean() > mid else -1
    for sd in (-1, 1):
        m = side == sd
        if not m.any():
            continue
        lo = co[m].min(0) - 0.03; hi = co[m].max(0) + 0.03
        sel = np.all((S > lo) & (S < hi), 1) & ((S[:, 0] - mid) * sd > 0)
        if sel.sum() < 30:
            log(f"WARNING: '{piece.name}' side {sd}: too little skin to carry it"); continue
        R, t = _kabsch(S[sel], B[sel], np.ones(sel.sum()))
        out[m] = co[m] @ R.T + t
        ang = math.degrees(math.acos(np.clip((np.trace(R) - 1) / 2, -1, 1)))
        log(f"  {piece.name} {'L' if sd > 0 else 'R'}: carried to rest pose, {np.linalg.norm(t) * 100:.1f} cm, "
            f"{ang:.1f} deg")
    inv = np.linalg.inv(np.array(piece.matrix_world))
    piece.data.vertices.foreach_set("co", (out @ inv[:3, :3].T + inv[:3, 3]).ravel()); piece.data.update()
    update()


def fit_shell_piece(piece, body, arm):
    """Fit a stiff piece without changing its shape. Each side (left/right loose parts) gets one transform:
    translation, rotation and per-axis scale clamped to SHELL_SCALE_RANGE, chosen so the skin under it sits
    inside the shell SURFACE_OFFSET from the wall (and, with SHELL_SNUG, not much further). The skin is
    tested against the shell's enclosure field, so the foot must end up in the boot, not just the boot out
    of the leg."""
    co, _, polys = eval_world(piece)
    with with_modifiers_off([body], {"MASK"}):
        B, _, _ = eval_world(body)
    mid = float(np.median(B[:, 0]))
    # fingers are left out: a glove's fingers are modelled in one pose and the hand's in another, and a
    # solid fit chasing them twists the whole glove; the cuff, back of the hand and palm decide
    names, dom = _dominant_bone(body, arm)
    fing = np.array([any(k in n for k in FINGER_KEYS) for n in names] + [False])
    finger = fing[dom]
    lab = islands(len(co), polys)
    side = np.zeros(len(co), int)
    for l in np.unique(lab):
        side[lab == l] = 1 if co[lab == l, 0].mean() > mid else -1
    lo_s, hi_s = np.log(SHELL_SCALE_RANGE[0]), np.log(SHELL_SCALE_RANGE[1])
    gap = SURFACE_OFFSET
    out = co.copy()
    for sd in (-1, 1):
        m = side == sd
        if not m.any():
            continue
        idx = np.full(len(co), -1); idx[m] = np.arange(m.sum())
        sp = [tuple(int(idx[v]) for v in pl) for pl in polys if m[pl[0]]]
        X = co[m]; lo = X.min(0) - 0.03; hi = X.max(0) + 0.03
        S, step = _enclosure_field(X, sp, lo, hi)
        inb = (np.all((B > lo) & (B < hi), 1) & ((B[:, 0] - mid) * sd > 0) & ~finger
               & (B[:, 2] < X[:, 2].max() - SHELL_TOP_MARGIN))
        P = B[inb]
        if len(P) < 30:
            log(f"WARNING: '{piece.name}' side {sd}: too little skin inside its box, left as is"); continue
        c = X.mean(0)

        def parts(q):
            t = q[:3]; w = q[3:6]; ls = np.clip(q[6:9], lo_s, hi_s)
            ang = float(np.linalg.norm(w))
            R = np.eye(3) if ang < 1e-12 else _axis_angle_matrix(w, ang)
            return t, R, np.exp(ls), ang

        def cost(q):
            t, R, sc, ang = parts(q)
            Q = ((P - c - t) @ R) / sc + c                  # skin in the shell's own (unmoved) frame
            d, far = _trilinear(S, lo, step, Q); d = (d + far) * sc.mean()      # signed: < 0 inside
            pen = np.maximum(0, d + gap) ** 2 + SHELL_SNUG * np.maximum(0, -d - gap) ** 2
            excess = float(np.abs(q[6:9] - np.clip(q[6:9], lo_s, hi_s)).sum())
            return float(pen.mean()) + 1e-5 * ang ** 2 + 1e-2 * excess

        best, bc = np.zeros(9), cost(np.zeros(9))
        for _ in range(3):                                   # restarts from the last best
            q, fq = _nelder_mead(cost, best, [0.01] * 3 + [0.05] * 3 + [0.03] * 3)
            if fq < bc - 1e-12:
                best, bc = q, fq
            else:
                break
        t, R, sc, ang = parts(best)
        out[m] = ((X - c) * sc) @ R.T + c + t
        Q = ((P - c - t) @ R) / sc + c
        inside = (_trilinear(S, lo, step, Q)[0] < 0).mean()
        inside0 = (_trilinear(S, lo, step, P)[0] < 0).mean()
        log(f"  {piece.name} {'L' if sd > 0 else 'R'}: move {np.linalg.norm(t) * 100:.1f} cm, turn "
            f"{math.degrees(ang):.1f} deg, scale {sc[0]:.2f}/{sc[1]:.2f}/{sc[2]:.2f}; skin inside "
            f"{inside0:.0%} -> {inside:.0%} ({len(P)} skin points)")
    inv = np.linalg.inv(np.array(piece.matrix_world))
    piece.data.vertices.foreach_set("co", (out @ inv[:3, :3].T + inv[:3, 3]).ravel()); piece.data.update()
    update()


def _penetration(X, colliders):
    """Per-vertex push (n,3) that moves each vertex out of every collider it sits inside.
    A collider is (bvh, search radius, gap): inside means behind the nearest face, or within `gap` of it."""
    push = np.zeros_like(X)
    for bvh, search, gap in colliders:
        for i, x in enumerate(X):
            xv = Vector(x + push[i])
            loc, n, _, d = bvh.find_nearest(xv, search)
            if loc is None:
                continue
            s = (xv - loc).dot(n)
            if s < gap:
                push[i] += np.array(n) * (gap - s)
    return push


def fit_armor_piece(piece, colliders, cell=None):
    """Lattice pass for one piece. Vertices inside a collider are pushed out along the collider normal. The
    push is scattered onto a linear lattice and iterated, so plates and bevels move as a unit instead of
    being crushed onto the surface. Returns the residual max penetration in metres."""
    with with_modifiers_off([piece], {"LATTICE"}):
        X0, _, _ = eval_world(piece)                     # pre-lattice shape (after any Surface Deform)
    lo, hi = X0.min(0), X0.max(0)
    pad = 0.05 * (hi - lo).max() + 0.02
    lo, hi = lo - pad, hi + pad
    size = hi - lo
    res = np.clip(np.ceil(size / (cell or LATTICE_CELL)).astype(int) + 1, 2, LATTICE_MAX_RES)
    lat = bpy.data.lattices.new("FitLattice_" + piece.name)
    lat.points_u, lat.points_v, lat.points_w = (int(r) for r in res)
    lat.interpolation_type_u = lat.interpolation_type_v = lat.interpolation_type_w = "KEY_LINEAR"
    lob = bpy.data.objects.new(lat.name, lat)
    fit_collection().objects.link(lob)
    rest = np.array([q.co[:] for q in lat.points])      # lattice-local rest grid (spacing depends on how
    span = rest.max(0) - rest.min(0)                     # the lattice was made, so read it, don't assume +-0.5)
    unit = size / span                                   # object scale that makes the grid span the box
    lob.location = Vector(0.5 * (lo + hi) - unit * 0.5 * (rest.max(0) + rest.min(0))); lob.scale = Vector(unit)
    mod = piece.modifiers.new("FitLattice", "LATTICE"); mod.object = lob
    # keep the lattice just after Surface Deform (if any), before weights/armature
    want = 1 if "FitSurfaceDeform" in piece.modifiers else 0
    with ctx(piece):
        bpy.ops.object.modifier_move_to_index(modifier=mod.name, index=want)
    update()

    U, V, W = (int(r) for r in res)
    D = np.zeros((len(rest), 3))                         # world displacement per lattice point
    g = (X0 - lo) / size * (res - 1)                     # grid coordinates of every vertex
    g0 = np.clip(np.floor(g).astype(int), 0, res - 2)
    f = g - g0
    corners, weights = [], []
    for du in (0, 1):
        for dv in (0, 1):
            for dw in (0, 1):
                idx = (g0[:, 0] + du) + (g0[:, 1] + dv) * U + (g0[:, 2] + dw) * U * V
                w = (f[:, 0] if du else 1 - f[:, 0]) * (f[:, 1] if dv else 1 - f[:, 1]) * (f[:, 2] if dw else 1 - f[:, 2])
                corners.append(idx); weights.append(w)

    worst = 0.0
    for it in range(LATTICE_ITERATIONS):
        X, _, _ = eval_world(piece)
        push = _penetration(X, colliders)
        mag = np.linalg.norm(push, axis=1)
        worst = float(mag.max()) if len(mag) else 0.0
        if worst <= LATTICE_TOLERANCE:
            break
        hit = mag > 0
        num = np.zeros_like(D); den = np.zeros(len(D))
        for idx, w in zip(corners, weights):
            np.add.at(num, idx[hit], w[hit, None] * push[hit])
            np.add.at(den, idx[hit], w[hit])
        moved = den > 1e-9
        D[moved] += num[moved] / den[moved, None]
        local = rest + D / unit
        for i in np.nonzero(moved)[0]:
            lat.points[i].co_deform = Vector(local[i])
        lat.update_tag(); update()
    log(f"  {piece.name}: lattice {U}x{V}x{W}, {it + 1} iterations, residual {worst * 1000:.1f} mm")
    return worst


def split_parts(body, arm, pieces):
    """SPLIT_PARTS: move the loose parts of a piece that sit on the named bones into a new piece."""
    import bmesh
    from mathutils.kdtree import KDTree
    if not SPLIT_PARTS:
        return
    names, dom = _dominant_bone(body, arm)
    seg = np.array([_segment_bone(arm, n).lower() for n in names] + [""])
    with with_modifiers_off([body], {"MASK"}):
        B, _, _ = eval_world(body)
    kd = KDTree(len(B))
    for i, c in enumerate(B): kd.insert(c, i)
    kd.balance()
    for pname, rules in SPLIT_PARTS.items():
        piece = next((p for p in pieces if p.name == pname), None)
        if piece is None:
            log(f"WARNING: SPLIT_PARTS piece '{pname}' not found"); continue
        X, _, polys = eval_world(piece)
        lab = islands(len(X), polys)
        near = seg[[dom[kd.find(x)[1]] for x in X]]
        taken = np.zeros(len(X), bool)
        for new_name, key in rules.items():
            keep = np.zeros(len(X), bool)
            for l in np.unique(lab):
                m = (lab == l) & ~taken
                if m.any() and np.mean([key.lower() in n for n in near[m]]) >= SPLIT_SHARE:
                    keep |= m
            if not keep.any():
                log(f"WARNING: no part of '{pname}' sits on '{key}', '{new_name}' not split"); continue
            taken |= keep
            ob = piece.copy(); ob.data = piece.data.copy(); ob.name = new_name
            for c in piece.users_collection: c.objects.link(ob)
            ob.modifiers.clear()
            bm = bmesh.new(); bm.from_mesh(ob.data); bm.verts.ensure_lookup_table()
            bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.nonzero(~keep)[0]], context="VERTS")
            bm.to_mesh(ob.data); bm.free()
            pieces.append(ob)
            log(f"  {new_name}: {int(keep.sum())} verts split from {pname}")
        if taken.any():
            bm = bmesh.new(); bm.from_mesh(piece.data); bm.verts.ensure_lookup_table()
            bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.nonzero(taken)[0]], context="VERTS")
            bm.to_mesh(piece.data); bm.free(); piece.data.update()
    update()


def fit_all(body, arm, src, pieces):
    """Step 2: cage fit (Case A or B), then the layered lattice pass."""
    if src is None:
        align_armor(body, pieces)
    split_parts(body, arm, pieces)                   # after alignment: parts are told apart by the skin
    if src is None:
        if POSE_MATCH:
            log("landmark alignment (pose match)")
            src = pose_match_source(body, arm, pieces)
    if CUT_RIGID_PIECES and (_POSE_INV is not None or src is None):
        cut = []
        for p in pieces:
            if p.name in SOFT_PIECES or p.name in SHELL_PIECES or p.name in SKINNED_PIECES:
                cut.append(p); continue
            parent = p.name
            for ob in cut_rigid_piece(p, body, arm, src or body):
                ob["fit_parent"] = parent; cut.append(ob)
        pieces[:] = cut
    if src is not None:
        for p in pieces:
            if p.name in SHELL_PIECES:
                carry_shell_piece(p, src, body)
            elif p.name in SKINNED_PIECES:
                carry_skinned_piece(p, src, body)
        build_source_cage(src, body, pieces)
    cage = build_target_cage(body)
    cco, _, cpolys = eval_world(cage)
    colliders = [(bvh_of(cco, cpolys), CAGE_SEARCH, 0.0)]
    cage.hide_set(True)
    residual = {}
    layer_of = lambda p: PIECE_LAYERS.get(p.name, PIECE_LAYERS.get(p.get("fit_parent", p.name), 0))
    for layer in sorted({layer_of(p) for p in pieces}):
        layer_pieces = [p for p in pieces if layer_of(p) == layer]
        log(f"layer {layer}: {', '.join(p.name for p in layer_pieces)}")
        for p in layer_pieces:
            if "fit_bone" in p:
                residual[p.name] = push_out_rigid(p, colliders)
            elif p.name in SHELL_PIECES:
                fit_shell_piece(p, body, arm)
                residual[p.name] = fit_armor_piece(p, colliders, SHELL_LATTICE_CELL)
            elif p.name in SKINNED_PIECES:
                fit_armor_piece(p, colliders)
                residual[p.name] = push_out_skinned(p, body)
            else:
                residual[p.name] = fit_armor_piece(p, colliders)
        for p in layer_pieces:                           # fitted pieces become colliders for the next layer
            pco, _, ppolys = eval_world(p)
            colliders.append((bvh_of(pco, ppolys), LAYER_SEARCH, LAYER_GAP))
    if APPLY_DEFORM_MODIFIERS:
        for p in pieces:
            if p.data.shape_keys:
                log(f"WARNING: '{p.name}' has shape keys; Blender cannot apply its deform modifiers")
                continue
            for name in ("FitSurfaceDeform", "FitLattice"):
                if name in p.modifiers:
                    with ctx(p):
                        bpy.ops.object.modifier_apply(modifier=name)
        c = bpy.data.collections.get(FIT_COLLECTION)
        for o in list(c.objects):
            if o.type == "LATTICE":
                lat = o.data; bpy.data.objects.remove(o); bpy.data.lattices.remove(lat)
        update()
        log("deform modifiers applied")
    return residual


# ===================================================================================== 3. body masking
def generate_body_mask(body, piece, bvh_piece=None):
    """Hide the skin under `piece`. A skin vertex is hidden when it is within MASK_PROXIMITY of the piece,
    or when the piece covers it: every ray of a small cone around its normal hits the piece within
    MASK_RAY_DISTANCE. The mask is eroded by MASK_ERODE_RINGS so its edge stays tucked under the armour.
    Adds the vertex group Mask_<piece> and an inverted Mask modifier on the body."""
    pco, _, ppolys = eval_world(piece)
    bvh = bvh_piece or bvh_of(pco, ppolys)
    with with_modifiers_off([body], {"MASK"}):
        bco, bno, bpolys = eval_world(body)
    lo, hi = pco.min(0) - MASK_RAY_DISTANCE, pco.max(0) + MASK_RAY_DISTANCE
    cand = np.nonzero(np.all((bco >= lo) & (bco <= hi), axis=1))[0]
    c = math.cos(math.radians(MASK_RAY_CONE_DEG)); s = math.sin(math.radians(MASK_RAY_CONE_DEG))
    covered = np.zeros(len(bco), bool)
    for i in cand:
        v = Vector(bco[i]); n = Vector(bno[i])
        if bvh.find_nearest(v, MASK_PROXIMITY)[0] is not None:
            covered[i] = True; continue
        t = n.orthogonal().normalized(); b = n.cross(t)
        ok = True
        for d in (n, n * c + t * s, n * c - t * s, n * c + b * s, n * c - b * s):
            if bvh.ray_cast(v + n * 1e-4, d.normalized(), MASK_RAY_DISTANCE)[0] is None:
                ok = False; break
        covered[i] = ok
    # erode: a vertex stays masked only if all its neighbours are covered
    edges = np.array([(p[k], p[(k + 1) % len(p)]) for p in bpolys for k in range(len(p))])
    for _ in range(MASK_ERODE_RINGS):
        bad = np.zeros(len(bco), bool)
        np.logical_or.at(bad, edges[:, 0], ~covered[edges[:, 1]])
        np.logical_or.at(bad, edges[:, 1], ~covered[edges[:, 0]])
        covered &= ~bad
    name = "Mask_" + piece.name
    vg = body.vertex_groups.get(name) or body.vertex_groups.new(name=name)
    idx = np.nonzero(covered)[0].tolist()
    if idx:
        vg.add(idx, 1.0, "REPLACE")
    m = body.modifiers.new(name, "MASK")
    m.mode = "VERTEX_GROUP"; m.vertex_group = name; m.invert_vertex_group = True
    update()
    return len(idx)


# ===================================================================================== 4. skin weights
def transfer_weights(piece, body, arm):
    """Parent to the rig, transfer weights from the body with a Data Transfer modifier, bake them, make
    rigid parts rigid, limit to MAX_INFLUENCES and normalise. Returns per-piece stats."""
    mw = piece.matrix_world.copy()
    piece.parent = arm; piece.parent_type = "OBJECT"
    piece.matrix_parent_inverse = arm.matrix_world.inverted()
    piece.matrix_world = mw
    deform = [b.name for b in arm.data.bones if b.use_deform]
    bone_set = set(deform)
    for g in list(piece.vertex_groups):
        piece.vertex_groups.remove(g)
    if "fit_bone" in piece:                             # a cut rigid part: all of it on its one bone
        piece.vertex_groups.new(name=piece["fit_bone"]).add(range(len(piece.data.vertices)), 1.0, "REPLACE")
        am = piece.modifiers.get("Armature") or piece.modifiers.new("Armature", "ARMATURE")
        am.object = arm
        update()
        return

    dt = piece.modifiers.new("WeightTransfer", "DATA_TRANSFER")
    dt.object = body; dt.use_object_transform = True
    dt.use_vert_data = True; dt.data_types_verts = {"VGROUP_WEIGHTS"}
    dt.vert_mapping = WEIGHT_MAPPING
    dt.layers_vgroup_select_src = "ALL"; dt.layers_vgroup_select_dst = "NAME"
    with ctx(piece):
        bpy.ops.object.datalayout_transfer(modifier=dt.name)
    am = piece.modifiers.get("Armature") or piece.modifiers.new("Armature", "ARMATURE")
    am.object = arm
    # stack: [FitSurfaceDeform] [FitLattice] WeightTransfer Armature
    with ctx(piece):
        bpy.ops.object.modifier_move_to_index(modifier=am.name, index=len(piece.modifiers) - 1)
    update()

    # bake: read the transferred weights off the evaluated mesh (body masks off, so no skin is missing)
    with with_modifiers_off([body], {"MASK"}):
        dg = bpy.context.evaluated_depsgraph_get()
        ev = piece.evaluated_get(dg)
        me = ev.to_mesh()
        names = [g.name for g in ev.vertex_groups]
        cols = {b: j for j, b in enumerate(deform)}
        Wt = np.zeros((len(me.vertices), len(deform)))
        for v in me.vertices:
            for ge in v.groups:
                nm = names[ge.group] if ge.group < len(names) else None
                if nm in cols:
                    Wt[v.index, cols[nm]] = ge.weight
        polys = [tuple(p.vertices) for p in me.polygons]
        ev.to_mesh_clear()
    dt.show_viewport = False; dt.show_render = False    # baked: keep the modifier for reference only

    rigid_note = []
    if (LOCK_RIGID_PIECES and piece.name not in SOFT_PIECES and piece.name not in SHELL_PIECES
            and piece.name not in SKINNED_PIECES):
        tot = Wt.sum(0)
        frac = tot.max() / max(tot.sum(), 1e-9)
        if piece.name in RIGID_PIECES or frac >= RIGID_BONE_THRESHOLD:
            j = int(tot.argmax()); Wt[:] = 0; Wt[:, j] = 1
            rigid_note.append(f"piece locked to {deform[j]} ({frac:.0%})")
        elif RIGID_ISLANDS:
            lab = islands(len(Wt), polys)
            X, _, _ = eval_world(piece)
            locked = averaged = 0
            for l in np.unique(lab):
                ids = np.nonzero(lab == l)[0]
                if (X[ids].max(0) - X[ids].min(0)).max() >= RIGID_ISLAND_MAX_DIM:
                    continue
                t = Wt[ids].sum(0); fr = t.max() / max(t.sum(), 1e-9)
                if fr >= RIGID_BONE_THRESHOLD:
                    Wt[ids] = 0; Wt[ids, int(t.argmax())] = 1; locked += 1
                elif RIGID_ISLAND_AVERAGE:
                    Wt[ids] = t / max(t.sum(), 1e-9); averaged += 1
            if locked or averaged:
                rigid_note.append(f"{locked} plates locked, {averaged} plates averaged")

    # write back as real vertex groups (replacing the ones the transfer created)
    for g in list(piece.vertex_groups):
        piece.vertex_groups.remove(g)
    used = np.nonzero(Wt.max(0) > 0)[0]
    groups = {j: piece.vertex_groups.new(name=deform[j]) for j in used}
    for i in range(len(Wt)):
        for j in np.nonzero(Wt[i] > 0)[0]:
            groups[j].add([i], float(Wt[i, j]), "REPLACE")
    with ctx(piece):
        bpy.ops.object.vertex_group_limit_total(group_select_mode="ALL", limit=MAX_INFLUENCES)
        bpy.ops.object.vertex_group_normalize_all(group_select_mode="ALL", lock_active=False)
        bpy.ops.object.vertex_group_clean(group_select_mode="ALL", limit=0.0001, keep_single=True)
    update()
    if rigid_note:
        log(f"  {piece.name}: " + "; ".join(rigid_note))
    unknown = [g.name for g in piece.vertex_groups if g.name not in bone_set]
    if unknown:
        log(f"WARNING: '{piece.name}' has non-bone groups: {unknown[:5]}")


# ====================================================================================== 5. Godot check
def validate_for_godot(body, arm, pieces, residual, masked):
    """Print a per-piece report: UVs, negative scale, normals facing the body, influences, clipping."""
    with with_modifiers_off([body], {"MASK"}):
        bco, _, bpolys = eval_world(body)
    bbvh = bvh_of(bco, bpolys)
    rows, problems = [], []
    for p in pieces:
        me = p.data
        uv = len(me.uv_layers)
        neg = p.matrix_world.to_3x3().determinant() < 0
        X, _, polys = eval_world(p)
        # normals: a closed loose part (a solid plate) must enclose positive volume; an open sheet (cloth)
        # should mostly face away from the body
        lab = islands(len(X), polys)
        flipped_parts = 0; open_in = open_near = 0
        vol = {}; edge_count = {}
        for poly in polys:
            l = lab[poly[0]]
            for k in range(1, len(poly) - 1):
                vol[l] = vol.get(l, 0.0) + float(np.dot(X[poly[0]], np.cross(X[poly[k]], X[poly[k + 1]])))
            for k in range(len(poly)):
                e = (min(poly[k], poly[(k + 1) % len(poly)]), max(poly[k], poly[(k + 1) % len(poly)]))
                edge_count[e] = edge_count.get(e, 0) + 1
        open_part = set()
        for (a, _b), c in edge_count.items():
            if c == 1: open_part.add(lab[a])
        flipped_parts = sum(1 for l, v in vol.items() if l not in open_part and v < 0)
        for poly in polys:
            if lab[poly[0]] not in open_part:
                continue
            c = X[list(poly)].mean(0)
            fn = np.cross(X[poly[1]] - X[poly[0]], X[poly[2]] - X[poly[0]])
            loc, n, _, d = bbvh.find_nearest(Vector(c), 0.1)
            if loc is None:
                continue
            open_near += 1
            if np.dot(fn, c - np.array(loc)) < 0:
                open_in += 1
        flipped = flipped_parts > 0 or (open_near > 0 and open_in / open_near > 0.5)
        # influences
        infl = np.zeros(len(me.vertices), int)
        for v in me.vertices:
            infl[v.index] = sum(1 for g in v.groups if g.weight > 0)
        # clipping into the bare body (rest pose)
        inside = 0
        for x in X:
            loc, n, _, d = bbvh.find_nearest(Vector(x), CAGE_SEARCH)
            if loc is not None and (Vector(x) - loc).dot(n) < 0:
                inside += 1
        rows.append((p.name, len(me.vertices), uv, int(infl.max()) if len(infl) else 0,
                     int((infl == 0).sum()), inside, residual.get(p.name, 0.0) * 1000, masked.get(p.name, 0)))
        if not uv: problems.append(f"{p.name}: no UV map")
        if neg: problems.append(f"{p.name}: negative scale")
        if flipped_parts: problems.append(f"{p.name}: {flipped_parts} closed parts are inside-out (flipped normals)")
        if open_near and open_in / open_near > 0.5:
            problems.append(f"{p.name}: {open_in}/{open_near} open faces near the body point at it (flipped normals?)")
        if (infl == 0).any(): problems.append(f"{p.name}: {int((infl == 0).sum())} unweighted vertices")
        if infl.max() > MAX_INFLUENCES: problems.append(f"{p.name}: {int(infl.max())} influences on a vertex")
    if body.data.shape_keys and any(m.type == "MASK" for m in body.modifiers):
        problems.append(f"{body.name}: has shape keys and Mask modifiers; the glTF exporter cannot apply "
                        "modifiers to a mesh with shape keys, so export the masks as data (Mask_* groups) "
                        "or apply them on a copy")
    print("\n" + "=" * 96)
    print(f"{'piece':<18}{'verts':>8}{'UVs':>5}{'max infl':>10}{'unweighted':>12}{'clipping':>10}"
          f"{'residual mm':>13}{'skin hidden':>13}")
    for r in rows:
        print(f"{r[0]:<18}{r[1]:>8}{r[2]:>5}{r[3]:>10}{r[4]:>12}{r[5]:>10}{r[6]:>13.1f}{r[7]:>13}")
    print(f"rig: {arm.name}, {sum(1 for b in arm.data.bones if b.use_deform)} deform bones")
    print("problems:" if problems else "no problems found")
    for pr in problems:
        print("  - " + pr)
    print("=" * 96 + "\n")
    return rows, problems


# ============================================================================================== main
def main(overrides=None):
    if overrides:
        g = globals()
        for k, v in overrides.items():
            if k not in g or not k.isupper():
                raise KeyError(f"unknown config '{k}'")
            g[k] = tuple(v) if isinstance(g[k], tuple) or k == "ALIGN_Z_RANGE" and v is not None else (
                set(v) if isinstance(g[k], set) else v)
    body, arm, src, pieces = validate_scene()
    cleanup(body, pieces)
    if RESET_POSE_TO_REST:
        reset_pose(arm)
    if APPLY_TRANSFORMS:
        apply_transforms(body, arm, src, pieces)
    log("step 2: fitting")
    residual = fit_all(body, arm, src, pieces)
    log("step 3: body masks")
    masked = {}
    for p in pieces:
        masked[p.name] = generate_body_mask(body, p)
        log(f"  {p.name}: {masked[p.name]} skin vertices hidden")
    log("step 4: weights")
    for p in pieces:
        transfer_weights(p, body, arm)
    log("step 5: Godot check")
    return validate_for_godot(body, arm, pieces, residual, masked)


def _cli_overrides():
    if "--" in sys.argv:
        rest = sys.argv[sys.argv.index("--") + 1:]
        if rest and rest[0].lstrip().startswith("{"):
            return json.loads(rest[0])
    return None


if __name__ == "__main__":
    main(_cli_overrides())
