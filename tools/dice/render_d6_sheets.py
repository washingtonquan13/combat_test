"""Renders the skill-check popup's sprite d6 from the community d20 rig.

The scene is the "Numbered Dice" BG3 custom-dice setup (Nexus mod 1325,
numbers_main.blend): its front-on orthographic camera, four area lights,
world, Cycles settings, the compositor's directional-blur motion smear and
the mod maker's render loop are kept. The die is swapped:
the d20 mesh is replaced by a sharp cube, each face a body-coloured square
in a white frame like the d20's faces, numerals 1-6 on top.

The render loop is the mod maker's batch script (the .blend's Text.001),
pointed at d6 actions; the tumbles are simulated here, since the rig's
roll actions were keyed for a d20. Run headless with Blender 4.3:

    blender -b <numbers_main.blend> -P tools/dice/render_d6_sheets.py \
        -- --out <frames_dir>

then pack with tools/dice/pack_d6_sheets.py (tools/dice/build.sh does both).
Into <frames_dir> it writes, as ####.png frames:

    tumble_<1|2|3>/  physics-simulated throws (TUMBLES), result-agnostic,
        each ending flat at rest with REST_FACE square to the camera; the
        compositor's spin blur is keyed from each frame's turn, so it
        fades out as the die slows.
    settle_<n>/  SETTLE_FRAMES frames like BG3's d20_N: the die still, face n
        square to the camera, numeral upright, a glint sweeping across. The
        last frame is the landed still.
    cover/  one frame: the die at rest with no numeral, BG3's faceCover,
        which the popup lays over the cut from roll to result.

Pass --only a,b to render just those (tumble_<n>, settle_<n>, cover).

The .blend is never written back; nothing from it ships but these renders.
"""

import itertools
import math
import os
import random
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

## Every result sheet is 18 frames, as the mod maker's script renders them.
SETTLE_FRAMES = 18

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


## The tumbles, physics-simulated rather than taken from the rig: the rig's
## roll actions were keyed for a d20, which reads as rolling however it
## spins, while a cube spinning freely just looks like a box in the air. A
## d6 tumbles: hits, hops, goes over its edges and tips flat. Each is a
## throw onto the floor (the camera looks straight down at it) from these
## seeds of throw_conditions, chosen for many edge flips.
TUMBLES = {"1": 19, "2": 12, "3": 35}
## The sim: the rig's 18 frames a second, substeps per frame, gravity
## (world units are the cube's: HALF = 1.7), restitution, friction.
SIM_FPS = 18
SIM_SUBSTEPS = 80
SIM_GRAVITY = 40.0
SIM_RESTITUTION = 0.35
SIM_FRICTION = 0.55
SIM_MAX_FRAMES = 120


def throw_conditions(seed: int):
    """Start state for throw `seed`: dropped from above while moving
    forward fast, at a random attitude and spin."""
    rnd = random.Random(seed)
    q = Quaternion(Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1))).normalized(), rnd.uniform(0, 6.28))
    w = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1))).normalized() * rnd.uniform(8, 16)
    v = Vector((rnd.uniform(20, 30), rnd.uniform(-4, 4), -6))
    return Vector((0, 0, 6)), v, q, w


def simulate(x, v, q, w):
    """A solid cube against the floor z = 0: impulses at every corner below
    it, restitution only on real impacts so it can come to rest, Coulomb
    friction, which is what turns its slide into rolling over an edge.
    Returns each frame's orientation, until it has been still two frames."""
    corners = [Vector((sx, sy, sz)) * HALF for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    inv_i = 6.0 / (2 * HALF) ** 2
    n = Vector((0, 0, 1))
    dt = 1.0 / (SIM_FPS * SIM_SUBSTEPS)
    out, still = [], 0
    for _f in range(SIM_MAX_FRAMES):
        for _s in range(SIM_SUBSTEPS):
            v.z -= SIM_GRAVITY * dt
            x += v * dt
            dq = Quaternion((0.0, w.x, w.y, w.z)) @ q
            q = Quaternion([a + 0.5 * dt * b for a, b in zip(q, dq)]).normalized()
            rot = q.to_matrix()
            contacts = [rot @ c for c in corners if (x + rot @ c).z < 0.0]
            if not contacts:
                continue
            x.z -= min((x + r).z for r in contacts)
            for _it in range(4):
                for r in contacts:
                    un = (v + w.cross(r)).dot(n)
                    if un >= 0.0:
                        continue
                    e = SIM_RESTITUTION if un < -3.0 else 0.0
                    rn = r.cross(n)
                    jn = -(1.0 + e) * un / (1.0 + inv_i * rn.dot(rn))
                    v += n * jn
                    w += rn * (jn * inv_i)
                    u = v + w.cross(r)
                    ut = u - n * u.dot(n)
                    if ut.length > 1e-6:
                        t = ut.normalized()
                        rt = r.cross(t)
                        jt = max(-ut.length / (1.0 + inv_i * rt.dot(rt)), -SIM_FRICTION * jn)
                        v += t * jt
                        w += rt * (jt * inv_i)
        out.append(q.copy())
        if v.length < 0.15 and w.length < 0.15 and x.z < HALF + 0.02:
            still += 1
            if still >= 2:
                break
        else:
            still = 0
    return out


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


def tumble_action(dice_empty, name: str, seed: int):
    """Throw `seed`, aimed to come to rest in the pose every result sheet
    holds (REST_FACE square to the camera, numeral upright).

    The sim's die lands with whatever face up, turned some way about the
    camera's axis. Relabelling which face is which (a turn of the cube onto
    itself, applied in its own frame) and turning the whole throw about the
    camera's axis (screen rotation, which the eye cannot tell from another
    throw) put it exactly at rest without touching the motion.
    The die stays centred like the rig's rolls; the popup moves it.
    Returns the action, each frame's location and each frame's spin."""
    samples = simulate(*throw_conditions(seed))
    end = samples[-1]
    rest = face_target(REST_FACE)
    best = None
    for m in cube_turns():
        fix = rest @ (end @ m).inverted()
        tilt = (fix.to_matrix() @ Vector((0, 0, 1))).angle(Vector((0, 0, 1)))
        if best is None or tilt < best[0]:
            best = (tilt, fix, m)
    _tilt, fix, m = best

    reset_deltas(dice_empty)
    dice_empty.rotation_mode = "QUATERNION"
    action = bpy.data.actions.new(f"d6_tumble_{name}")
    dice_empty.animation_data.action = action
    spins, locations, prev = [], [], None
    for i, q in enumerate(samples):
        q = fix @ q @ m
        if prev is not None and prev.dot(q) < 0.0:
            q.negate()
        spins.append(0.0 if prev is None else math.degrees(prev.rotation_difference(q).angle))
        locations.append(Vector((0, 0, 0)))
        prev = q
        key_pose(dice_empty, 1 + i, q, Vector((0, 0, 0)))
    linear(action)
    if len(spins) > 1:
        spins[0] = spins[1]
    print(f"render_d6_sheets: tumble_{name} seed {seed}: {len(samples)} frames")
    return action, locations, spins, len(samples)


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

    for name, seed in TUMBLES.items():
        if not wanted(f"tumble_{name}"):
            continue
        action, locations, spins, duration = tumble_action(dice_empty, name, seed)
        blur_action(scene, name, 1, locations, spins)
        render(dice_empty, scene, action, os.path.join(out, f"tumble_{name}"), duration, True)

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
