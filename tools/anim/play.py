"""Playblast of a keyed .blend: three-quarter and side view next to each other, looped, as mp4.

    blender -b --factory-startup --python tools/anim/play.py -- --src recordings/anim_work/slash_step.blend
        [--out recordings/anim_look/slash_step/play.mp4] [--loops 4] [--fps 24]

The frame number is not stamped; read exact poses from look.py's pose sheet.
"""
import bpy, sys, os, shutil
import numpy as np
from mathutils import Vector


def arg(name, default=None):
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return a[a.index(name) + 1] if name in a else default


SRC = os.path.abspath(arg("--src"))
NAME = os.path.splitext(os.path.basename(SRC))[0]
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.abspath(arg("--out", os.path.join(ROOT, "recordings", "anim_look", NAME, "play.mp4")))
LOOPS = int(arg("--loops", "4"))
FPS = int(arg("--fps", "24"))
CELL = (640, 720)
TMP = os.path.join(os.path.dirname(OUT), "_play_frames")

bpy.ops.wm.open_mainfile(filepath=SRC)
scene = bpy.context.scene
arm = max((o for o in scene.objects if o.type == "ARMATURE"), key=lambda o: len(o.data.bones))
act = arm.animation_data.action
f0, f1 = int(act.frame_range[0]), int(act.frame_range[1])

mesh = bpy.data.meshes.new("play_ground")
mesh.from_pydata([(-8, -8, 0), (8, -8, 0), (8, 8, 0), (-8, 8, 0)], [], [[0, 1, 2, 3]])
ground = bpy.data.objects.new("play_ground", mesh)
ground.color = (0.62, 0.62, 0.6, 1)
scene.collection.objects.link(ground)

scene.render.engine = "BLENDER_WORKBENCH"
sh = scene.display.shading
sh.light = "STUDIO"
sh.color_type = "OBJECT"
sh.show_shadows = True
sh.show_cavity = True
scene.display.render_aa = "5"
scene.render.film_transparent = False
scene.view_settings.view_transform = "Standard"
scene.render.resolution_x, scene.render.resolution_y = CELL
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.fps = FPS
if scene.world is None:
    scene.world = bpy.data.worlds.new("play_world")
scene.world.color = (0.8, 0.8, 0.78)
cam = bpy.data.objects.new("play_cam", bpy.data.cameras.new("play_cam"))
scene.collection.objects.link(cam)
scene.camera = cam
cam.data.lens = 50
centre = Vector((0.05, -0.15, 0.95))
VIEWS = [Vector((0.75, -1, 0.3)), Vector((1, 0, 0.12))]

shutil.rmtree(TMP, ignore_errors=True)
os.makedirs(TMP)


def shot(d, path):
    d = d.normalized()
    cam.location = centre + d * 5.6
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:], dtype=np.float32).reshape(img.size[1], img.size[0], 4)
    bpy.data.images.remove(img)
    return px


frames = list(range(f0, f1))  # last key repeats the first, so drop it for a clean loop
names = []
for n, f in enumerate(frames):
    scene.frame_set(f)
    row = np.concatenate([shot(v, os.path.join(TMP, "v.png")) for v in VIEWS], axis=1)
    img = bpy.data.images.new("row", row.shape[1], row.shape[0], alpha=True)
    img.pixels.foreach_set(row.ravel())
    img.filepath_raw = os.path.join(TMP, "c%04d.png" % n)
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    names.append("c%04d.png" % n)

# encode through the sequencer
out = bpy.data.scenes.new("play_out")
bpy.context.window.scene = out
out.render.resolution_x, out.render.resolution_y = CELL[0] * 2, CELL[1]
out.render.resolution_percentage = 100
out.render.fps = FPS
out.view_settings.view_transform = "Standard"
se = out.sequence_editor_create()
strips = se.strips if hasattr(se, "strips") else se.sequences
order = names * LOOPS
st = strips.new_image(name="play", filepath=os.path.join(TMP, order[0]), channel=1, frame_start=1)
for nm in order[1:]:
    st.elements.append(nm)
out.frame_start, out.frame_end = 1, len(order)
ims = out.render.image_settings
try:
    ims.media_type = "VIDEO"
except Exception:
    pass
ims.file_format = "FFMPEG"
out.render.ffmpeg.format = "MPEG4"
out.render.ffmpeg.codec = "H264"
out.render.ffmpeg.constant_rate_factor = "HIGH"
out.render.filepath = OUT
out.render.use_file_extension = False
bpy.ops.render.render(animation=True, scene=out.name)
shutil.rmtree(TMP, ignore_errors=True)
print("PLAY wrote", OUT, "frames", len(order))
