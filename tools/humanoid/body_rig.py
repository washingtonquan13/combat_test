# Solves a humanoid pose from a physical description, on the UAL skeleton's
# T-pose. Nothing here knows a clip, and nothing is read from a source clip.
#
# Blender space, metres: the character faces -Y, +X is their LEFT, +Z is up.
# Every rotation is (pitch, roll, yaw) in degrees, world axes:
#   pitch + leans forward, roll + leans to their left, yaw + turns to their left.
#
# A pose is a dict:
#   hip        (x, y, z)  where the pelvis joint is. Rest (0, .05, .917).
#   hip_rot    (p, r, y)  the pelvis.
#   chest_rot  (p, r, y)  the ribcage, in the world. The spine shares the
#                         difference from the pelvis, so a twist reads as a twist.
#   look       (x, y, z)  where the face points. Optional head_up, or head_rot
#                         instead of look. The neck shares the difference.
#   feet       {"l": {...}, "r": {...}}
#                at (x, y, z) ankle, rot (p, r, y), toe degrees (ball bent up),
#                optional pole for the knee. Use motion.plant() for a foot on the ground.
#   hands      {"l": {...}, "r": {...}}, one of three ways of saying where it is:
#                aim + up: it holds something. at is the held thing's origin
#                  (the game's Grip node), aim its +Z (blade or muzzle in Godot's
#                  axes), up its +Y.
#                blade + edge: the same for a sword or axe, blade exact (Godot +Y),
#                  edge the way the cutting edge faces (Godot +Z).
#                point + palm: at is the wrist, fingers along point, palm facing palm.
#                neither: at is the wrist and the hand follows the forearm.
#                Also: pole (where the elbow goes), space "chest" or "hip"
#                (at, directions and pole are given as if that part were at rest,
#                and ride it), curl 0-1, thumb 0-1, spread degrees, clav (fwd, up).
#   body       optional {"pivot": (x, y, z), "rot": (p, r, y), "shift": (x, y, z)}
#              turns the whole solved figure, for falls and rolls.

import math
import bpy
from mathutils import Matrix, Vector

SPINE = ("spine_01", "spine_02", "spine_03")
SPINE_SHARE = (0.35, 0.7, 1.0)
NECK_SHARE = 0.45
SIDES = {"r": 1.0, "l": -1.0}
FINGERS = ("index", "middle", "ring", "pinky")
FINGER_BEND = (72.0, 92.0, 55.0)
THUMB_BEND = (16.0, 34.0, 40.0)
SPREAD_SHARE = {"index": 1.0, "middle": 0.3, "ring": -0.4, "pinky": -1.0}
# How much of the hand's turn about the forearm the forearm itself takes, so
# the wrist doesn't wring.
FOREARM_TWIST = 0.6

# The game's Grip nodes at T-pose, turned into Blender axes (x, -z, y):
# scenes/character_models/placeholder_model.tscn MainHand/Grip and OffHand/Grip.
GRIP_AIM = {"r": Vector((-0.94, -0.342, 0.0)), "l": Vector((0.94, -0.342, 0.0))}
GRIP_UP = {"r": Vector((0.342, -0.94, 0.0)), "l": Vector((-0.342, -0.94, 0.0))}
GRIP_AT = {"r": Vector((-0.8239, 0.0654, 1.4058)), "l": Vector((0.8239, 0.0654, 1.4058))}


def euler(pitch, roll, yaw):
    """World rotation: pitch about X, roll about Y, yaw about Z, in degrees."""
    return (Matrix.Rotation(math.radians(yaw), 3, "Z")
            @ Matrix.Rotation(math.radians(roll), 3, "Y")
            @ Matrix.Rotation(math.radians(pitch), 3, "X"))


def _frame(forward, up):
    """Orthonormal basis, forward as Y and `up` steering Z."""
    y = forward.normalized()
    x = y.cross(up).normalized()
    return Matrix((x, y, x.cross(y))).transposed()


def held_matrix(at, aim, up):
    """Blender matrix of a held thing whose Godot +Z is aim and +Y is up.
    Godot (x, y, z) is Blender (x, -z, y), so a model's Blender axes are
    (up x aim, -aim, up)."""
    aim = Vector(aim).normalized()
    up = Vector(up)
    x = up.cross(aim).normalized()
    up = aim.cross(x).normalized()
    m = Matrix((x, -aim, up)).transposed().to_4x4()
    m.translation = Vector(at)
    return m


class Rig:
    def __init__(self, arm):
        self.arm = arm
        self.bones = arm.data.bones
        self.L = {b.name: b.matrix_local.copy() for b in self.bones}
        self.len = {b.name: b.length for b in self.bones}
        for pb in arm.pose.bones:
            pb.rotation_mode = "QUATERNION"
        self.P = {}
        self.grip_rest = {s: held_matrix(GRIP_AT[s], GRIP_AIM[s], GRIP_UP[s]) for s in SIDES}
        self.held = {}
        self.miss = {}

    def _head(self, name):
        return self.L[name].translation.copy()

    def _rest_rot(self, name):
        return self.L[name].to_3x3()

    def _set(self, name, at, delta):
        """Bone `name` with its head at `at`, turned from rest by `delta`."""
        m = (delta @ self._rest_rot(name)).to_4x4()
        m.translation = at
        self.P[name] = m

    def _from_parent(self, parent, point):
        return self.P[parent] @ self.L[parent].inverted() @ point

    def _child_rigid(self, parent, name):
        return self.P[parent] @ self.L[parent].inverted() @ self.L[name]

    def _delta(self, name):
        return self.P[name].to_3x3() @ self._rest_rot(name).inverted()

    def solve(self, pose):
        """Fills self.P with every bone's armature-space matrix, and self.held
        with where each hand's held thing is."""
        self.P = {"root": self.L["root"].copy()}
        self.held = {}
        hip_q = euler(*pose.get("hip_rot", (0, 0, 0))).to_quaternion()
        chest_q = euler(*pose.get("chest_rot", (0, 0, 0))).to_quaternion()
        self._set("pelvis", Vector(pose["hip"]), hip_q.to_matrix())

        parent = "pelvis"
        for name, share in zip(SPINE, SPINE_SHARE):
            self._set(name, self._from_parent(parent, self._head(name)), hip_q.slerp(chest_q, share).to_matrix())
            parent = name

        if "look" in pose:
            rest = _frame(Vector((0, -1, 0)), Vector((0, 0, 1)))
            head_q = (_frame(Vector(pose["look"]), Vector(pose.get("head_up", (0, 0, 1)))) @ rest.inverted()).to_quaternion()
        else:
            head_q = euler(*pose.get("head_rot", (0, 0, 0))).to_quaternion()
        self._set("neck_01", self._from_parent("spine_03", self._head("neck_01")), chest_q.slerp(head_q, NECK_SHARE).to_matrix())
        self._set("Head", self._from_parent("neck_01", self._head("Head")), head_q.to_matrix())

        for side in SIDES:
            self._arm(side, pose["hands"][side])
            self._leg(side, pose["feet"][side])
        self._fill_rest()
        b = pose.get("body")
        if b:
            pivot = Vector(b["pivot"])
            m = Matrix.Translation(pivot + Vector(b["shift"])) @ euler(*b["rot"]).to_4x4() @ Matrix.Translation(-pivot)
            self.P = {n: m @ p for n, p in self.P.items()}
            self.held = {s: m @ h for s, h in self.held.items()}
        return self.P

    def _carried(self, c):
        """c's `at` and directions in the world, riding its space if it has one."""
        space = {"chest": "spine_03", "hip": "pelvis"}.get(c.get("space"))
        if not space:
            return lambda v: Vector(v), lambda v: Vector(v)
        rest = self._head(space)
        now = self.P[space].translation
        turn = self._delta(space)
        return (lambda v: now + turn @ (Vector(v) - rest)), (lambda v: turn @ Vector(v))

    def _forearm(self, side, c, at, dir_of):
        """Where the forearm points with the hand at `at`: an edge laid along
        it leaves the wrist straight, whatever the blade is doing."""
        s = SIDES[side]
        clavicle, upper, lower, hand = ("%s_%s" % (n, side) for n in ("clavicle", "upperarm", "lowerarm", "hand"))
        chest = self._delta("spine_03")
        self._set(clavicle, self._from_parent("spine_03", self._head(clavicle)), chest)
        root = self._from_parent(clavicle, self._head(upper))
        hint = dir_of(c["pole"]) if "pole" in c else chest @ Vector((-s * 0.45, 0.45, -1.0))
        joint, _ = self._two_bone(upper, lower, hand, root, at, hint)
        return (at - joint).normalized()

    def _arm(self, side, c):
        s = SIDES[side]
        clavicle, upper, lower, hand = ("%s_%s" % (n, side) for n in ("clavicle", "upperarm", "lowerarm", "hand"))
        point_of, dir_of = self._carried(c)
        at = point_of(c["at"])
        chest = self._delta("spine_03")

        # The hand first where it is fixed: a held thing or a stated direction
        # decides where the wrist has to be.
        hand_m = None
        if "blade" in c:
            blade = dir_of(c["blade"]).normalized()
            edge = self._forearm(side, c, at, dir_of) if c["edge"] == "forearm" else dir_of(c["edge"])
            c = dict(c, aim=tuple(edge - blade * edge.dot(blade)), up=tuple(blade), raw=True)
        if "aim" in c:
            grip = held_matrix(at, Vector(c["aim"]) if c.get("raw") else dir_of(c["aim"]),
                               Vector(c["up"]) if c.get("raw") else dir_of(c["up"]))
            self.held[side] = grip
            hand_m = grip @ self.grip_rest[side].inverted() @ self.L[hand]
            wrist = hand_m.translation.copy()
        elif "point" in c:
            rest_point = Vector((-s, 0, 0))
            rest_palm = Vector((0, 0, -1))
            turn = _frame(dir_of(c["point"]), dir_of(c["palm"])) @ _frame(rest_point, rest_palm).inverted()
            hand_m = (turn @ self._rest_rot(hand)).to_4x4()
            hand_m.translation = at
            wrist = at
        else:
            wrist = at

        # The shoulder follows the reach: it rides up with a raised hand and
        # comes forward with a forward one.
        rest_shoulder = self._from_parent("spine_03", self._head(upper))
        v = chest.inverted() @ (wrist - rest_shoulder).normalized()
        up = 15.0 * max(0.0, v.z) - 3.0 * max(0.0, -v.z)
        fwd = 13.0 * max(0.0, -v.y) - 5.0 * max(0.0, v.y)
        extra = c.get("clav", (0.0, 0.0))
        fwd += extra[0]
        up += extra[1]
        clav_turn = Matrix.Rotation(math.radians(s * fwd), 3, "Z") @ Matrix.Rotation(math.radians(s * up), 3, "Y")
        self._set(clavicle, self._from_parent("spine_03", self._head(clavicle)), chest @ clav_turn)

        root = self._from_parent(clavicle, self._head(upper))
        hint = dir_of(c["pole"]) if "pole" in c else chest @ Vector((-s * 0.45, 0.45, -1.0))
        joint, tip = self._two_bone(upper, lower, hand, root, wrist, hint)
        self.miss[side] = (tip - wrist).length  # out of reach: the held thing stays in the hand
        if side in self.held:
            self.held[side].translation += tip - wrist
        if hand_m is None:
            self._set(hand, tip, self._delta(lower))
        else:
            self.P[hand] = hand_m.copy()
            self.P[hand].translation = tip
            self._share_twist(lower, hand)
        self._fingers(side, c, "aim" in c)

    def _two_bone(self, upper, lower, end, root, target, hint):
        a = (self._head(lower) - self._head(upper)).length
        b = (self._head(end) - self._head(lower)).length
        to = target - root
        d = max(min(to.length, (a + b) * 0.9995), abs(a - b) * 1.001)
        forward = to.normalized()
        # Rest: which way this joint points, so the bone rolls with it.
        joint_rest = self._head(lower)
        rest_root = self._head(upper)
        rest_axis = (self._head(end) - rest_root).normalized()
        rest_bend = joint_rest - rest_root
        rest_bend = (rest_bend - rest_axis * rest_bend.dot(rest_axis)).normalized()
        bend = (hint - forward * hint.dot(forward)).normalized()
        along = (a * a - b * b + d * d) / (2.0 * d)
        out = math.sqrt(max(a * a - along * along, 0.0))
        joint = root + forward * along + bend * out
        tip = root + forward * d

        def turn(rest_dir, new_dir):
            new_dir = new_dir.normalized()
            rest_up = (rest_bend - rest_dir * rest_bend.dot(rest_dir)).normalized()
            new_up = (bend - new_dir * bend.dot(new_dir)).normalized()
            return _frame(new_dir, new_up) @ _frame(rest_dir, rest_up).inverted()

        self._set(upper, root, turn((joint_rest - rest_root).normalized(), joint - root))
        self._set(lower, joint, turn((self._head(end) - joint_rest).normalized(), tip - joint))
        return joint, tip

    def _share_twist(self, lower, hand):
        axis = (self._head(hand) - self._head(lower)).normalized()
        q = (self._delta(lower).inverted() @ self._delta(hand)).to_quaternion()
        # Twist about the forearm: the part of q around axis.
        along = Vector((q.x, q.y, q.z)).dot(axis)
        angle = 2.0 * math.atan2(along, q.w)
        if angle > math.pi:
            angle -= 2.0 * math.pi
        elif angle < -math.pi:
            angle += 2.0 * math.pi
        self._set(lower, self.P[lower].translation.copy(),
                  self._delta(lower) @ Matrix.Rotation(angle * FOREARM_TWIST, 3, axis))

    def _fingers(self, side, c, holding):
        curl = c.get("curl", 0.85 if holding else 0.28)
        thumb = c.get("thumb", 0.7 if holding else 0.25)
        spread = c.get("spread", 0.0)
        hand = "hand_" + side
        for f in FINGERS:
            parent = hand
            for i, bend in enumerate(FINGER_BEND):
                name = "%s_%02d_%s" % (f, i + 1, side)
                side_turn = Matrix.Rotation(math.radians(spread * SPREAD_SHARE[f]), 4, "Z") if i == 0 else Matrix.Identity(4)
                self.P[name] = self._child_rigid(parent, name) @ side_turn @ Matrix.Rotation(math.radians(curl * bend), 4, "X")
                parent = name
        parent = hand
        for i, bend in enumerate(THUMB_BEND):
            name = "thumb_%02d_%s" % (i + 1, side)
            self.P[name] = self._child_rigid(parent, name) @ Matrix.Rotation(math.radians(thumb * bend), 4, "X")
            parent = name

    def _leg(self, side, c):
        s = SIDES[side]
        thigh, calf, foot, ball = ("%s_%s" % (n, side) for n in ("thigh", "calf", "foot", "ball"))
        at = Vector(c["at"])
        root = self._from_parent("pelvis", self._head(thigh))
        # The knee goes where the foot points, a little out, unless told.
        turn = euler(*c.get("rot", (0, 0, 0)))
        hint = Vector(c["pole"]) if "pole" in c else turn @ Vector((-s * 0.08, -1.0, 0.0))
        self._two_bone(thigh, calf, foot, root, at, hint)
        self._set(foot, at, turn)
        self._set(ball, self._child_rigid(foot, ball).translation, turn @ euler(-c.get("toe", 0.0), 0, 0))

    def _fill_rest(self):
        """Every bone not posed rides its parent as it does at rest."""
        def walk(bone):
            if bone.name not in self.P:
                self.P[bone.name] = self._child_rigid(bone.parent.name, bone.name) if bone.parent else self.L[bone.name].copy()
            for child in bone.children:
                walk(child)
        for bone in self.bones:
            if bone.parent is None:
                walk(bone)

    def apply(self):
        """Writes self.P to the pose bones as local channels."""
        for bone in self.bones:
            pb = self.arm.pose.bones[bone.name]
            if bone.parent:
                rel = self.L[bone.parent.name].inverted() @ self.L[bone.name]
                pb.matrix_basis = rel.inverted() @ self.P[bone.parent.name].inverted() @ self.P[bone.name]
            else:
                pb.matrix_basis = self.L[bone.name].inverted() @ self.P[bone.name]
        bpy.context.view_layer.update()
