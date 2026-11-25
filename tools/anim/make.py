"""Key a clip on the hero from a pose sheet, in headless Blender.

    blender -b --factory-startup --python tools/anim/make.py -- \
        --clip tools/anim/clips/slash_step.py [--mode stepped|spline] \
        [--out recordings/anim_work/slash_step.blend]

Then look at it:  tools/anim/look.py --src <that .blend> --track ...,SwordTip

A clip file is plain Python holding POSES, a list of dicts, one per key. All
positions are metres in the world, the character facing -Y with its left on
+X. Angles are degrees: yaw + turns to the character's left, pitch + leans
forward, roll + leans to the character's left.

    frame    the key's frame (24 fps)
    hips     (x, y, z) of the pelvis joint
    hips_rot (yaw, pitch, roll) of the pelvis
    chest    (yaw, pitch, roll) of the ribcage relative to the pelvis, spread
             up the three spine bones
    head     (yaw, pitch, roll) relative to the ribcage, half of it in the neck
    foot_l / foot_r   dict: ball=(x, y) of the ball of the foot on the floor,
             yaw, heel (degrees the heel is raised, pivoting on the ball),
             lift (metres the ball is off the floor), knee=(x, y) optional
             direction the knee points (default: where the toes point)
    grip     (x, y, z) of the sword hand's hold on the handle
    blade    direction from guard to tip
    edge     direction the cutting edge faces (made square to the blade)
    elbow_r / elbow_l   direction the elbow is pushed toward
    hand_l   (x, y, z) of the left wrist
    A key may leave out anything but frame; it then keeps the previous key's.

Legs solve by IK to foot controls, so planted feet stay planted between keys.
Spine, head and arms are keyed as plain bone rotations (arms solved here at
each key), so they swing in arcs between keys rather than in straight lines.
"""
import bpy, sys, os, math, runpy
from mathutils import Vector, Matrix, Quaternion

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def arg(name, default=None):
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return argv[argv.index(name) + 1] if name in argv else default


CLIP = arg("--clip")
MODE = arg("--mode", "stepped")
NAME = os.path.splitext(os.path.basename(CLIP))[0]
OUT = arg("--out", os.path.join(ROOT, "recordings", "anim_work", NAME + ".blend"))
HERO = os.path.join(ROOT, "assets/characters/proof_hero/proof_hero.glb")
SWORD = os.path.join(ROOT, "assets/weapons/longsword.glb")
spec = runpy.run_path(CLIP)
POSES = spec["POSES"]

# ------------------------------------------------------------------ scene
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=HERO, bone_heuristic="BLENDER")
scene = bpy.context.scene
scene.render.fps = 24
arm = max((o for o in scene.objects if o.type == "ARMATURE"), key=lambda o: len(o.data.bones))
for o in list(scene.objects):
    if o.type == "MESH" and o.parent is None:
        bpy.data.objects.remove(o, do_unlink=True)
assert (arm.matrix_world - Matrix.Identity(4)).to_3x3().col[0].length < 1e-4, "armature is not at the origin"

# control bones: a foot target and a knee pole per leg
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
eb = arm.data.edit_bones
for s, n in (("Left", "l"), ("Right", "r")):
    foot = eb[s + "Foot"]
    c = eb.new("ctl_foot_" + n)
    c.head, c.tail, c.roll = foot.head, foot.tail, foot.roll
    c.matrix = foot.matrix.copy()
    c.length = foot.length
    k = eb.new("ctl_knee_" + n)
    k.head = eb[s + "Leg"].head + Vector((0, -0.6, 0))
    k.tail = k.head + Vector((0, 0, 0.1))
bpy.ops.object.mode_set(mode="POSE")
PB = arm.pose.bones
REST = {b.name: b.bone.matrix_local.copy() for b in PB}
for b in PB:
    b.rotation_mode = "QUATERNION"
for s, n in (("Left", "l"), ("Right", "r")):
    ik = PB[s + "Leg"].constraints.new("IK")
    ik.target, ik.subtarget = arm, "ctl_foot_" + n
    ik.pole_target, ik.pole_subtarget = arm, "ctl_knee_" + n
    ik.chain_count, ik.use_stretch = 2, False
    cr = PB[s + "Foot"].constraints.new("COPY_ROTATION")
    cr.target, cr.subtarget = arm, "ctl_foot_" + n
    cr.owner_space = cr.target_space = "WORLD"
    # pole angle: squat a little and keep whichever angle sends the knee forward
    PB["Hips"].location = REST["Hips"].inverted().to_3x3() @ Vector((0, 0, -0.15))
    best = None
    for deg in (-180, -90, 0, 90):
        ik.pole_angle = math.radians(deg)
        bpy.context.view_layer.update()
        y = PB[s + "Leg"].head.y
        if best is None or y < best[0]:
            best = (y, deg)
    ik.pole_angle = math.radians(best[1])
    PB["Hips"].location = (0, 0, 0)
bpy.ops.object.mode_set(mode="OBJECT")

# the sword in the right hand: blade out of the thumb side, edge with the knuckles
S0 = Matrix(((0, 1, 0), (0, 0, -1), (-1, 0, 0)))  # columns: sword X, Y, Z at rest
hand = REST["RightHand"]
hand_dir = (arm.data.bones["RightHand"].tail_local - arm.data.bones["RightHand"].head_local).normalized()
GRIP_REST = hand.translation + hand_dir * spec.get("GRIP_ALONG", 0.075) + Vector((0, 0, -spec.get("GRIP_PALM", 0.03)))
before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=SWORD)
sword = next(o for o in set(bpy.data.objects) - before if o.type == "MESH")
sword.name = "Sword"
sword.parent, sword.parent_type, sword.parent_bone = arm, "BONE", "RightHand"
bpy.context.view_layer.update()
sword.matrix_world = Matrix.Translation(GRIP_REST) @ S0.to_4x4() @ Matrix.Translation((0, 0, -spec.get("GRIP_ON_HANDLE", 0.0)))
tip = bpy.data.objects.new("SwordTip", None)
scene.collection.objects.link(tip)
tip.parent = sword
tip.location = (0, 0, max(v[2] for v in sword.bound_box))
tip.empty_display_size = 0.01


# ------------------------------------------------------------------ posing
def rot(yaw=0.0, pitch=0.0, roll=0.0):
    return (Matrix.Rotation(math.radians(yaw), 3, "Z") @ Matrix.Rotation(math.radians(pitch), 3, "X")
            @ Matrix.Rotation(math.radians(roll), 3, "Y"))


def part(r, t):
    return Quaternion().slerp(r.to_quaternion(), t).to_matrix()


def parent_of(name):
    p = arm.data.bones[name].parent
    return p.name if p else None


class Pose:
    """World matrices of the bones posed so far; anything unposed sits at rest
    on its parent."""

    def __init__(self):
        self.basis = {}

    def world(self, name):
        p = parent_of(name)
        pre = (self.world(p) @ REST[p].inverted() @ REST[name]) if p else REST[name]
        return pre @ self.basis.get(name, Matrix.Identity(4))

    def pre(self, name):
        p = parent_of(name)
        return (self.world(p) @ REST[p].inverted() @ REST[name]) if p else REST[name]

    def aim(self, name, world_rot, world_pos=None):
        pre = self.pre(name)
        m = world_rot.to_4x4()
        m.translation = pre.translation if world_pos is None else Vector(world_pos)
        self.basis[name] = pre.inverted() @ m

    def swing(self, name, direction):
        """Point the bone along a direction with no added twist."""
        c = self.pre(name).to_3x3()
        q = c.col[1].normalized().rotation_difference(Vector(direction).normalized())
        self.aim(name, q.to_matrix() @ c)


def two_bone(pose, upper, lower, target, hint):
    s = pose.pre(upper).translation
    l1 = (REST[lower].translation - REST[upper].translation).length
    end = arm.data.bones[lower].tail_local
    l2 = (end - REST[lower].translation).length
    to = Vector(target) - s
    d = min(to.length, (l1 + l2) * 0.999)
    n = to.normalized()
    a = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
    h = Vector(hint) - n * Vector(hint).dot(n)
    h = h.normalized() if h.length > 1e-5 else n.orthogonal().normalized()
    elbow = s + n * a + h * math.sqrt(max(l1 * l1 - a * a, 0.0))
    pose.swing(upper, elbow - s)
    pose.swing(lower, (s + n * d) - elbow)
    return to.length / (l1 + l2)


BALL = {s: arm.data.bones[s + "ToeBase"].head_local.copy() for s in ("Left", "Right")}
LEG_LEN = sum((arm.data.bones[b].tail_local - arm.data.bones[b].head_local).length for b in ("LeftUpLeg", "LeftLeg"))
state, last_q, notes = {}, {}, []


def build(p):
    state.update(p)
    g = state.get
    pose = Pose()
    rh = rot(*g("hips_rot", (0, 0, 0)))
    pose.aim("Hips", rh @ REST["Hips"].to_3x3(), g("hips"))
    rc = rot(*g("chest", (0, 0, 0)))
    for name, t in (("Spine", 0.25), ("Spine1", 0.6), ("Spine2", 1.0)):
        pose.aim(name, rh @ part(rc, t) @ REST[name].to_3x3())
    rhd = rot(*g("head", (0, 0, 0)))
    pose.aim("Neck", rh @ rc @ part(rhd, 0.5) @ REST["Neck"].to_3x3())
    pose.aim("Head", rh @ rc @ rhd @ REST["Head"].to_3x3())
    reach = {}
    for s, n in (("Left", "l"), ("Right", "r")):
        f = g("foot_" + n)
        rf = rot(f.get("yaw", 0.0), f.get("heel", 0.0))
        ball = Vector((f["ball"][0], f["ball"][1], BALL[s].z + f.get("lift", 0.0)))
        ankle = ball + rf @ (REST[s + "Foot"].translation - BALL[s])
        pose.aim("ctl_foot_" + n, rf @ REST[s + "Foot"].to_3x3(), ankle)
        fwd = rot(f.get("yaw", 0.0)) @ Vector((0, -1, 0))
        if "knee" in f:
            fwd = Vector((f["knee"][0], f["knee"][1], 0)).normalized()
        hip = pose.pre(s + "UpLeg").translation
        pose.aim("ctl_knee_" + n, REST["ctl_knee_" + n].to_3x3(), (hip + ankle) * 0.5 + fwd * 0.8)
        # toes stay flat on the floor while the heel lifts
        foot_w = rf @ REST[s + "Foot"].to_3x3()
        toe_pre = foot_w @ REST[s + "Foot"].to_3x3().inverted() @ REST[s + "ToeBase"].to_3x3()
        want = rot(f.get("yaw", 0.0), f.get("toe", 0.0)) @ REST[s + "ToeBase"].to_3x3()
        pose.basis[s + "ToeBase"] = (toe_pre.inverted() @ want).to_4x4()
        reach[n] = (ankle - hip).length / LEG_LEN
    # sword hand
    blade = Vector(g("blade")).normalized()
    edge = Vector(g("edge"))
    edge = (edge - blade * edge.dot(blade)).normalized()
    y = -edge
    sw = Matrix((y.cross(blade), y, blade)).transposed()
    hand_rot = sw @ S0.inverted() @ REST["RightHand"].to_3x3()
    wrist = Vector(g("grip")) - hand_rot @ REST["RightHand"].to_3x3().inverted() @ (GRIP_REST - REST["RightHand"].translation)
    reach["arm_r"] = two_bone(pose, "RightArm", "RightForeArm", wrist, g("elbow_r", (0, 0, -1)))
    pose.aim("RightHand", hand_rot)
    reach["arm_l"] = two_bone(pose, "LeftArm", "LeftForeArm", g("hand_l"), g("elbow_l", (0, 0, -1)))
    sh = pose.pre("RightArm").translation
    notes.append("f%-3d leg reach L %.2f R %.2f   arm reach R %.2f L %.2f   r.shoulder (%.2f %.2f %.2f)%s" % (
        state["frame"], reach["l"], reach["r"], reach["arm_r"], reach["arm_l"], sh.x, sh.y, sh.z,
        "   <-- OUT OF REACH" if max(reach.values()) > 1.0 else ""))
    return pose


arm.animation_data_create()
action = bpy.data.actions.new(NAME)
arm.animation_data.action = action
for p in POSES:
    pose = build(p)
    f = p["frame"]
    for name, basis in pose.basis.items():
        b = PB[name]
        loc, q, _ = basis.decompose()
        if name in last_q and last_q[name].dot(q) < 0:
            q.negate()
        last_q[name] = q
        b.rotation_quaternion = q
        b.keyframe_insert("rotation_quaternion", frame=f)
        if name == "Hips" or name.startswith("ctl_"):
            b.location = loc
            b.keyframe_insert("location", frame=f)

# fist round the handle, off hand loosely curled
def curl(side, deg, thumb):
    for b in PB:
        if not b.name.startswith(side):
            continue
        if any(k in b.name for k in ("Index", "Middle", "Ring", "Pinky")):
            b.rotation_quaternion = Quaternion(CURL_AXIS, math.radians(deg))
        elif "Thumb" in b.name:
            b.rotation_quaternion = Quaternion(CURL_AXIS, math.radians(thumb))
        else:
            continue
        b.keyframe_insert("rotation_quaternion", frame=POSES[0]["frame"])


CURL_AXIS = Vector(spec.get("CURL_AXIS", (1, 0, 0)))
curl("Right", spec.get("CURL", 75.0), spec.get("CURL_THUMB", 25.0))
curl("Left", spec.get("CURL_OFF", 25.0), 10.0)


def fcurves(act):
    if getattr(act, "layers", None):
        return [fc for layer in act.layers for strip in layer.strips for cb in strip.channelbags for fc in cb.fcurves]
    return list(act.fcurves)


for fc in fcurves(action):
    for kp in fc.keyframe_points:
        kp.interpolation = "CONSTANT" if MODE == "stepped" else "BEZIER"
        kp.handle_left_type = kp.handle_right_type = "AUTO_CLAMPED"
    fc.update()
scene.frame_start, scene.frame_end = POSES[0]["frame"], POSES[-1]["frame"]
scene.frame_set(scene.frame_start)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=OUT)
print("MAKE", NAME, MODE, "keys", [p["frame"] for p in POSES])
for n in notes:
    print("MAKE", n)
print("MAKE wrote", OUT)
