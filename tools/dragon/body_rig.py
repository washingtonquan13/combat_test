# A dragon pose as a physical description, solved onto the skeleton from its
# rest pose. No clip underneath: every bone is computed from where the body
# parts are said to be.
#
#   hip, chest      where the pelvis and the ribcage are
#   back, neck, tail  points the chain's curve passes through
#   head, look      where the skull is and where it faces
#   feet            where each paw stands; the legs reach it
#   wing            where each finger's two knuckles and tip are; the right
#                   wing mirrors the left unless wing_R is given
#   jaw, lip        degrees the mouth opens: lower jaw down, upper lip up
#   body            optional: the finished pose turned about `pivot` by `rot`
#                   (as chest_rot) and moved by `shift`, for a body on its side
#
# A wing is three fingers fanned from the shoulder, and it closes by bringing
# them together and zigzagging each: back from the shoulder, forward to the
# knuckle, back to the tip. The membrane goes slack between them. Wing points
# are written as if the chest were at rest, so the wing rides the ribcage. An
# open wing has no zigzag: `ups` gives the way each finger segment's top face
# looks instead.
#
# Numbers are Blender space at SM 0 (2 m nose to tail): +Z up, the dragon faces
# -Y, +X is its left. Nothing here names a clip, and the control names are what
# a replacement rig would have to map.

import math
import bpy
from mathutils import Matrix, Quaternion, Vector

SPINE = ["pelvic_2", "pelvic_1", "paunch"]
NECK = ["ACT_neck_4", "ACT_neck_3", "ACT_neck_2", "ACT_neck_1"]
TAIL = ["tail_1", "tail_2", "tail_3", "ik_ACT_tail_5"]
LEGS = {"Hand_L": ("upper_arm_L", "ik_underarm_L"), "Hand_R": ("upper_arm_R", "ik_underarm_R"),
        "back_food_L": ("Oberschenkel_L", "lowerleg_L"), "back_food_R": ("Oberschenkel_R", "lowerleg_R")}
# Each wing finger is shoulder, elbow, wrist segments.
WING_FINGERS = [("w1", "w2", "w3"), ("w4", "w5", "w6"), ("w7", "w8", "w9")]
# Which face of the membrane looks along the wing's `out` on each segment: a
# zigzag turns it over at each knuckle.
WING_FACE = (-1.0, 1.0, -1.0)


def normalize(arm, body, length=2.0):
    """The same size and centre export_dragon.py gives the model: rest pose,
    nose to tail `length` metres, torso centred on the origin."""
    if arm.animation_data:
        arm.animation_data.action = None
        for track in list(arm.animation_data.nla_tracks):
            arm.animation_data.nla_tracks.remove(track)
    bpy.context.view_layer.update()
    ys = [(body.matrix_world @ v.co).y for v in body.data.vertices]
    s = length / (max(ys) - min(ys))
    fore = (arm.matrix_world @ arm.data.bones["Hand_L"].head_local).y
    hind = (arm.matrix_world @ arm.data.bones["back_food_L"].head_local).y
    arm.location = (0.0, -(fore + hind) * 0.5 * s, 0.0)
    arm.scale = (s, s, s)
    for o in bpy.data.objects:
        o.select_set(o in (arm, body))
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.context.view_layer.update()


def _euler(pitch=0.0, yaw=0.0, roll=0.0):
    """Degrees: pitch dips the nose, yaw turns to its left, roll drops its left."""
    return (Quaternion((0, 0, 1), math.radians(-yaw))
            @ Quaternion((0, 1, 0), math.radians(roll))
            @ Quaternion((1, 0, 0), math.radians(pitch))).to_matrix()


def _frame(forward, up):
    """Orthonormal basis, forward as Y and `up` steering Z."""
    y = forward.normalized()
    x = y.cross(up).normalized()
    return Matrix((x, y, x.cross(y))).transposed()


def _catmull(points, per_span=48):
    pts = [points[0] * 2 - points[1]] + list(points) + [points[-1] * 2 - points[-2]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for k in range(per_span):
            t = k / per_span
            out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t))
    out.append(pts[-2].copy())
    return out


def _walk(curve, lengths):
    """Joints spaced by the bone lengths along a dense curve."""
    joints = [curve[0].copy()]
    i = 1
    for length in lengths:
        last = joints[-1]
        while i < len(curve) and (curve[i] - last).length < length:
            i += 1
        if i >= len(curve):
            prev = joints[-2] if len(joints) > 1 else last - Vector((0, 0, 1))
            joints.append(last + (last - prev).normalized() * length)
            continue
        a, b = curve[i - 1], curve[i]
        lo, hi = 0.0, 1.0
        for _ in range(24):
            mid = (lo + hi) * 0.5
            if (a.lerp(b, mid) - last).length < length:
                lo = mid
            else:
                hi = mid
        joints.append(a.lerp(b, lo))
    return joints


def _fabrik(joints, lengths, end, iterations=40):
    """Pulls a chain's tip onto `end`, base fixed, bone lengths kept."""
    start = joints[0].copy()
    if (end - start).length >= sum(lengths):
        d = (end - start).normalized()
        for i, length in enumerate(lengths):
            joints[i + 1] = joints[i] + d * length
        return joints
    for _ in range(iterations):
        joints[-1] = end.copy()
        for i in range(len(joints) - 2, -1, -1):
            joints[i] = joints[i + 1] + (joints[i] - joints[i + 1]).normalized() * lengths[i]
        joints[0] = start.copy()
        for i in range(len(joints) - 1):
            joints[i + 1] = joints[i] + (joints[i + 1] - joints[i]).normalized() * lengths[i]
    return joints


class Rig:
    def __init__(self, arm):
        self.arm = arm
        self.bones = arm.data.bones
        self.L = {b.name: b.matrix_local.copy() for b in self.bones}
        self.len = {b.name: b.length for b in self.bones}
        for pb in arm.pose.bones:
            pb.rotation_mode = "QUATERNION"
        self.P = {}

    def _head(self, name):
        return self.L[name].translation.copy()

    def _rest_rot(self, name):
        return self.L[name].to_3x3()

    def _dir(self, name):
        return (self.L[name].to_3x3() @ Vector((0, 1, 0))).normalized()

    def _set(self, name, at, delta):
        """Bone `name` with its head at `at`, turned from rest by `delta`."""
        m = (delta @ self._rest_rot(name)).to_4x4()
        m.translation = at
        self.P[name] = m

    def _tail(self, name):
        return self.P[name] @ Vector((0, self.len[name], 0))

    def _from_parent(self, parent, point):
        return self.P[parent] @ self.L[parent].inverted() @ point

    def _delta(self, name):
        return self.P[name].to_3x3() @ self._rest_rot(name).inverted()

    def _aim_chain(self, names, joints):
        for i, name in enumerate(names):
            d = joints[i + 1] - joints[i]
            self._set(name, joints[i], self._dir(name).rotation_difference(d).to_matrix())

    def solve(self, pose):
        """Fills self.P with every bone's armature-space matrix."""
        self.P = {}
        hip = Vector(pose["hip"])
        chest = Vector(pose["chest"])

        # Spine: pelvis to ribcage along the back's curve.
        lengths = [self.len[n] for n in SPINE]
        curve = _catmull([hip] + [Vector(p) for p in pose["back"]] + [chest])
        joints = _fabrik(_walk(curve, lengths), lengths, chest)
        self._aim_chain(SPINE, joints)
        chest_delta = _euler(*pose.get("chest_rot", (0, 0, 0)))
        self._set("breast", chest, chest_delta)

        # Neck: out of the ribcage along its curve, up to the base of the skull.
        base = self._tail("breast")
        skull = Vector(pose["head"])
        lengths = [self.len[n] for n in NECK]
        curve = _catmull([base] + [Vector(p) for p in pose["neck"]] + [skull])
        joints = _fabrik(_walk(curve, lengths), lengths, skull)
        self._aim_chain(NECK, joints)
        rest_forward = self._dir("IK_head")
        head_delta = _frame(Vector(pose["look"]), Vector(pose.get("head_up", (0, 0, 1)))) @ _frame(rest_forward, Vector((0, 0, 1))).inverted()
        self._set("head", self._tail("ACT_neck_1"), head_delta)
        self.P["IK_head"] = self._child_rigid("head", "IK_head")

        # Tail: a curve from the root of the pelvis.
        lengths = [self.len[n] for n in TAIL]
        joints = _walk(_catmull([hip] + [Vector(p) for p in pose["tail"]]), lengths)
        self._aim_chain(TAIL, joints)

        for side in "LR":
            self._wing(side, pose.get("wing_" + side) or pose["wing"])
        for foot, (upper, lower) in LEGS.items():
            self._leg(foot, upper, lower, pose["feet"][foot])
        for name, angle in (("Bone", pose.get("jaw", 0.0)), ("upper_lip", -pose.get("lip", 0.0))):
            at = self._child_rigid("IK_head", name).translation
            self._set(name, at, self._delta("IK_head") @ Matrix.Rotation(math.radians(angle), 3, "X"))
        self._fill_rest()
        b = pose.get("body")
        if b:
            pivot = Vector(b["pivot"])
            m = Matrix.Translation(pivot + Vector(b["shift"])) @ _euler(*b["rot"]).to_4x4() @ Matrix.Translation(-pivot)
            self.P = {n: m @ p for n, p in self.P.items()}
        return self.P

    def _child_rigid(self, parent, name):
        return self.P[parent] @ self.L[parent].inverted() @ self.L[name]

    def _wing(self, side, c):
        s = 1.0 if side == "L" else -1.0
        def mirrored(p):
            return Vector((s * p[0], p[1], p[2]))
        centre = "w_C_" + side
        self.P[centre] = self._child_rigid("breast", centre)
        out = mirrored(c["out"]).normalized()
        ups = c.get("ups")
        for k, (finger, points) in enumerate(zip(WING_FINGERS, c["fingers"])):
            names = [n + "_" + side for n in finger]
            joints = [self._from_parent(centre, self._head(names[0]))]
            joints += [self._from_parent("breast", mirrored(p)) for p in points]
            lengths = [self.len[n] for n in names]
            joints = _fabrik(joints, lengths, joints[-1])
            for i, name in enumerate(names):
                rest_dir = self._dir(name)
                rest_up = Vector((0, 0, 1))
                rest_up = (rest_up - rest_dir * rest_up.dot(rest_dir)).normalized()
                new_dir = (joints[i + 1] - joints[i]).normalized()
                up = self._delta("breast") @ mirrored(ups[k][i]) if ups else out * WING_FACE[i]
                self._set(name, joints[i], _frame(new_dir, up) @ _frame(rest_dir, rest_up).inverted())

    def _leg(self, foot, upper, lower, c):
        at = Vector(c["at"])
        parent = self.bones[upper].parent.name
        root = self._from_parent(parent, self._head(upper))
        a, b = self.len[upper], self.len[lower]
        to = at - root
        d = max(min(to.length, (a + b) * 0.9995), abs(a - b) * 1.001)
        forward = to.normalized()
        # The knee or elbow bends the way it does at rest, or toward `pole`.
        joint_rest = self._head(lower)
        rest_root = self._head(upper)
        rest_axis = (self._head(foot) - rest_root).normalized()
        rest_bend = joint_rest - rest_root
        rest_bend = (rest_bend - rest_axis * rest_bend.dot(rest_axis)).normalized()
        hint = Vector(c["pole"]) if "pole" in c else self._delta(parent) @ rest_bend
        bend = (hint - forward * hint.dot(forward)).normalized()
        along = (a * a - b * b + d * d) / (2.0 * d)
        out = math.sqrt(max(a * a - along * along, 0.0))
        joint = root + forward * along + bend * out
        tip = root + forward * d

        def turn(name, new_dir):
            rest_dir = self._dir(name)
            rest_up = (rest_bend - rest_dir * rest_bend.dot(rest_dir)).normalized()
            new_up = (bend - new_dir.normalized() * bend.dot(new_dir.normalized())).normalized()
            return _frame(new_dir, new_up) @ _frame(rest_dir, rest_up).inverted()

        self._set(upper, root, turn(upper, joint - root))
        self._set(lower, joint, turn(lower, tip - joint))
        self._set(foot, at, _euler(*c.get("rot", (0, 0, 0))))

    def _fill_rest(self):
        """Every bone not posed rides its parent as it does at rest."""
        def walk(bone):
            if bone.name not in self.P:
                if bone.parent:
                    self.P[bone.name] = self._child_rigid(bone.parent.name, bone.name)
                else:
                    self.P[bone.name] = self.L[bone.name].copy()
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
