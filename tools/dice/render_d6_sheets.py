"""Renders the frames for the skill-check dice popup's sprite d6.

Run headless with Blender 4.3:

    "C:/Program Files/Blender Foundation/Blender 4.3/blender.exe" -b \
        -P tools/dice/render_d6_sheets.py -- --out <frames_dir>

then pack the frames into sheets with tools/dice/pack_d6_sheets.py (or run
tools/dice/build.sh, which does both).

Everything is built here: a bevelled cube with the numerals 1-6 inlaid in
Blender's own font, no downloaded assets. It renders, into <frames_dir>:

    tumble_<a|b|c>/####.png  TUMBLE_FRAMES frames each, a seamless loop of a
                             motion-blurred tumble in the air; one spin per
                             die so three dice never look identical.
                             Result-agnostic.
    settle_<n>/####.png      SETTLE_FRAMES frames: the die drops out of a
                             tumble, rolls over its corners and comes to rest
                             with face n up, then a glint sweeps its top.
                             The last frame is the landed still.
    landed_<n>.png           face n up, at rest, no glint.

The camera looks down at the die from CAMERA_ELEVATION degrees and the
numeral on the top face reads upright to it. The background is transparent;
the die's shadow is kept in alpha by a shadow catcher.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector

FRAME_PX = 192
TUMBLE_FRAMES = 32
SETTLE_FRAMES = 16
## Frame (1-based) the settling die comes to rest on; the glint plays after.
SETTLE_REST_FRAME = 10
CAMERA_ELEVATION = 60.0
## Width of the view at the die, in die widths.
VIEW_WIDTH = 2.5
CAMERA_DISTANCE = 7.0
HOVER_Z = 0.9
SAMPLES = 48

## Face value -> (outward normal, the numeral's up direction on that face).
## Opposite faces sum to 7.
FACES = {
    1: (Vector((0, 0, 1)), Vector((0, 1, 0))),
    6: (Vector((0, 0, -1)), Vector((0, -1, 0))),
    2: (Vector((1, 0, 0)), Vector((0, 0, 1))),
    5: (Vector((-1, 0, 0)), Vector((0, 0, 1))),
    3: (Vector((0, -1, 0)), Vector((0, 0, 1))),
    4: (Vector((0, 1, 0)), Vector((0, 0, 1))),
}

## Per-die tumble: two spin axes and whole turns per loop of each, so every
## loop closes on itself exactly (both spins return to identity at t=1).
TUMBLES = {
    "a": ((1.0, 0.35, 0.2), 2, (0.1, 1.0, 0.4), 1, (0.3, 0.2, 0.0)),
    "b": ((-0.4, 1.0, 0.3), 2, (1.0, 0.0, 0.5), 1, (1.1, -0.4, 0.7)),
    "c": ((0.6, -0.5, 1.0), 2, (0.8, 1.0, -0.2), -1, (-0.6, 0.9, 0.3)),
}


def parse_out() -> str:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--out" not in argv:
        raise SystemExit("usage: blender -b -P render_d6_sheets.py -- --out <dir>")
    return os.path.abspath(argv[argv.index("--out") + 1])


def face_frame(value: int) -> Matrix:
    """Rotation whose columns are the numeral's right, up and normal."""
    normal, up = FACES[value]
    right = up.cross(normal)
    return Matrix((right, up, normal)).transposed()


def landed_rotation(value: int) -> Quaternion:
    """Die rotation that puts face `value` up, numeral upright to camera."""
    return face_frame(value).transposed().to_quaternion()


def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def make_materials():
    body = bpy.data.materials.new("DieBody")
    body.use_nodes = True
    p = body.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (0.13, 0.006, 0.012, 1.0)
    p.inputs["Roughness"].default_value = 0.22
    p.inputs["Coat Weight"].default_value = 0.6
    p.inputs["Coat Roughness"].default_value = 0.05

    ink = bpy.data.materials.new("DieNumeral")
    ink.use_nodes = True
    p = ink.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (1.0, 0.78, 0.38, 1.0)
    p.inputs["Metallic"].default_value = 1.0
    p.inputs["Roughness"].default_value = 0.28
    return body, ink


def numeral_mesh(ink) -> bpy.types.Object:
    """One mesh holding all six numerals, each inlaid a hair proud of its
    face. (An EXACT boolean engraving was tried and mangled the die.)"""
    bm = bmesh.new()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for value in FACES:
        curve = bpy.data.curves.new(f"num{value}", type="FONT")
        curve.body = str(value)
        curve.align_x = "CENTER"
        curve.align_y = "CENTER"
        curve.size = 0.62
        curve.offset = 0.014
        curve.extrude = 0.004
        curve.resolution_u = 6
        obj = bpy.data.objects.new(f"num{value}", curve)
        bpy.context.scene.collection.objects.link(obj)
        depsgraph.update()
        evaluated = obj.evaluated_get(depsgraph)
        mesh = bpy.data.meshes.new_from_object(evaluated)
        normal, _ = FACES[value]
        placement = face_frame(value).to_4x4()
        placement.translation = normal * 0.5015
        mesh.transform(placement)
        bm.from_mesh(mesh)
        bpy.data.objects.remove(obj)
        bpy.data.meshes.remove(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("Numerals")
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(ink)
    numerals = bpy.data.objects.new("Numerals", mesh)
    bpy.context.scene.collection.objects.link(numerals)
    return numerals


def build_die():
    body, ink = make_materials()
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    die = bpy.context.active_object
    die.name = "Die"
    die.data.materials.append(body)
    bevel = die.modifiers.new("Bevel", "BEVEL")
    bevel.width = 0.1
    bevel.segments = 6
    bevel.limit_method = "NONE"
    bevel.harden_normals = True
    numerals = numeral_mesh(ink)
    numerals.parent = die
    bpy.ops.object.shade_smooth()
    die.rotation_mode = "QUATERNION"
    die.cycles.use_motion_blur = True
    die.cycles.motion_steps = 4
    return die


def add_area(name, location, size, energy, color=(1, 1, 1), shadow=True):
    data = bpy.data.lights.new(name, "AREA")
    data.size = size
    data.energy = energy
    data.color = color
    data.use_shadow = shadow
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (Vector((0, 0, 0.5)) - Vector(location)).to_track_quat("-Z", "Y").to_euler()
    return obj


def build_stage():
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.cycles.use_adaptive_sampling = True
    scene.render.film_transparent = True
    scene.render.resolution_x = FRAME_PX
    scene.render.resolution_y = FRAME_PX
    scene.render.resolution_percentage = 100
    scene.render.fps = 30
    scene.render.use_motion_blur = True
    scene.render.motion_blur_shutter = 0.75
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"

    world = bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.05, 0.05, 0.06, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0

    target = Vector((0, 0, 0.55))
    elev = math.radians(CAMERA_ELEVATION)
    cam_data = bpy.data.cameras.new("Camera")
    # Perspective, though narrow: through an orthographic camera a flat
    # face mirrors one direction everywhere, so the glint lit the whole
    # face at once instead of travelling across it.
    cam_data.type = "PERSP"
    cam_data.sensor_fit = "HORIZONTAL"
    cam_data.angle = 2 * math.atan(VIEW_WIDTH / 2 / CAMERA_DISTANCE)
    cam = bpy.data.objects.new("Camera", cam_data)
    scene.collection.objects.link(cam)
    cam.location = target + CAMERA_DISTANCE * Vector((0, -math.cos(elev), math.sin(elev)))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam

    add_area("Key", (-1.4, -1.2, 5.0), 2.5, 300)
    # Only the key casts a shadow: the low fill and rim threw long ones
    # off the edge of the frame.
    add_area("Fill", (3.0, -2.5, 2.0), 3.0, 50, (0.85, 0.9, 1.0), shadow=False)
    add_area("Rim", (0.5, 3.5, 3.0), 1.5, 300, shadow=False)

    # Mirror direction of the camera about the top face: a light on this
    # line shows up as a highlight on that face. It sweeps across it for
    # the settle glint, and is invisible to diffuse so only the specular
    # glint shows.
    glint_data = bpy.data.lights.new("Glint", "AREA")
    glint_data.size = 0.06
    glint_data.energy = 0.0
    glint = bpy.data.objects.new("Glint", glint_data)
    scene.collection.objects.link(glint)
    glint.visible_diffuse = False
    glint.visible_volume_scatter = False

    bpy.ops.mesh.primitive_plane_add(size=8.0, location=(0, 0, 0))
    ground = bpy.context.active_object
    ground.is_shadow_catcher = True
    # Lit, the catcher would show up mirrored in the die's glossy coat.
    ground.visible_glossy = False
    return glint, target, elev


def clear_animation(*objs):
    for obj in objs:
        obj.animation_data_clear()
        obj.data.animation_data_clear() if hasattr(obj.data, "animation_data_clear") else None


def lowest_extent(q: Quaternion) -> float:
    """Half the die's height for rotation q, so it rests on the ground
    instead of sinking through it (bevel ignored: it only lowers corners)."""
    m = q.to_matrix()
    return 0.5 * (abs(m[2][0]) + abs(m[2][1]) + abs(m[2][2])) - 0.03


def key_die(die, frame, q, z, prev):
    if prev is not None and prev.dot(q) < 0:
        q = -q
    die.rotation_quaternion = q
    die.location = (0, 0, z)
    die.keyframe_insert("rotation_quaternion", frame=frame)
    die.keyframe_insert("location", frame=frame)
    return q


def linear_keys(obj):
    if obj.animation_data and obj.animation_data.action:
        for fc in obj.animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"


def tumble_rotation(spec, t: float) -> Quaternion:
    axis1, turns1, axis2, turns2, base = spec
    q1 = Quaternion(Vector(axis1).normalized(), math.tau * turns1 * t)
    q2 = Quaternion(Vector(axis2).normalized(), math.tau * turns2 * t)
    return q1 @ q2 @ Matrix.Rotation(base[0], 3, "X").to_quaternion() \
        @ Matrix.Rotation(base[1], 3, "Y").to_quaternion() \
        @ Matrix.Rotation(base[2], 3, "Z").to_quaternion()


## Keys every SUBSTEPS of a frame, so the motion blur follows the curved
## spin instead of a straight chord between whole frames.
SUBSTEPS = 4


def render_tumble(die, glint, name, spec, out_dir):
    scene = bpy.context.scene
    clear_animation(die, glint)
    prev = None
    for i in range(-2 * SUBSTEPS, (TUMBLE_FRAMES + 2) * SUBSTEPS + 1):
        f = 1 + i / SUBSTEPS
        t = (f - 1) / TUMBLE_FRAMES
        z = HOVER_Z + 0.04 * math.sin(math.tau * t)
        prev = key_die(die, f, tumble_rotation(spec, t), z, prev)
    linear_keys(die)
    scene.frame_start = 1
    scene.frame_end = TUMBLE_FRAMES
    scene.render.filepath = os.path.join(out_dir, f"tumble_{name}", "")
    bpy.ops.render.render(animation=True)


def settle_pose(value: int, f: float, spin_axis: Vector):
    """(rotation, height) of the settling die at frame f."""
    rest = landed_rotation(value)
    u = min(max((f - 1) / (SETTLE_REST_FRAME - 1), 0.0), 1.0)
    # Fast at the start (matching the tumble it cuts in from), easing to a
    # stop, then a small damped rock about the same axis once down.
    angle = math.radians(150) * (1 - u) ** 2
    after = f - SETTLE_REST_FRAME
    if after > 0:
        angle += math.radians(5) * math.exp(-after * 0.9) * math.sin(after * 2.2)
    if f < 1:
        angle = math.radians(150) * (1 + (1 - f) / (SETTLE_REST_FRAME - 1) * 2)
    q = Quaternion(spin_axis, angle) @ rest
    # Drops from the hover height, a little bounce, then rests on whichever
    # corner or edge is lowest.
    drop = min(max((f - 1) / 5.0, 0.0), 1.0)
    z = HOVER_Z + (0.5 - HOVER_Z) * drop * drop
    if 6 <= f <= 9:
        z += 0.07 * math.sin(math.pi * (f - 6) / 3.0)
    return q, max(z, lowest_extent(q))


def render_settle(die, glint, value, target, elev, out_dir):
    scene = bpy.context.scene
    clear_animation(die, glint)
    spin_axis = Vector((1.0, 0.45 * (1 if value % 2 else -1), 0.15)).normalized()
    prev = None
    for i in range(-2 * SUBSTEPS, (SETTLE_FRAMES + 2) * SUBSTEPS + 1):
        f = 1 + i / SUBSTEPS
        q, z = settle_pose(value, f, spin_axis)
        if f >= SETTLE_REST_FRAME:
            q, z = landed_rotation(value), 0.5
        prev = key_die(die, f, q, z, prev)
    linear_keys(die)

    # Glint: sweeps along the camera's mirror line over the top face.
    mirror = Vector((0, math.cos(elev), math.sin(elev)))
    top = Vector((0, 0, 1.0))
    glint.data.energy = 0.0
    glint.data.keyframe_insert("energy", frame=SETTLE_REST_FRAME)
    for k, f in enumerate(range(SETTLE_REST_FRAME, SETTLE_FRAMES + 2)):
        s = (f - SETTLE_REST_FRAME) / (SETTLE_FRAMES - SETTLE_REST_FRAME)
        glint.location = top + 6 * mirror + Vector((-2.2 + 4.4 * s, -0.6 + 1.2 * s, 0))
        glint.rotation_euler = (top - glint.location).to_track_quat("-Z", "Y").to_euler()
        glint.keyframe_insert("location", frame=f)
        glint.keyframe_insert("rotation_euler", frame=f)
    for f, e in ((SETTLE_REST_FRAME + 1, 120.0), (SETTLE_FRAMES - 1, 120.0), (SETTLE_FRAMES, 0.0)):
        glint.data.energy = e
        glint.data.keyframe_insert("energy", frame=f)
    scene.frame_start = 1
    scene.frame_end = SETTLE_FRAMES
    scene.render.filepath = os.path.join(out_dir, f"settle_{value}", "")
    bpy.ops.render.render(animation=True)
    glint.data.animation_data_clear()
    glint.data.energy = 0.0


def render_landed(die, glint, value, out_dir):
    scene = bpy.context.scene
    clear_animation(die, glint)
    glint.data.energy = 0.0
    die.rotation_quaternion = landed_rotation(value)
    die.location = (0, 0, 0.5)
    scene.frame_set(1)
    scene.render.filepath = os.path.join(out_dir, f"landed_{value}.png")
    bpy.ops.render.render(write_still=True)


def main():
    out_dir = parse_out()
    only = os.environ.get("D6_ONLY", "")
    os.makedirs(out_dir, exist_ok=True)
    reset_scene()
    die = build_die()
    glint, target, elev = build_stage()
    for value in FACES:
        if not only or only == "landed":
            render_landed(die, glint, value, out_dir)
    for name, spec in TUMBLES.items():
        if not only or only == "tumble":
            render_tumble(die, glint, name, spec, out_dir)
    for value in sorted(FACES):
        if not only or only == "settle":
            render_settle(die, glint, value, target, elev, out_dir)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    print("render_d6_sheets: die has", len(die.evaluated_get(depsgraph).data.polygons), "faces")
    print("render_d6_sheets: frames written to", out_dir)


main()
