"""MPFB's own T-pose, made the rig's rest.

MPFB's rig rests in MakeHuman's A-pose: arms down at 45 degrees, elbows bent.
Mixamo's rest is a T-pose, and so is Godot's humanoid profile; a clip carried
between the two has to guess what the gap means (how far a forearm rolls,
which way an elbow hinges), and those guesses showed as twisted elbows and
drooped shoulders.

The bake uses MPFB's "mixamo_unity" rig because MPFB ships a T-pose for it
(data/poses/mixamo_unity_fk/t-pose.json, written for that rig's bones and
weights; it turns the collarbones, arms, forearms, thighs and feet). apply()
loads it with MPFB's own RigService, as its "Load pose" button does, then
makes it the rest. MPFB's "Apply as rest pose" applies the armature
modifier, which Blender refuses on a mesh with shape keys (the face's), so
that step is done here: each bound mesh, and each of its shape keys, is moved
to where the armature puts it, then the pose is applied as the rest.

    import tpose; tpose.apply(rig)   # from bake_character.py
"""
import json
import os
import sys

import bpy
from mathutils import Matrix

from bl_ext.user_default.mpfb.services.locationservice import LocationService
from bl_ext.user_default.mpfb.services.rigservice import RigService

PREFIX = "mixamorig:"
RIG = "mixamo_unity"


def _pose():
    """MPFB's T-pose for the rig, its bone names less the prefix the bake strips."""
    path = os.path.join(LocationService.get_mpfb_data("poses"), RIG + "_fk", "t-pose.json")
    with open(path, encoding="utf-8") as f:
        pose = json.load(f)
    for key in ("bone_rotations", "bone_translations", "bone_rotation_modes"):
        if key in pose:
            pose[key] = {k[len(PREFIX):] if k.startswith(PREFIX) else k: v for k, v in pose[key].items()}
    return pose


def _bound_meshes(rig):
    return [o for o in bpy.data.objects if o.type == "MESH"
            and any(m.type == "ARMATURE" and m.object is rig for m in o.modifiers)]


def _bake_pose_into(obj):
    """Moves `obj`'s vertices, and each of its shape keys, to where its
    armature puts them now, so the pose can become the rest."""
    deps = bpy.context.evaluated_depsgraph_get()
    n = len(obj.data.vertices)
    # Only the armature moves it here; the rest (a subdivision MPFB puts on
    # clothes, masks) stay as they were and apply on top as before.
    others = [(m, m.show_viewport) for m in obj.modifiers if m.type != "ARMATURE"]
    for m, _ in others:
        m.show_viewport = False
    try:
        return _bake_evaluated(obj, deps, n)
    finally:
        for m, shown in others:
            m.show_viewport = shown


def _bake_evaluated(obj, deps, n):

    def evaluated():
        deps.update()
        ev = obj.evaluated_get(deps)
        mesh = ev.to_mesh()
        if len(mesh.vertices) != n:
            sys.exit("tpose: %s evaluates to %d vertices, not %d (a modifier other than the armature?)"
                     % (obj.name, len(mesh.vertices), n))
        co = [0.0] * (n * 3)
        mesh.vertices.foreach_get("co", co)
        ev.to_mesh_clear()
        return co

    keys = obj.data.shape_keys.key_blocks if obj.data.shape_keys else []
    if not keys:
        obj.data.vertices.foreach_set("co", evaluated())
        obj.data.update()
        return 0
    # Each key on its own, at full strength, unmasked: skinning is linear, so
    # the posed key less the posed basis is the key's offset in the pose.
    saved = [(k.value, k.vertex_group, k.mute) for k in keys]
    obj.show_only_shape_key = False
    for k in keys:
        k.value, k.vertex_group, k.mute = 0.0, "", False
    moved = [evaluated()]
    for k in keys[1:]:
        k.value = 1.0
        moved.append(evaluated())
        k.value = 0.0
    for k, co in zip(keys, moved):
        k.data.foreach_set("co", co)
    obj.data.vertices.foreach_set("co", moved[0])
    for k, (value, group, mute) in zip(keys, saved):
        k.value, k.vertex_group, k.mute = value, group, mute
    obj.data.update()
    return len(keys) - 1


def apply(rig):
    """Poses `rig` in MPFB's T-pose, bakes the pose into every mesh bound to
    it, and makes it the rest."""
    pose = _pose()
    missing = [b for b in pose["bone_rotations"] if b not in rig.pose.bones]
    if missing:
        sys.exit("tpose: the rig lacks %s" % missing)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="POSE")
    RigService.set_pose_from_dict(rig, pose)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()
    for obj in _bound_meshes(rig):
        print("TPOSE baked", obj.name, "shape keys", _bake_pose_into(obj))
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="POSE")
    bpy.ops.pose.armature_apply(selected=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    print("TPOSE rig rests in MPFB's T-pose (%d bones turned)" % len(pose["bone_rotations"]))
