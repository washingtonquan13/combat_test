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
        result-agnostic, re-aimed to come to rest face-on with REST_FACE up
        front; the compositor's spin blur is keyed from each frame's turn,
        so it fades out as the die slows.
    settle_<n>/  SETTLE_FRAMES frames like BG3's d20_N: the die still, face n
        square to the camera, numeral upright, a glint sweeping across. The
        last frame is the landed still.
    cover/  one frame: the die at rest with no numeral, BG3's faceCover,
        which the popup lays over the cut from roll to result.

Pass --only a,b to render just those (roll names, settle_<n>, cover).

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
## Every roll comes to rest with this face up front; the popup's face cover
## hides its numeral while the result's takes over.
REST_FACE = 1
## The roll eases the last of the way to rest over this many frames.
DAMP_FRAMES = 6
## Spin blur per degree the die turned that frame, and its cap (the rig's).
BLUR_PER_DEGREE = 0.5
BLUR_MAX_DEGREES = 20.0
## The result sheet's glint: the frames it crosses the face between, its
## height (above the camera's 7.2, so the camera never sees it), how far to
## either side of centre it waits, its width and power.
GLINT_FRAMES = (4, 13)
GLINT_HEIGHT = 9.0
GLINT_REACH = 4.0
GLINT_WIDTH = 0.8
GLINT_ENERGY = 400.0


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


def key_pose(obj, frame: int, rotation: Quaternion, location: Vector) -> None:
    obj.rotation_quaternion = rotation
    obj.location = location
    obj.scale = (1, 1, 1)
    for path in ("rotation_quaternion", "location", "scale"):
        obj.keyframe_insert(path, frame=frame)


def linear(action) -> None:
    for fc in action.fcurves:
        for k in fc.keyframe_points:
            k.interpolation = "LINEAR"


def roll_action(dice_empty, scene, name: str, duration: int):
    """The community tumble `name`, re-aimed so it comes to rest square to
    the camera in the pose every result sheet holds (REST_FACE up front).

    On the d20 a tumble can stop anywhere: an icosahedron's outline is near
    enough the same from every side, so BG3 cuts from the roll's last frame
    to the result sheet without a seam. A cube's outline is not, so every
    frame's rotation is taken relative to where the tumble ends and applied
    on top of the rest pose, and the last DAMP_FRAMES ease the rest of the
    way in, so the die stops instead of freezing mid-turn.
    Returns the action, each frame's location and each frame's spin in
    degrees."""
    source = bpy.data.actions[name]
    dice_empty.animation_data.action = source
    first = int(source.frame_range[0])
    samples = []
    for f in range(first, first + duration):
        scene.frame_set(f)
        loc, rot, _scale = dice_empty.matrix_world.decompose()
        samples.append((loc.copy(), rot.normalized()))
    end_inv = samples[-1][1].inverted()
    rest = face_target(REST_FACE)

    reset_deltas(dice_empty)
    dice_empty.rotation_mode = "QUATERNION"
    action = bpy.data.actions.new(f"d6_{name}")
    dice_empty.animation_data.action = action
    spins, locations, prev = [], [], None
    for i, (loc, rot) in enumerate(samples):
        q = (rot @ end_inv) @ rest
        t = min(1.0, max(0.0, (i - (duration - 1 - DAMP_FRAMES)) / DAMP_FRAMES))
        w = t * t * (3.0 - 2.0 * t)
        q = q.slerp(rest, w)
        loc = loc.lerp(Vector((0, 0, 0)), w)
        if prev is not None and prev.dot(q) < 0.0:
            q.negate()
        spins.append(0.0 if prev is None else math.degrees(prev.rotation_difference(q).angle))
        locations.append(loc)
        prev = q
        key_pose(dice_empty, first + i, q, loc)
    linear(action)
    if len(spins) > 1:
        spins[0] = spins[1]
    return action, locations, spins


def blur_action(scene, name: str, first: int, locations, spins) -> None:
    """Keys the rig's spin blur (the Directional Blur.001 that feeds the
    Composite) frame by frame from the die's own motion: centred where the
    die is on screen, BLUR_PER_DEGREE of spin per degree it turned that
    frame, at most the rig's 20, so the smear dies away as the die stops.
    The rig's own keys were set by hand for one roll and hold full blur to
    the last frame of the others."""
    tree = scene.node_tree
    node = tree.nodes["Directional Blur.001"]
    if tree.animation_data is None:
        tree.animation_data_create()
    action = bpy.data.actions.new(f"blur_{name}")
    tree.animation_data.action = action
    across = scene.camera.data.ortho_scale
    for i, (loc, spin) in enumerate(zip(locations, spins)):
        f = first + i
        node.spin = math.radians(min(BLUR_MAX_DEGREES, spin * BLUR_PER_DEGREE))
        node.center_x = 0.5 + loc.x / across
        node.center_y = 0.5 + loc.y / across
        node.distance = 0.0
        node.zoom = 0.0
        for prop in ("spin", "center_x", "center_y", "distance", "zoom"):
            node.keyframe_insert(prop, frame=f)
    linear(action)


def still_action(dice_empty, n: int):
    """BG3's result sheet: the die holds still at rest, face n square to the
    camera, while the glint sweeps over it."""
    reset_deltas(dice_empty)
    dice_empty.rotation_mode = "QUATERNION"
    action = bpy.data.actions.new(f"d6_{n}")
    dice_empty.animation_data.action = action
    key_pose(dice_empty, 1, face_target(n), Vector((0, 0, 0)))
    key_pose(dice_empty, SETTLE_FRAMES, face_target(n), Vector((0, 0, 0)))
    linear(action)
    return action


def build_glint(scene):
    """A long thin area light above the camera, out of its sight and seen
    only in the face's reflection (no diffuse), so it adds a highlight bar
    and nothing else. Keyed to cross the face diagonally between
    GLINT_FRAMES and to sit out of reach before and after, so the first
    frame matches the roll's last and the last is the clean landed still."""
    data = bpy.data.lights.new("glint", "AREA")
    data.shape = "RECTANGLE"
    data.size = GLINT_WIDTH
    data.size_y = 14.0
    data.energy = GLINT_ENERGY
    glint = bpy.data.objects.new("glint", data)
    scene.collection.objects.link(glint)
    glint.visible_diffuse = False
    glint.visible_transmission = False
    glint.visible_volume_scatter = False
    glint.rotation_euler = (0, 0, math.radians(-45))
    a, b = GLINT_FRAMES
    across = Vector((1, -1, 0)).normalized()
    for f, s in ((1, -GLINT_REACH), (a, -GLINT_REACH), (b, GLINT_REACH), (SETTLE_FRAMES, GLINT_REACH)):
        glint.location = across * s + Vector((0, 0, GLINT_HEIGHT))
        glint.keyframe_insert("location", frame=f)
    linear(glint.animation_data.action)
    glint.hide_render = True
    return glint


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

    glint = build_glint(scene)
    numerals = [o for o in dice_empty.children if o.name.startswith("num")]
    only = argv[argv.index("--only") + 1].split(",") if "--only" in argv else None

    def wanted(key: str) -> bool:
        return only is None or key in only

    for name, duration in ROLLS.items():
        if not wanted(name):
            continue
        action, locations, spins = roll_action(dice_empty, scene, name, duration)
        blur_action(scene, name, int(action.frame_range[0]), locations, spins)
        render(dice_empty, scene, action, os.path.join(out, f"roll_{name}"), duration, True)

    glint.hide_render = False
    for n in range(1, 7):
        if wanted(f"settle_{n}"):
            render(dice_empty, scene, still_action(dice_empty, n), os.path.join(out, f"settle_{n}"), SETTLE_FRAMES, False)
    glint.hide_render = True

    # The face cover: the die at rest with no numeral, laid over the cut
    # from the roll's last frame to the result sheet.
    if wanted("cover"):
        for o in numerals:
            o.hide_render = True
        render(dice_empty, scene, still_action(dice_empty, REST_FACE), os.path.join(out, "cover"), 1, False)
    print("render_d6_sheets: frames written to", out)


main()
