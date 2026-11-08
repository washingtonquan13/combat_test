# Bakes the clips in poses.py into actions, replacing whatever held the name.
# Every frame is solved from the rest pose; nothing is read from another clip.

import bpy

import body_rig
import dragon_clips
import poses


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


def _bake(arm, rig, name, clip):
    count = int(round(clip["length"] * dragon_clips.FPS))
    frames = []
    for f in range(count + 1):  # the last key repeats the first, so the loop closes
        rig.solve(clip["at"](f / count))
        rig.apply()
        frames.append(_channels(arm))
    dragon_clips._continuous(frames)
    return dragon_clips._action(arm, name, frames)


def replace(arm, body, clips):
    """clips maps an action name to a poses.CLIPS name. The action keeps its NLA track's place."""
    rig = body_rig.Rig(arm)
    deform = [m for m in body.modifiers if m.type == "ARMATURE"]
    for m in deform:
        m.show_viewport = False  # no skinning on every pose update while baking
    for name, source in clips.items():
        for track in list(arm.animation_data.nla_tracks):
            if track.name == name:
                arm.animation_data.nla_tracks.remove(track)
        old = bpy.data.actions.get(name)
        if old:
            bpy.data.actions.remove(old)
        act = _bake(arm, rig, name, poses.CLIPS[source])
        track = arm.animation_data.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name, 0, act)
        strip.action_slot = act.slots[0]
        print("DRAGON baked", name, "from", source, int(act.frame_end) + 1, "frames")
    for m in deform:
        m.show_viewport = True
