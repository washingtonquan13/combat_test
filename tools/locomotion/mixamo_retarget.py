"""Mixamo clips onto the game's humanoid rig, for tools/locomotion/land_mixamo.gd.

    blender -b --factory-startup --python tools/locomotion/mixamo_retarget.py

Reads the Mixamo FBX takes in CLIPS (downloaded "Without Skin", 30 fps, from
SOURCE) and writes tools/locomotion/takes/mixamo.glb: the proof hero's own
skeleton (imported from its baked .glb, so the rest is the game's to the bit)
with one action per clip, and no mesh. The clips keep their travel and turn;
land_mixamo.gd bakes them in place.

The hero is on MPFB's "mixamo_unity" rig (tools/characters/bake_character.py),
Mixamo's own bones by name (the extra jaw, eye, breast and buttock bones have
no source and follow their parents), so each bone takes its source bone's
motion by name. How each one takes it depends on why its rest differs from
the source's:

  the limbs           differ a little by POSE: both rest in a T (the hero in
                      MPFB's T-pose, tools/characters/tpose.py), but the
                      hero's arms sit ~4 deg, its forearms ~8 deg and its
                      hands ~12 deg off Mixamo's, and MakeHuman's fingers rest
                      curled (20-40 deg). Each is laid so its head -> child-head
                      line runs along the source's, and takes the source's
                      turn from there.
  BUILD (spine, pelvis, neck, head, clavicles, feet, toes)
                      differ by BUILD (the hero's S-curved spine, sloped
                      clavicles, low ankle): each takes the source's turn away
                      from its rest on the hero's own rest. Laying these along
                      the source would put the Y Bot's body on the hero
                      (shrugged shoulders, a straight back, toes down).

No posture correction: what the mocap did is what plays. The hips' path is
scaled by leg (hip height) and dropped so the lower ankle on the first frame
stands at the rest's height. Each clip prints its worst limb-direction and
bone-turn error against the source (both 0.0 when right), its lowest toe and
its loop seam.
"""
import bpy, math, os
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
HERO = os.path.join(HERE, "..", "..", "assets", "characters", "proof_hero", "proof_hero.glb")
OUT = os.path.join(HERE, "takes", "mixamo.glb")
PACK = "D:/ai_motion/mixamo/locomotion_pack/"
STARTS = "D:/ai_motion/mixamo/starts_stops/"
# game clip name: (Mixamo file, played mirrored). The Locomotion Pack's loops
# and turns; Standing Idle, Start Walking, Stop Walking and Run To Stop, each
# stop also mirrored so there is one off either foot.
CLIPS = {
    "idle": (STARTS + "standing idle", False),
    "walk": (PACK + "walking", False),
    "run": (PACK + "running", False),
    "turn_l90": (PACK + "left turn 90", False),
    "turn_r90": (PACK + "right turn 90", False),
    "turn_l180": (PACK + "left turn", False),
    "turn_r180": (PACK + "right turn", False),
    "walk_start": (STARTS + "start walking", False),
    "walk_stop_a": (STARTS + "stop walking", False),
    "walk_stop_b": (STARTS + "stop walking", True),
    "run_stop_a": (STARTS + "run to stop", False),
    "run_stop_b": (STARTS + "run to stop", True),
}
# LADDER=1: the three ladder takes instead (Mixamo "Start Climbing Ladder",
# "Climbing Ladder", "Climbing To Top"), into their own glb for
# tools/locomotion/land_ladder.gd. Its baking finds the rungs from the hands
# and feet, so the first-frame drop below does not matter to it.
LADDER = os.environ.get("LADDER") == "1"
if LADDER:
    OUT = os.path.join(HERE, "takes", "mixamo_ladder.glb")
    LADDER_DIR = os.environ.get("LADDER_DIR", "D:/BrowserDownloads/")
    CLIPS = {
        "ladder_start": (LADDER_DIR + "Start Climbing Ladder", False),
        "ladder_up": (LADDER_DIR + "Climbing Ladder", False),
        "ladder_top": (LADDER_DIR + "Climbing To Top", False),
    }

P = "mixamorig:"
# the child that sets a bone's direction where it has several (or none, in the target)
AIM = {"Hips": "Spine", "Spine2": "Neck", "LeftHand": "LeftHandMiddle1", "RightHand": "RightHandMiddle1",
       "Head": "HeadTop_End", "LeftToeBase": "LeftToe_End", "RightToeBase": "RightToe_End"}
BUILD = {"Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "LeftShoulder", "RightShoulder",
         "LeftFoot", "RightFoot", "LeftToeBase", "RightToeBase"}

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.import_scene.gltf(filepath=HERO, bone_heuristic="BLENDER")
A = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
for o in [o for o in bpy.data.objects if o is not A]:
    bpy.data.objects.remove(o, do_unlink=True)
for act in list(bpy.data.actions):
    bpy.data.actions.remove(act)
bpy.context.scene.render.fps = 30
BONES = [b.name for b in A.data.bones]           # parents before children
PARENT = {b.name: (b.parent.name if b.parent else None) for b in A.data.bones}
REST = {b.name: A.matrix_world @ b.matrix_local for b in A.data.bones}


def aim_of(name, kids):
    """The source bone (prefixed) that sets source bone `name`'s line."""
    s = name[len(P):]
    if s in AIM:
        return P + AIM[s]
    if s[-1] == "3" and "Hand" in s:            # finger tips: the source's _4 end bone
        return name[:-1] + "4"
    return kids[0] if len(kids) == 1 else None


def laid_rest(s_rest, aim):
    """Each target bone's rest turn, laid along the source's line for a limb."""
    T = {}
    for b in BONES:
        R = REST[b].to_3x3().normalized()
        k = aim.get(P + b)
        if b not in BUILD and P + b in s_rest and k in s_rest:
            want = (s_rest[k].translation - s_rest[P + b].translation).normalized()
            tk = k[len(P):]
            have = (REST[tk].translation - REST[b].translation).normalized() if tk in REST else R.col[1].normalized()
            R = have.rotation_difference(want).to_matrix() @ R
        T[b] = R
    return T


def swap(name):
    """The bone's other-side twin ("LeftHand" <-> "RightHand")."""
    if "Left" in name:
        return name.replace("Left", "Right")
    return name.replace("Right", "Left")


FLIP = Matrix.Diagonal((-1.0, 1.0, 1.0))          # across the source's middle (its x is to the side)
FLIP4 = Matrix.Diagonal((-1.0, 1.0, 1.0, 1.0))


def retarget(fbx, action, mirror=False):
    before, acts = set(bpy.data.objects), set(bpy.data.actions)
    bpy.ops.import_scene.fbx(filepath=fbx, automatic_bone_orientation=False, ignore_leaf_bones=False)
    new = [o for o in bpy.data.objects if o not in before]
    src = next(o for o in new if o.type == 'ARMATURE')
    s_rest = {b.name: src.matrix_world @ b.matrix_local for b in src.data.bones}
    aim = {b.name: aim_of(b.name, [c.name for c in b.children]) for b in src.data.bones}
    T = laid_rest(s_rest, aim)
    s_inv = {n: m.to_3x3().normalized().inverted() for n, m in s_rest.items()}
    scale = REST["Hips"].translation.z / s_rest[P + "Hips"].translation.z
    side = s_rest[P + "LeftUpLeg"].translation - s_rest[P + "RightUpLeg"].translation
    assert not mirror or abs(side.x) > 10 * max(abs(side.y), abs(side.z)), "the source's side is not along x"

    a, z = map(int, src.animation_data.action.frame_range)
    sc = bpy.context.scene
    frames, src_dirs = [], []
    for f in range(a, z + 1):
        sc.frame_set(f)
        bpy.context.view_layer.update()
        Mw = {n: src.matrix_world @ src.pose.bones[n].matrix for n in s_rest}
        G = {n[len(P):]: Mw[n].to_3x3().normalized() @ s_inv[n] for n in s_rest}
        if mirror:                               # across the body's middle: the other side's turn, x flipped
            G = {n: FLIP @ G[swap(n)] @ FLIP for n in G}
            Mw = {n: FLIP4 @ Mw[swap(n)] for n in Mw}
        frames.append((G, Mw[P + "Hips"].translation.copy()))
        src_dirs.append({b: (Mw[aim[P + b]].translation - Mw[P + b].translation).normalized()
                         for b in BONES if b not in BUILD and aim.get(P + b) in Mw and aim[P + b][len(P):] in REST})
    for o in new:
        bpy.data.objects.remove(o, do_unlink=True)
    for x in [x for x in bpy.data.actions if x not in acts]:
        bpy.data.actions.remove(x)

    # world matrices of every target bone, every frame; travel kept, hips scaled by leg
    h0 = frames[0][1]
    out = []
    for G, hip in frames:
        h = hip - Vector((h0.x, h0.y, 0.0))
        hip_w = Vector((h.x * scale + REST["Hips"].translation.x, h.y * scale + REST["Hips"].translation.y, h.z * scale))
        W = {}
        for b in BONES:
            p = PARENT[b]
            if p is None:                        # the game's root bone: stays at rest
                W[b] = REST[b].copy()
                continue
            rel = REST[p].inverted() @ REST[b]
            M = (G[b] @ T[b]).to_4x4() if b in G else (W[p].to_3x3() @ rel.to_3x3()).to_4x4()
            M.translation = hip_w if b == "Hips" else (W[p] @ rel).translation
            W[b] = M
        out.append(W)
    drop = min(out[0]["LeftFoot"].translation.z, out[0]["RightFoot"].translation.z) - REST["LeftFoot"].translation.z
    for W in out:
        for b in W:
            if PARENT[b] is not None:
                W[b].translation.z -= drop

    act = bpy.data.actions.new(action)
    act.use_fake_user = True
    if A.animation_data is None:
        A.animation_data_create()
    A.animation_data.action = act
    last = {}
    for f, W in enumerate(out):
        for b in BONES:
            p = PARENT[b]
            rest_rel = (A.matrix_world.inverted() @ REST[b]) if p is None else (REST[p].inverted() @ REST[b])
            pose_rel = (A.matrix_world.inverted() @ W[b]) if p is None else (W[p].inverted() @ W[b])
            loc, rot, _ = (rest_rel.inverted() @ pose_rel).decompose()
            if b in last and last[b].dot(rot) < 0.0:
                rot.negate()
            last[b] = rot.copy()
            pb = A.pose.bones[b]
            pb.rotation_mode = 'QUATERNION'
            pb.rotation_quaternion = rot
            pb.keyframe_insert("rotation_quaternion", frame=f)
            if b == "Hips":
                pb.location = loc
                pb.keyframe_insert("location", frame=f)
    return measure(out, src_dirs, aim, frames, T)


def measure(out, src_dirs, aim, frames, T):
    """Played back from the keyed action: the worst angle between any limb's line
    and the source's, the worst full turn of any bone against the source's turn
    from rest, the lowest toe, and how far the last frame's pose is from the first."""
    sc = bpy.context.scene
    worst = tw = 0.0
    toes = []
    for f, sd in enumerate(src_dirs):
        sc.frame_set(f)
        bpy.context.view_layer.update()
        G = frames[f][0]
        for b in BONES:
            if b in G:
                have = ((A.matrix_world @ A.pose.bones[b].matrix).to_3x3().normalized() @ T[b].inverted()).to_quaternion()
                e = math.degrees(have.rotation_difference(G[b].to_quaternion()).angle)
                tw = max(tw, min(e, 360.0 - e))
        for b, d in sd.items():
            t = (A.matrix_world @ A.pose.bones[aim[P + b][len(P):]].head) - (A.matrix_world @ A.pose.bones[b].head)
            if t.length > 0:
                worst = max(worst, math.degrees(t.normalized().angle(d)))
        toes.append(min((A.matrix_world @ A.pose.bones[s + "ToeBase"].head).z for s in ("Left", "Right")))
    first, end = out[0], out[-1]
    hips = end["Hips"].translation - first["Hips"].translation
    seam = max(((first[k].translation - first["Hips"].translation) - (end[k].translation - end["Hips"].translation)).length
               for k in ("Head", "LeftHand", "RightHand", "LeftFoot", "RightFoot"))
    return "%3d frames  limb dir %.3f deg  bone turn %.3f deg  toe %+d mm  travel %.2f m  seam %d mm" % (
        len(out), worst, tw, round((min(toes) - REST["LeftToeBase"].translation.z) * 1000),
        Vector((hips.x, hips.y)).length, round(seam * 1000))


for name, (fbx, mirror) in CLIPS.items():
    print("CLIP %-11s %s" % (name, retarget(fbx + ".fbx", name, mirror)))
A.animation_data.action = None
for b in A.pose.bones:
    b.rotation_quaternion = (1, 0, 0, 0)
    b.location = (0, 0, 0)
bpy.ops.object.select_all(action='DESELECT')
A.select_set(True)
bpy.context.view_layer.objects.active = A
os.makedirs(os.path.dirname(OUT), exist_ok=True)
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True, export_animations=True,
                          export_animation_mode="ACTIONS", export_force_sampling=True, export_skins=True,
                          export_def_bones=False, export_reset_pose_bones=True)
print("WROTE", OUT)
