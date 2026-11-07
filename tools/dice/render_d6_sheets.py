"""Renders the skill-check popup's sprite d6 from the community d20 rig.

The scene is the "Numbered Dice" BG3 custom-dice setup (Nexus mod 1325,
numbers_main.blend): its front-on orthographic camera, four area lights,
world, Cycles settings, the compositor's directional-blur motion smear and
the rig's roll and settle actions are all kept. Only the die is swapped:
the d20 mesh is replaced by a sharp cube, each face a body-coloured square
in a white frame like the d20's faces, numerals 1-6 on top.

The render loop is the mod maker's batch script (the .blend's Text.001),
pointed at d6 actions. Run headless with Blender 4.3:

    blender -b <numbers_main.blend> -P tools/dice/render_d6_sheets.py \
        -- --out <frames_dir>

then pack with tools/dice/pack_d6_sheets.py (tools/dice/build.sh does both).
Into <frames_dir> it writes, as ####.png frames:

    roll_<double_roll_1|double_roll_2|single_roll>/  the community tumbles,
        compositor blur on, result-agnostic, exactly as the d20 renders them.
    settle_<n>/  SETTLE_FRAMES frames: the community d<k> wobble, moved onto
        the cube so it comes to rest with face n square to the camera and its
        numeral upright. The last frame is the landed still.

The .blend is never written back; nothing from it ships but these renders.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector

## Half the cube's edge, world units. The camera's orthographic view is 6
## across, so face-on the die fills 57% of the frame and even corner-on
## (half * sqrt 3 = 2.94) the tumble stays inside it.
HALF = 1.7
## White frame round each face, as a fraction of the edge.
BORDER = 0.07
## Numeral height, fraction of the edge.
NUMERAL = 0.62
## Numerals sit this far proud of the face so they never z-fight it.
NUMERAL_LIFT = 0.004
BODY_COLOR = (0.32, 0.025, 0.03, 1.0)

## Same durations the mod maker's script renders: every settle 18 frames
## (holding the last pose past the action's end), the rolls their length.
SETTLE_FRAMES = 18
ROLLS = {"double_roll_1": 27, "double_roll_2": 28, "single_roll": 61}

## Face n: (outward normal, the way "up" its numeral reads). Opposite faces
## sum to 7.
FACES = {
    1: (Vector((0, 0, 1)), Vector((0, 1, 0))),
    6: (Vector((0, 0, -1)), Vector((0, 1, 0))),
    2: (Vector((1, 0, 0)), Vector((0, 0, 1))),
    5: (Vector((-1, 0, 0)), Vector((0, 0, 1))),
    3: (Vector((0, -1, 0)), Vector((0, 0, 1))),
    4: (Vector((0, 1, 0)), Vector((0, 0, 1))),
}
## Which community settle wobble each face borrows (d1..d6, all distinct).
WOBBLE_OF = {n: f"d{n}" for n in range(1, 7)}


def face_frame(n: int):
    normal, up = FACES[n]
    right = up.cross(normal)
    return right, up, normal


def build_cube(materials) -> bpy.types.Object:
    mesh = bpy.data.meshes.new("d6")
    bm = bmesh.new()
    inner = HALF * (1.0 - 2.0 * BORDER)
    for n in range(1, 7):
        right, up, normal = face_frame(n)
        c = normal * HALF

        def corner(x, y):
            return bm.verts.new(c + right * x + up * y)

        outer = [corner(-HALF, -HALF), corner(HALF, -HALF), corner(HALF, HALF), corner(-HALF, HALF)]
        ins = [corner(-inner, -inner), corner(inner, -inner), corner(inner, inner), corner(-inner, inner)]
        body = bm.faces.new(ins)
        body.material_index = 1
        for i in range(4):
            j = (i + 1) % 4
            strip = bm.faces.new((outer[i], outer[j], ins[j], ins[i]))
            strip.material_index = 0
    bm.normal_update()
    bm.to_mesh(mesh)
    bm.free()
    for m in materials:
        mesh.materials.append(m)
    for p in mesh.polygons:
        p.use_smooth = False
    return bpy.data.objects.new("d6", mesh)


def build_numeral(n: int, material) -> bpy.types.Object:
    curve = bpy.data.curves.new(f"num{n}", "FONT")
    curve.body = str(n)
    curve.align_x = "CENTER"
    curve.align_y = "CENTER"
    curve.size = 2.0 * HALF * NUMERAL
    text = bpy.data.objects.new(f"num{n}", curve)
    bpy.context.scene.collection.objects.link(text)
    mesh = text.to_mesh().copy()
    text.to_mesh_clear()
    bpy.data.objects.remove(text)
    bpy.data.curves.remove(curve)
    right, up, normal = face_frame(n)
    # Text lies in its local XY, facing +Z: map that onto the face.
    basis = Matrix((right, up, normal)).transposed().to_4x4()
    mesh.transform(Matrix.Translation(normal * (HALF + NUMERAL_LIFT)) @ basis)
    mesh.materials.append(material)
    return bpy.data.objects.new(f"num{n}", mesh)


def swap_die(dice_empty: bpy.types.Object) -> None:
    old = bpy.data.objects["dice"]
    edge, body = old.data.materials[0], old.data.materials[1]
    for name in ("dice", "numbers"):
        bpy.data.objects.remove(bpy.data.objects[name])

    # Body: the community plastic, a flat colour where its (missing) d20
    # texture was. Its shading-only bevel rounds the edges; the cube's are
    # meant to be sharp.
    tree = body.node_tree
    for node in tree.nodes:
        if node.type == "GROUP" and "Base Color" in node.inputs:
            sock = node.inputs["Base Color"]
            for link in list(sock.links):
                tree.links.remove(link)
            sock.default_value = BODY_COLOR
            for inner in node.node_tree.nodes:
                if inner.type == "BEVEL":
                    inner.inputs["Radius"].default_value = 0.0

    scene = bpy.context.scene
    parts = [build_cube([edge, body])] + [build_numeral(n, edge) for n in range(1, 7)]
    for part in parts:
        scene.collection.objects.link(part)
        part.parent = dice_empty
        part.matrix_parent_inverse = Matrix.Identity(4)


def face_target(n: int) -> Quaternion:
    """The Dice rotation that turns face n square to the camera (+Z),
    numeral upright (+Y on screen)."""
    right, up, normal = face_frame(n)
    return Matrix((right, up, normal)).to_quaternion()


def reset_deltas(obj) -> None:
    obj.delta_rotation_euler = (0, 0, 0)
    obj.delta_rotation_quaternion = (1, 0, 0, 0)
    obj.delta_location = (0, 0, 0)


def settle_action(dice_empty, scene, n: int) -> bpy.types.Action:
    """The community wobble WOBBLE_OF[n], re-aimed at face n: every frame's
    rotation is the wobble's own rotation relative to where it ends, applied
    on top of face n's rest pose. Location and scale are kept as is."""
    source = bpy.data.actions[WOBBLE_OF[n]]
    dice_empty.animation_data.action = source
    dice_empty.rotation_mode = "QUATERNION"
    first, last = int(source.frame_range[0]), int(source.frame_range[1])
    samples = []
    for f in range(first, last + 1):
        scene.frame_set(f)
        samples.append((f, dice_empty.rotation_quaternion.copy(), dice_empty.location.copy(), dice_empty.scale.copy()))
    rest_inv = samples[-1][1].normalized().inverted()
    target = face_target(n)

    action = bpy.data.actions.new(f"d6_{n}")
    dice_empty.animation_data.action = action
    prev = None
    for f, q, loc, scale in samples:
        out = (q.normalized() @ rest_inv) @ target
        if prev is not None and prev.dot(out) < 0.0:
            out.negate()
        prev = out
        dice_empty.rotation_quaternion = out
        dice_empty.location = loc
        dice_empty.scale = scale
        for path in ("rotation_quaternion", "location", "scale"):
            dice_empty.keyframe_insert(path, frame=f)
    for fc in action.fcurves:
        for k in fc.keyframe_points:
            k.interpolation = "LINEAR"
    return action


def use_gpu() -> None:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for backend in ("OPTIX", "CUDA", "HIP", "ONEAPI"):
        try:
            prefs.compute_device_type = backend
        except TypeError:
            continue
        prefs.get_devices()
        if any(d.type == backend for d in prefs.devices):
            for d in prefs.devices:
                d.use = d.type == backend
            print("render_d6_sheets: Cycles on", backend)
            return
    bpy.context.scene.cycles.device = "CPU"
    print("render_d6_sheets: Cycles on CPU")


def render(dice_empty, scene, action, out_dir: str, duration: int, compositing: bool) -> None:
    """The mod maker's loop body: assign, set the range, render."""
    reset_deltas(dice_empty)
    dice_empty.animation_data.action = action
    scene.use_nodes = compositing
    scene.frame_start = int(action.frame_range[0])
    scene.frame_end = scene.frame_start + duration - 1
    os.makedirs(out_dir, exist_ok=True)
    scene.render.filepath = os.path.join(out_dir, "")
    bpy.ops.render.render(animation=True)


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = os.path.abspath(argv[argv.index("--out") + 1])

    scene = bpy.data.scenes["d20"]
    if bpy.context.window:
        bpy.context.window.scene = scene
    dice_empty = bpy.data.objects["Dice"]
    swap_die(dice_empty)
    use_gpu()
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"

    settles = {n: settle_action(dice_empty, scene, n) for n in range(1, 7)}
    for n, action in settles.items():
        dice_empty.rotation_mode = "QUATERNION"
        render(dice_empty, scene, action, os.path.join(out, f"settle_{n}"), SETTLE_FRAMES, False)
    for name, duration in ROLLS.items():
        dice_empty.rotation_mode = "QUATERNION"
        render(dice_empty, scene, bpy.data.actions[name], os.path.join(out, f"roll_{name}"), duration, True)
    print("render_d6_sheets: frames written to", out)


main()
