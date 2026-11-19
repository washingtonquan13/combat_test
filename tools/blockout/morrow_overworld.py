"""Writes world/morrow_overworld.tscn: the grey-box overworld that replaced
the New Orleans map. One compact downtown (Morrow) on a street grid round
a central square, a ring of low outskirts, and the Greywood wilderness out
to the map's edge, with a dirt road west to the Old Quarry.

Grey-box trees (cylinders and cones) and rocks. The ground is stage 1's
(morrow_terrain.py), the roads stage 2's (morrow_roads.py) and the
buildings stage 3's (morrow_city.py): run those first. Everything here
stands on stage 1's heights and keeps off the roads and the buildings. Everything is seeded, so running it again writes
the same map.

    python tools/blockout/morrow_overworld.py

Hand edits to the .tscn are lost on the next run; move a door or a
district by changing the tables below instead.
"""
import json
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from shapely.geometry import Point, Polygon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from morrow_layout import (DOOR_SCALE, DOORS, DOWNTOWN, HALF, INN_HOUSE, LAKE, OUTSKIRTS,  # noqa: E402
                           QUARRY_CLEARING, RIVER, ROAD, SAFE_SPOT, START)
from morrow_terrain import OUT as STAGES, Terrain, polyline  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "world", "morrow_overworld.tscn")
SEED = 7
TEX = "res://assets/level/"

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
    for i, (x, y, z) in enumerate(cylinders):
        sc.node("Trunk%d" % i, "CollisionShape3D", path, {"transform": xform(x, y + height * 0.5 - 1.0, z),
                                                          "shape": shape})


# ---------------------------------------------------------------- layout

ground = Terrain()


def on_ground(box, sink=0.5):
    """A box (x, _, z, sx, h, sz) standing on the terrain: from below its
    lowest corner to h above its highest."""
    x, _, z, sx, h, sz = box
    lo, hi = ground.span(x - sx * 0.5, x + sx * 0.5, z - sz * 0.5, z + sz * 0.5)
    base, top = lo - sink, hi + h
    return (x, (base + top) * 0.5, z, sx, top - base, sz)


def load_stage(name):
    with open(os.path.join(STAGES, name), encoding="utf-8") as fh:
        return json.load(fh)


roads = load_stage("roads.json")["roads"]
city = load_stage("city.json")


def clearance():
    """Metres from every point of the map (a metre a texel) to the nearest
    road or building."""
    x0 = ground.x0
    size = int(math.ceil(-x0 * 2)) + 1
    img = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(img)

    def px(p):
        return (p[0] - x0, p[1] - x0)

    for road in roads:
        if road["kind"] == "square":
            draw.polygon([px(p) for p in road["points"]], fill=255)
        else:
            draw.line([px(p) for p in road["points"]], fill=255, width=max(1, int(round(road["width"]))))
    for bld in city["buildings"]:
        draw.polygon([px(p) for p in bld["points"]], fill=255)
    return ndimage.distance_transform_edt(np.asarray(img) == 0)


CLEAR = clearance()


def clear_of_roads(x, z, margin):
    """Margin metres or more from every road and building, and clear of the
    doors, the quarry, the lake and the river."""
    i, j = int(round(x - ground.x0)), int(round(z - ground.x0))
    if not (0 <= i < CLEAR.shape[1] and 0 <= j < CLEAR.shape[0]) or CLEAR[j, i] < margin:
        return False
    for _, _, (dx, dz), _ in DOORS:
        if math.hypot(x - dx, z - dz) < 40.0 + margin:
            return False
    if math.hypot(x - QUARRY_CLEARING[0], z - QUARRY_CLEARING[1]) < 90.0:
        return False
    if math.hypot(x - LAKE[0], z - LAKE[1]) < LAKE[2] + margin + 10.0:
        return False
    if polyline(x, z, RIVER)[0] < 40.0 + margin:
        return False
    return True


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
        out.append((x, z, rng.uniform(0.8, 1.4), ground.at(x, z)))
    # Downtown's parks: a loose grid of smaller trees.
    for park in city["parks"]:
        inner = Polygon(park).buffer(-5.0)
        x0, z0, x1, z1 = inner.bounds
        for x in np.arange(x0, x1, 12.0):
            for z in np.arange(z0, z1, 12.0):
                tx, tz = float(x) + rng.uniform(-3, 3), float(z) + rng.uniform(-3, 3)
                if inner.contains(Point(tx, tz)):
                    out.append((tx, tz, rng.uniform(0.6, 0.9), ground.at(tx, tz)))
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

    # A sky, mostly for the water to reflect (quarry_water.gdshader has
    # nothing to mirror against a flat colour); its horizon is the fog's.
    sky_mat = sc.sub_res("ProceduralSkyMaterial", {
        "sky_top_color": color(0.36, 0.52, 0.76), "sky_horizon_color": color(0.62, 0.68, 0.72),
        "ground_bottom_color": color(0.2, 0.22, 0.16), "ground_horizon_color": color(0.62, 0.68, 0.72)})
    sky = sc.sub_res("Sky", {"sky_material": sky_mat})
    env = sc.sub_res("Environment", {
        "background_mode": "2", "sky": sky, "reflected_light_source": "2",
        "ambient_light_source": "2", "ambient_light_color": color(0.78, 0.84, 0.95),
        "ambient_light_energy": "0.6", "tonemap_mode": "2", "tonemap_exposure": "1.05",
        "ssao_enabled": "true", "ssao_radius": "2.5", "ssao_intensity": "2.0",
        "fog_enabled": "true", "fog_mode": "1", "fog_light_color": color(0.62, 0.68, 0.72),
        "fog_density": "1.0", "fog_depth_curve": "1.6", "fog_depth_begin": "350.0", "fog_depth_end": "1400.0",
    })

    bark = material(sc, (0.32, 0.24, 0.17))
    leaves = material(sc, (1, 1, 1), 0.9, vertex=True)
    rock = material(sc, (0.48, 0.46, 0.43))
    inn = material(sc, (0.6, 0.42, 0.28))

    sc.node("MorrowOverworld", "Node3D", None, {
        "script": overworld, "avatar_speed_scale": "4.0", "avatar_icon_scale": "5.0",
        "deck_cutaway_radius": "0.0"})

    # Ground: stage 1's terrain, built on load (morrow_terrain.gd).
    sc.node("Ground", "Node3D", ".")
    terrain_script = sc.ext_res("Script", "res://world/morrow/morrow_terrain.gd")
    shader = sc.ext_res("Shader", "res://world/morrow/morrow_ground.gdshader")
    noise = sc.sub_res("FastNoiseLite", {"noise_type": "1", "frequency": "0.02", "fractal_octaves": "4"})
    variation = sc.sub_res("NoiseTexture2D", {"width": "256", "height": "256", "seamless": "true",
                                              "generate_mipmaps": "true", "noise": noise})
    params = {"shader": shader, "shader_parameter/variation": variation}
    layers = [("grass", "quarry/textures/grass_path_2"), ("soil", "quarry/textures/forest_ground_04"),
              ("rock", "quarry/textures/rock_face_03"), ("dirt", "quarry/textures/dirt_floor"),
              ("asphalt", "morrow/textures/asphalt_02"), ("paving", "morrow/textures/concrete_pavement"),
              ("cobble", "morrow/textures/cobblestone_floor_08")]
    for name, stem in layers:
        params["shader_parameter/%s_albedo" % name] = sc.ext_res("Texture2D", TEX + stem + "_diff_2k.jpg")
        params["shader_parameter/%s_normal" % name] = sc.ext_res("Texture2D", TEX + stem + "_nor_gl_2k.jpg")
    params["shader_parameter/nature_mask"] = sc.ext_res("Texture2D", "res://world/morrow/ground_nature.png")
    params["shader_parameter/town_mask"] = sc.ext_res("Texture2D", "res://world/morrow/ground_town.png")
    span = ground.meta["paint_size"]
    px0 = ground.meta["paint_x0"]
    params["shader_parameter/mask_rect"] = "Vector4(%s, %s, %r, %r)" % (f(px0), f(px0), 1.0 / span, 1.0 / span)
    ground_mat = sc.sub_res("ShaderMaterial", params)
    # The quarry's water shader (flow from the vertex colours morrow_terrain.gd
    # writes), its ripples scaled up for the overworld's high camera and its
    # pond greens cooled toward a river's blue.
    river_water = sc.sub_res("ShaderMaterial", {
        "shader": sc.ext_res("Shader", "res://world/goblin_quarry/quarry_water.gdshader"),
        "shader_parameter/ripple_size": "2.5", "shader_parameter/ripple_height": "0.3",
        "shader_parameter/clear_depth": "0.9",
        "shader_parameter/deep_color": color(0.03, 0.07, 0.09), "shader_parameter/murk_color": color(0.12, 0.18, 0.17)})
    sc.node("Terrain", "Node3D", "Ground", {"script": terrain_script, "material": ground_mat,
                                            "water_material": river_water})


    # Downtown and the outskirts: stage 3's buildings, built on load
    # (morrow_city.gd). Not under Ground: encounters don't spawn on roofs.
    def tex(stem, kind):
        return sc.ext_res("Texture2D", TEX + "morrow/textures/%s/%s_%s_2k.jpg" % (stem, stem, kind))

    def textured(stem, tile, triplanar=False):
        p = {"albedo_texture": tex(stem, "diff"), "normal_enabled": "true",
             "normal_texture": tex(stem, "nor_gl"), "roughness": "0.9", "texture_filter": "5"}
        if triplanar:
            p.update({"uv1_triplanar": "true", "uv1_world_triplanar": "true",
                      "uv1_scale": "Vector3(%s, %s, %s)" % (f(tile), f(tile), f(tile))})
        else:
            p["uv1_scale"] = "Vector3(%s, %s, 1)" % (f(tile), f(tile))
        return sc.sub_res("StandardMaterial3D", p)

    facade = sc.ext_res("Shader", "res://world/morrow/morrow_facade.gdshader")
    walls = {}
    for style, stem, tile in [("brick", "red_brick_03", 0.4), ("brick_dark", "brick_wall_02", 0.4),
                              ("plaster", "painted_plaster_wall", 0.3), ("plaster_warm", "beige_wall_001", 0.3),
                              ("stone", "sandstone_blocks_08", 0.3)]:
        walls[style] = sc.sub_res("ShaderMaterial", {
            "shader": facade, "shader_parameter/wall_tile": f(tile),
            "shader_parameter/wall_albedo": tex(stem, "diff"),
            "shader_parameter/wall_normal": tex(stem, "nor_gl"),
            "shader_parameter/ground_floor": f(city["ground_floor"]), "shader_parameter/storey": f(city["storey"])})
    sc.node("City", "Node3D", ".", {
        "script": sc.ext_res("Script", "res://world/morrow/morrow_city.gd"),
        "wall_materials": "{\n%s\n}" % ",\n".join('"%s": %s' % kv for kv in walls.items()),
        "flat_roof_material": textured("roof_slates_02", 0.25, True),
        "gable_roof_material": textured("clay_roof_tiles_02", 0.4)})

    # Bridges where a road crosses the river (stage 2 finds them, stage 1
    # sets their decks level with the road either side).
    sc.node("Bridges", "Node3D", ".")
    deck_stone = textured("sandstone_blocks_08", 0.25, True)
    for i, br in enumerate(ground.meta["bridges"]):
        name = "Bridge%d" % i
        sc.node(name, "StaticBody3D", "Bridges",
                {"transform": xform(br["x"], br["y"], br["z"], yaw=-math.degrees(br["yaw"]))})
        length, width = br["length"], br["width"]
        parts = [("Deck", 0.0, -0.6, 1.2, width)]
        for k, side in enumerate((-1, 1)):
            parts.append(("Rail%d" % k, side * (width * 0.5 - 0.2), 0.55, 1.1, 0.4))
        for part, off, y, sy, sz in parts:
            size = "Vector3(%s, %s, %s)" % (f(length), f(sy), f(sz))
            mesh = sc.sub_res("BoxMesh", {"size": size, "material": deck_stone})
            shape = sc.sub_res("BoxShape3D", {"size": size})
            sc.node(part, "MeshInstance3D", "Bridges/" + name, {"transform": xform(0, y, off), "mesh": mesh})
            sc.node(part + "Shape", "CollisionShape3D", "Bridges/" + name, {"transform": xform(0, y, off), "shape": shape})

    # The inn on the square: where a full rest will be taken.
    sx, sz = SAFE_SPOT
    sc.node("Inn", "Node3D", ".", {"transform": xform(sx, ground.at(sx, sz), sz)})
    inn_box = sc.sub_res("BoxMesh", {"size": "Vector3(16, 9, 12)"})
    ix, iz = INN_HOUSE
    sc.node("House", "MeshInstance3D", "Inn", {"transform": xform(ix, 4.5, iz), "mesh": inn_box,
                                               "material_override": inn})
    static_boxes(sc, "Solid", "Inn", [(ix, 4.5, iz, 16, 9, 12)])
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
    multimesh(sc, "Trunks", "Wilds", trunk, [(x, y + 2.5 * s - 0.5, z, 1.6 * s, 5 * s + 1, 1.6 * s) for (x, z, s, y) in tr])
    greens = [(rng.uniform(0.16, 0.26), rng.uniform(0.3, 0.42), rng.uniform(0.15, 0.22), 1.0) for _ in tr]
    multimesh(sc, "Crowns", "Wilds", crown, [(x, y + 11 * s, z, 7 * s, 14 * s, 7 * s) for (x, z, s, y) in tr], greens)
    static_cylinders(sc, "TreeTrunks", "Wilds", [(x, y, z) for (x, z, _, y) in tr], 1.6, 8.0)

    rk = [on_ground(r, 1.0) for r in rocks()]
    unit_rock = sc.sub_res("BoxMesh", {"size": "Vector3(1, 1, 1)", "material": rock})
    multimesh(sc, "Outcrops", "Wilds", unit_rock, rk)
    static_boxes(sc, "Rock", "Wilds", rk)

    lx, lz, lr = LAKE
    lake_water = ground.meta["lake"]["water"]
    # The lake's water is the terrain's (morrow_terrain.gd); this keeps walkers out.
    shore = sc.sub_res("CylinderShape3D", {"height": "20.0", "radius": f(lr - 4)})
    sc.node("LakeShore", "StaticBody3D", "Wilds")
    sc.node("Shape", "CollisionShape3D", "Wilds/LakeShore", {"transform": xform(lx, lake_water + 10, lz), "shape": shore})

    # The edge of the world: walls behind the tree belt.
    e = HALF
    static_boxes(sc, "Edge", ".", [(0, 50, -e - 5, e * 2 + 20, 300, 10), (0, 50, e + 5, e * 2 + 20, 300, 10),
                                   (-e - 5, 50, 0, 10, 300, e * 2 + 20), (e + 5, 50, 0, 10, 300, e * 2 + 20)])

    # Spawn points and doors.
    sc.node("SpawnPoints", "Node3D", ".")
    sc.node("Start", "Marker3D", "SpawnPoints", {"transform": xform(START[0], ground.at(*START) + 0.5, START[1])})
    for name, area, (x, z), yaw in DOORS:
        sc.node(name, None, "SpawnPoints", {"transform": xform(x, ground.at(x, z), z, DOOR_SCALE, DOOR_SCALE, DOOR_SCALE, yaw)},
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
    print("wrote", os.path.normpath(OUT), "-", len(city["buildings"]), "buildings,", len(tr), "trees,", len(rk), "rocks")


build()
