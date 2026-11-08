# Converts 3DHaupt's "Dragon Rigged and Game Ready" (CGTrader, Editorial
# License: a prototype stand-in, swap before shipping) into
# assets/dragon/dragon.glb.
#
#   blender -b -Y <Dragon_Baked_Actions.blend> --python tools/dragon/export_dragon.py -- <textures dir>
#
# <textures dir> is the unzipped textures folder that ships beside the
# .blend; it needs Dragon_ground_color.jpg and Dragon_Nor.jpg.
#
# The source is a Blender 2.77 file in arbitrary units, head toward -Y,
# with four baked in-place loops (Idel_New, Walk_New, Run_New, Fly_New) and
# legacy materials with no image nodes. This script:
#   - scales it to SM 0, 2 m nose to tail, and centres the torso on the
#     origin, so CharacterModel.authored_size_modifier stays 0 and the
#     unit's SM stat alone makes it bigger;
#   - scales every action's location keys by the same factor, since
#     applying scale to an armature leaves its keyframes in the old units;
#   - rebuilds the materials on the colour and normal maps, on the
#     non-mirrored UV set (the mirrored set is for a grey detail map the
#     game doesn't use);
#   - names the loops Idle/Walk/Run/Fly with Godot's -loop suffix, cuts
#     Fly down to two clean wing beats, and splits its lift-off out as
#     Takeoff (and, reversed, Land).
# Blender space: +Z up, the dragon faces -Y; glTF turns that into Godot +Z.

import os
import sys
import bpy
from mathutils import Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "assets", "dragon")
ARGS = sys.argv[sys.argv.index("--") + 1:]
TEX_DIR = ARGS[0]
# --preview=<dir>: render the authored clips there instead of exporting.
PREVIEW = next((a.split("=", 1)[1] for a in ARGS if a.startswith("--preview=")), None)
# --clips=Bite,Claw: preview only these.
ONLY = next((a.split("=", 1)[1].split(",") for a in ARGS if a.startswith("--clips=")), None)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bake_poses  # noqa: E402
import dragon_clips  # noqa: E402

LENGTH = 2.0  # metres nose to tail: SizeModifier.length_for(0)
ACTIONS = {"Idel_New": "Idle-loop", "Walk_New": "Walk-loop",
           "Run_New": "Run-loop", "Fly_New": "Fly-loop"}

arm = bpy.data.objects["Armature"]
body = bpy.data.objects["Dragon_Mesh"]
scene = bpy.context.scene


def fcurves(act):
    try:
        return list(act.fcurves)
    except AttributeError:
        return [fc for layer in act.layers for strip in layer.strips
                for cb in strip.channelbags for fc in cb.fcurves]


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

for act in bpy.data.actions:
    for fc in fcurves(act):
        if fc.data_path.endswith(".location"):
            for k in fc.keyframe_points:
                k.co[1] *= s
                k.handle_left[1] *= s
                k.handle_right[1] *= s
            fc.update()
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

arm.animation_data_create()
for track in list(arm.animation_data.nla_tracks):
    arm.animation_data.nla_tracks.remove(track)
for src, name in ACTIONS.items():
    act = bpy.data.actions[src]
    act.name = name
    start, end = act.frame_range
    act.use_frame_range = True
    act.frame_start = start
    act.frame_end = end
    track = arm.animation_data.nla_tracks.new()
    track.name = name
    strip = track.strips.new(name, int(start), act)
    if hasattr(strip, "action_slot") and act.slots:
        strip.action_slot = act.slots[0]
arm.animation_data.action = None


# Fly_New takes off (frames 0-14), beats its wings (a ~19-frame flap that
# settles by about frame 40 and runs to about 120), glides, lands and stands
# still. Split it: the hover loops over the closest-matching pair of frames
# two flaps apart in the settled flapping; Takeoff runs from the start to
# the early frame that best matches the loop's first, so it hands over
# without a jump; Land is Takeoff run backwards. (Looping to the end would
# replay the landing and the standing frames in mid air.)
def pose_at(curves, f):
    return [fc.evaluate(f) for fc in curves]


def mismatch(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b))


fly = bpy.data.actions["Fly-loop"]
curves = fcurves(fly)
fly_start, fly_end = (int(x) for x in fly.frame_range)
poses = {f: pose_at(curves, f) for f in range(fly_start, fly_start + 121)}
loop_from, loop_to = min(((s, e) for s in range(fly_start + 34, fly_start + 80)
                          for e in range(s + 30, min(s + 46, fly_start + 121))),
                         key=lambda se: mismatch(poses[se[0]], poses[se[1]]))
takeoff_to = min(range(fly_start + 12, fly_start + 35), key=lambda f: mismatch(poses[f], poses[loop_from]))
print("DRAGON fly loops over frames", loop_from, loop_to, "mismatch %.5f;" % mismatch(poses[loop_from], poses[loop_to]),
      "takeoff ends", takeoff_to, "mismatch %.5f" % mismatch(poses[takeoff_to], poses[loop_from]))


def copy_range(src, name, frames, reverse=False):
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    slot = act.slots.new("OBJECT", arm.name) if hasattr(act, "slots") else None
    if slot:
        layer = act.layers.new("Layer")
        strip = layer.strips.new(type="KEYFRAME")
        bag = strip.channelbag(slot, ensure=True)
        new_curve = lambda fc: bag.fcurves.new(fc.data_path, index=fc.array_index)
    else:
        new_curve = lambda fc: act.fcurves.new(fc.data_path, index=fc.array_index, action_group=fc.group.name if fc.group else "")
    seq = list(frames)[::-1] if reverse else list(frames)
    for fc in fcurves(src):
        out = new_curve(fc)
        out.keyframe_points.add(len(seq))
        for i, f in enumerate(seq):
            k = out.keyframe_points[i]
            k.co = (i, fc.evaluate(f))
            k.interpolation = "LINEAR"
        out.update()
    act.use_frame_range = True
    act.frame_start = 0
    act.frame_end = len(seq) - 1
    return act


takeoff = range(fly_start, takeoff_to + 1)
hover = range(loop_from, loop_to + 1)
extra = [copy_range(fly, "Takeoff", takeoff), copy_range(fly, "Land", takeoff, reverse=True)]
hover_act = copy_range(fly, "Hover-loop", hover)
bpy.data.actions.remove(fly)
hover_act.name = "Fly-loop"
for act in extra + [hover_act]:
    track = arm.animation_data.nla_tracks.new()
    track.name = act.name
    strip = track.strips.new(act.name, int(act.frame_start), act)
    if hasattr(strip, "action_slot") and act.slots:
        strip.action_slot = act.slots[0]
for track in list(arm.animation_data.nla_tracks):
    if not track.strips or track.strips[0].action is None:
        arm.animation_data.nla_tracks.remove(track)

# The action clips, authored over Idle (dragon_clips.py).
authored, moments = dragon_clips.build(arm, body, bpy.data.actions["Idle-loop"], fly=hover_act)
for act in authored:
    track = arm.animation_data.nla_tracks.new()
    track.name = act.name
    strip = track.strips.new(act.name, 0, act)
    strip.action_slot = act.slots[0]

# Authored from scratch (poses.py). Run last: the clips above still build on
# the model's own Idle until they are re-authored.
bake_poses.replace(arm, body, {"Idle-loop": "idle", "Fly-loop": "hover"})

KEEP = set(ACTIONS.values()) | {"Takeoff", "Land"} | {a.name for a in authored}
for act in [a for a in bpy.data.actions if a.name not in KEEP]:
    bpy.data.actions.remove(act)

for o in [o for o in bpy.data.objects if o not in (arm, body)]:
    bpy.data.objects.remove(o)


# --- Write ------------------------------------------------------------------

if PREVIEW:
    dragon_clips.preview(arm, authored + [bpy.data.actions["Fly-loop"]], PREVIEW, only=ONLY)
    sys.exit(0)

bpy.context.view_layer.update()
co = [body.matrix_world @ v.co for v in mesh.vertices]
lo = Vector((min(c.x for c in co), min(c.y for c in co), min(c.z for c in co)))
hi = Vector((max(c.x for c in co), max(c.y for c in co), max(c.z for c in co)))
print("DRAGON rest bbox", tuple(round(v, 3) for v in lo), tuple(round(v, 3) for v in hi))

os.makedirs(OUT_DIR, exist_ok=True)
# Keyed into the clips as release()/impact() method tracks on import
# (dragon_post_import.gd).
dragon_clips.write_moments(os.path.join(OUT_DIR, "dragon_moments.json"), moments)
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
