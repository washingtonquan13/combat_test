# Authors the fairy wings placeholder: an armature, a membrane mesh and the
# clips WingRig plays, written to assets/fairy_wings/fairy_wings.glb (and
# the .blend beside this script's output in assets/fairy_wings/source/,
# which Godot ignores, for hand tweaks).
#
#   blender -b --factory-startup --python tools/wings/make_fairy_wings.py
#
# Blender space: +Z up, the body is at -Y (it faces -Y), the back faces +Y,
# the fairy's left is +X. Origin is the mount point on the back; WingRig
# puts it there. glTF turns +Y into Godot -Z, behind the model.
#
# Per side, a forewing and a hindwing, each two bones: a hinge from the
# root to mid-span and a tip from mid-span out. A pose is four angles per
# wing, applied about the wing's root, world-space:
#   flap  about +Z, tips sweep back (+Y) - the book opening and closing
#   fold  about +Y, in the back plane, sweeping the span down like a cape
#   twist about the span, feathering
#   flex  the tip, about the in-plane perpendicular; + curls toward the body
# The right side is the left mirrored in X.

import math
import os
import bpy
from mathutils import Matrix, Vector, Quaternion

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "assets", "fairy_wings")
FPS = 30

# name, root, spread angle (deg above +X in the back plane), hinge length,
# tip length, half-chord, share of the chord above the span, width curve
WINGS = {
    "Fore": dict(root=(0.03, 0.0, 0.035), angle=32.0, hinge=0.34, tip=0.30,
                 chord=0.19, upper=0.32, power=1.4),
    "Hind": dict(root=(0.025, 0.0, -0.03), angle=-40.0, hinge=0.22, tip=0.20,
                 chord=0.13, upper=0.45, power=1.15),
}

MIRROR = Matrix.Diagonal((-1.0, 1.0, 1.0))


def span_dir(w):
    a = math.radians(w["angle"])
    return Vector((math.cos(a), 0.0, math.sin(a)))


def side_vec(v, side):
    return Vector((v[0] if side == "L" else -v[0], v[1], v[2]))


# --- Scene -----------------------------------------------------------------

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = FPS

arm_data = bpy.data.armatures.new("WingRig")
arm = bpy.data.objects.new("WingRig", arm_data)
scene.collection.objects.link(arm)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_data.edit_bones
root = eb.new("Root")
root.head = (0, 0, 0)
root.tail = (0, 0, 0.05)
for wname, w in WINGS.items():
    s = span_dir(w)
    for side in "LR":
        r = side_vec(w["root"], side)
        d = side_vec(s, side)
        mid = Vector(r) + d * w["hinge"]
        h = eb.new(f"{wname}_{side}")
        h.head = r
        h.tail = mid
        h.roll = 0.0
        h.parent = root
        t = eb.new(f"{wname}Tip_{side}")
        t.head = mid
        t.tail = mid + d * w["tip"]
        t.roll = 0.0
        t.parent = h
        t.use_connect = True
bpy.ops.object.mode_set(mode="OBJECT")


# --- Membrane --------------------------------------------------------------

def width(u, w):
    return max(0.0, math.sin(math.pi * min(1.0, u) ** w["power"])) ** 0.6


NU, NV = 18, 10
verts, faces, uvs, groups = [], [], [], []
for wname, w in WINGS.items():
    s = span_dir(w)
    n = Vector((-s.z, 0.0, s.x))  # in-plane perpendicular, "up" of the span
    length = w["hinge"] + w["tip"]
    joint = w["hinge"] / length
    for side in "LR":
        base = len(verts)
        r = Vector(w["root"])
        for i in range(NU + 1):
            u = 0.015 + 0.985 * i / NU
            wd = width(u, w) * w["chord"]
            for j in range(NV + 1):
                vn = j / NV  # 0 = trailing (lower) edge, 1 = leading (upper)
                off = (vn - (1.0 - w["upper"])) / max(w["upper"], 1.0 - w["upper"])
                p = r + s * (u * length) + n * (off * wd)
                p = side_vec(p, side)
                verts.append(p)
                uvs.append((u, vn))
                t = min(1.0, max(0.0, (u - (joint - 0.12)) / 0.24))
                t = t * t * (3.0 - 2.0 * t)
                groups.append(((f"{wname}_{side}", 1.0 - t), (f"{wname}Tip_{side}", t)))
        for i in range(NU):
            for j in range(NV):
                a = base + i * (NV + 1) + j
                b = a + NV + 1
                quad = (a, b, b + 1, a + 1) if side == "L" else (a, a + 1, b + 1, b)
                faces.append(quad)

mesh = bpy.data.meshes.new("Wings")
mesh.from_pydata([tuple(v) for v in verts], [], faces)
mesh.update()
uv_layer = mesh.uv_layers.new(name="UVMap")
for poly in mesh.polygons:
    for li in poly.loop_indices:
        uv_layer.data[li].uv = uvs[mesh.loops[li].vertex_index]
mat = bpy.data.materials.new("WingMembrane")
mat.diffuse_color = (0.8, 0.95, 1.0, 0.4)
mesh.materials.append(mat)

wings = bpy.data.objects.new("Wings", mesh)
scene.collection.objects.link(wings)
wings.parent = arm
for bone in arm_data.bones:
    if bone.name != "Root":
        wings.vertex_groups.new(name=bone.name)
for vi, gs in enumerate(groups):
    for gname, weight in gs:
        if weight > 1e-4:
            wings.vertex_groups[gname].add([vi], weight, "REPLACE")
mod = wings.modifiers.new("Armature", "ARMATURE")
mod.object = arm


# --- Poses -----------------------------------------------------------------

def about(point, rot):
    p = Vector(point)
    return Matrix.Translation(p) @ rot.to_4x4() @ Matrix.Translation(-p)


def left_deltas(wname, flap, fold, twist, flex):
    """World rotations (3x3) for the hinge and tip of the left wing."""
    w = WINGS[wname]
    s = span_dir(w)
    d_hinge = (Matrix.Rotation(math.radians(flap), 3, "Z")
               @ Matrix.Rotation(math.radians(fold), 3, "Y")
               @ Matrix.Rotation(math.radians(twist), 3, s))
    perp = Vector((0, 1, 0)).cross(s).normalized()
    d_flex = Matrix.Rotation(math.radians(flex), 3, perp)
    return d_hinge, d_flex


def pose_wing(wname, side, flap, fold, twist, flex):
    d_hinge, d_flex = left_deltas(wname, flap, fold, twist, flex)
    if side == "R":
        d_hinge = MIRROR @ d_hinge @ MIRROR
        d_flex = MIRROR @ d_flex @ MIRROR
    for bname, d in ((f"{wname}_{side}", d_hinge), (f"{wname}Tip_{side}", d_flex)):
        rest = arm_data.bones[bname].matrix_local.to_3x3()
        local = rest.inverted() @ d @ rest
        pb = arm.pose.bones[bname]
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = local.to_quaternion()


def pose(params):
    """params: {"Fore": (flap, fold, twist, flex), "Hind": (...)} - both sides."""
    for wname, p in params.items():
        for side in "LR":
            pose_wing(wname, side, *p)


# The two rests. Spread is open, swept a little back so the pair reads as a
# shallow V from above; folded is swept down the back, tilted out behind it,
# tips curled in.
SPREAD = {"Fore": (18.0, 0.0, 0.0, 0.0), "Hind": (14.0, 0.0, 0.0, 0.0)}
FOLDED = {"Fore": (14.0, 116.0, -4.0, 6.0), "Hind": (10.0, 52.0, -4.0, 6.0)}


def lerp_params(a, b, t):
    return {k: tuple(x + (y - x) * t for x, y in zip(a[k], b[k])) for k in a}


def ease(t):
    return t * t * (3.0 - 2.0 * t)


FLUTTER_FRAMES = 10  # 3 beats a second; WingRig scales it


def flutter(f):
    """The flutter at frame f: the flap swings, the tip lags it."""
    out = {}
    for wname, lag, amp in (("Fore", 0.0, 1.0), ("Hind", 0.12, 0.85)):
        ph = 2.0 * math.pi * (f / FLUTTER_FRAMES - lag)
        base = SPREAD[wname]
        flap = base[0] + 8.0 + 30.0 * amp * math.sin(ph)
        twist = -12.0 * amp * math.cos(ph)
        flex = 16.0 * amp * math.cos(ph)
        out[wname] = (flap, base[1], twist, flex)
    return out


def make_action(name, frames, params_at):
    act = bpy.data.actions.new(name)
    arm.animation_data.action = act
    for f in range(frames + 1):
        pose(params_at(f))
        for pb in arm.pose.bones:
            if pb.name != "Root":
                pb.keyframe_insert("rotation_quaternion", frame=f)
    act.use_frame_range = True
    act.frame_start = 0
    act.frame_end = frames
    act.use_fake_user = True
    track = arm.animation_data.nla_tracks.new()
    track.name = name
    track.strips.new(name, 0, act)
    arm.animation_data.action = None
    return act


arm.animation_data_create()

# Folded and breathing: 3 s.
make_action("Folded-loop", 90, lambda f: lerp_params(
    FOLDED, {"Fore": (16.0, 114.0, -4.0, 9.0), "Hind": (12.0, 51.0, -4.0, 8.0)},
    0.5 - 0.5 * math.cos(2.0 * math.pi * f / 90)))

make_action("Flutter-loop", FLUTTER_FRAMES, flutter)


def unfold(f, n=12):
    # Out from the back in the first two thirds, overshooting open, then
    # settling into the flutter's first frame so the loop takes over clean.
    t = f / n
    if t < 0.65:
        k = ease(t / 0.65)
        p = lerp_params(FOLDED, SPREAD, k)
        # the tips trail the sweep, then fling open
        return {w: (v[0] + 14.0 * math.sin(math.pi * k), v[1], v[2],
                    v[3] + 22.0 * math.sin(math.pi * k)) for w, v in p.items()}
    k = ease((t - 0.65) / 0.35)
    return lerp_params(SPREAD, flutter(0), k)


make_action("Unfold", 12, unfold)


def fold(f, n=15):
    # Close: the wing sweeps down first, the tips come last and settle.
    t = f / n
    start = flutter(0)
    k = ease(min(1.0, t / 0.8))
    p = lerp_params(start, FOLDED, k)
    settle = math.sin(math.pi * min(1.0, t / 0.9)) * (1.0 - t)
    return {w: (v[0], v[1], v[2], v[3] - 20.0 * settle) for w, v in p.items()}


make_action("Fold", 15, fold)

# Rest pose shows folded, so the .blend opens on the grounded look.
pose(FOLDED)


# --- Write -----------------------------------------------------------------

bpy.context.preferences.filepaths.save_version = 0  # no .blend1 backups
os.makedirs(os.path.join(OUT_DIR, "source"), exist_ok=True)
ignore = os.path.join(OUT_DIR, "source", ".gdignore")
if not os.path.exists(ignore):
    open(ignore, "w").close()
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT_DIR, "source", "fairy_wings.blend"))
bpy.ops.export_scene.gltf(
    filepath=os.path.join(OUT_DIR, "fairy_wings.glb"),
    export_format="GLB",
    export_animations=True,
    export_animation_mode="ACTIONS",
    export_force_sampling=True,
    export_frame_step=1,
    export_skins=True,
    export_yup=True,
    export_apply=False,
)
print("WINGS OK", len(verts), "verts", len(faces), "faces",
      [a.name for a in bpy.data.actions])
