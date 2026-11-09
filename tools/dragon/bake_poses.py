# Bakes the clips in action_clips.py into actions, one track each.
# Every frame is solved from the rest pose; nothing is read from another clip.

import json

import bpy

import action_clips
import body_rig

FPS = 24


def _channels(arm):
    out = {}
    for pb in arm.pose.bones:
        base = 'pose.bones["%s"].' % pb.name
        for i, v in enumerate(pb.location):
            out[(base + "location", i)] = v
        for i, v in enumerate(pb.rotation_quaternion):
            out[(base + "rotation_quaternion", i)] = v
        for i, v in enumerate(pb.scale):
            out[(base + "scale", i)] = v
    return out


def _continuous(frames):
    """Flips quaternion signs so each bone's rotation never jumps hemispheres."""
    quats = {}
    for key in frames[0]:
        if key[0].endswith("rotation_quaternion"):
            quats.setdefault(key[0], []).append(key)
    for keys in quats.values():
        keys.sort(key=lambda k: k[1])
        for i in range(1, len(frames)):
            dot = sum(frames[i][k] * frames[i - 1][k] for k in keys)
            if dot < 0.0:
                for k in keys:
                    frames[i][k] = -frames[i][k]


def _action(arm, name, frames):
    """An action from [{(path, index): value}] per frame."""
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    slot = act.slots.new("OBJECT", arm.name)
    layer = act.layers.new("Layer")
    strip = layer.strips.new(type="KEYFRAME")
    bag = strip.channelbag(slot, ensure=True)
    for key in frames[0]:
        path, index = key
        fc = bag.fcurves.new(path, index=index)
        fc.keyframe_points.add(len(frames))
        co = []
        for i, fr in enumerate(frames):
            co += [float(i), fr[key]]
        fc.keyframe_points.foreach_set("co", co)
        for k in fc.keyframe_points:
            k.interpolation = "LINEAR"
        fc.update()
    act.use_frame_range = True
    act.frame_start = 0
    act.frame_end = len(frames) - 1
    return act


def _bake(arm, rig, name, clip):
    count = int(round(clip["length"] * FPS))
    frames = []
    for f in range(count + 1):  # a loop's last key repeats its first, so it closes
        rig.solve(clip["at"](f / count))
        rig.apply()
        frames.append(_channels(arm))
    _continuous(frames)
    return _action(arm, name, frames)


def bake(arm, body, clips):
    """clips maps an action name to an action_clips.CLIPS name. Returns the
    release/impact moments as {clip: {method: [seconds]}}, clip named as Godot
    imports it."""
    rig = body_rig.Rig(arm)
    deform = [m for m in body.modifiers if m.type == "ARMATURE"]
    for m in deform:
        m.show_viewport = False  # no skinning on every pose update while baking
    moments = {}
    actions = {}
    for name, source in clips.items():
        clip = action_clips.CLIPS[source]
        act = _bake(arm, rig, name, clip)
        actions[name] = act
        if clip.get("moments"):
            moments[name.removesuffix("-loop")] = {
                method: [round(f / FPS, 4) for f in frames] for method, frames in clip["moments"].items()}
        print("DRAGON baked", name, "from", source, int(act.frame_end) + 1, "frames")
    # Tracks go on last: a new one makes the next view layer update evaluate the
    # NLA over the pose just solved, and that frame would bake the wrong pose.
    for name, act in actions.items():
        track = arm.animation_data.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name, 0, act)
        strip.action_slot = act.slots[0]
    for m in deform:
        m.show_viewport = True
    return moments


def write_moments(path, moments):
    with open(path, "w", newline="\n") as fh:
        json.dump(moments, fh, indent=1, sort_keys=True)
        fh.write("\n")
