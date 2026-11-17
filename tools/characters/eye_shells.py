"""The eye shells: an occlusion strip and a tear line round each eye, built
along the lid's waterline, where the lid meets the eyeball.

MakeHuman's lid is a set of 28-vertex rings round each eye: they close in
from the face to the lid margin, then the surface turns back and opens out
again into a socket wider than the eyeball. The waterline is the last ring
before that turn, the one the next ring lies far behind. mark() finds it on
the base mesh, before subdivision, and keeps it as a vertex group per eye
("waterline-L", "waterline-R"); the subdivision carries the group through
(the ring's own vertices and the new ones along it keep weight 1).

build() then lays two strips per eye on the eyeball's outer surface, each
column of them riding on one waterline vertex: its bone weights and every
face blend shape's offset (a blink, a squint) are that vertex's, so the
strips move with the lid.
- "<name>.eye_occlusion": from just under the lid to OCCLUSION_WIDTH in,
  for the shadow the lid and lashes cast on the eye
  (assets/characters/shaders/eye_occlusion.gdshader);
- "<name>.tearline": a thin wet strip where lid and eyeball meet
  (assets/characters/shaders/tear_line.gdshader).
Each has UV.y from the lid (0) inward (1) and a colour whose red is how
far toward the upper lid the column is (1 at the top, 0 at the bottom),
so the shaders can weigh the lids apart.
"""
import math

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

# Metres. How far in from the waterline the occlusion reaches, how far it
# starts under the lid, and how far above the eyeball both strips float.
OCCLUSION_WIDTH = 0.003
UNDER_LID = 0.0006
LIFT = 0.00015
OCCLUSION_ROWS = 6
# The tear line: from tucked against the lid to this far onto the eye.
TEAR_WIDTH = 0.0007
# Next ring this much deeper than the last (metres): the surface has
# turned back into the socket.
TURN_BACK = 0.001


def _eyes(eyes):
    """Per side, the eyeball's centre and diameter (world), and a BVH of its
    surface."""
    evaluated = eyes.evaluated_get(bpy.context.evaluated_depsgraph_get())
    bm = bmesh.new()
    bm.from_mesh(evaluated.to_mesh())
    evaluated.to_mesh_clear()
    bm.transform(eyes.matrix_world)
    tree = BVHTree.FromBMesh(bm)
    out = {}
    for side, sign in (("L", 1.0), ("R", -1.0)):
        points = [v.co for v in bm.verts if v.co.x * sign > 0.0]
        centre = sum(points, Vector()) / len(points)
        size = max(p.x for p in points) - min(p.x for p in points)
        out[side] = (centre, size)
    return out, tree


def _ring_area(points, centre):
    """The ring's area seen from the front (x, z), and how many times it
    winds round the centre."""
    area = 0.0
    turns = 0.0
    for i, p in enumerate(points):
        q = points[(i + 1) % len(points)]
        area += p.x * q.z - q.x * p.z
        a = math.atan2(p.z - centre.z, p.x - centre.x)
        b = math.atan2(q.z - centre.z, q.x - centre.x)
        turns += (b - a + math.pi) % (2.0 * math.pi) - math.pi
    return abs(area) / 2.0, abs(turns) / (2.0 * math.pi)


def _rings(bm, centre, reach, allowed):
    """Every closed 28-vertex edge loop round the eye within reach of its
    centre: the lid's rings (wider loops round the whole face are not)."""
    def across(edge, vert):
        if len(vert.link_edges) != 4:
            return None
        faces = set(edge.link_faces)
        options = [e for e in vert.link_edges if e is not edge and not set(e.link_faces) & faces]
        return options[0] if len(options) == 1 else None

    rings = {}
    for edge in bm.edges:
        a, b = edge.verts
        if a.index not in allowed or ((a.co + b.co) / 2.0 - centre).length > reach:
            continue
        loop = [a.index]
        current, vert = edge, b
        for _ in range(200):
            if vert is a:
                break
            loop.append(vert.index)
            current = across(current, vert)
            if current is None:
                break
            vert = current.other_vert(vert)
        else:
            continue
        if current is None or frozenset(loop) in rings:
            continue
        points = [bm.verts[i].co for i in loop]
        area, turns = _ring_area(points, centre)
        if turns > 0.9 and len(loop) == 28:
            rings[frozenset(loop)] = dict(verts=loop, area=area,
                                         depth=sum(p.y for p in points) / len(points))
    return list(rings.values())


def mark(basemesh, eyes):
    """Finds each eye's waterline on the unsubdivided base mesh and keeps it
    as the vertex group waterline-<side>."""
    sides, _tree = _eyes(eyes)
    bm = bmesh.new()
    bm.from_mesh(basemesh.data)
    bm.transform(basemesh.matrix_world)
    bm.verts.ensure_lookup_table()
    body = basemesh.vertex_groups["body"].index
    allowed = {v.index for v in basemesh.data.vertices if any(g.group == body for g in v.groups)}
    for side, (centre, size) in sides.items():
        rings = _rings(bm, centre, size, allowed)
        by_vert = {}
        for n, ring in enumerate(rings):
            for v in ring["verts"]:
                by_vert[v] = n
        # Chain the rings from the face's outermost inward: each touches the
        # next by an edge.
        chain = [max(range(len(rings)), key=lambda n: rings[n]["area"])]
        while True:
            touching = {by_vert[e.other_vert(bm.verts[v]).index]
                        for v in rings[chain[-1]]["verts"] for e in bm.verts[v].link_edges
                        if e.other_vert(bm.verts[v]).index in by_vert} - set(chain)
            if not touching:
                break
            chain.append(min(touching, key=lambda n: rings[n]["area"]) if len(touching) > 1 else touching.pop())
        waterline = None
        for here, after in zip(chain, chain[1:]):
            # Front is -y: deeper is larger y.
            if rings[after]["depth"] - rings[here]["depth"] > TURN_BACK:
                waterline = rings[here]
                break
        if waterline is None or len(waterline["verts"]) != 28:
            print("eye_shells: rings", len(rings), "centre", centre, "size", size)
            for n in chain:
                print("  ring", len(rings[n]["verts"]), "area %.6f depth %.4f" % (rings[n]["area"], rings[n]["depth"] - centre.y))
            raise SystemExit("eye_shells: no waterline found round the %s eye" % side)
        group = basemesh.vertex_groups.new(name="waterline-" + side)
        group.add(waterline["verts"], 1.0, "REPLACE")


def _outer_surface(tree, centre, point):
    """Where the line from point to the eye's centre first meets the eye,
    from outside, and the outward direction there."""
    out = (point - centre).normalized()
    hit, _normal, _i, _d = tree.ray_cast(centre + out * 0.05, -out, 0.1)
    if hit is None:
        hit = centre + out * (point - centre).length
    return hit, (hit - centre).normalized()


def _ordered_waterline(basemesh, side):
    group = basemesh.vertex_groups["waterline-" + side].index
    world = basemesh.matrix_world
    verts = [v.index for v in basemesh.data.vertices
             if any(g.group == group and g.weight > 0.99 for g in v.groups)]
    points = {v: world @ basemesh.data.vertices[v].co for v in verts}
    middle = sum(points.values(), Vector()) / len(points)
    verts.sort(key=lambda v: math.atan2(points[v].z - middle.z, points[v].x - middle.x))
    return verts, points, middle


def _strip(name, basemesh, rig, rings, rows):
    """One mesh object on the rig, a closed ring of quads per eye. rings is
    [(eye centre, columns)], columns[i] = (waterline vertex, upper-lid share,
    [world point per row, lid first])."""
    world_to_local = basemesh.matrix_world.inverted()
    coords, faces, uvs, colours, sources = [], [], [], [], []
    for centre, columns in rings:
        first = len(coords)
        count = len(columns)
        for c, (vert, upper, points) in enumerate(columns):
            for k, p in enumerate(points):
                coords.append(p)
                uvs.append((c / count, 1.0 - k / (rows - 1)))
                colours.append((upper, 0.0, 0.0, 1.0))
                sources.append(vert)
        for i in range(count):
            j = (i + 1) % count
            for k in range(rows - 1):
                quad = [first + i * rows + k, first + j * rows + k,
                        first + j * rows + k + 1, first + i * rows + k + 1]
                a, b, d = (coords[q] for q in quad[:3])
                mid = sum((coords[q] for q in quad), Vector()) / 4.0
                # Wound to face out of the eye.
                if (b - a).cross(d - b).dot(mid - centre) < 0.0:
                    quad.reverse()
                faces.append(quad)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([world_to_local @ p for p in coords], [], faces)
    uv = mesh.uv_layers.new(name="UVMap")
    for poly in mesh.polygons:
        for loop in poly.loop_indices:
            uv.data[loop].uv = uvs[mesh.loops[loop].vertex_index]
    colour = mesh.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    for i, c in enumerate(colours):
        colour.data[i].color = c
    mesh.color_attributes.active_color = colour
    mesh.shade_smooth()
    mesh.materials.append(bpy.data.materials.new(name))
    obj = bpy.data.objects.new(name, mesh)
    for collection in basemesh.users_collection:
        collection.objects.link(obj)
    obj.parent = rig
    obj.matrix_world = basemesh.matrix_world.copy()

    # Each column rides on its waterline vertex: weights and blend shapes.
    source = basemesh.data
    bones = {g.index: g.name for g in basemesh.vertex_groups if g.name in rig.data.bones}
    for i, vert in enumerate(sources):
        for g in source.vertices[vert].groups:
            if g.group in bones and g.weight > 0.0:
                group = obj.vertex_groups.get(bones[g.group]) or obj.vertex_groups.new(name=bones[g.group])
                group.add([i], g.weight, "REPLACE")
    obj.modifiers.new("Armature", "ARMATURE").object = rig
    keys = source.shape_keys.key_blocks if source.shape_keys else []
    if keys:
        basis = obj.shape_key_add(name=keys[0].name, from_mix=False)
        for key in keys[1:]:
            block = obj.shape_key_add(name=key.name, from_mix=False)
            for i, vert in enumerate(sources):
                block.data[i].co = basis.data[i].co + (key.data[vert].co - keys[0].data[vert].co)
    return obj


def build(basemesh, eyes, rig, name):
    """The occlusion strip and tear line of both eyes, as two objects, and
    the waterline groups taken off the body."""
    sides, tree = _eyes(eyes)
    occlusion, tear = [], []
    for side, (centre, _size) in sides.items():
        verts, points, middle = _ordered_waterline(basemesh, side)
        heights = [points[v].z - middle.z for v in verts]
        half = max(abs(h) for h in heights)
        opening, _n = _outer_surface(tree, centre, middle)
        occ_columns, tear_columns = [], []
        for v, height in zip(verts, heights):
            upper = min(max(0.5 + height / half, 0.0), 1.0)
            surface, normal = _outer_surface(tree, centre, points[v])
            inward = opening - surface
            inward = (inward - normal * inward.dot(normal)).normalized()
            row = []
            for k in range(OCCLUSION_ROWS):
                along = -UNDER_LID + (OCCLUSION_WIDTH + UNDER_LID) * k / (OCCLUSION_ROWS - 1)
                at, n = _outer_surface(tree, centre, surface + inward * along)
                row.append(at + n * LIFT)
            occ_columns.append((v, upper, row))
            tucked, n0 = _outer_surface(tree, centre, surface - inward * 0.0002)
            onto, n1 = _outer_surface(tree, centre, surface + inward * TEAR_WIDTH)
            tear_columns.append((v, upper, [tucked + n0 * LIFT * 2.0, onto + n1 * LIFT]))
        occlusion.append((centre, occ_columns))
        tear.append((centre, tear_columns))
    built = [_strip("%s.eye_occlusion" % name, basemesh, rig, occlusion, OCCLUSION_ROWS),
             _strip("%s.tearline" % name, basemesh, rig, tear, 2)]
    for side in ("L", "R"):
        basemesh.vertex_groups.remove(basemesh.vertex_groups["waterline-" + side])
    for obj in built:
        print("EYE SHELL", obj.name, "verts", len(obj.data.vertices),
              "blend shapes", len(obj.data.shape_keys.key_blocks) - 1 if obj.data.shape_keys else 0)
    return built
