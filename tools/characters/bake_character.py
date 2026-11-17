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
      "hairstyle": "short_side_part",
      "clothes": [],
      "wearables": ["male_casualsuit01", "shoes01"]
    }

`macros` are MakeHuman's macro sliders, 0..1; anything left out keeps MakeHuman's
default. `targets` are optional detail targets by MakeHuman name, valued -1..1.
`parts` are face parts under tools/characters/parts/<source>/, whole or at
an amount: cut from a head scan by bake_scan_parts.py (nose, mouth, chin,
cheeks, brow, ears, skull) or made by rule, with no scan, by
bake_bone_shapes.py ("bone": brow_ridge, cheekbones, cheek_hollows, jaw, chin). They go on over the macros and
targets, so the face is MPFB's with those features swapped in.
The rest name assets from the MakeHuman system assets pack (CC0), installed in
MPFB's user data: `skin` a folder under skins/, `eyes` an eye colour under
eyes/materials/, the others a folder under their own kind. A face is always
whole: eyes, eyebrows, eyelashes, teeth and tongue fall back to a default when
left out ("eyebrows": null leaves brows off); `skin` and `clothes` are only
there when asked for. `hairstyle` is not MakeHuman's: it names a style under
tools/characters/hairstyles/, grown by rule (hairstyle.py). Clothes hide the body under them by deleting it.
`wearables` are MakeHuman clothes too, fitted to this body the same way, but
baked to their own .glb so the game can put them on and take them off: see
"What comes out" below.

What comes out, every time:
- the body with its shape baked in: no slider shape keys, helper geometry gone;
- MPFB's mixamo rig, as "Armature", with Mixamo's bone names less the
  "mixamorig:" prefix and a "root" bone that Hips hangs from, so Mixamo's clips
  go onto it bone for bone. The .glb's import BoneMap takes it to Godot's
  humanoid profile, which every library retargets through. It rests in an
  A-pose: the import also needs retarget/rest_fixer/fix_silhouette;
- the 52 ARKit face units and the Meta/Oculus visemes as blend shapes, at 0,
  carried over onto the brows, lashes, teeth and tongue so a blink or a jaw
  drop moves them too. The rig has no jaw or eye bones, so the face is driven
  by these alone;
- every part with a game-engine material (Principled BSDF and image
  textures), which glTF carries as standard PBR;
- with a hairstyle, its hair as cards (groom.py), a hull over it for the
  outline (hidden in game), and <out>_scalp.png beside the .glb: where the
  hair grows, for the skin shader;
- for each wearable, assets/wearables/<item>/<name>.glb, the item fitted to
  this body on the same rig (no blend shapes), and <item>_covers.png beside
  it: the body's skin it hides, in the body's UV space, which is every
  character's. The body keeps its skin there; the skin shader drops what the
  worn items cover (Wearable, CharacterLook.wear).
"""
import json
import os
import sys

import addon_utils
import bpy
import numpy as np

argv = sys.argv[sys.argv.index("--") + 1:]
recipe_path, out_path = argv[0], argv[1]
with open(recipe_path, encoding="utf-8") as f:
    recipe = json.load(f)

addon_utils.enable("bl_ext.user_default.mpfb", default_set=True)
from bl_ext.user_default.mpfb.entities.clothes.mhclo import Mhclo
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
# MPFB's "mixamo" rig: Mixamo's own skeleton (52 bones, Hips at the top), so
# Mixamo's clips are laid on it bone for bone (tools/_probe/gait/mixrig).
HumanService.add_builtin_rig(basemesh, "mixamo", import_weights=True)


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
    # subdiv 0 here: the clothes are subdivided below, once the face shapes
    # have reached every part; the face parts are fine as cut. The part is fitted to
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
eyes = None
if eye_colour:
    eyes = add_part("eyes", "high-poly", material="materials/%s.mhmat" % eye_colour)
for kind, default in FACE_DEFAULTS.items():
    if recipe.get(kind, default):
        add_part(kind, recipe.get(kind, default))
clothes = [add_part("clothes", name) for name in recipe.get("clothes", [])]

COVERS_SIZE = 1024


def covers_mask(mhclo_path):
    """Where an item hides the body: its delete faces (those whose every vertex
    it deletes, as MPFB's own conservative mask has it) drawn into the body's
    UV space, as an RGBA image whose alpha is the cover."""
    mhclo = Mhclo()
    mhclo.load(mhclo_path)
    deleted = np.zeros(len(basemesh.data.vertices), bool)
    deleted[[v for v in mhclo.delverts if v < len(deleted)]] = True
    uv = np.zeros(len(basemesh.data.loops) * 2)
    basemesh.data.uv_layers.active.data.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)
    alpha = np.zeros((COVERS_SIZE, COVERS_SIZE), np.uint8)
    for poly in basemesh.data.polygons:
        if not deleted[list(poly.vertices)].all():
            continue
        corners = uv[list(poly.loop_indices)] * COVERS_SIZE
        corners[:, 1] = COVERS_SIZE - corners[:, 1]  # rows run down from the image's top
        for i in range(1, len(corners) - 1):
            a, b, c = corners[0], corners[i], corners[i + 1]
            x0, y0 = np.floor(np.minimum(np.minimum(a, b), c)).astype(int)
            x1, y1 = np.ceil(np.maximum(np.maximum(a, b), c)).astype(int)
            x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, COVERS_SIZE), min(y1, COVERS_SIZE)
            if x1 <= x0 or y1 <= y0:
                continue
            px, py = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
            area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
            if abs(area) < 1e-9:
                continue
            w0 = ((b[0] - px) * (c[1] - py) - (b[1] - py) * (c[0] - px)) / area
            w1 = ((c[0] - px) * (a[1] - py) - (c[1] - py) * (a[0] - px)) / area
            inside = (w0 >= -1e-3) & (w1 >= -1e-3) & (1.0 - w0 - w1 >= -1e-3)
            alpha[y0:y1, x0:x1][inside] = 255
    rgba = np.full((COVERS_SIZE, COVERS_SIZE, 4), 255, np.uint8)
    rgba[..., 3] = alpha
    return rgba


# Wearables are fitted like clothes, but the body under them stays: adding one
# masks the body with a vertex group of what it deletes, which the mask bake
# would cut away, so every mask goes back to what the baked clothes alone ask.


def mask_groups():
    out = {}
    for mod in basemesh.modifiers:
        group = basemesh.vertex_groups.get(mod.vertex_group) if mod.type == "MASK" else None
        if group:
            out[mod.name] = (group.name, [v.index for v in basemesh.data.vertices
                                          if any(g.group == group.index for g in v.groups)])
    return out


masks_before = mask_groups()
wearables = {}
wearables_covers = {}
for name in recipe.get("wearables", []):
    wearables[name] = add_part("clothes", name)
    wearables_covers[name] = covers_mask(asset_file("clothes", name, "mhclo"))
if wearables:
    everything = list(range(len(basemesh.data.vertices)))
    for mod_name, (group_name, _members) in mask_groups().items():
        group = basemesh.vertex_groups[group_name]
        group.remove(everything)
        if mod_name in masks_before:
            if masks_before[mod_name][1]:
                group.add(masks_before[mod_name][1], 1.0, "REPLACE")
        else:
            basemesh.modifiers.remove(basemesh.modifiers[mod_name])


FaceService.load_targets(basemesh, load_microsoft_visemes=False,
                         load_meta_visemes=True, load_arkit_faceunits=True)
# The face shapes live on the body; the parts riding on it need them too.
FaceService.interpolate_targets(basemesh)
# One level of subdivision on the body and the clothes: MakeHuman's base mesh
# is cut for 2000s game budgets, and its polygons show at the jaw, ears and
# shoulders up close. The shape keys are carried through the subdivision, and
# Godot builds the far LODs back down on import.
SUBDIV = int(recipe.get("subdiv", 1))
if SUBDIV:
    for obj in [basemesh] + clothes + list(wearables.values()):
        mod = obj.modifiers.new("Subdivision", "SUBSURF")
        mod.levels = mod.render_levels = SUBDIV
        if obj is not basemesh:
            bpy.context.view_layer.objects.active = obj
            ExportService._apply_modifiers_keep_shapekeys(obj, [mod.name])
ExportService.bake_modifiers_remove_helpers(basemesh, bake_masks=True, bake_subdiv=bool(SUBDIV),
                                            remove_helpers=True)

rig = basemesh.parent
# Bones named as Mixamo's without the "mixamorig:" prefix (Hips, Spine1,
# LeftUpLeg, ...); the .glb's import BoneMap takes them to Godot's humanoid
# profile, which every animation library and the ragdoll are written in.
# Renaming a bone renames its vertex group with it.
rig.name = rig.data.name = "Armature"
for bone in rig.data.bones:
    if bone.name.startswith("mixamorig:"):
        bone.name = bone.name[len("mixamorig:"):]
# The profile's Root, which Mixamo's rig lacks: a bone at the feet that Hips
# hangs from, as the old game_engine rig had. The libraries key it (at rest).
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
root = rig.data.edit_bones.new("root")
root.head, root.tail = (0.0, 0.0, 0.0), (0.0, 0.1, 0.0)
rig.data.edit_bones["Hips"].parent = root
bpy.ops.object.mode_set(mode="OBJECT")

here = os.path.dirname(os.path.abspath(__file__))

# Each wearable to its own .glb, on the same rig: worn, its skin binds to the
# body's skeleton by bone name. No blend shapes: the face's don't reach cloth.
sys.path.insert(0, here)
import groom
wear_root = os.path.join(here, "..", "..", "assets", "wearables")
for name, obj in wearables.items():
    if obj.data.shape_keys:
        obj.shape_key_clear()
    folder = os.path.join(wear_root, name)
    os.makedirs(folder, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    rig.select_set(True)
    glb = os.path.join(folder, basemesh.name + ".glb")
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=True,
                              export_apply=False, export_animations=False, export_morph=False,
                              export_tangents=True, export_vertex_color="ACTIVE")
    groom.write_png(os.path.join(folder, name + "_covers.png"), wearables_covers[name])
    print("WORE", name, "verts", len(obj.data.vertices), "->", glb)
    bpy.data.objects.remove(obj, do_unlink=True)

if recipe.get("hairstyle"):
    if eyes is None:
        sys.exit("bake_character: a hairstyle needs the eyes, which place the head")
    groom.build(basemesh, eyes, rig, os.path.join(here, "hairstyles", recipe["hairstyle"] + ".json"),
                basemesh.name, os.path.splitext(out_path)[0] + "_scalp.png",
                os.path.splitext(out_path)[0] + "_strands.png")

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
