# The dragon's action clips, authored in code over its own Idle: Bite, Claw,
# Breath (inhale) / Breath_Hold-loop / Breath_Out, Hit, Death and Get_Up
# (Death backwards). export_dragon.py calls build() once the source clips
# are in place and the armature is at its game scale.
#
# Each clip is blocked as keys on a few named controls (neck pitch, jaw,
# the swiping arm...), interpolated by a monotone cubic so it flows through
# passing keys and settles on the extremes. Every frame starts from the
# Idle pose at that frame, so the body keeps breathing under the action.
# The controls turn bones in armature space about their heads, parents
# first; the whole-body controls (pelvis shift, the death roll) go on the
# root last.
#
# The feet are parentless bones in this rig (Hand_L/R in front,
# back_food_L/R behind), so a foot either stays planted, the leg reaching
# it by a two-bone IK, or follows its leg's end rigidly (a raised paw, a
# fallen body).
#
# Blender space: +Z up, the dragon faces -Y, +X is its left. Positive
# pitch here lifts the front end; positive yaw turns to its left.

import json
import math
import os
import bpy
from mathutils import Matrix, Vector

FPS = 24  # the source's scene rate; clips are authored in its frames
X = Vector((1.0, 0.0, 0.0))
Y = Vector((0.0, 1.0, 0.0))
Z = Vector((0.0, 0.0, 1.0))

NECK = ["ACT_neck_4", "ACT_neck_3", "ACT_neck_2", "ACT_neck_1"]
TAIL = ["tail_1", "tail_2", "tail_3", "ik_ACT_tail_5"]
LEGS = {  # foot: (upper, lower)
    "Hand_L": ("upper_arm_L", "ik_underarm_L"),
    "Hand_R": ("upper_arm_R", "ik_underarm_R"),
    "back_food_L": ("Oberschenkel_L", "lowerleg_L"),
    "back_food_R": ("Oberschenkel_R", "lowerleg_R"),
}


def _rot(axis, deg):
    return Matrix.Rotation(math.radians(deg), 3, axis)


def _pitch(deg):
    return _rot(X, -deg)  # -X lifts whatever points along -Y


def _yaw(deg):
    return _rot(Z, deg)


def _side(deg):
    return _rot(Y, deg)  # a bone pointing up bends toward +X (its left)


# --- Interpolation ----------------------------------------------------------

def _monotone(keys, f):
    """Fritsch-Carlson monotone cubic through [(frame, value)]: flat at the
    extremes and the ends, flowing through keys on the way."""
    if f <= keys[0][0]:
        return keys[0][1]
    if f >= keys[-1][0]:
        return keys[-1][1]
    xs = [k[0] for k in keys]
    ys = [k[1] for k in keys]
    n = len(keys)
    d = [(ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) for i in range(n - 1)]
    m = [0.0] * n
    for i in range(1, n - 1):
        if d[i - 1] * d[i] > 0.0:
            m[i] = 2.0 / (1.0 / d[i - 1] + 1.0 / d[i])  # harmonic mean
    i = max(j for j in range(n - 1) if xs[j] <= f)
    h = xs[i + 1] - xs[i]
    t = (f - xs[i]) / h
    t2, t3 = t * t, t * t * t
    return ((2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i]
            + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1])


class Clip:
    def __init__(self, name, frames, keys, follow=(), moments=None, wobble=None):
        self.name = name
        self.frames = frames  # last frame; the clip runs 0..frames
        self.keys = keys  # control -> [(frame, value)]
        self.follow = set(follow)  # feet that ride their legs; the rest stay planted
        self.moments = moments or {}  # method -> [frame]
        self.wobble = wobble  # f -> {control: offset}, added on top

    def controls(self, f):
        c = {k: _monotone(v, f) for k, v in self.keys.items()}
        if self.wobble:
            for k, v in self.wobble(f).items():
                c[k] = c.get(k, 0.0) + v
        return c


# --- The clips --------------------------------------------------------------
# Controls (degrees unless noted; metres at SM 0, where the head is ~0.53 m up):
#   neck_lo / neck_hi  pitch of neck_4+3 / neck_2+1     head  pitch of the head
#   neck_yaw           yaw over the whole neck           neck_side  lateral bend
#   jaw                open                              lip   upper lip lifted
#   chest              pitch of the front half (pelvic_1)
#   shift_y / shift_z  pelvis translation (-y is forward)
#   wings              both wings lifted                 wing_spread  forward sweep
#   wing_L / wing_R    one wing lifted, on top of wings
#   tail_yaw / tail_pitch  over the tail
#   arm_raise / arm_out / arm_in / elbow / paw   the right foreleg
#   roll / sink        the whole body onto its left side, and down

def _bite():
    return Clip("Bite", 24, {
        "neck_lo":  [(0, 0), (8, 22), (11, -32), (13, -38), (17, -26), (24, 0)],
        "neck_hi":  [(0, 0), (8, 22), (11, -6), (13, -10), (17, -8), (24, 0)],
        "head":     [(0, 0), (8, 16), (11, -16), (13, -22), (17, -12), (24, 0)],
        "jaw":      [(0, 0), (6, 18), (10, 45), (12, 36), (13, 2), (16, 0), (24, 0)],
        "lip":      [(0, 0), (8, 14), (12, 8), (14, 0), (24, 0)],
        "chest":    [(0, 0), (8, 8), (12, -9), (14, -9), (24, 0)],
        "shift_y":  [(0, 0), (8, 0.06), (12, -0.1), (14, -0.11), (24, 0)],
        "shift_z":  [(0, 0), (8, 0.015), (13, -0.03), (24, 0)],
        "wings":    [(0, 0), (8, 10), (13, -4), (24, 0)],
        "tail_yaw": [(0, 0), (9, 6), (15, -8), (24, 0)],
        "tail_pitch": [(0, 0), (8, 6), (13, -4), (24, 0)],
    }, moments={"impact": [13]})


def _claw():
    return Clip("Claw", 26, {
        "arm_raise": [(0, 0), (9, 135), (12, 110), (15, 40), (18, 10), (26, 0)],
        "arm_out":   [(0, 0), (9, 35), (13, 15), (15, -10), (18, -14), (26, 0)],
        "arm_in":    [(0, 0), (9, -15), (13, 0), (15, 30), (18, 25), (26, 0)],
        "elbow":     [(0, 0), (9, 70), (13, 30), (15, -5), (19, 0), (26, 0)],
        "paw":       [(0, 0), (9, 40), (13, 20), (15, -30), (18, -20), (26, 0)],
        "chest":     [(0, 0), (9, 22), (13, 6), (15, -8), (19, -5), (26, 0)],
        "shift_y":   [(0, 0), (9, 0.05), (15, -0.06), (19, -0.05), (26, 0)],
        "shift_z":   [(0, 0), (9, 0.04), (15, -0.02), (26, 0)],
        "neck_lo":   [(0, 0), (9, 4), (15, -12), (19, -8), (26, 0)],
        "neck_hi":   [(0, 0), (9, 6), (15, -4), (26, 0)],
        "head":      [(0, 0), (9, 4), (15, -10), (26, 0)],
        "neck_yaw":  [(0, 0), (9, -8), (15, 10), (19, 8), (26, 0)],
        "jaw":       [(0, 0), (9, 12), (15, 22), (19, 6), (26, 0)],
        "lip":       [(0, 0), (9, 8), (15, 10), (26, 0)],
        "wings":     [(0, 0), (9, 14), (15, -6), (26, 0)],
        "tail_yaw":  [(0, 0), (9, -10), (16, 12), (26, 0)],
    }, follow=["Hand_R"], moments={"impact": [15]})


def _breath():
    return Clip("Breath", 14, {
        "neck_lo":  [(0, 0), (9, 16), (14, -20)],
        "neck_hi":  [(0, 0), (9, 18), (14, 4)],
        "head":     [(0, 0), (9, 14), (14, -10)],
        "jaw":      [(0, 0), (9, 4), (12, 28), (14, 42)],
        "lip":      [(0, 0), (9, 4), (14, 14)],
        "chest":    [(0, 0), (9, 8), (14, -2)],
        "shift_y":  [(0, 0), (9, 0.04), (14, -0.03)],
        "wings":    [(0, 0), (9, 22), (14, 6)],
        "wing_spread": [(0, 0), (9, 10), (14, 4)],
        "tail_pitch": [(0, 0), (9, 10), (14, -2)],
    }, moments={"release": [13]})


BREATH_HOLD = {"neck_lo": -20, "neck_hi": 4, "head": -10, "jaw": 42, "lip": 14,
               "chest": -2, "shift_y": -0.03, "wings": 6, "wing_spread": 4, "tail_pitch": -2}


def _breath_hold():
    period = 24.0

    def wobble(f):
        a = 2.0 * math.pi * f / period
        return {"neck_yaw": 3.0 * math.sin(a), "head": 1.5 * math.sin(2 * a),
                "jaw": 2.0 * math.sin(3 * a), "wings": 2.0 * math.sin(a + 1.0)}

    return Clip("Breath_Hold-loop", 24, {k: [(0, v), (24, v)] for k, v in BREATH_HOLD.items()},
                wobble=wobble)


def _breath_out():
    return Clip("Breath_Out", 14, {k: [(0, v), (14, 0)] for k, v in BREATH_HOLD.items()})


def _hit():
    return Clip("Hit", 12, {
        "neck_lo":  [(0, 0), (2, 10), (5, 4), (12, 0)],
        "neck_hi":  [(0, 0), (2, 12), (6, 2), (12, 0)],
        "head":     [(0, 0), (2, 14), (6, -3), (12, 0)],
        "neck_yaw": [(0, 0), (2, 14), (6, 4), (12, 0)],
        "jaw":      [(0, 0), (2, 24), (6, 6), (12, 0)],
        "chest":    [(0, 0), (2, 5), (7, -1), (12, 0)],
        "shift_y":  [(0, 0), (2, 0.03), (6, 0.008), (12, 0)],
        "wings":    [(0, 0), (2, 18), (5, -4), (8, 2), (12, 0)],
        "tail_yaw": [(0, 0), (3, -10), (8, 3), (12, 0)],
    })


def _death():
    return Clip("Death", 48, {
        # Rears up and roars, then rolls onto its left side and sinks.
        "neck_lo":  [(0, 0), (8, 14), (18, 0), (30, -18), (48, -18)],
        "neck_hi":  [(0, 0), (8, 20), (18, 4), (30, -24), (48, -26)],
        "head":     [(0, 0), (8, 18), (18, 0), (30, -20), (48, -22)],
        "neck_side": [(0, 0), (12, 0), (30, 26), (40, 30), (48, 30)],
        "jaw":      [(0, 0), (6, 34), (12, 30), (22, 8), (32, 14), (48, 12)],
        "lip":      [(0, 0), (6, 14), (16, 0)],
        "chest":    [(0, 0), (8, 10), (20, -6), (48, -6)],
        "wings":    [(0, 0), (8, 30), (20, -10), (48, 0)],
        # Once on its side, the lower (left) wing lies out flat behind its
        # back and the upper one drapes over its belly.
        "wing_L":   [(0, 0), (16, 0), (30, 55), (34, 62), (48, 60)],
        "wing_R":   [(0, 0), (16, 0), (30, -80), (36, -98), (48, -95)],
        "tail_yaw": [(0, 0), (10, 8), (30, 24), (48, 26)],
        "limp":     [(0, 0), (14, 0), (32, 1), (48, 1)],
        "roll":     [(0, 0), (12, 0), (26, 62), (31, 74), (36, 70), (48, 72)],
        "sink":     [(0, 0), (8, -0.03), (16, 0.02), (28, 0.05), (48, 0.05)],
    }, follow=list(LEGS))


def clips():
    return [_bite(), _claw(), _breath(), _breath_hold(), _breath_out(), _hit(), _death()]


# --- Posing -----------------------------------------------------------------

class Poser:
    def __init__(self, arm, idle):
        self.arm = arm
        self.pb = arm.pose.bones
        self.idle = [(fc.data_path, fc.array_index, fc) for fc in _fcurves(idle)]
        self.idle_start = int(idle.frame_range[0])
        self.idle_len = int(idle.frame_range[1]) - self.idle_start
        self.order = []

        def walk(b):
            self.order.append(b.name)
            for c in b.children:
                walk(c)
        for b in arm.data.bones:
            if b.parent is None:
                walk(b)

    def update(self):
        bpy.context.view_layer.update()

    def set_idle(self, f):
        for pb in self.pb:
            pb.location = (0, 0, 0)
            pb.rotation_quaternion = (1, 0, 0, 0)
            pb.rotation_euler = (0, 0, 0)
            pb.scale = (1, 1, 1)
        frame = self.idle_start + (f % self.idle_len)
        for path, i, fc in self.idle:
            self.arm.path_resolve(path)[i] = fc.evaluate(frame)
        self.update()

    def turn(self, name, r3, pivot=None):
        pb = self.pb[name]
        m = pb.matrix.copy()
        p = pivot if pivot is not None else m.translation.copy()
        pb.matrix = Matrix.Translation(p) @ r3.to_4x4() @ Matrix.Translation(-p) @ m
        self.update()

    def shift(self, name, v):
        pb = self.pb[name]
        pb.matrix = Matrix.Translation(v) @ pb.matrix
        self.update()

    def ik(self, upper, lower, target):
        up, lo = self.pb[upper], self.pb[lower]
        h, k, t = up.head.copy(), up.tail.copy(), lo.tail.copy()
        l1, l2 = (k - h).length, (t - k).length
        d = target - h
        n = (k - h).cross(t - h)
        if n.length < 1e-9 or d.length < 1e-9:
            return
        n.normalize()
        dist = min(max(d.length, abs(l1 - l2) + 1e-6), l1 + l2 - 1e-6)
        a = math.acos(max(-1.0, min(1.0, (l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist))))
        knee = h + (Matrix.Rotation(-a, 3, n) @ d.normalized()) * l1
        self.turn(upper, (k - h).rotation_difference(knee - h).to_matrix(), h)
        k2, t2 = lo.head.copy(), lo.tail.copy()
        self.turn(lower, (t2 - k2).rotation_difference(target - k2).to_matrix(), k2)

    def pose(self, clip, f):
        c = clip.controls(f)
        g = lambda k: c.get(k, 0.0)
        self.set_idle(f)
        feet = {foot: self.pb[foot].matrix.copy() for foot in LEGS}
        ends = {foot: self.pb[lower].matrix.copy() for foot, (_, lower) in LEGS.items()}

        # Body, parents first.
        self.shift("pelvic_2", Vector((0.0, g("shift_y"), g("shift_z"))))
        if g("chest"):
            self.turn("pelvic_1", _pitch(g("chest")))
        for i, name in enumerate(NECK):
            r = _pitch(g("neck_lo") if i < 2 else g("neck_hi")) @ _yaw(g("neck_yaw") * 0.25) @ _side(g("neck_side") * 0.25)
            self.turn(name, r)
        if g("head"):
            self.turn("head", _pitch(g("head")))
        if g("jaw"):
            self.turn("Bone", _pitch(-g("jaw")))
        if g("lip"):
            self.turn("upper_lip", _pitch(g("lip")))
        for side, s in (("L", 1.0), ("R", -1.0)):
            lift = g("wings") + g("wing_" + side)
            spread = g("wing_spread")
            if lift or spread:
                self.turn("w_C_" + side, _side(-s * lift) @ _yaw(-s * spread))
        for i, name in enumerate(TAIL):
            if g("tail_yaw") or g("tail_pitch"):
                self.turn(name, _yaw(g("tail_yaw") * 0.25) @ _pitch(g("tail_pitch") * 0.25))
        # The right foreleg: raised forward and out, swept in across the chest.
        if g("arm_raise") or g("arm_out") or g("arm_in"):
            self.turn("upper_arm_R", _yaw(g("arm_in")) @ _side(g("arm_out")) @ _pitch(g("arm_raise")))
        if g("elbow"):
            self.turn("ik_underarm_R", _pitch(g("elbow")))
        # Limp: the legs fall loose, the upper (right) ones lifting off.
        limp = g("limp")
        if limp:
            for foot, (upper, lower) in LEGS.items():
                s = 1.0 if foot.endswith("_L") else -1.0
                front = foot.startswith("Hand")
                self.turn(upper, _side(-s * 18 * limp) @ _pitch((25 if front else -20) * limp))
                self.turn(lower, _pitch((-30 if front else 25) * limp))

        # The whole body, last: rolled about a line along its left flank.
        roll, sink = g("roll"), g("sink")
        if roll or sink:
            pivot = Vector((0.11, 0.0, 0.0))
            r = _rot(Y, roll)
            pb = self.pb["pelvic_2"]
            pb.matrix = Matrix.Translation(Vector((0.0, 0.0, -sink))) @ Matrix.Translation(pivot) @ r.to_4x4() @ Matrix.Translation(-pivot) @ pb.matrix
            self.update()

        # Feet: planted ones stay where Idle put them, the leg reaching down
        # to them; the rest ride their leg's end.
        for foot, (upper, lower) in LEGS.items():
            pb = self.pb[foot]
            if foot in clip.follow:
                pb.matrix = self.pb[lower].matrix @ ends[foot].inverted() @ feet[foot]
                self.update()
            else:
                self.ik(upper, lower, feet[foot].translation.copy())
        if g("paw"):
            self.turn("Hand_R", _pitch(g("paw")))

    def channels(self):
        out = {}
        for pb in self.pb:
            base = 'pose.bones["%s"].' % pb.name
            for i, v in enumerate(pb.location):
                out[(base + "location", i)] = v
            if pb.rotation_mode == "QUATERNION":
                for i, v in enumerate(pb.rotation_quaternion):
                    out[(base + "rotation_quaternion", i)] = v
            else:
                for i, v in enumerate(pb.rotation_euler):
                    out[(base + "rotation_euler", i)] = v
            for i, v in enumerate(pb.scale):
                out[(base + "scale", i)] = v
        return out


def _fcurves(act):
    return [fc for layer in act.layers for strip in layer.strips
            for cb in strip.channelbags for fc in cb.fcurves]


def _action(arm, name, frames, reverse=False):
    """An action from [{(path, index): value}] per frame."""
    if reverse:
        frames = frames[::-1]
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    slot = act.slots.new("OBJECT", arm.name)
    layer = act.layers.new("Layer")
    strip = layer.strips.new(type="KEYFRAME")
    bag = strip.channelbag(slot, ensure=True)
    for key in frames[0]:
        path, index = key
        values = [fr[key] for fr in frames]
        if path.endswith("rotation_quaternion"):
            pass  # sign continuity is fixed per bone below
        fc = bag.fcurves.new(path, index=index)
        fc.keyframe_points.add(len(values))
        co = []
        for i, v in enumerate(values):
            co += [float(i), v]
        fc.keyframe_points.foreach_set("co", co)
        for k in fc.keyframe_points:
            k.interpolation = "LINEAR"
        fc.update()
    act.use_frame_range = True
    act.frame_start = 0
    act.frame_end = len(frames) - 1
    return act


def _continuous(frames):
    """Flips quaternion signs so each bone's rotation never jumps hemispheres."""
    quats = {}
    for key in frames[0]:
        if key[0].endswith("rotation_quaternion"):
            quats.setdefault(key[0], []).append(key)
    for path, keys in quats.items():
        keys.sort(key=lambda k: k[1])
        for i in range(1, len(frames)):
            dot = sum(frames[i][k] * frames[i - 1][k] for k in keys)
            if dot < 0.0:
                for k in keys:
                    frames[i][k] = -frames[i][k]


def build(arm, body, idle):
    """Bakes every clip into a new action. Returns (actions, moments), with
    moments as {clip: {method: [seconds]}}."""
    deform = [m for m in body.modifiers if m.type == "ARMATURE"]
    for m in deform:
        m.show_viewport = False  # no skinning on every pose update while baking
    arm.animation_data.action = None
    poser = Poser(arm, idle)
    poser.pose(clips()[0], 0)  # the first pose after setup reads stale matrices; spend it
    actions, moments = [], {}
    for clip in clips():
        frames = []
        for f in range(clip.frames + 1):
            poser.pose(clip, f)
            frames.append(poser.channels())
        _continuous(frames)
        actions.append(_action(arm, clip.name, frames))
        if clip.name == "Death":
            actions.append(_action(arm, "Get_Up", frames, reverse=True))
        if clip.moments:
            moments[clip.name] = {m: [round(fr / FPS, 4) for fr in fs] for m, fs in clip.moments.items()}
        print("DRAGON clip", clip.name, clip.frames + 1, "frames")
    poser.set_idle(0)
    for m in deform:
        m.show_viewport = True
    return actions, moments


def write_moments(path, moments):
    with open(path, "w", newline="\n") as fh:
        json.dump(moments, fh, indent=1, sort_keys=True)
        fh.write("\n")


# --- Preview ----------------------------------------------------------------

VIEWS = {  # name: (camera location, look-at, ortho scale)
    "left": (Vector((4.0, 0.3, 0.4)), Vector((0.0, 0.3, 0.4)), 2.0),
    "right": (Vector((-4.0, 0.0, 0.4)), Vector((0.0, 0.0, 0.4)), 2.0),
    "head": (Vector((-4.0, -0.55, 0.4)), Vector((0.0, -0.55, 0.4)), 0.8),
    "front": (Vector((0.0, -4.0, 0.5)), Vector((0.0, 0.0, 0.4)), 2.0),
    "quarter": (Vector((-2.9, -2.9, 1.4)), Vector((0.0, -0.2, 0.3)), 2.0),
    "top": (Vector((0.0, 0.3, 4.0)), Vector((0.0, 0.3, 0.0)), 2.0),
}


def preview(arm, actions, out_dir, samples=9, views=("right", "head", "front", "quarter"), only=None):
    """Renders each action at `samples` evenly spaced frames from each view
    into out_dir/<clip>_<frame>_<view>.png (Workbench, textured)."""
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "OBJECT"  # the hide is near black
    for o in scene.objects:
        o.color = (0.8, 0.7, 0.55, 1.0)
    scene.display.shading.show_shadows = True
    scene.render.resolution_x = 420
    scene.render.resolution_y = 420
    scene.render.film_transparent = False
    if scene.world is None:
        scene.world = bpy.data.worlds.new("World")
    scene.world.color = (0.55, 0.6, 0.66)
    bpy.ops.mesh.primitive_plane_add(size=6.0, location=(0, 0, 0))
    ground = bpy.context.active_object
    mat = bpy.data.materials.new("Ground")
    mat.diffuse_color = (0.35, 0.33, 0.3, 1.0)
    ground.data.materials.append(mat)
    ground.color = (0.3, 0.3, 0.32, 1.0)
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.0
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    for track in arm.animation_data.nla_tracks:
        track.mute = True
    scene.render.filepath = os.path.join(out_dir, "_warmup.png")
    bpy.ops.render.render(write_still=True)  # the first render shows the rest pose
    for act in actions:
        if only and act.name not in only:
            continue
        arm.animation_data.action = act
        arm.animation_data.action_slot = act.slots[0]
        last = int(act.frame_end)
        picks = sorted({round(last * i / (samples - 1)) for i in range(samples)})
        for f in picks:
            scene.frame_set(f + 1)  # frame_set to the current frame skips evaluation
            scene.frame_set(f)
            for v in views:
                loc, at, scale = VIEWS[v]
                cam_data.ortho_scale = scale
                cam.location = loc
                cam.rotation_euler = (at - loc).to_track_quat("-Z", "Y").to_euler()
                scene.render.filepath = os.path.join(out_dir, "%s_%03d_%s.png" % (act.name, f, v))
                bpy.ops.render.render(write_still=True)
    print("DRAGON preview", out_dir)
