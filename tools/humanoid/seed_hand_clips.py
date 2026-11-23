# Starts hand-animated clips: bakes scripted clips into
# assets/humanoid/source/hand_clips.blend as ordinary keyframed actions on the
# game's rig, thinned to the keys a person would set, for polishing by hand in
# Blender. From then on the .blend is the clip's source: export_humanoid.py
# bakes any CARRIED clip found there from its action, not from the script.
#
#   blender -b -Y --python tools/humanoid/seed_hand_clips.py -- Hover Fly_Fwd Takeoff Land
#
# Refuses a clip the .blend already has, so hand work is never overwritten;
# delete the action in Blender first to reseed it, or pass --replace when the
# script's version is meant to win over what is there.
#
# Also keeps the golden poses (golden_poses.py) in the .blend as one-frame
# pose actions, "Pose_<name>", marked as assets for the Pose Library, under
# the same rule.

import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.append(os.path.join(HERE, "..", "dragon"))
import action_clips  # noqa: E402
import body_rig  # noqa: E402
from golden_poses import GOLDEN  # noqa: E402
import lab_setup as lab  # noqa: E402

FPS = 24
BLEND = os.path.join(lab.PROJECT, "assets", "humanoid", "source", "hand_clips.blend")
# How far a thinned curve may stray from the bake: radians for quaternion
# parts, metres for the hips. About a fifth of a degree.
TOLERANCE = 0.002

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
REPLACE = "--replace" in ARGS
NAMES = [a for a in ARGS if a != "--replace"]


def _keep(values, tol):
    """Frames to key so straight lines between them stay within tol of every
    frame (Ramer-Douglas-Peucker). Bezier handles then round the corners."""
    keep = {0, len(values) - 1}
    stack = [(0, len(values) - 1)]
    while stack:
        a, b = stack.pop()
        worst, at = 0.0, None
        for i in range(a + 1, b):
            line = values[a] + (values[b] - values[a]) * (i - a) / (b - a)
            d = abs(values[i] - line)
            if d > worst:
                worst, at = d, i
        if at is not None and worst > tol:
            keep.add(at)
            stack += [(a, at), (at, b)]
    return sorted(keep)


def _channels(arm):
    out = {}
    for pb in arm.pose.bones:
        base = 'pose.bones["%s"].' % pb.name
        out.update({(base + "location", i): v for i, v in enumerate(pb.location)})
        out.update({(base + "rotation_quaternion", i): v for i, v in enumerate(pb.rotation_quaternion)})
    return out


def _continuous(frames):
    """No quaternion jumps to the other hemisphere between frames."""
    bones = {k[0] for k in frames[0] if k[0].endswith("rotation_quaternion")}
    for path in bones:
        keys = [(path, i) for i in range(4)]
        for i in range(1, len(frames)):
            if sum(frames[i][k] * frames[i - 1][k] for k in keys) < 0.0:
                for k in keys:
                    frames[i][k] = -frames[i][k]


def _pose_action(arm, rig, name):
    """One golden pose as a one-frame action, for the Pose Library."""
    rig.solve(GOLDEN[name])
    rig.apply()
    act = bpy.data.actions.new("Pose_" + name)
    slot = act.slots.new("OBJECT", arm.name)
    bag = act.layers.new("Layer").strips.new(type="KEYFRAME").channelbag(slot, ensure=True)
    for (path, i), v in _channels(arm).items():
        fc = bag.fcurves.new(path, index=i, group_name=path.split('"')[1])
        fc.keyframe_points.insert(0.0, v, options={"FAST"})
    act.use_frame_range = True
    act.frame_start = act.frame_end = 0
    act.asset_mark()
    print("POSE", act.name)


def _seed(arm, rig, name):
    clip = action_clips.CLIPS[name]
    count = int(round(clip["length"] * FPS))
    frames = []
    for f in range(count + 1):
        rig.solve(clip["at"](f / count))
        rig.apply()
        frames.append(_channels(arm))
    _continuous(frames)
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    slot = act.slots.new("OBJECT", arm.name)
    bag = act.layers.new("Layer").strips.new(type="KEYFRAME").channelbag(slot, ensure=True)
    keys = 0
    for key in frames[0]:
        values = [fr[key] for fr in frames]
        if max(values) - min(values) < 1e-5 and not key[0].endswith("rotation_quaternion"):
            continue  # a bone that never moves there: rest, no curve to clutter
        fc = bag.fcurves.new(key[0], index=key[1], group_name=key[0].split('"')[1])
        for i in _keep(values, TOLERANCE):
            k = fc.keyframe_points.insert(float(i), values[i], options={"FAST"})
            k.interpolation = "BEZIER"
            k.handle_left_type = k.handle_right_type = "AUTO_CLAMPED"
        if clip.get("loop"):
            fc.modifiers.new("CYCLES")  # the curve wraps, so the seam eases too
        fc.update()
        keys += len(fc.keyframe_points)
    act.use_frame_range = True
    act.frame_start, act.frame_end = 0, count
    act.use_cyclic = bool(clip.get("loop"))
    print("SEEDED", name, count + 1, "frames,", keys, "keys")
    return act


def main():
    if os.path.exists(BLEND):
        bpy.ops.wm.open_mainfile(filepath=BLEND)
        arm = bpy.data.objects["Armature"]
    else:
        arm, body, _ = lab.open_mannequin()
        _stage(arm)
    have = {a.name for a in bpy.data.actions}
    rig = body_rig.Rig(arm)
    rest = {pb.name: (pb.location.copy(), pb.rotation_quaternion.copy()) for pb in arm.pose.bones}
    held = arm.animation_data.action.name if arm.animation_data.action else None
    arm.animation_data.action = None
    for name in NAMES:
        if name in have:
            if not REPLACE:
                print("SKIPPED", name, "already in the .blend; delete it there or pass --replace")
                continue
            bpy.data.actions.remove(bpy.data.actions[name])
            print("REPLACING", name)
        _seed(arm, rig, name)
    for name in GOLDEN:
        old = bpy.data.actions.get("Pose_" + name)
        if old and not REPLACE:
            continue
        if old:
            bpy.data.actions.remove(old)
        _pose_action(arm, rig, name)
    for pb in arm.pose.bones:
        pb.location, pb.rotation_quaternion = rest[pb.name]
    first = bpy.data.actions.get(held or "") or next((a for a in bpy.data.actions if a.name in NAMES), None)
    if first:
        arm.animation_data.action = first
        arm.animation_data.action_slot = first.slots[0]
        bpy.context.scene.frame_end = int(first.frame_end)
    os.makedirs(os.path.dirname(BLEND), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND, compress=True)
    print("SAVED", BLEND)


def _stage(arm):
    """Floor, light and 24 fps, so the file opens ready to animate."""
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.frame_start = 0
    bpy.ops.mesh.primitive_plane_add(size=6.0, location=(0, 0, 0))
    bpy.context.active_object.name = "Floor"
    bpy.context.active_object.hide_select = True
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (0.7, 0.2, 0.6)
    scene.collection.objects.link(sun)
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"


main()
