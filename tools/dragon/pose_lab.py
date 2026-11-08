# Renders a dragon pose from several angles into one contact sheet.
#
#   blender -b -Y <Dragon_Baked_Actions.blend> --python tools/dragon/pose_lab.py -- <out dir> <pose> [<pose> ...]
#
# A name from poses.CLIPS renders one loop instead, as <out dir>/<name>/frame_NNNN.png.
#
# Flat clay on purpose: the hide is near black and hides the shape. The wing
# membrane is tinted so a bad fold is visible.

import importlib
import os
import sys
import bpy
import numpy as np
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import body_rig  # noqa: E402
import poses  # noqa: E402
importlib.reload(poses)

ARGS = sys.argv[sys.argv.index("--") + 1:]
OUT = ARGS[0]
NAMES = ARGS[1:] or ["stance"]
os.makedirs(OUT, exist_ok=True)

arm = bpy.data.objects["Armature"]
body = bpy.data.objects["Dragon_Mesh"]
scene = bpy.context.scene
body_rig.normalize(arm, body)
rig = body_rig.Rig(arm)

CELL = 620
VIEWS = [
    ("left side", (5, 0.3, 0.3), (0, 0.3, 0.3), 2.0),
    ("right side", (-5, 0.3, 0.3), (0, 0.3, 0.3), 2.0),
    ("front", (0, -5, 0.3), (0, 0, 0.3), 1.0),
    ("back", (0, 5, 0.6), (0, 0, 0.3), 1.0),
    ("top", (0, 0.3, 5), (0, 0.3, 0), 2.0),
    ("CRPG camera", (-2.4, -2.4, 3.6), (0, 0.2, 0.15), 1.7),
]
VIEWS_ALOFT = [
    ("left side", (5, 0.2, 0.75), (0, 0.2, 0.75), 2.9),
    ("right side", (-5, 0.2, 0.75), (0, 0.2, 0.75), 2.9),
    ("front", (0, -5, 0.75), (0, 0, 0.75), 3.0),
    ("back", (0, 5, 0.95), (0, 0, 0.75), 3.0),
    ("top", (0, 0.2, 6), (0, 0.2, 0), 3.1),
    ("CRPG camera", (-2.4, -2.4, 4.2), (0, 0.1, 0.7), 3.3),
]

scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "MATERIAL"
scene.display.shading.show_shadows = True
scene.display.shading.show_cavity = True
scene.render.resolution_x = CELL
scene.render.resolution_y = CELL
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
if scene.world is None:
    scene.world = bpy.data.worlds.new("World")
scene.world.color = (0.55, 0.6, 0.66)
for mat in body.data.materials:
    if mat is None:
        continue
    mat.diffuse_color = (0.62, 0.3, 0.24, 1.0) if mat.name.startswith("Game_dragon.003") else (0.8, 0.72, 0.58, 1.0)

bpy.ops.mesh.primitive_plane_add(size=9.0, location=(0, 0, -0.003))
ground = bpy.context.active_object
ground_mat = bpy.data.materials.new("Ground")
ground_mat.diffuse_color = (0.33, 0.33, 0.35, 1.0)
ground.data.materials.append(ground_mat)
cam_data = bpy.data.cameras.new("Cam")
cam_data.type = "ORTHO"
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
scene.render.filepath = os.path.join(OUT, "_warm.png")
bpy.ops.render.render(write_still=True)  # the first render shows the rest pose


def read(path):
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    return px.reshape(h, w, 4)


def sheet(panels, cols, path):
    rows = (len(panels) + cols - 1) // cols
    h, w = panels[0].shape[:2]
    out = np.ones((rows * h, cols * w, 4), dtype=np.float32)
    for i, p in enumerate(panels):
        r, c = i // cols, i % cols
        out[(rows - 1 - r) * h:(rows - r) * h, c * w:(c + 1) * w] = p
    img = bpy.data.images.new("sheet", cols * w, rows * h, alpha=True)
    img.pixels.foreach_set(out.ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


def views(wanted, stem, name):
    panels = []
    for label, loc, at, scale in (VIEWS_ALOFT if name in poses.ALOFT else VIEWS):
        if wanted and label not in wanted:
            continue
        loc, at = Vector(loc), Vector(at)
        cam_data.ortho_scale = scale
        cam.location = loc
        cam.rotation_euler = (at - loc).to_track_quat("-Z", "Y").to_euler()
        bpy.context.view_layer.update()
        path = "%s_%s.png" % (stem, label.replace(" ", "_"))
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        panels.append(read(path))
        os.remove(path) if wanted else None
    return panels


CLIP_VIEWS = ("left side", "front", "CRPG camera")
FPS = 24

for name in NAMES:
    if name in poses.CLIPS:
        clip = poses.CLIPS[name]
        out = os.path.join(OUT, name)
        os.makedirs(out, exist_ok=True)
        frames = int(round(clip["length"] * FPS))
        for f in range(frames):
            rig.solve(clip["at"](f / frames))
            rig.apply()
            sheet(views(CLIP_VIEWS, os.path.join(out, "_v"), name), 3, os.path.join(out, "frame_%04d.png" % f))
            if f % 12 == 0:
                print("LAB", name, f, "/", frames, flush=True)
        continue
    rig.solve(poses.POSES[name])
    rig.apply()
    sheet(views(None, os.path.join(OUT, name), name), 3, os.path.join(OUT, "%s_sheet.png" % name))
print("LAB OK")
