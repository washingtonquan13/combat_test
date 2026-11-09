# Converts 3DHaupt's "Dragon Rigged and Game Ready" (CGTrader, Editorial
# License: a prototype stand-in, swap before shipping) into
# assets/dragon/dragon.glb.
#
#   blender -b -Y <Dragon_Baked_Actions.blend> --python tools/dragon/export_dragon.py -- <textures dir>
#
# <textures dir> is the unzipped textures folder that ships beside the
# .blend; it needs Dragon_ground_color.jpg and Dragon_Nor.jpg.
#
# The source is a Blender 2.77 file in arbitrary units, head toward -Y, with
# legacy materials with no image nodes. This script:
#   - scales it to SM 0, 2 m nose to tail, and centres the torso on the
#     origin, so CharacterModel.authored_size_modifier stays 0 and the
#     unit's SM stat alone makes it bigger;
#   - rebuilds the materials on the colour and normal maps, on the
#     non-mirrored UV set (the mirrored set is for a grey detail map the
#     game doesn't use);
#   - throws away the clips that came with the model and bakes every clip
#     from action_clips.py, solved from the rest pose.
# Blender space: +Z up, the dragon faces -Y; glTF turns that into Godot +Z.

import os
import sys
import bpy
from mathutils import Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "assets", "dragon")
ARGS = sys.argv[sys.argv.index("--") + 1:]
TEX_DIR = ARGS[0]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bake_poses  # noqa: E402

LENGTH = 2.0  # metres nose to tail: SizeModifier.length_for(0)
arm = bpy.data.objects["Armature"]
body = bpy.data.objects["Dragon_Mesh"]
scene = bpy.context.scene


# --- Size and centre --------------------------------------------------------

arm.animation_data.action = None
for pb in arm.pose.bones:
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)
    pb.rotation_euler = (0, 0, 0)
    pb.scale = (1, 1, 1)
bpy.context.view_layer.update()

ys = [(body.matrix_world @ v.co).y for v in body.data.vertices]
length = max(ys) - min(ys)
s = LENGTH / length
# The torso: from the forefeet to the hind feet, not the tail's far end.
fore = (arm.matrix_world @ arm.data.bones["Hand_L"].head_local).y
hind = (arm.matrix_world @ arm.data.bones["back_food_L"].head_local).y
centre_y = (fore + hind) * 0.5
print("DRAGON source length", round(length, 2), "scale", round(s, 5), "torso centre y", round(centre_y, 2))

arm.location = (0.0, -centre_y * s, 0.0)
arm.scale = (s, s, s)
for o in bpy.data.objects:
    o.select_set(o in (arm, body))
bpy.context.view_layer.objects.active = arm
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

constraints = sum(len(pb.constraints) for pb in arm.pose.bones)
for pb in arm.pose.bones:
    for c in pb.constraints:
        c.mute = True  # the clips are baked; constraints would apply twice

print("DRAGON muted constraints", constraints)


# --- Materials --------------------------------------------------------------

mesh = body.data
uv_keep = mesh.uv_layers["UV_NO_mirror"]
for uv in [u for u in mesh.uv_layers if u.name != uv_keep.name]:
    mesh.uv_layers.remove(uv)
mesh.uv_layers.active = mesh.uv_layers[0]
mesh.uv_layers[0].active_render = True

color = bpy.data.images.load(os.path.join(TEX_DIR, "Dragon_ground_color.jpg"))
normal = bpy.data.images.load(os.path.join(TEX_DIR, "Dragon_Nor.jpg"))
normal.colorspace_settings.name = "Non-Color"


def make_material(name, double_sided):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.use_backface_culling = not double_sided
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.6
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = color
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    ntex = nt.nodes.new("ShaderNodeTexImage")
    ntex.image = normal
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(ntex.outputs["Color"], nmap.inputs["Color"])
    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


hide = make_material("DragonHide", False)
membrane = make_material("DragonMembrane", True)
# Game_dragon.003 is the wing membrane; the body and the eyes share the hide.
# Read every face's new slot before clearing, which resets the indices.
old = [m.name if m else "" for m in mesh.materials]
slots = [1 if old[p.material_index].startswith("Game_dragon.003") else 0
         for p in mesh.polygons]
mesh.materials.clear()
mesh.materials.append(hide)
mesh.materials.append(membrane)
mesh.polygons.foreach_set("material_index", slots)
mesh.update()
print("DRAGON membrane faces", sum(slots))


# --- Clips ------------------------------------------------------------------

# Action name (with Godot's -loop suffix) -> clip in action_clips.py.
CLIPS = {
    "Idle-loop": "idle",
    "Walk-loop": "walk",
    "Turn_L-loop": "turn_l",
    "Turn_R-loop": "turn_r",
    "Fly-loop": "hover",
    "Fly_Forward-loop": "cruise",
    "Takeoff": "takeoff",
    "Land": "land",
    "Hit": "hit",
    "Hit_Air": "hit_air",
    "Death": "death",
    "Knockdown": "knockdown",
    "Get_Up": "get_up",
    "Bite": "bite",
    "Bite_Air": "bite_air",
    "Claw": "claw",
    "Claw_Air": "claw_air",
    "Breath": "breath",
    "Breath_Hold-loop": "breath_hold",
    "Breath_Out": "breath_out",
    "Breath_Air": "breath_air",
    "Breath_Hold_Air-loop": "breath_hold_air",
    "Breath_Out_Air": "breath_out_air",
    "Roar": "roar",
    "Tail_Swipe": "tail_swipe",
    "Wing_Buffet": "wing_buffet",
}

arm.animation_data_create()
arm.animation_data.action = None
for track in list(arm.animation_data.nla_tracks):
    arm.animation_data.nla_tracks.remove(track)
for act in list(bpy.data.actions):
    bpy.data.actions.remove(act)
moments = bake_poses.bake(arm, body, CLIPS)

for o in [o for o in bpy.data.objects if o not in (arm, body)]:
    bpy.data.objects.remove(o)


# --- Write ------------------------------------------------------------------

bpy.context.view_layer.update()
co = [body.matrix_world @ v.co for v in mesh.vertices]
lo = Vector((min(c.x for c in co), min(c.y for c in co), min(c.z for c in co)))
hi = Vector((max(c.x for c in co), max(c.y for c in co), max(c.z for c in co)))
print("DRAGON rest bbox", tuple(round(v, 3) for v in lo), tuple(round(v, 3) for v in hi))

os.makedirs(OUT_DIR, exist_ok=True)
# Keyed into the clips as release()/impact() method tracks on import
# (dragon_post_import.gd).
bake_poses.write_moments(os.path.join(OUT_DIR, "dragon_moments.json"), moments)
bpy.ops.export_scene.gltf(
    filepath=os.path.join(OUT_DIR, "dragon.glb"),
    export_format="GLB",
    export_animations=True,
    export_animation_mode="ACTIONS",
    export_force_sampling=True,
    export_frame_step=1,
    export_skins=True,
    export_yup=True,
    export_apply=False,
    export_image_format="AUTO",
)
print("DRAGON OK", [a.name for a in bpy.data.actions], "fps", scene.render.fps)
