"""Bakes one human character from a recipe into a game-ready .glb.

    blender -b --factory-startup --python tools/characters/bake_character.py -- <recipe.json> <out.glb>

Needs MPFB2 (MakeHuman for Blender) enabled as bl_ext.user_default.mpfb, with the
faceunits01 and visemes02 target packs in MPFB's user data. Run Blender with
BLENDER_USER_RESOURCES pointing at the profile MPFB is installed in, which on
the dev PC is D:/PortablePrograms/mpfb_profile. Keep that path short: MPFB's
macro targets sit 137 characters deep inside it, and Blender's Python cannot
open a file past Windows' 260-character limit (a longer profile path fails as
soon as a recipe moves the proportions slider).

A recipe says what the character is, never how it is built:

    {
      "name": "hero",
      "macros": {"gender": 1.0, "age": 0.5, "muscle": 0.6, "weight": 0.5,
                 "height": 0.55, "proportions": 0.5,
                 "race": {"african": 0.2, "asian": 0.1, "caucasian": 0.7}},
      "targets": {"nose/nose-scale-horiz-incr|decr": 0.3}
    }

`macros` are MakeHuman's macro sliders, 0..1; anything left out keeps MakeHuman's
default. `targets` are optional detail targets by MakeHuman name, valued -1..1.

What comes out, every time:
- the body with its shape baked in: no slider shape keys, helper geometry gone;
- the game_engine rig, as "Armature", with bones named as the UAL animation
  library names them, so UAL1_Standard.glb's BoneMap retargets UAL clips onto
  it unchanged. It rests in an A-pose: the import also needs
  retarget/rest_fixer/fix_silhouette;
- the 52 ARKit face units and the Meta/Oculus visemes as blend shapes, at 0.
  The rig has no jaw or eye bones, so the face is driven by these alone.
"""
import json
import sys

import addon_utils
import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
recipe_path, out_path = argv[0], argv[1]
with open(recipe_path, encoding="utf-8") as f:
    recipe = json.load(f)

addon_utils.enable("bl_ext.user_default.mpfb", default_set=True)
from bl_ext.user_default.mpfb.services.exportservice import ExportService
from bl_ext.user_default.mpfb.services.faceservice import FaceService
from bl_ext.user_default.mpfb.services.humanservice import HumanService
from bl_ext.user_default.mpfb.services.targetservice import TargetService

if not FaceService.is_faceunits01_installed():
    sys.exit("bake_character: the faceunits01 target pack is not installed")

for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)

macros = TargetService.get_default_macro_info_dict()
for key, value in recipe.get("macros", {}).items():
    if key == "race":
        macros["race"].update(value)
    elif key in macros:
        macros[key] = float(value)
    else:
        sys.exit("bake_character: unknown macro '%s'" % key)

# scale 0.1: MakeHuman works in decimetres.
basemesh = HumanService.create_human(scale=0.1, macro_detail_dict=macros)
basemesh.name = recipe.get("name", "human")

for name, value in recipe.get("targets", {}).items():
    path = TargetService.target_full_path(name)
    if path is None:
        sys.exit("bake_character: no target called '%s'" % name)
    TargetService.load_target(basemesh, path, weight=float(value), name=name)

# The shape is the character: bake it so the only blend shapes left are the face.
TargetService.bake_targets(basemesh)

# The rig is fitted to the helper geometry, so it goes on before helpers go.
HumanService.add_builtin_rig(basemesh, "game_engine", import_weights=True)
FaceService.load_targets(basemesh, load_microsoft_visemes=False,
                         load_meta_visemes=True, load_arkit_faceunits=True)
ExportService.bake_modifiers_remove_helpers(basemesh, remove_helpers=True)

rig = basemesh.parent
# Named as the UAL library names its own: the same BoneMap and the same
# animation track paths (Armature/Skeleton3D:bone) then fit every character.
# Renaming a bone renames its vertex group with it.
rig.name = rig.data.name = "Armature"
for old, new in (("Root", "root"), ("head", "Head")):
    rig.data.bones[old].name = new
keys =basemesh.data.shape_keys.key_blocks if basemesh.data.shape_keys else []
print("BAKED", basemesh.name, "height %.3f m" % basemesh.dimensions.z,
      "verts", len(basemesh.data.vertices), "bones", len(rig.data.bones),
      "blend shapes", len(keys) - 1 if keys else 0)

bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB", export_apply=False,
                          export_animations=False, export_morph=True,
                          export_morph_normal=True)
print("WROTE", out_path)
