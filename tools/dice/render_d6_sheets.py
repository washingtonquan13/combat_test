"""Renders the skill-check popup's sprite d6 from the community d20 rig.

The scene is the "Numbered Dice" BG3 custom-dice setup (Nexus mod 1325,
numbers_main.blend): its orthographic top-down camera, four area lights,
world, EEVEE and colour settings are kept; its compositor blur is off, real
motion blur does that job. The d20 is swapped for a sharp cube, each face a
body-coloured square in a narrow white frame, numerals 1-6 (DejaVu Sans
Bold, whose 1 has a flag and a foot) on top. Run headless with Blender 4.3:

    blender -b <numbers_main.blend> -P tools/dice/render_d6_sheets.py \
        -- --throws <throws.json> --out <frames_dir>

The motion is not made here: tools/dice/d6_throws.py simulates and picks the
throws and writes every sample (SAMPLES a frame) of each, already turned to
rest square to the screen, once per result face, labelled from the first
sample. This only keys them: every (throw, result) is one whole roll. Each
frame is centred on the die at the moment its shutter opens (a follow empty
carries the camera and every light, so the lighting rides with the die) and
the shutter smears the next 0.9 frame's spin and travel.

Into <frames_dir>, one PNG per frame, named by the throw's frame index:

    roll_<i>_<n>/  throw i, n = 1..6, all its frames, labelled so face n
                   ends up
    still_<n>/     the die at rest, face n up, numeral upright
    still_blank/   the same with no numeral
    numeral_<n>/   numeral n alone, the cube a holdout
    glint/         GLINT_FRAMES frames: a highlight sweeps the resting
                   (blank) die; pack_d6_sheets.py subtracts still_blank

Pass --only a,b to render just those folders (roll_<i>_<n>, still, blank,
numerals, glint), --frames f,g to render just those frames of each roll and
--steps N to override MOTION_STEPS (the strobe check renders with both).
tools/dice/pack_d6_sheets.py packs the frames; tools/dice/build.sh runs all.

The .blend is never written back; nothing from it ships but these renders.
"""

import itertools
import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector

## Half the cube's edge, world units. Must match d6_throws.py.
HALF = 1.7
## Cell edge, px, and the face edge at rest, px: the camera's orthographic
## view is the cell, so face-on the die is FACE_PX across.
CELL_PX = 208
FACE_PX = 96
## White frame round each face, as a fraction of the edge. Narrow, so a
## motion-blurred face stays red rather than washing out pink.
BORDER = 0.0375
## Numeral font (a 1 with a flag and a foot) and its cap height (the height
## of its flat-topped 1), as a fraction of the edge.
NUMERAL_FONT = os.environ.get("DICE_FONT", "C:/Windows/Fonts/DejaVuSans-Bold.ttf")
NUMERAL_CAP = 0.5
## Numerals sit this far proud of the face so they never z-fight it.
NUMERAL_LIFT = 0.004
BODY_COLOR = (0.32, 0.025, 0.03, 1.0)
BODY_ROUGHNESS = 0.3
## Mesh attribute the body's texture reads instead of object coordinates.
FACE_CO = "face_co"

## Real motion blur: shutter open at the frame, this long, in this many
## sub-frame steps (each blurred by velocity in between). Half a frame:
## a longer shutter smears the white border into a translucent fringe.
SHUTTER = 0.5
MOTION_STEPS = 8
RENDER_SAMPLES = 64

## The overhead card: a soft box over the die, riding with it, so the top
## face carries a broad plastic sheen.
CARD_SIZE = (7.0, 5.0)
CARD_ENERGY = 250.0
CARD_ABOVE_TOP = 4.0

## The glint: a long thin specular-only bar sweeping the resting die
## diagonally, from off its face to off its other side.
GLINT_FRAMES = 10
GLINT_ABOVE_TOP = 1.5
GLINT_REACH = 4.5
GLINT_WIDTH = 0.5
GLINT_ENERGY = 260.0

## Face n: (outward normal, the way "up" its numeral reads). Opposite faces
## sum to 7. Must match d6_throws.py's FACES.
FACES = {
    1: (Vector((0, 0, 1)), Vector((0, 1, 0))),
    6: (Vector((0, 0, -1)), Vector((0, 1, 0))),
    2: (Vector((1, 0, 0)), Vector((0, 0, 1))),
    5: (Vector((-1, 0, 0)), Vector((0, 0, 1))),
    3: (Vector((0, -1, 0)), Vector((0, 0, 1))),
    4: (Vector((0, 1, 0)), Vector((0, 0, 1))),
}
## Lights from the rig, kept where it put them round the die.
RIG_LIGHTS = ("Area", "Area.001", "Area.002", "Area.003")


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
    # Each corner's place in its own face's frame (right, up, out), for the
    # body's grain and scratches: textured from object space, every face
    # would show a different slice, so a still's body would differ from
    # face to face and no one blank could sit under every numeral.
    face_co = mesh.attributes.new(FACE_CO, "FLOAT_VECTOR", "CORNER")
    for poly in mesh.polygons:
        n = next(k for k in FACES if (FACES[k][0] - poly.normal).length < 1e-4)
        right, up, normal = face_frame(n)
        for li in poly.loop_indices:
            co = mesh.vertices[mesh.loops[li].vertex_index].co
            face_co.data[li].vector = (co.dot(right), co.dot(up), co.dot(normal))
    for m in materials:
        mesh.materials.append(m)
    for p in mesh.polygons:
        p.use_smooth = False
    return bpy.data.objects.new("d6", mesh)


def glyph_mesh(body: str, font, size: float) -> bpy.types.Mesh:
    curve = bpy.data.curves.new(f"num{body}", "FONT")
    curve.body = body
    curve.font = font
    curve.align_x = "CENTER"
    curve.align_y = "CENTER"
    curve.size = size
    text = bpy.data.objects.new(f"num{body}", curve)
    bpy.context.scene.collection.objects.link(text)
    mesh = text.to_mesh().copy()
    text.to_mesh_clear()
    bpy.data.objects.remove(text)
    bpy.data.curves.remove(curve)
    return mesh


def numeral_size(font) -> float:
    """The font size that stands a 1 (flat foot, flag at cap height)
    NUMERAL_CAP of the edge."""
    mesh = glyph_mesh("1", font, 1.0)
    ys = [v.co.y for v in mesh.vertices]
    bpy.data.meshes.remove(mesh)
    return NUMERAL_CAP * 2.0 * HALF / (max(ys) - min(ys))


def build_numeral(n: int, font, size: float, material) -> bpy.types.Object:
    mesh = glyph_mesh(str(n), font, size)
    # Centre the glyph's own box on the face: the font's CENTER alignment
    # centres the line, which sits the digits high.
    xs = [v.co.x for v in mesh.vertices]
    ys = [v.co.y for v in mesh.vertices]
    mesh.transform(Matrix.Translation((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, 0)))
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
    # texture was, a set roughness so the card reads as a soft sheen. Its
    # shading-only bevel rounds the edges; the cube's are meant to be sharp.
    tree = body.node_tree
    for node in tree.nodes:
        if node.type == "GROUP" and "Base Color" in node.inputs:
            sock = node.inputs["Base Color"]
            for link in list(sock.links):
                tree.links.remove(link)
            sock.default_value = BODY_COLOR
            inner_tree = node.node_tree
            for coord in [n for n in inner_tree.nodes if n.type == "TEX_COORD"]:
                attr = inner_tree.nodes.new("ShaderNodeAttribute")
                attr.attribute_type = "GEOMETRY"
                attr.attribute_name = FACE_CO
                # A new link into a socket replaces the one there.
                for to in [link.to_socket for link in coord.outputs["Object"].links]:
                    inner_tree.links.new(attr.outputs["Vector"], to)
            for inner in inner_tree.nodes:
                if inner.type == "BEVEL":
                    inner.inputs["Radius"].default_value = 0.0
                if inner.type == "BSDF_PRINCIPLED":
                    rough = inner.inputs["Roughness"]
                    for link in list(rough.links):
                        inner_tree.links.remove(link)
                    rough.default_value = BODY_ROUGHNESS

    scene = bpy.context.scene
    if not os.path.isfile(NUMERAL_FONT):
        raise SystemExit(f"render_d6_sheets: numeral font {NUMERAL_FONT} missing (set DICE_FONT)")
    font = bpy.data.fonts.load(NUMERAL_FONT)
    size = numeral_size(font)
    parts = [build_cube([edge, body])] + [build_numeral(n, font, size, edge) for n in range(1, 7)]
    for part in parts:
        scene.collection.objects.link(part)
        part.parent = dice_empty
        part.matrix_parent_inverse = Matrix.Identity(4)


def face_target(n: int) -> Quaternion:
    """The Dice rotation that turns face n square to the camera (+Z),
    numeral upright (+Y on screen)."""
    right, up, normal = face_frame(n)
    return Matrix((right, up, normal)).to_quaternion()


def cube_turns():
    """The 24 rotations that map the cube onto itself."""
    turns = []
    for m in itertools.permutations(range(3)):
        for signs in itertools.product((1, -1), repeat=3):
            rows = [Vector([signs[i] if j == m[i] else 0 for j in range(3)]) for i in range(3)]
            mat = Matrix(rows)
            if mat.determinant() > 0:
                turns.append(mat.to_quaternion())
    return turns


def build_follow(scene) -> bpy.types.Object:
    """A translation-only empty the camera and every light hang from, at
    their rig offsets round the die's centre (the rig's die sat at the
    origin). Keyed to the die per frame, constant between: the view is
    centred on the die as the shutter opens and holds while it moves."""
    follow = bpy.data.objects.new("follow", None)
    scene.collection.objects.link(follow)
    riders = [scene.camera] + [bpy.data.objects[n] for n in RIG_LIGHTS]

    card_data = bpy.data.lights.new("card", "AREA")
    card_data.shape = "RECTANGLE"
    card_data.size, card_data.size_y = CARD_SIZE
    card_data.energy = CARD_ENERGY
    card = bpy.data.objects.new("card", card_data)
    scene.collection.objects.link(card)
    card.location = (0.0, 0.0, HALF + CARD_ABOVE_TOP)
    riders.append(card)

    for obj in riders:
        obj.animation_data_clear()
        world = obj.matrix_world.copy()
        obj.parent = follow
        obj.matrix_parent_inverse = Matrix.Identity(4)
        obj.matrix_basis = world
    return follow


def build_glint(scene, follow) -> bpy.types.Object:
    """Seen only in the body's reflection (no diffuse), so it adds a
    highlight bar and nothing else; the camera is orthographic and straight
    down, so the bar lights the face under its own footprint. Keyed to cross
    the face diagonally over GLINT_FRAMES, off the face at both ends."""
    data = bpy.data.lights.new("glint", "AREA")
    data.shape = "RECTANGLE"
    data.size = GLINT_WIDTH
    data.size_y = 14.0
    data.energy = GLINT_ENERGY
    data.diffuse_factor = 0.0
    data.volume_factor = 0.0
    glint = bpy.data.objects.new("glint", data)
    scene.collection.objects.link(glint)
    glint.parent = follow
    glint.rotation_euler = (0, 0, math.radians(-45))
    across = Vector((1, -1, 0)).normalized()
    up = Vector((0, 0, HALF + GLINT_ABOVE_TOP))
    for f, s in ((0, -GLINT_REACH), (GLINT_FRAMES - 1, GLINT_REACH)):
        glint.location = across * s + up
        glint.keyframe_insert("location", frame=f)
    for fc in glint.animation_data.action.fcurves:
        for k in fc.keyframe_points:
            k.interpolation = "LINEAR"
    glint.hide_render = True
    return glint


def keyed_action(name: str, frames, tracks, interpolation: str):
    """An action from sampled channels: tracks is [(data_path, [values per
    key])]. Built through fcurves directly; keyframe_insert per key is slow
    at four samples a frame."""
    action = bpy.data.actions.new(name)
    count = len(frames)
    for path, values in tracks:
        for index in range(len(values[0])):
            fc = action.fcurves.new(path, index=index)
            fc.keyframe_points.add(count)
            co = []
            for f, v in zip(frames, values):
                co += (f, v[index])
            fc.keyframe_points.foreach_set("co", co)
            for k in fc.keyframe_points:
                k.interpolation = interpolation
                k.handle_left_type = k.handle_right_type = "VECTOR"
            fc.update()
    return action


def pose(dice_empty, follow, samples: int, positions, quats) -> None:
    """Keys the die on every sample (frame s / samples) and the follow empty
    on whole frames. A single position and rotation holds a still pose."""
    dice_frames = [s / samples for s in range(len(positions))]
    quats = [list(q) for q in quats]
    for a, b in zip(quats, quats[1:]):
        if sum(x * y for x, y in zip(a, b)) < 0.0:
            b[:] = [-x for x in b]
    dice_empty.animation_data.action = keyed_action(
        "die", dice_frames, [("location", positions), ("rotation_quaternion", quats)], "LINEAR")
    whole = list(range(0, len(positions), samples))
    follow.animation_data.action = keyed_action(
        "follow", [s // samples for s in whole], [("location", [positions[s] for s in whole])], "CONSTANT")


def render_frames(scene, out_dir: str, first: int, last: int, frames=None) -> None:
    """Renders frames first..last (or just the listed ones among them) as
    <out_dir>/<frame>.png."""
    os.makedirs(out_dir, exist_ok=True)
    scene.render.filepath = os.path.join(out_dir, "")
    spans = [(first, last)] if frames is None else [(f, f) for f in frames if first <= f <= last]
    for a, b in spans:
        scene.frame_start, scene.frame_end = a, b
        bpy.ops.render.render(animation=True)


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

    def arg(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default

    out = os.path.abspath(arg("--out"))
    with open(arg("--throws")) as fh:
        throws = json.load(fh)
    assert abs(throws["half"] - HALF) < 1e-9 and throws["face_px"] == FACE_PX
    only = arg("--only").split(",") if arg("--only") else None
    pick = [int(f) for f in arg("--frames").split(",")] if arg("--frames") else None
    samples = throws["samples"]

    def wanted(key: str) -> bool:
        return only is None or key in only

    scene = bpy.data.scenes["d20"]
    if bpy.context.window:
        bpy.context.window.scene = scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.fps = throws["fps"]
    scene.render.fps_base = 1.0
    scene.render.resolution_x = scene.render.resolution_y = CELL_PX
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.use_motion_blur = True
    scene.render.motion_blur_shutter = SHUTTER
    scene.render.motion_blur_position = "START"
    scene.eevee.motion_blur_steps = int(arg("--steps", MOTION_STEPS))
    scene.eevee.taa_render_samples = RENDER_SAMPLES
    scene.use_nodes = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.camera.data.ortho_scale = 2.0 * HALF * CELL_PX / FACE_PX

    dice_empty = bpy.data.objects["Dice"]
    dice_empty.animation_data_clear()
    dice_empty.animation_data_create()
    dice_empty.delta_location = (0, 0, 0)
    dice_empty.delta_rotation_quaternion = (1, 0, 0, 0)
    dice_empty.scale = (1, 1, 1)
    dice_empty.rotation_mode = "QUATERNION"
    swap_die(dice_empty)
    follow = build_follow(scene)
    follow.animation_data_create()
    glint = build_glint(scene, follow)
    cube = bpy.data.objects["d6"]
    numerals = {n: bpy.data.objects[f"num{n}"] for n in range(1, 7)}

    for i, head in enumerate(throws["heads"]):
        positions = head["samples"]["pos"]
        for n in range(1, 7):
            key = f"roll_{i}_{n}"
            if not wanted(key):
                continue
            pose(dice_empty, follow, samples, positions, head["samples"]["quat"][str(n)])
            render_frames(scene, os.path.join(out, key), 0, head["frames"] - 1, pick)

    rest = [(0.0, 0.0, HALF)]

    def still(folder: str, n: int, frames: int = 1) -> None:
        pose(dice_empty, follow, samples, rest, [face_target(n)])
        render_frames(scene, os.path.join(out, folder), 0, frames - 1)

    if wanted("still"):
        for n in range(1, 7):
            still(f"still_{n}", n)
    for o in numerals.values():
        o.hide_render = True
    if wanted("blank"):
        still("still_blank", 1)
    if wanted("glint"):
        glint.hide_render = False
        still("glint", 1, GLINT_FRAMES)
        glint.hide_render = True
    if wanted("numerals"):
        cube.is_holdout = True
        for n in range(1, 7):
            numerals[n].hide_render = False
            still(f"numeral_{n}", n)
            numerals[n].hide_render = True
        cube.is_holdout = False
    print("render_d6_sheets: frames written to", out)


main()
