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
      "targets": {"nose/nose-scale-horiz-incr|decr": 0.3},
      "parts": {"nose": "lee", "ears": ["lee", 0.7]},
      "skin": "young_caucasian_male",
      "eyes": "brown",
      "eyebrows": "eyebrow001",
      "hair": "short02",
      "clothes": ["male_casualsuit01", "shoes01"]
    }

`macros` are MakeHuman's macro sliders, 0..1; anything left out keeps MakeHuman's
default. `targets` are optional detail targets by MakeHuman name, valued -1..1.
`parts` are face parts cut from head scans by bake_scan_parts.py: a part
(nose, mouth, chin, cheeks, brow, ears, skull) from a scan under
tools/characters/parts/, whole or at an amount. They go on over the macros and
targets, so the face is MPFB's with those features swapped in.
The rest name assets from the MakeHuman system assets pack (CC0), installed in
MPFB's user data: `skin` a folder under skins/, `eyes` an eye colour under
eyes/materials/, the others a folder under their own kind. A face is always
whole: eyes, eyebrows, eyelashes, teeth and tongue fall back to a default when
left out ("eyebrows": null leaves brows off); `skin`, `hair` and `clothes` are
only there when asked for. Clothes hide the body under them by deleting it.

What comes out, every time:
- the body with its shape baked in: no slider shape keys, helper geometry gone;
- the game_engine rig, as "Armature", with bones named as the UAL animation
  library names them, so UAL1_Standard.glb's BoneMap retargets UAL clips onto
  it unchanged. It rests in an A-pose: the import also needs
  retarget/rest_fixer/fix_silhouette;
- the 52 ARKit face units and the Meta/Oculus visemes as blend shapes, at 0,
  carried over onto the brows, lashes, teeth and tongue so a blink or a jaw
  drop moves them too. The rig has no jaw or eye bones, so the face is driven
  by these alone;
- every part with a game-engine material (Principled BSDF and image
  textures), which glTF carries as standard PBR;
- when tools/characters/grooms/<hair>.json exists, the hair as cards grown by
  groom.py in place of MakeHuman's painted shell (the shell stays, hidden in
  game, for the outline), and <out>_scalp.png beside the .glb: where the hair
  grows, for the skin shader.
"""
import json
import os
import sys

import addon_utils
import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
recipe_path, out_path = argv[0], argv[1]
with open(recipe_path, encoding="utf-8") as f:
    recipe = json.load(f)

addon_utils.enable("bl_ext.user_default.mpfb", default_set=True)
from bl_ext.user_default.mpfb.services.assetservice import AssetService
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

parts_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "parts")
for part, source in recipe.get("parts", {}).items():
    source, amount = (source, 1.0) if isinstance(source, str) else source
    path = os.path.join(parts_dir, source, part + ".target")
    if not os.path.exists(path):
        sys.exit("bake_character: no part '%s' from '%s'" % (part, source))
    TargetService.load_target(basemesh, path, weight=float(amount), name="part-%s-%s" % (source, part))

# The shape is the character: bake it so the only blend shapes left are the face.
TargetService.bake_targets(basemesh)

# The rig is fitted to the helper geometry, so it goes on before helpers go.
HumanService.add_builtin_rig(basemesh, "game_engine", import_weights=True)


def asset_file(kind, name, ext):
    path = AssetService.find_asset_absolute_path("%s/%s.%s" % (name, name, ext), kind)
    if path is None:
        sys.exit("bake_character: no %s called '%s'" % (kind, name))
    return path


def mhclo_uuid(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("uuid "):
                return line.split()[1]
    return None


# Parts that draw with alpha. The game-engine material wires every texture's
# alpha into the shader, which glTF exports as alpha BLEND; on skin and cloth
# that only buys sorting trouble, so everything else is made opaque.
SEE_THROUGH = {"eyes", "eyebrows", "eyelashes", "hair"}


def make_opaque(obj):
    for mat in obj.data.materials:
        if not mat or not mat.node_tree:
            continue
        for node in mat.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED":
                for link in list(node.inputs["Alpha"].links):
                    mat.node_tree.links.remove(link)
                node.inputs["Alpha"].default_value = 1.0


def add_part(kind, name, path=None, material=None):
    path = path or asset_file(kind, name, "mhclo")
    alternatives = {mhclo_uuid(path): material} if material else None
    # subdiv 0: a game mesh carries its own resolution. The part is fitted to
    # the baked shape and weighted to the rig, so it deforms with the body.
    part = HumanService.add_mhclo_asset(path, basemesh, asset_type=kind.capitalize(),
                                        subdiv_levels=0, material_type="GAMEENGINE",
                                        alternative_materials=alternatives)
    if kind not in SEE_THROUGH:
        make_opaque(part)
    return part


if recipe.get("skin"):
    HumanService.set_character_skin(asset_file("skins", recipe["skin"], "mhmat"),
                                    basemesh, skin_type="GAMEENGINE")
    make_opaque(basemesh)

FACE_DEFAULTS = {"eyebrows": "eyebrow001", "eyelashes": "eyelashes01",
                 "teeth": "teeth_base", "tongue": "tongue01"}
eye_colour = recipe.get("eyes", "brown")
if eye_colour:
    add_part("eyes", "high-poly", material="materials/%s.mhmat" % eye_colour)
for kind, default in FACE_DEFAULTS.items():
    if recipe.get(kind, default):
        add_part(kind, recipe.get(kind, default))
hair = add_part("hair", recipe["hair"]) if recipe.get("hair") else None
for name in recipe.get("clothes", []):
    add_part("clothes", name)

FaceService.load_targets(basemesh, load_microsoft_visemes=False,
                         load_meta_visemes=True, load_arkit_faceunits=True)
# The face shapes live on the body; the parts riding on it need them too.
FaceService.interpolate_targets(basemesh)
ExportService.bake_modifiers_remove_helpers(basemesh, bake_masks=True, remove_helpers=True)

rig = basemesh.parent
# Named as the UAL library names its own: the same BoneMap and the same
# animation track paths (Armature/Skeleton3D:bone) then fit every character.
# Renaming a bone renames its vertex group with it.
rig.name = rig.data.name = "Armature"
for old, new in (("Root", "root"), ("head", "Head")):
    rig.data.bones[old].name = new

here = os.path.dirname(os.path.abspath(__file__))
style_path = os.path.join(here, "grooms", "%s.json" % recipe.get("hair"))
if hair is not None and os.path.exists(style_path):
    sys.path.insert(0, here)
    import groom
    with open(style_path, encoding="utf-8") as f:
        style = json.load(f)
    groom.build(basemesh, hair, rig, style, basemesh.name,
                os.path.splitext(out_path)[0] + "_scalp.png")

for obj in [basemesh] + [c for c in rig.children if c is not basemesh]:
    keys = obj.data.shape_keys.key_blocks if obj.data.shape_keys else []
    print("BAKED", obj.name, "verts", len(obj.data.vertices),
          "blend shapes", max(len(keys) - 1, 0),
          "materials", [m.name for m in obj.data.materials if m])
print("BAKED", basemesh.name, "height %.3f m" % basemesh.dimensions.z,
      "bones", len(rig.data.bones))

bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB", export_apply=False,
                          export_animations=False, export_morph=True,
                          export_morph_normal=True, export_tangents=True,
                          export_vertex_color="ACTIVE")
print("WROTE", out_path)
