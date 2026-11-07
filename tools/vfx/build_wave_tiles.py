"""Build the Wall of Water's wave tiles: a few sections of a stylized
curling wave, each TILE_LENGTH metres long, that join end to end in any
order. water_wall.gd lays them along the wall and bends them to its cubes.

    "C:\\Program Files\\Blender Foundation\\Blender 4.3\\blender.exe" --background ^
        --factory-startup --python tools/vfx/build_wave_tiles.py -- ^
        --out assets/water_wall

Writes wave_tile_<n>.obj (+ .mtl) and wave_tiles.blend (to look at or
sculpt further) into --out.

The cross-section is water_wall.gd's PROFILE and THICKNESS, read from the
script so the two never drift: x metres forward (away from the caster),
y the height as a share of NOMINAL_HEIGHT. Each tile is that section swept
along its length, its lip reaching further out and its crest standing a
little higher toward the tile's middle (by a different amount on each
tile), and back to the plain section at both ends, so tiles meet without
a seam. Foam is a rope of metaballs packed along the lip; the balls near
either end are the same on every tile, so the foam runs on across a join.

Each OBJ holds two surfaces, by material: "body" and "foam". In the file
x runs along the wall, y is up (metres), z forward (metres). The body's UV
is (water thickness in metres, distance along the cross-section in
metres), which the game turns into the shader's attributes; the foam has
no UV.
"""

import math
import os
import random
import re
import sys

import bmesh
import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "systems", "surface_system", "water_wall.gd")

TILE_LENGTH = 3.0
NOMINAL_HEIGHT = 4.0
STEPS = 8            # points between each two of PROFILE's
ROW = 0.08           # metres between rows along the tile
VARIANTS = [
    # lip reach gain, crest gain, lip skew (peels one way), foam seed
    (0.05, 0.0, 0.05, 11),
    (0.08, 0.0, -0.06, 23),
    (0.03, 0.0, 0.03, 37),
]
END_ZONE = 0.45      # foam balls this near an end are shared by every tile
INNER_GAP = 0.95     # a tile's own balls stay this far from either end


def read_profile():
    text = open(SCRIPT, encoding="utf-8").read()
    block = re.search(r"const PROFILE: Array\[Vector2\] = \[(.*?)\n\]", text, re.S).group(1)
    profile = [(float(a), float(b)) for a, b in re.findall(r"Vector2\(([-\d.]+),\s*([-\d.]+)\)", block)]
    block = re.search(r"const THICKNESS: Array\[float\] = \[(.*?)\]", text, re.S).group(1)
    thickness = [float(v) for v in re.findall(r"[-\d.]+", block)]
    tip = int(re.search(r"const TIP: int = (\d+)", text).group(1))
    assert len(profile) == len(thickness), (len(profile), len(thickness))
    return profile, thickness, tip


def cubic(p0, p1, p2, p3, t):
    # Godot's Vector2.cubic_interpolate (Catmull-Rom).
    t2 = t * t
    t3 = t2 * t
    return tuple(0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2 + (-a + 3.0 * b - 3.0 * c + d) * t3)
                 for a, b, c, d in zip(p0, p1, p2, p3))


def smooth(profile, thickness):
    pts = []
    th = []
    n = len(profile)
    for i in range(n - 1):
        p0 = profile[max(i - 1, 0)]
        p3 = profile[min(i + 2, n - 1)]
        for k in range(STEPS):
            f = k / STEPS
            pts.append(cubic(p0, profile[i], profile[i + 1], p3, f))
            th.append(thickness[i] + (thickness[i + 1] - thickness[i]) * f)
    pts.append(profile[-1])
    th.append(thickness[-1])
    return pts, th


def envelope(x):
    # 0 at both ends with no slope there, 1 in the middle.
    return math.sin(math.pi * x / TILE_LENGTH) ** 2


def shaped(p, x, crest_x, variant):
    """Cross-section point p (forward m, height share) at x along a tile."""
    lip_gain, crest_gain, skew = variant[:3]
    e = envelope(x)
    fx, fy = p
    if fx > crest_x:
        out = fx - crest_x
        fx = crest_x + out * (1.0 + lip_gain * e) + skew * math.sin(2.0 * math.pi * x / TILE_LENGTH) * e * out
    fy *= 1.0 + crest_gain * e * fy
    return fx, fy


def to_world(x, p):
    # Blender: x along, -y forward, z up (metres). Exported y-up, so the
    # file reads x along, y up, z forward.
    return Vector((x, -p[0], p[1] * NOMINAL_HEIGHT))


def build_body(name, pts, th, variant):
    crest = max(range(len(pts)), key=lambda j: pts[j][1])
    crest_x = pts[crest][0]
    rows = int(round(TILE_LENGTH / ROW)) + 1
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    grid = []
    arc = [0.0]
    for j in range(1, len(pts)):
        a = to_world(0.0, pts[j - 1])
        b = to_world(0.0, pts[j])
        arc.append(arc[-1] + (b - a).length)
    for r in range(rows):
        x = TILE_LENGTH * r / (rows - 1)
        grid.append([bm.verts.new(to_world(x, shaped(p, x, crest_x, variant))) for p in pts])
    for r in range(rows - 1):
        for j in range(len(pts) - 1):
            face = bm.faces.new((grid[r][j], grid[r][j + 1], grid[r + 1][j + 1], grid[r + 1][j]))
            for loop in face.loops:
                jj = grid[r].index(loop.vert) if loop.vert in grid[r] else grid[r + 1].index(loop.vert)
                loop[uv_layer].uv = (th[jj], arc[jj])
    bm.normal_update()
    # Outward: the crest's normal points up.
    crest_face = grid[rows // 2][crest].link_faces[0]
    if crest_face.normal.z < 0.0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    for poly in mesh.polygons:
        poly.use_smooth = True
    return mesh, crest, crest_x


def foam_balls(pts, crest, tip, crest_x, variant, rng, x_lo, x_hi, count, shaping=True):
    """Metaball (centre, radius) pairs over the outer arc crest..tip."""
    balls = []
    for _ in range(count):
        x = rng.uniform(x_lo, x_hi)
        # A rope along the lip's last stretch, round to the point.
        a = rng.uniform(0.78, 1.0)
        j = crest + a * (tip - crest)
        j0 = int(math.floor(j))
        j1 = min(j0 + 1, len(pts) - 1)
        f = j - j0
        p = (pts[j0][0] + (pts[j1][0] - pts[j0][0]) * f, pts[j0][1] + (pts[j1][1] - pts[j0][1]) * f)
        q = (pts[j0 - 1][0], pts[j0 - 1][1])
        xx = x % TILE_LENGTH
        if shaping:
            p = shaped(p, xx, crest_x, variant)
            q = shaped(q, xx, crest_x, variant)
        c = to_world(x, p)
        tangent = (c - to_world(x, q)).normalized()
        # Outward from the surface, in the section's plane.
        normal = Vector((0.0, tangent.z, -tangent.y))
        radius = rng.uniform(0.15, 0.26)
        balls.append((c - normal * radius * 0.15, radius))
    return balls


def build_foam(name, pts, crest, tip, crest_x, variant, seed):
    shared = random.Random(1)
    own = random.Random(seed)
    span = TILE_LENGTH - 2.0 * INNER_GAP
    balls = foam_balls(pts, crest, tip, crest_x, variant, own, INNER_GAP, TILE_LENGTH - INNER_GAP, int(span * 40))
    # The shared balls about each end, unshaped (the shaping fades to
    # nothing there anyway), at x and x + TILE_LENGTH alike.
    edge = foam_balls(pts, crest, tip, crest_x, variant, shared, -END_ZONE, END_ZONE, int(2 * END_ZONE * 40), shaping=False)
    for c, r in edge:
        balls.append((c, r))
        balls.append((c + Vector((TILE_LENGTH, 0.0, 0.0)), r))
    # Drops hanging from the lip's point.
    for k in range(int(TILE_LENGTH * 3)):
        x = (k + own.uniform(0.2, 0.8)) / 3.0
        if x < INNER_GAP or x > TILE_LENGTH - INNER_GAP:
            continue
        p = shaped(pts[tip], x, crest_x, variant)
        balls.append((to_world(x, p) + Vector((0.0, 0.0, -0.08)), own.uniform(0.12, 0.2)))
    mb = bpy.data.metaballs.new(name + "_mb")
    mb.resolution = 0.045
    mb.render_resolution = 0.045
    mb.threshold = 0.6
    for c, r in balls:
        el = mb.elements.new()
        el.co = c
        el.radius = r
    ob = bpy.data.objects.new(name + "_mb", mb)
    bpy.context.scene.collection.objects.link(ob)
    deps = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(ob.evaluated_get(deps))
    bpy.data.objects.remove(ob)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    # Cut to the tile, so the foam ends flush with the next tile's.
    for plane_x, keep_above in ((0.0, True), (TILE_LENGTH, False)):
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(plane_x, 0.0, 0.0), plane_no=(1.0, 0.0, 0.0),
                               clear_inner=keep_above, clear_outer=not keep_above)
    bmesh.ops.smooth_vert(bm, verts=bm.verts[:], factor=0.5, use_axis_x=False, use_axis_y=True, use_axis_z=True)
    bm.to_mesh(mesh)
    bm.free()
    mesh.name = name
    for poly in mesh.polygons:
        poly.use_smooth = True
    return mesh


def material(name, colour):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.diffuse_color = colour
    return m


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = argv[argv.index("--out") + 1] if "--out" in argv else os.path.join(ROOT, "assets", "water_wall")
    out = os.path.abspath(os.path.join(ROOT, out)) if not os.path.isabs(out) else out
    os.makedirs(out, exist_ok=True)
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob)
    profile, thickness, tip_index = read_profile()
    pts, th = smooth(profile, thickness)
    tip = tip_index * STEPS
    body_mat = material("body", (0.1, 0.4, 0.6, 1.0))
    foam_mat = material("foam", (0.95, 0.97, 1.0, 1.0))
    for n, variant in enumerate(VARIANTS):
        body, crest, crest_x = build_body("wave_body_%d" % n, pts, th, variant)
        foam = build_foam("wave_foam_%d" % n, pts, crest, tip, crest_x, variant, variant[3])
        body.materials.append(body_mat)
        foam.materials.append(foam_mat)
        objects = []
        for mesh in (body, foam):
            ob = bpy.data.objects.new(mesh.name, mesh)
            ob.location.y = n * 6.0
            bpy.context.scene.collection.objects.link(ob)
            objects.append(ob)
        bpy.ops.object.select_all(action="DESELECT")
        for ob in objects:
            ob.location.y = 0.0
            ob.select_set(True)
        bpy.context.view_layer.objects.active = objects[0]
        bpy.ops.wm.obj_export(filepath=os.path.join(out, "wave_tile_%d.obj" % n), export_selected_objects=True,
                              export_uv=True, export_normals=True, export_materials=True,
                              forward_axis="NEGATIVE_Z", up_axis="Y", apply_modifiers=True)
        for ob in objects:
            ob.location.y = n * 6.0
        print("tile %d: body %d verts, foam %d verts" % (n, len(body.vertices), len(foam.vertices)))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, "wave_tiles.blend"))


main()
