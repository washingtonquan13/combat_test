"""Renders the odds wheel once, in layers, for odds_wheel.gd to put back together.

blender -b --factory-startup -P render_wheel.py -- --look lacquer|wood --out DIR [--size N] [--samples N] [--only a,b]

wheel_<kind>   Wedges, numbers and wires, every wedge showing that outcome. The
               game takes each wedge from the render of its own outcome, so one
               set of renders covers every target number.
pegs           What turns with the wheel but sits on top of the rim.
frame          Rim and hub, with a hole where the wedges go.
shade          Shadow the rim and hub drop on the wedges, on a white disc.
sheen          The soft highlight that stays put while the wedges go under it.
needle         The pointer and its shadow.

What turns is lit evenly round the axis, so a turned render is still correctly
lit; everything lopsided about the light lives in the layers that don't turn.
"""
import math
import sys

import bmesh
import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
LOOK = argv[argv.index("--look") + 1]
OUT = argv[argv.index("--out") + 1]
SIZE = int(argv[argv.index("--size") + 1]) if "--size" in argv else 1024
SAMPLES = int(argv[argv.index("--samples") + 1]) if "--samples" in argv else 256
KINDS = ["success", "fail", "crit_success", "crit_fail"]
LAYERS = [f"wheel_{k}" for k in KINDS] + ["pegs", "frame", "shade", "sheen", "needle"]
if "--only" in argv:
    LAYERS = argv[argv.index("--only") + 1].split(",")
SHEEN = 0.55
SHEEN_FLOOR = 0.012
# Overhead light in the layers that turn: even all the way round, for the gold
# to mirror. The wedges' own gloss is left to the sheen layer, or this would
# wash them out.
TURNING_FLOOR = 0.18
RING = 3.2
RING_SHADE_LOW = 0.4
RING_SHADE_HIGH = 1.35
# The sheen is faint; it is rendered this much brighter so 8 bits are enough,
# and pack_wheel.py takes it back out.
SHEEN_GAIN = 16.0

COUNTS = [1, 3, 6, 10, 15, 21, 25, 27, 27, 25, 21, 15, 10, 6, 3, 1]
FIRST = 3
TAU = math.tau
R_WEDGE_OUT = 1.87
R_WEDGE_IN = 0.56
R_NUMBER = 1.60
GAP = 0.018
Z_WEDGE = 0.09


weights = [math.sqrt(c) for c in COUNTS]
spans = [w / sum(weights) * TAU for w in weights]
starts = [sum(spans[:i]) for i in range(len(spans))]
spin = math.pi - (starts[7] + spans[7] * 0.5)  # needle on the middle of 10


def at(theta, r):
    return Vector((-math.sin(theta) * r, -math.cos(theta) * r, 0.0))


def facing(theta):
    return math.pi - theta


# --- materials ---------------------------------------------------------------

def new_material(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    return m, m.node_tree, m.node_tree.nodes["Principled BSDF"]


def plain(name, base, metal=0.0, rough=0.4, coat=0.0, coat_rough=0.05):
    m, _, b = new_material(name)
    b.inputs["Base Color"].default_value = (*base, 1.0)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Coat Roughness"].default_value = coat_rough
    return m


def metal(name, base, rough_low, rough_high, scale=26.0, hammer=0.0):
    m, t, b = new_material(name)
    b.inputs["Base Color"].default_value = (*base, 1.0)
    b.inputs["Metallic"].default_value = 1.0
    coord = t.nodes.new("ShaderNodeTexCoord")
    noise = t.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = 8.0
    ramp = t.nodes.new("ShaderNodeMapRange")
    ramp.inputs["From Min"].default_value = 0.3
    ramp.inputs["From Max"].default_value = 0.7
    ramp.inputs["To Min"].default_value = rough_low
    ramp.inputs["To Max"].default_value = rough_high
    t.links.new(coord.outputs["Object"], noise.inputs["Vector"])
    t.links.new(noise.outputs[0], ramp.inputs["Value"])
    t.links.new(ramp.outputs[0], b.inputs["Roughness"])
    if hammer > 0.0:
        dents = t.nodes.new("ShaderNodeTexVoronoi")
        dents.feature = "SMOOTH_F1"
        dents.inputs["Scale"].default_value = 24.0
        bump = t.nodes.new("ShaderNodeBump")
        bump.inputs["Strength"].default_value = hammer
        bump.inputs["Distance"].default_value = 0.09
        t.links.new(coord.outputs["Object"], dents.inputs["Vector"])
        t.links.new(dents.outputs["Distance"], bump.inputs["Height"])
        t.links.new(bump.outputs[0], b.inputs["Normal"])
    return m


def gilt(name, base, rough):
    """Satin gold brushed along the wedge's radius. Rough enough that a flat
    face takes the key light and the ring instead of mirroring the dim middle."""
    m, t, b = new_material(name)
    b.inputs["Metallic"].default_value = 1.0
    coord = t.nodes.new("ShaderNodeTexCoord")
    mapping = t.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (120.0, 1.5, 120.0)
    t.links.new(coord.outputs["Object"], mapping.inputs["Vector"])
    noise = t.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 1.0
    noise.inputs["Detail"].default_value = 3.0
    t.links.new(mapping.outputs["Vector"], noise.inputs["Vector"])
    rough_range = t.nodes.new("ShaderNodeMapRange")
    rough_range.inputs["From Min"].default_value = 0.3
    rough_range.inputs["From Max"].default_value = 0.7
    rough_range.inputs["To Min"].default_value = rough - 0.03
    rough_range.inputs["To Max"].default_value = rough + 0.03
    t.links.new(noise.outputs[0], rough_range.inputs["Value"])
    t.links.new(rough_range.outputs[0], b.inputs["Roughness"])
    shade = t.nodes.new("ShaderNodeMapRange")
    shade.inputs["From Min"].default_value = 0.3
    shade.inputs["From Max"].default_value = 0.7
    shade.inputs["To Min"].default_value = 0.95
    shade.inputs["To Max"].default_value = 1.05
    t.links.new(noise.outputs[0], shade.inputs["Value"])
    tint = t.nodes.new("ShaderNodeVectorMath")
    tint.operation = "SCALE"
    tint.inputs["Vector"].default_value = base
    t.links.new(shade.outputs[0], tint.inputs["Scale"])
    t.links.new(tint.outputs["Vector"], b.inputs["Base Color"])
    return m


def wood(name, tint, grain=0.38):
    """Stained wood under lacquer, grain along local Y (the wedge's radius)."""
    m, t, b = new_material(name)
    coord = t.nodes.new("ShaderNodeTexCoord")
    info = t.nodes.new("ShaderNodeObjectInfo")
    offset = t.nodes.new("ShaderNodeVectorMath")
    offset.operation = "ADD"
    scale_random = t.nodes.new("ShaderNodeVectorMath")
    scale_random.operation = "SCALE"
    scale_random.inputs["Vector"].default_value = (19.0, 7.0, 3.0)
    t.links.new(info.outputs["Random"], scale_random.inputs["Scale"])
    t.links.new(coord.outputs["Object"], offset.inputs[0])
    t.links.new(scale_random.outputs["Vector"], offset.inputs[1])
    mapping = t.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (13.0, 1.1, 13.0)
    t.links.new(offset.outputs["Vector"], mapping.inputs["Vector"])
    noise = t.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 1.0
    noise.inputs["Detail"].default_value = 9.0
    noise.inputs["Roughness"].default_value = 0.6
    noise.inputs["Distortion"].default_value = 0.35
    t.links.new(mapping.outputs["Vector"], noise.inputs["Vector"])
    ramp = t.nodes.new("ShaderNodeMapRange")
    ramp.inputs["From Min"].default_value = 0.32
    ramp.inputs["From Max"].default_value = 0.68
    ramp.inputs["To Min"].default_value = grain
    ramp.inputs["To Max"].default_value = 1.3
    t.links.new(noise.outputs[0], ramp.inputs["Value"])
    colour = t.nodes.new("ShaderNodeVectorMath")
    colour.operation = "SCALE"
    colour.inputs["Vector"].default_value = tint
    t.links.new(ramp.outputs[0], colour.inputs["Scale"])
    t.links.new(colour.outputs["Vector"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.45
    b.inputs["Coat Weight"].default_value = 1.0
    b.inputs["Coat Roughness"].default_value = 0.14
    bump = t.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.08
    bump.inputs["Distance"].default_value = 0.01
    t.links.new(noise.outputs[0], bump.inputs["Height"])
    t.links.new(bump.outputs[0], b.inputs["Normal"])
    return m


def enamel(name, base):
    m, t, b = new_material(name)
    b.inputs["Base Color"].default_value = (*base, 1.0)
    b.inputs["Roughness"].default_value = 0.35
    b.inputs["Coat Weight"].default_value = 1.0
    b.inputs["Coat Roughness"].default_value = 0.1
    coord = t.nodes.new("ShaderNodeTexCoord")
    noise = t.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 3.0
    noise.inputs["Detail"].default_value = 6.0
    ramp = t.nodes.new("ShaderNodeMapRange")
    ramp.inputs["From Min"].default_value = 0.3
    ramp.inputs["From Max"].default_value = 0.7
    ramp.inputs["To Min"].default_value = 0.72
    ramp.inputs["To Max"].default_value = 1.3
    tint = t.nodes.new("ShaderNodeVectorMath")
    tint.operation = "SCALE"
    tint.inputs["Vector"].default_value = base
    t.links.new(coord.outputs["Object"], noise.inputs["Vector"])
    t.links.new(noise.outputs[0], ramp.inputs["Value"])
    t.links.new(ramp.outputs[0], tint.inputs["Scale"])
    t.links.new(tint.outputs["Vector"], b.inputs["Base Color"])
    return m


BRASS = (0.72, 0.50, 0.20)
GOLD = (1.0, 0.70, 0.27)

if LOOK == "wood":
    FONT = "C:/Windows/Fonts/palab.ttf"
    trim = metal("brass", BRASS, 0.22, 0.42)
    studs = trim
    hub_cap = wood("hub", (0.05, 0.028, 0.016), 0.6)
    base_mat = plain("base", (0.012, 0.008, 0.006), rough=0.6)
    rim_mat = trim
    fills = {
        "success": [wood("blue_a", (0.045, 0.14, 0.30)), wood("blue_b", (0.03, 0.095, 0.21))],
        "fail": [wood("red_a", (0.30, 0.035, 0.05)), wood("red_b", (0.20, 0.022, 0.032))],
        "crit_success": [gilt("gilt_a", (0.60, 0.37, 0.10), 0.5), gilt("gilt_b", (0.47, 0.28, 0.07), 0.5)],
        "crit_fail": [wood("ebony_a", (0.022, 0.012, 0.012), 0.5), wood("ebony_b", (0.012, 0.007, 0.008), 0.5)],
    }
    ink = plain("ivory", (0.82, 0.72, 0.50), rough=0.35, coat=0.5)
    ink_on_gold = plain("ink_dark", (0.02, 0.012, 0.005), rough=0.5)
else:
    FONT = "C:/Windows/Fonts/cambriab.ttf"
    trim = metal("gold", GOLD, 0.14, 0.3)
    studs = trim
    hub_cap = plain("hub", (0.006, 0.006, 0.008), rough=0.2, coat=1.0, coat_rough=0.06)
    base_mat = plain("base", (0.004, 0.004, 0.005), rough=0.4)
    rim_mat = plain("lacquer", (0.006, 0.006, 0.008), rough=0.2, coat=1.0, coat_rough=0.06)
    fills = {
        "success": [enamel("blue_a", (0.022, 0.09, 0.30)), enamel("blue_b", (0.014, 0.06, 0.21))],
        "fail": [enamel("red_a", (0.26, 0.012, 0.03)), enamel("red_b", (0.17, 0.008, 0.02))],
        "crit_success": [gilt("gilt_a", (0.62, 0.38, 0.10), 0.46), gilt("gilt_b", (0.48, 0.29, 0.07), 0.46)],
        "crit_fail": [enamel("void_a", (0.016, 0.004, 0.012)), enamel("void_b", (0.009, 0.003, 0.008))],
    }
    ink = trim
    ink_on_gold = plain("ink_dark", (0.008, 0.006, 0.006), rough=0.3)


for pair in fills.values():
    for material in pair:
        bsdf = material.node_tree.nodes["Principled BSDF"]
        if bsdf.inputs["Metallic"].default_value < 0.5:
            bsdf.inputs["Coat Weight"].default_value = 0.0
            bsdf.inputs["Specular IOR Level"].default_value = 0.0


# --- meshes ------------------------------------------------------------------

def link(name, mesh, material):
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    mesh.materials.append(material)
    return obj


def smooth(obj):
    for poly in obj.data.polygons:
        poly.use_smooth = True
    obj.modifiers.new("wn", "WEIGHTED_NORMAL").keep_sharp = True


def rounded(points, d):
    """Replaces each interior corner of a profile with a small arc."""
    out = [points[0]]
    for a, b, c in zip(points, points[1:], points[2:]):
        ab = Vector((a[0] - b[0], a[1] - b[1]))
        cb = Vector((c[0] - b[0], c[1] - b[1]))
        p = Vector(b) + ab.normalized() * min(d, ab.length * 0.45)
        q = Vector(b) + cb.normalized() * min(d, cb.length * 0.45)
        for s in range(5):
            t = s / 4.0
            out.append(tuple((1 - t) ** 2 * p + 2 * t * (1 - t) * Vector(b) + t * t * q))
    out.append(points[-1])
    return out


def lathe(name, profile, material, segments=256, bevel=0.012, shade=True):
    """Spins an (r, z) profile round Z."""
    points = rounded(profile, bevel) if bevel > 0.0 else profile
    verts, faces = [], []
    rows = []
    for r, z in points:
        if r < 1e-6:
            rows.append([len(verts)] * segments)
            verts.append((0.0, 0.0, z))
            continue
        row = []
        for s in range(segments):
            a = TAU * s / segments
            row.append(len(verts))
            verts.append((math.cos(a) * r, math.sin(a) * r, z))
        rows.append(row)
    for low, high in zip(rows, rows[1:]):
        for s in range(segments):
            quad = [low[s], low[(s + 1) % segments], high[(s + 1) % segments], high[s]]
            unique = list(dict.fromkeys(quad))
            if len(unique) >= 3:
                faces.append(unique)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    obj = link(name, mesh, material)
    if shade:
        smooth(obj)
    return obj


def wedge(i, kind):
    half = spans[i] * 0.5
    steps = max(4, int(spans[i] / math.radians(1.0)))
    verts, faces = [], []
    top_out, top_in, low_out, low_in = [], [], [], []
    for s in range(steps + 1):
        t = -1.0 + 2.0 * s / steps
        a_out = t * (half - GAP * 0.5 / R_WEDGE_OUT)
        a_in = t * (half - GAP * 0.5 / R_WEDGE_IN)
        for bucket, r, a, z in [
            (top_out, R_WEDGE_OUT, a_out, Z_WEDGE), (top_in, R_WEDGE_IN, a_in, Z_WEDGE),
            (low_out, R_WEDGE_OUT, a_out, 0.01), (low_in, R_WEDGE_IN, a_in, 0.01),
        ]:
            bucket.append(len(verts))
            verts.append((math.sin(a) * r, math.cos(a) * r, z))
    for s in range(steps):
        faces.append([top_in[s], top_out[s], top_out[s + 1], top_in[s + 1]][::-1])
        faces.append([top_out[s], low_out[s], low_out[s + 1], top_out[s + 1]][::-1])
        faces.append([low_in[s], top_in[s], top_in[s + 1], low_in[s + 1]][::-1])
    faces.append([top_out[0], top_in[0], low_in[0], low_out[0]][::-1])
    faces.append([top_in[-1], top_out[-1], low_out[-1], low_in[-1]][::-1])
    mesh = bpy.data.meshes.new(f"wedge_{i}")
    mesh.from_pydata(verts, [], faces)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    obj = link(f"wedge_{i}", mesh, fills[kind][(FIRST + i) % 2])
    obj.rotation_euler = (0.0, 0.0, facing(starts[i] + spin + half))
    bevel = obj.modifiers.new("bevel", "BEVEL")
    bevel.width = 0.016
    bevel.segments = 3
    bevel.limit_method = "ANGLE"
    bevel.angle_limit = math.radians(30.0)
    smooth(obj)


def number(i, kind):
    half = spans[i] * 0.5
    theta = starts[i] + spin + half
    curve = bpy.data.curves.new(f"num_{i}", "FONT")
    curve.body = str(FIRST + i)
    curve.font = bpy.data.fonts.load(FONT, check_existing=True)
    curve.align_x = "CENTER"
    curve.align_y = "CENTER"
    curve.size = min(max(R_NUMBER * spans[i] * 0.62, 0.16), 0.36)
    curve.extrude = 0.008
    curve.bevel_depth = 0.003
    curve.bevel_resolution = 2
    curve.resolution_u = 8
    if curve.body in ("6", "9"):
        curve.body_format[0].use_underline = True
        curve.underline_position = -0.07
        curve.underline_height = 0.045
    obj = bpy.data.objects.new(f"num_{i}", curve)
    bpy.context.scene.collection.objects.link(obj)
    curve.materials.append(ink_on_gold if kind == "crit_success" else ink)
    obj.location = at(theta, R_NUMBER) + Vector((0.0, 0.0, Z_WEDGE + 0.008))
    obj.rotation_euler = (0.0, 0.0, facing(theta))


def boxes(name, material, placed, bevel=0.0):
    """placed: (theta, r_low, r_high, half_width, z_low, z_high) radial bars."""
    bm = bmesh.new()
    for theta, r_low, r_high, half_width, z_low, z_high in placed:
        radial = at(theta, 1.0)
        side = Vector((radial.y, -radial.x, 0.0)) * half_width
        corners = []
        for r, w in [(r_low, -1), (r_high, -1), (r_high, 1), (r_low, 1)]:
            corners.append(radial * r + side * w)
        bottom = [bm.verts.new((c.x, c.y, z_low)) for c in corners]
        top = [bm.verts.new((c.x, c.y, z_high)) for c in corners]
        bm.faces.new(top)
        bm.faces.new(bottom[::-1])
        for k in range(4):
            bm.faces.new([bottom[k], bottom[(k + 1) % 4], top[(k + 1) % 4], top[k]])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = link(name, mesh, material)
    if bevel > 0.0:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
        smooth(obj)
    return obj


def pointer():
    tip, top, pivot_y = 1.80, 2.42, 2.28
    outline = [(0.0, tip)]
    outline += [(0.135, pivot_y - 0.03)]
    for s in range(1, 12):
        a = -0.2 + (math.pi + 0.4) * s / 12.0
        outline.append((math.cos(a) * 0.14, pivot_y + math.sin(a) * 0.14))
    outline += [(-0.135, pivot_y - 0.03)]
    bm = bmesh.new()
    low = [bm.verts.new((x, y, 0.30)) for x, y in outline]
    high = [bm.verts.new((x, y, 0.37)) for x, y in outline]
    bm.faces.new(high)
    bm.faces.new(low[::-1])
    for k in range(len(outline)):
        n = (k + 1) % len(outline)
        bm.faces.new([low[k], low[n], high[n], high[k]])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("pointer")
    bm.to_mesh(mesh)
    bm.free()
    obj = link("pointer", mesh, trim)
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = 0.02
    mod.segments = 3
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(50.0)
    smooth(obj)
    pin = lathe("pin", [(0.0, 0.44), (0.05, 0.44), (0.065, 0.36)], rim_mat if LOOK == "lacquer" else plain("pin", (0.02, 0.015, 0.01), rough=0.3), segments=48, bevel=0.018)
    pin.location = (0.0, pivot_y, 0.0)


def rim():
    return lathe("rim", [(1.86, 0.03), (1.86, 0.17), (1.91, 0.215), (1.96, 0.23), (2.03, 0.205), (2.09, 0.14), (2.11, 0.0)], rim_mat, bevel=0.018)


def hub():
    cap = lathe("hub_cap", [(0.0, 0.12), (0.5, 0.12)], hub_cap, bevel=0.0)
    if LOOK == "wood":
        ring = lathe("hub_ring", [(0.47, 0.08), (0.47, 0.15), (0.50, 0.195), (0.535, 0.21), (0.575, 0.19), (0.60, 0.15), (0.60, 0.07)], trim, bevel=0.018)
    else:
        ring = lathe("hub_ring", [(0.48, 0.08), (0.48, 0.145), (0.505, 0.18), (0.54, 0.195), (0.575, 0.175), (0.60, 0.14), (0.60, 0.07)], trim, bevel=0.012)
    return [cap, ring]


def edges():
    return [starts[i] + spin for i in range(len(COUNTS))]


def build_wheel(kind):
    lathe("base", [(0.0, 0.0), (1.9, 0.0)], base_mat, bevel=0.0)
    for i in range(len(COUNTS)):
        wedge(i, kind)
        number(i, kind)
    if LOOK != "wood":
        boxes("wires", trim, [(t, 0.58, 1.87, 0.009, 0.02, 0.112) for t in edges()], bevel=0.003)
        lathe("wire_inner", [(0.735, 0.08), (0.735, 0.108), (0.748, 0.108), (0.748, 0.08)], trim, bevel=0.003)
        lathe("wire_outer", [(1.33, 0.08), (1.33, 0.108), (1.343, 0.108), (1.343, 0.08)], trim, bevel=0.003)


def build_pegs():
    rim().is_shadow_catcher = True
    # A shadow catcher doesn't show in reflections, and the pegs' tilted faces
    # look sideways at the rim and its gold inlays: that's their whole shine.
    for mirrored in build_frame():
        mirrored.visible_camera = False
        mirrored.visible_shadow = False
    if LOOK == "wood":
        for k, theta in enumerate(edges()):
            peg = lathe(f"peg_{k}", [(0.0, 0.29), (0.03, 0.285), (0.05, 0.25), (0.052, 0.2)], studs, segments=32, bevel=0.012)
            peg.location = at(theta, 1.96)
        return
    ticks = []
    for n in range(216):
        theta = TAU * n / 216.0
        if min(abs(math.remainder(theta - e, TAU)) for e in edges()) < math.radians(2.4):
            continue
        long = n % 6 == 0
        ticks.append((theta, 1.935 if long else 1.948, 1.985 if long else 1.972, 0.0065 if long else 0.004, 0.2, 0.242))
    boxes("ticks", trim, ticks)
    for k, theta in enumerate(edges()):
        stud = lathe(f"stud_{k}", [(0.0, 0.30), (0.075, 0.22)], studs, segments=4, bevel=0.0, shade=False)
        stud.location = at(theta, 1.96)
        stud.rotation_euler = (0.0, 0.0, facing(theta))


def build_frame():
    parts = [rim()] + hub()
    if LOOK != "wood":
        parts.append(lathe("inlay_a", [(1.905, 0.19), (1.905, 0.232), (1.915, 0.232), (1.915, 0.19)], trim, bevel=0.002))
        parts.append(lathe("inlay_b", [(2.005, 0.19), (2.005, 0.232), (2.015, 0.232), (2.015, 0.19)], trim, bevel=0.002))
    return parts


def build_shade():
    lathe("disc", [(0.0, Z_WEDGE), (1.9, Z_WEDGE)], plain("white", (0.8, 0.8, 0.8), rough=1.0), bevel=0.0)
    for obj in [rim()] + hub():
        obj.visible_camera = False


def build_sheen():
    coat_rough = 0.14 if LOOK == "wood" else 0.1
    lathe("disc", [(0.0, Z_WEDGE), (1.9, Z_WEDGE)], plain("mirror", (0.0, 0.0, 0.0), rough=0.5, coat=1.0, coat_rough=coat_rough), bevel=0.0)


def build_needle():
    lathe("catcher", [(0.0, 0.2), (2.7, 0.2)], plain("catcher", (0.5, 0.5, 0.5)), bevel=0.0).is_shadow_catcher = True
    pointer()


def build(layer):
    if layer.startswith("wheel_"):
        build_wheel(layer[len("wheel_"):])
    else:
        {"pegs": build_pegs, "frame": build_frame, "shade": build_shade, "sheen": build_sheen, "needle": build_needle}[layer]()


# --- stage -------------------------------------------------------------------

def stage(layer):
    scene = bpy.context.scene
    turns = layer.startswith("wheel_") or layer == "pegs"
    only_sheen = layer == "sheen"
    sheen_high = SHEEN * SHEEN_GAIN if only_sheen else (TURNING_FLOOR if turns else SHEEN)
    sheen_low = 0.0 if only_sheen else (TURNING_FLOOR if turns else SHEEN_FLOOR)
    ring_strength = 0.0 if only_sheen else RING
    ring_even = (RING_SHADE_LOW + RING_SHADE_HIGH) * 0.5
    shade_low, shade_high = (ring_even, ring_even) if turns else (RING_SHADE_LOW, RING_SHADE_HIGH)
    world = bpy.data.worlds.new("world")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.0, 0.0, 0.0, 1.0) if only_sheen else (0.03, 0.03, 0.035, 1.0)

    # With a straight-on view a flat surface reflects what's directly above
    # it, so a graded emitter overhead is what gives the sheen its shape.
    bpy.ops.mesh.primitive_plane_add(size=30.0, location=(0.0, 0.0, 6.0))
    panel = bpy.context.object
    panel.visible_camera = False
    panel.visible_shadow = False
    panel.visible_diffuse = False
    m = bpy.data.materials.new("panel")
    m.use_nodes = True
    t = m.node_tree
    t.nodes.clear()
    out = t.nodes.new("ShaderNodeOutputMaterial")
    emit = t.nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = (1.0, 0.95, 0.86, 1.0)
    coord = t.nodes.new("ShaderNodeTexCoord")

    def smooth_range(value, low, high, to_low, to_high):
        r = t.nodes.new("ShaderNodeMapRange")
        r.interpolation_type = "SMOOTHSTEP"
        r.inputs["From Min"].default_value = low
        r.inputs["From Max"].default_value = high
        r.inputs["To Min"].default_value = to_low
        r.inputs["To Max"].default_value = to_high
        t.links.new(value, r.inputs["Value"])
        return r.outputs[0]

    def distance_to(point):
        d = t.nodes.new("ShaderNodeVectorMath")
        d.operation = "DISTANCE"
        d.inputs[1].default_value = point
        t.links.new(coord.outputs["Object"], d.inputs[0])
        return d.outputs["Value"]

    # A flat surface mirrors the patch straight above it, so the middle
    # stays dim with one soft sheen; only tilted metal sees the bright ring.
    sheen = smooth_range(distance_to((-1.15, 1.35, 0.0)), 0.0, 2.3, sheen_high, sheen_low)
    ring = smooth_range(distance_to((0.0, 0.0, 0.0)), 2.5, 5.0, 0.0, ring_strength)
    side = t.nodes.new("ShaderNodeSeparateXYZ")
    t.links.new(coord.outputs["Object"], side.inputs[0])
    tilt = t.nodes.new("ShaderNodeMath")
    tilt.operation = "SUBTRACT"
    t.links.new(side.outputs["Y"], tilt.inputs[0])
    t.links.new(side.outputs["X"], tilt.inputs[1])
    shade = smooth_range(tilt.outputs[0], -9.0, 9.0, shade_low, shade_high)
    ring_lit = t.nodes.new("ShaderNodeMath")
    ring_lit.operation = "MULTIPLY"
    t.links.new(ring, ring_lit.inputs[0])
    t.links.new(shade, ring_lit.inputs[1])
    total = t.nodes.new("ShaderNodeMath")
    total.operation = "ADD"
    t.links.new(sheen, total.inputs[0])
    t.links.new(ring_lit.outputs[0], total.inputs[1])
    t.links.new(total.outputs[0], emit.inputs["Strength"])
    t.links.new(emit.outputs[0], out.inputs["Surface"])
    panel.data.materials.append(m)

    sun_data = bpy.data.lights.new("key", "SUN")
    sun_data.energy = 0.0 if only_sheen else 2.4
    sun_data.angle = math.radians(14.0)
    sun_data.color = (1.0, 0.93, 0.82)
    sun = bpy.data.objects.new("key", sun_data)
    scene.collection.objects.link(sun)
    sun.rotation_euler = Vector((-0.45, 0.6, 1.0)).to_track_quat("Z", "Y").to_euler()

    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 5.05
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = (0.0, 0.14, 10.0)
    scene.camera = cam

    scene.render.engine = "CYCLES"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.cycles.denoiser = "OPENIMAGEDENOISE"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for backend in ("OPTIX", "CUDA", "HIP", "ONEAPI"):
        try:
            prefs.compute_device_type = backend
            prefs.get_devices()
            usable = [d for d in prefs.devices if d.type == backend]
        except Exception:
            usable = []
        if usable:
            for d in prefs.devices:
                d.use = d.type == backend
            scene.cycles.device = "GPU"
            print("WHEEL device", backend, [d.name for d in usable])
            break
    scene.render.resolution_x = SIZE
    scene.render.resolution_y = SIZE
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.render.filepath = f"{OUT}/{layer}.png"


for layer in LAYERS:
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    build(layer)
    stage(layer)
    bpy.ops.render.render(write_still=True)
    print("WHEEL rendered", layer)
