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

arm, body, _rig = lab.open_mannequin()
moments = bake_poses.bake(arm, body, {name: name for name in CARRIED})
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
