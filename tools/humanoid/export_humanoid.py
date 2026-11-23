# Bakes the approved clips onto the UAL skeleton: assets/humanoid/humanoid_clips.glb
# and the release/impact moments beside it. carry_clips.gd then puts them in
# the game's animation libraries.
#
#   blender -b -Y --python tools/humanoid/export_humanoid.py

import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# Appended, so the dragon's baker finds this folder's action_clips and body_rig.
sys.path.append(os.path.join(HERE, "..", "dragon"))
import bake_poses  # noqa: E402
import lab_setup as lab  # noqa: E402
from carried_clips import CARRIED  # noqa: E402

OUT_DIR = os.path.join(lab.PROJECT, "assets", "humanoid")

import action_clips  # noqa: E402

# Clips animated by hand (seed_hand_clips.py): their action in this .blend is
# the source, and the script's version of them is not baked.
HAND = os.path.join(OUT_DIR, "source", "hand_clips.blend")

arm, body, _rig = lab.open_mannequin()
hand = []
if os.path.exists(HAND):
    with bpy.data.libraries.load(HAND) as (src, dst):
        hand = [n for n in src.actions if n in CARRIED]
        dst.actions = list(hand)  # a copy: the loader swaps names for actions in place
moments = bake_poses.bake(arm, body, {name: name for name in CARRIED if name not in hand})
for name in hand:
    act = bpy.data.actions[name]
    act.use_fake_user = True
    track = arm.animation_data.nla_tracks.new()
    track.name = name
    strip = track.strips.new(name, int(act.frame_start), act)
    strip.action_slot = act.slots[0]
    timed = action_clips.CLIPS.get(name, {}).get("moments")
    if timed:  # the script's timings stand until the hand clip says otherwise
        moments[name] = {m: [round(f / bake_poses.FPS, 4) for f in fr] for m, fr in timed.items()}
    print("HAND", name, int(act.frame_start), "to", int(act.frame_end))
bake_poses.write_moments(os.path.join(OUT_DIR, "humanoid_clips_moments.json"), moments)
for o in bpy.data.objects:
    o.select_set(o in (arm, body))
bpy.ops.export_scene.gltf(
    filepath=os.path.join(OUT_DIR, "humanoid_clips.glb"),
    export_format="GLB",
    export_animations=True,
    export_animation_mode="ACTIONS",
    export_force_sampling=True,
    export_frame_step=1,
    export_skins=True,
    export_yup=True,
    export_apply=False,
    use_selection=True,
)
print("HUMANOID OK", len(bpy.data.actions), "fps", bpy.context.scene.render.fps)
