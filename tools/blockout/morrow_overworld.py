"""Writes world/morrow_overworld.tscn: the grey-box overworld that replaced
the New Orleans map. One compact downtown (Morrow) on a street grid round
a central square, a ring of low outskirts, and the Greywood wilderness out
to the map's edge, with a dirt road west to the Old Quarry.

Grey-box only: boxes for buildings, cylinders and cones for trees, flat
ground. Everything is seeded, so running it again writes the same map.

    python -I tools/blockout/morrow_overworld.py

Hand edits to the .tscn are lost on the next run; move a door or a
district by changing the tables below instead.
"""
import math
import os
import random

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "world", "morrow_overworld.tscn")
SEED = 7

HALF = 800.0           # the map is 1600 m square
STREET = 80.0          # street pitch downtown
ROAD = 20.0            # street width
DOWNTOWN = 240.0       # downtown streets run from -240 to 240
OUTSKIRTS = 440.0      # houses thin out into the woods past this
SQUARE = 70.0          # half-size of the open central square
DOOR_SCALE = 4.0

# Doors: name, area id, position (x, z), yaw in degrees.
DOORS = [
    ("CathedralSteps", "cathedral_of_shadows", (0.0, -60.0), 0.0),
    ("ArenaGate", "test_arena", (-55.0, 30.0), 0.0),
    ("MarketHall", "test_area_2", (160.0, 120.0), 0.0),
    ("OldDocks", "test_area_3", (-160.0, -200.0), 0.0),
    ("OldQuarry", "goblin_quarry", (-640.0, 40.0), 0.0),
]
START = (0.0, 20.0)
SAFE_SPOT = (55.0, 30.0)   # the inn on the square: free rests (rest_spot.gd)

# Districts, smallest wins where they overlap: name, half-extent of a square,
# then its random encounters (see world/overworld_encounters.gd): danger is
# the chance per metre walked (the avatar covers ~24 m a second, so 1/300
# is a chase every ~12 s of walking), the fights it holds before it is
# quiet until a rest, its battle area and its table (data/encounters/).
DISTRICTS = [
    ("Downtown", "Downtown Morrow", DOWNTOWN + ROAD,
     1.0 / 1500.0, 2, "battle_downtown", ["goblin_pair"]),
    ("Outskirts", "Morrow Outskirts", OUTSKIRTS,
     1.0 / 600.0, 4, "battle_outskirts", ["goblin_pair", "wolf_pack", "goblin_band"]),
    ("Greywood", "Greywood", HALF,
     1.0 / 300.0, 6, "battle_greywood", ["wolf_pack", "goblin_band", "hobgoblin_patrol", "giant_spider"]),
]

rng = random.Random(SEED)


class Scene:
    def __init__(self):
        self.ext = []
        self.sub = []
        self.nodes = []
        self._id = 0

    def ext_res(self, kind, path, uid=None):
        rid = "%d_ext" % (len(self.ext) + 1)
        u = ' uid="%s"' % uid if uid else ""
        self.ext.append('[ext_resource type="%s"%s path="%s" id="%s"]' % (kind, u, path, rid))
        return 'ExtResource("%s")' % rid

    def sub_res(self, kind, props):
        self._id += 1
        rid = "%s_%d" % (kind, self._id)
        body = "\n".join("%s = %s" % kv for kv in props.items())
        self.sub.append('[sub_resource type="%s" id="%s"]\n%s' % (kind, rid, body))
        return 'SubResource("%s")' % rid

    def node(self, name, kind=None, parent=None, props=None, instance=None):
        head = '[node name="%s"' % name
        if kind:
            head += ' type="%s"' % kind
        if parent is not None:
            head += ' parent="%s"' % parent
        if instance:
            head += " instance=%s" % instance
        head += "]"
        body = "\n".join("%s = %s" % kv for kv in (props or {}).items())
        self.nodes.append(head + ("\n" + body if body else ""))

    def write(self, path):
        steps = len(self.ext) + len(self.sub) + 1
        out = ["[gd_scene load_steps=%d format=3]" % steps, ""]
        out += self.ext + [""]
        for s in self.sub:
            out += [s, ""]
        for n in self.nodes:
            out += [n, ""]
        with open(path, "w", newline="\n") as f:
            f.write("\n".join(out))


def f(v):
    return ("%.3f" % v).rstrip("0").rstrip(".")


def xform(x, y, z, sx=1.0, sy=1.0, sz=1.0, yaw=0.0):
    c, s = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    # Rows of basis * scale: columns are the scaled local axes.
    b = [c * sx, 0, s * sz, 0, sy, 0, -s * sx, 0, c * sz]
    return "Transform3D(%s, %s, %s, %s)" % (", ".join(f(v) for v in b[0:3]), ", ".join(f(v) for v in b[3:6]),
                                           ", ".join(f(v) for v in b[6:9]), ", ".join(f(v) for v in (x, y, z)))


def color(r, g, b, a=1.0):
    return "Color(%s, %s, %s, %s)" % (f(r), f(g), f(b), f(a))


def material(sc, rgb, rough=0.9, vertex=False):
    p = {"albedo_color": color(*rgb), "roughness": f(rough)}
    if vertex:
        p["vertex_color_use_as_albedo"] = "true"
        # The instance colours below are written as seen, not linear.
        p["vertex_color_is_srgb"] = "true"
    return sc.sub_res("StandardMaterial3D", p)


def multimesh(sc, name, parent, mesh, instances, colors=None):
    """instances: (x, y, z, sx, sy, sz); the mesh is unit-sized."""
    floats = []
    for i, (x, y, z, sx, sy, sz) in enumerate(instances):
        floats += [sx, 0, 0, x, 0, sy, 0, y, 0, 0, sz, z]
        if colors:
            floats += list(colors[i])
    # Order matters: colours must be switched on before there are any
    # instances, and the buffer must match the count already set.
    props = {"transform_format": "1"}
    if colors:
        props["use_colors"] = "true"
    props.update({"instance_count": str(len(instances)), "mesh": mesh,
                  "buffer": "PackedFloat32Array(%s)" % ", ".join(f(v) for v in floats)})
    mm = sc.sub_res("MultiMesh", props)
    sc.node(name, "MultiMeshInstance3D", parent, {"multimesh": mm})


def static_boxes(sc, name, parent, boxes):
    """boxes: (x, y, z, sx, sy, sz) centre and size."""
    sc.node(name, "StaticBody3D", parent)
    path = name if parent == "." else parent + "/" + name
    shapes = {}
    for i, (x, y, z, sx, sy, sz) in enumerate(boxes):
        key = (round(sx, 2), round(sy, 2), round(sz, 2))
        if key not in shapes:
            shapes[key] = sc.sub_res("BoxShape3D", {"size": "Vector3(%s, %s, %s)" % (f(sx), f(sy), f(sz))})
        sc.node("Box%d" % i, "CollisionShape3D", path, {"transform": xform(x, y, z), "shape": shapes[key]})


def static_cylinders(sc, name, parent, cylinders, radius, height):
    sc.node(name, "StaticBody3D", parent)
    path = name if parent == "." else parent + "/" + name
    shape = sc.sub_res("CylinderShape3D", {"height": f(height), "radius": f(radius)})
    for i, (x, z) in enumerate(cylinders):
        sc.node("Trunk%d" % i, "CollisionShape3D", path, {"transform": xform(x, height * 0.5, z), "shape": shape})


# ---------------------------------------------------------------- layout

def street_lines():
    n = int(DOWNTOWN // STREET)
    return [i * STREET for i in range(-n, n + 1)]


def downtown_buildings():
    """Every block between the streets, split into one to four lots, the
    middle four blocks left open as the square."""
    out = []
    lines = street_lines()
    for i in range(len(lines) - 1):
        for j in range(len(lines) - 1):
            x0, x1 = lines[i] + ROAD * 0.5, lines[i + 1] - ROAD * 0.5
            z0, z1 = lines[j] + ROAD * 0.5, lines[j + 1] - ROAD * 0.5
            cx, cz = (x0 + x1) * 0.5, (z0 + z1) * 0.5
            if abs(cx) < SQUARE + STREET * 0.5 and abs(cz) < SQUARE + STREET * 0.5:
                continue
            centre = 1.0 - max(abs(cx), abs(cz)) / DOWNTOWN
            split = rng.choice([1, 2, 2, 4])
            lots = [(x0, x1, z0, z1)]
            if split == 2:
                if rng.random() < 0.5:
                    m = (x0 + x1) * 0.5
                    lots = [(x0, m, z0, z1), (m, x1, z0, z1)]
                else:
                    m = (z0 + z1) * 0.5
                    lots = [(x0, x1, z0, m), (x0, x1, m, z1)]
            elif split == 4:
                mx, mz = (x0 + x1) * 0.5, (z0 + z1) * 0.5
                lots = [(x0, mx, z0, mz), (mx, x1, z0, mz), (x0, mx, mz, z1), (mx, x1, mz, z1)]
            for (a0, a1, b0, b1) in lots:
                inset = 3.0
                sx, sz = a1 - a0 - inset * 2, b1 - b0 - inset * 2
                h = rng.uniform(10.0, 22.0) + centre * rng.uniform(15.0, 50.0)
                out.append(((a0 + a1) * 0.5, h * 0.5, (b0 + b1) * 0.5, sx, h, sz))
    return out


def clear_of_roads(x, z, margin):
    # The two main roads run out of town along x = 0 and z = 0.
    if abs(x) < ROAD * 0.5 + margin or abs(z) < ROAD * 0.5 + margin:
        return False
    for _, _, (dx, dz), _ in DOORS:
        if math.hypot(x - dx, z - dz) < 40.0 + margin:
            return False
    if math.hypot(x - QUARRY_CLEARING[0], z - QUARRY_CLEARING[1]) < 90.0:
        return False
    if math.hypot(x - LAKE[0], z - LAKE[1]) < LAKE[2] + margin + 10.0:
        return False
    return True


QUARRY_CLEARING = (-640.0, 40.0)
LAKE = (520.0, -480.0, 110.0)   # x, z, radius


def outskirts_houses():
    out = []
    ring_in = DOWNTOWN + ROAD + 20.0
    tries = 0
    while len(out) < 120 and tries < 5000:
        tries += 1
        x, z = rng.uniform(-OUTSKIRTS, OUTSKIRTS), rng.uniform(-OUTSKIRTS, OUTSKIRTS)
        if max(abs(x), abs(z)) < ring_in:
            continue
        if not clear_of_roads(x, z, 14.0):
            continue
        w, d, h = rng.uniform(10, 18), rng.uniform(10, 18), rng.uniform(5, 10)
        if any(abs(x - o[0]) < (w + o[3]) * 0.5 + 8 and abs(z - o[2]) < (d + o[5]) * 0.5 + 8 for o in out):
            continue
        out.append((x, h * 0.5, z, w, h, d))
    return out


def trees():
    """Clumps in the outskirts thickening into woods past them, and a dense
    belt at the map's edge."""
    out = []
    tries = 0
    while len(out) < 1500 and tries < 40000:
        tries += 1
        x, z = rng.uniform(-HALF + 10, HALF - 10), rng.uniform(-HALF + 10, HALF - 10)
        r = max(abs(x), abs(z))
        if r < DOWNTOWN + ROAD + 30:
            continue
        # Fewer trees nearer town, a wall of them at the edge.
        density = 0.15 if r < OUTSKIRTS else (0.75 if r < HALF - 60 else 1.0)
        # Glades: open patches in the woods, so it is not one even carpet.
        glade = math.sin(x * 0.011) * math.cos(z * 0.013) + 0.35 * math.sin((x + z) * 0.02)
        if r < HALF - 60 and glade > 0.55:
            continue
        if rng.random() > density:
            continue
        if not clear_of_roads(x, z, 6.0):
            continue
        if any(abs(x - t[0]) < 9 and abs(z - t[1]) < 9 for t in out[-60:]):
            continue
        out.append((x, z, rng.uniform(0.8, 1.4)))
    return out


def rocks():
    """Outcrops round the quarry clearing and scattered through the woods."""
    out = []
    qx, qz = QUARRY_CLEARING
    for k in range(9):
        a = math.radians(40 + k * 32)
        d = rng.uniform(95, 120)
        w, h, dd = rng.uniform(14, 30), rng.uniform(6, 16), rng.uniform(12, 26)
        out.append((qx + math.cos(a) * d, h * 0.5, qz + math.sin(a) * d, w, h, dd))
    tries = 0
    while len(out) < 40 and tries < 3000:
        tries += 1
        x, z = rng.uniform(-HALF + 60, HALF - 60), rng.uniform(-HALF + 60, HALF - 60)
        if max(abs(x), abs(z)) < OUTSKIRTS + 20 or not clear_of_roads(x, z, 20.0):
            continue
        w, h, d = rng.uniform(8, 22), rng.uniform(4, 12), rng.uniform(8, 22)
        out.append((x, h * 0.5, z, w, h, d))
    return out


# ---------------------------------------------------------------- scene

def build():
    sc = Scene()
    overworld = sc.ext_res("Script", "res://world/overworld.gd")
    camera = sc.ext_res("PackedScene", "res://systems/camera_system/overworld_camera.tscn")
    door = sc.ext_res("PackedScene", "res://world/overworld_door.tscn", "uid://b826s0f7pql2r")
    exit_script = sc.ext_res("Script", "res://systems/world_system/area_exit.gd", "uid://d1ity5hrprjde")
    district = sc.ext_res("Script", "res://world/overworld_district.gd")
    rest_spot = sc.ext_res("PackedScene", "res://world/inn_rest_spot.tscn")

    env = sc.sub_res("Environment", {
        "background_mode": "1", "background_color": color(0.62, 0.68, 0.72),
        "ambient_light_source": "2", "ambient_light_color": color(0.78, 0.84, 0.95),
        "ambient_light_energy": "0.6", "tonemap_mode": "2", "tonemap_exposure": "1.05",
        "ssao_enabled": "true", "ssao_radius": "2.5", "ssao_intensity": "2.0",
        "fog_enabled": "true", "fog_mode": "1", "fog_light_color": color(0.62, 0.68, 0.72),
        "fog_density": "1.0", "fog_depth_curve": "1.6", "fog_depth_begin": "350.0", "fog_depth_end": "1400.0",
    })

    grass = material(sc, (0.34, 0.42, 0.28))
    paving = material(sc, (0.55, 0.55, 0.53), 0.95)
    asphalt = material(sc, (0.3, 0.3, 0.32), 0.95)
    dirt = material(sc, (0.52, 0.44, 0.32))
    plaza = material(sc, (0.66, 0.62, 0.55), 0.9)
    stone = material(sc, (1, 1, 1), 0.85, vertex=True)
    bark = material(sc, (0.32, 0.24, 0.17))
    leaves = material(sc, (1, 1, 1), 0.9, vertex=True)
    rock = material(sc, (0.48, 0.46, 0.43))
    water = material(sc, (0.18, 0.3, 0.38), 0.15)
    inn = material(sc, (0.6, 0.42, 0.28))

    sc.node("MorrowOverworld", "Node3D", None, {
        "script": overworld, "avatar_speed_scale": "4.0", "avatar_icon_scale": "5.0",
        "deck_cutaway_radius": "0.0"})

    # Ground: one slab whose top is y = 0, painted with flat decals above it.
    sc.node("Ground", "Node3D", ".")
    static_boxes(sc, "Floor", "Ground", [(0, -1.0, 0, HALF * 2 + 200, 2.0, HALF * 2 + 200)])
    ground_plane = sc.sub_res("PlaneMesh", {"size": "Vector2(%s, %s)" % (f(HALF * 2 + 400), f(HALF * 2 + 400))})
    sc.node("Grass", "MeshInstance3D", "Ground", {"mesh": ground_plane, "material_override": grass})

    def decal(name, x, z, sx, sz, mat, y):
        m = sc.sub_res("PlaneMesh", {"size": "Vector2(%s, %s)" % (f(sx), f(sz))})
        sc.node(name, "MeshInstance3D", "Ground", {"transform": xform(x, y, z), "mesh": m,
                                                  "material_override": mat, "cast_shadow": "0"})

    town = (DOWNTOWN + ROAD) * 2
    decal("Paving", 0, 0, town, town, paving, 0.02)
    for k, line in enumerate(street_lines()):
        decal("StreetX%d" % k, line, 0, ROAD, town, asphalt, 0.04)
        decal("StreetZ%d" % k, 0, line, town, ROAD, asphalt, 0.04)
    decal("Square", 0, 0, SQUARE * 2 + ROAD, SQUARE * 2 + ROAD, plaza, 0.06)
    # The two main roads out of town, paved through the outskirts, dirt beyond.
    for k, sgn in enumerate((-1, 1)):
        mid = sgn * (DOWNTOWN + OUTSKIRTS) * 0.5
        span = OUTSKIRTS - DOWNTOWN
        decal("RoadX%d" % k, mid, 0, span, ROAD, asphalt, 0.04)
        decal("RoadZ%d" % k, 0, mid, ROAD, span, asphalt, 0.04)
        far = sgn * (OUTSKIRTS + HALF) * 0.5
        decal("TrailX%d" % k, far, 0, HALF - OUTSKIRTS, ROAD * 0.7, dirt, 0.04)
        decal("TrailZ%d" % k, 0, far, ROAD * 0.7, HALF - OUTSKIRTS, dirt, 0.04)
    decal("QuarryClearing", QUARRY_CLEARING[0], QUARRY_CLEARING[1], 170, 170, dirt, 0.05)

    unit_box = sc.sub_res("BoxMesh", {"size": "Vector3(1, 1, 1)"})

    # Downtown and the outskirts.
    town_boxes = downtown_buildings()
    houses = outskirts_houses()
    sc.node("Buildings", "Node3D", ".")
    shades = []
    for (_, _, _, _, h, _) in town_boxes:
        g = rng.uniform(0.55, 0.78) - min(h, 70) * 0.002
        shades.append((g, g, g * rng.uniform(0.97, 1.03), 1.0))
    for _ in houses:
        shades.append((rng.uniform(0.62, 0.74), rng.uniform(0.55, 0.62), rng.uniform(0.45, 0.52), 1.0))
    every = town_boxes + houses
    unit_stone = sc.sub_res("BoxMesh", {"size": "Vector3(1, 1, 1)", "material": stone})
    multimesh(sc, "Blocks", "Buildings", unit_stone, every, shades)
    static_boxes(sc, "Solid", "Buildings", every)

    # The inn on the square: where a full rest will be taken.
    sx, sz = SAFE_SPOT
    sc.node("Inn", "Node3D", ".", {"transform": xform(sx, 0, sz)})
    inn_box = sc.sub_res("BoxMesh", {"size": "Vector3(16, 9, 12)"})
    sc.node("House", "MeshInstance3D", "Inn", {"transform": xform(0, 4.5, -12), "mesh": inn_box,
                                               "material_override": inn})
    static_boxes(sc, "Solid", "Inn", [(0, 4.5, -12, 16, 9, 12)])
    # Stand in the blue corona and press interact: a free rest at the inn
    # (rest_spot.gd, world/inn_rest_spot.tscn).
    sc.node("SafeSpot", None, "Inn", {}, instance=rest_spot)

    # The wilderness.
    sc.node("Wilds", "Node3D", ".")
    tr = trees()
    trunk = sc.sub_res("CylinderMesh", {"top_radius": "0.6", "bottom_radius": "0.8", "height": "1.0",
                                        "material": bark, "radial_segments": "6", "rings": "1"})
    crown = sc.sub_res("CylinderMesh", {"top_radius": "0.0", "bottom_radius": "1.0", "height": "1.0",
                                        "material": leaves, "radial_segments": "7", "rings": "1"})
    multimesh(sc, "Trunks", "Wilds", trunk, [(x, 2.5 * s, z, 1.6 * s, 5 * s, 1.6 * s) for (x, z, s) in tr])
    greens = [(rng.uniform(0.16, 0.26), rng.uniform(0.3, 0.42), rng.uniform(0.15, 0.22), 1.0) for _ in tr]
    multimesh(sc, "Crowns", "Wilds", crown, [(x, 11 * s, z, 7 * s, 14 * s, 7 * s) for (x, z, s) in tr], greens)
    static_cylinders(sc, "TreeTrunks", "Wilds", [(x, z) for (x, z, _) in tr], 1.6, 8.0)

    rk = rocks()
    unit_rock = sc.sub_res("BoxMesh", {"size": "Vector3(1, 1, 1)", "material": rock})
    multimesh(sc, "Outcrops", "Wilds", unit_rock, rk)
    static_boxes(sc, "Rock", "Wilds", rk)

    lx, lz, lr = LAKE
    lake = sc.sub_res("CylinderMesh", {"top_radius": f(lr), "bottom_radius": f(lr), "height": "0.2",
                                       "radial_segments": "48", "rings": "1"})
    sc.node("Lake", "MeshInstance3D", "Wilds", {"transform": xform(lx, 0.08, lz), "mesh": lake,
                                               "material_override": water, "cast_shadow": "0"})
    shore = sc.sub_res("CylinderShape3D", {"height": "20.0", "radius": f(lr - 4)})
    sc.node("LakeShore", "StaticBody3D", "Wilds")
    sc.node("Shape", "CollisionShape3D", "Wilds/LakeShore", {"transform": xform(lx, 10, lz), "shape": shore})

    # The edge of the world: walls behind the tree belt.
    e = HALF
    static_boxes(sc, "Edge", ".", [(0, 20, -e - 5, e * 2 + 20, 40, 10), (0, 20, e + 5, e * 2 + 20, 40, 10),
                                   (-e - 5, 20, 0, 10, 40, e * 2 + 20), (e + 5, 20, 0, 10, 40, e * 2 + 20)])

    # Spawn points and doors.
    sc.node("SpawnPoints", "Node3D", ".")
    sc.node("Start", "Marker3D", "SpawnPoints", {"transform": xform(START[0], 0.5, START[1])})
    for name, area, (x, z), yaw in DOORS:
        sc.node(name, None, "SpawnPoints", {"transform": xform(x, 0, z, DOOR_SCALE, DOOR_SCALE, DOOR_SCALE, yaw)},
                instance=door)
        sc.node("AreaExit", "Node", "SpawnPoints/" + name, {"script": exit_script, "target_area": '&"%s"' % area})

    sc.node("OverworldCamera", None, ".", {
        "height": "69.282", "distance": "40.0", "pitch_degrees": "60.0", "min_distance": "20.0",
        "max_distance": "80.0", "zoom_step": "6.0", "tactical_range": "1100.0",
        "tactical_min_range": "500.0", "tactical_max_range": "1800.0"}, instance=camera)
    sc.node("WorldEnvironment", "WorldEnvironment", ".", {"environment": env})
    sc.node("DirectionalLight3D", "DirectionalLight3D", ".", {
        "transform": "Transform3D(0.766044, 0.492404, -0.413176, 0, 0.642788, 0.766044, 0.642788, -0.586824, 0.492404, 0, 0, 0)",
        "light_color": color(1, 0.94, 0.84), "light_energy": "1.25", "shadow_enabled": "true",
        "shadow_blur": "1.5", "directional_shadow_max_distance": "300.0"})

    # Districts, for the area label (and, from step 2, encounters).
    sc.node("Districts", "Node3D", ".")
    tables = {}
    group_script = sc.ext_res("Script", "res://world/encounter_group.gd")
    for node, display, half, danger, limit, battle, table in DISTRICTS:
        for name in table:
            if name not in tables:
                tables[name] = sc.ext_res("Resource", "res://data/encounters/%s.tres" % name)
        sc.node(node, "Area3D", "Districts", {"collision_layer": "0", "collision_mask": "0", "monitoring": "false",
                                              "monitorable": "false", "script": district,
                                              "display_name": '"%s"' % display,
                                              "danger": "%.6f" % danger,
                                              "encounters": "Array[%s]([%s])" % (
                                                  group_script, ", ".join(tables[n] for n in table)),
                                              "battle_area": '&"%s"' % battle,
                                              "encounter_limit": str(limit)})
        h = f(half)
        sc.node("Piece0", "CollisionPolygon3D", "Districts/" + node, {
            "rotation": "Vector3(1.5707964, 0, 0)", "depth": "400.0",
            "polygon": "PackedVector2Array(-%s, -%s, %s, -%s, %s, %s, -%s, %s)" % (h, h, h, h, h, h, h, h)})

    sc.write(OUT)
    print("wrote", os.path.normpath(OUT), "-", len(every), "buildings,", len(tr), "trees,", len(rk), "rocks")


build()
