"""Writes the grey-box battlefields that overworld random encounters are
fought on: one per district, world/battle_<zone>.tscn plus its
data/areas/battle_<zone>.tres. Run with `python -I tools/blockout/battle_fields.py`.

Each is a 60 m square of proto blocks with the party's spawn at the south
end, four EnemySpawns markers at the north end facing it, and some cover
between, in the district's own kind: trunks in the Greywood, fences and
crates in the outskirts, building corners and barricades downtown. The
script is world/battle_field.gd (BattleField), which spawns the pending
fight and starts it; see docs/systems/areas_bootstrap.md, "Random
encounters".
"""
import math
import os
import random

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
SEED = 11
HALF = 30.0
PARTY = (0.0, -10.0)
ENEMIES = [(-6.0, 10.0), (-2.0, 11.0), (2.0, 11.0), (6.0, 10.0)]
# Kept clear of cover: the strip between the two sides, so the fight
# starts with a line of sight and nobody spawns inside a block.
LANE_X = 9.0
LANE_Z = 14.0

ZONES = {
    "greywood": ("Greywood Clearing", "trees"),
    "outskirts": ("Outskirts Lane", "fences"),
    "downtown": ("Morrow Backstreet", "streets"),
}


def f(v):
    return ("%.3f" % v).rstrip("0").rstrip(".")


def xform(x, y, z, yaw=0.0):
    c, s = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    return "Transform3D(%s, 0, %s, 0, 1, 0, %s, 0, %s, %s, %s, %s)" % (
        f(c), f(s), f(-s), f(c), f(x), f(y), f(z))


def cover(kind, rng):
    """(x, z, size, yaw) blocks for one zone."""
    out = []

    def clear(x, z, r):
        if abs(x) < LANE_X + r and abs(z) < LANE_Z + r:
            # Inside the lanes' box: only the middle band, as cover.
            return abs(z) < 4.0 and abs(x) > 2.5
        return abs(x) < HALF - 2 and abs(z) < HALF - 2

    tries = 0
    want = {"trees": 26, "fences": 10, "streets": 6}[kind]
    while len(out) < want and tries < 2000:
        tries += 1
        x, z = rng.uniform(-HALF, HALF), rng.uniform(-HALF, HALF)
        if kind == "trees":
            size, yaw = (1.2, 7.0, 1.2), rng.uniform(0, 90)
        elif kind == "fences":
            size, yaw = ((5.0, 1.4, 0.4), rng.choice([0, 90])) if rng.random() < 0.6 \
                else ((1.4, 1.4, 1.4), rng.uniform(0, 90))
        else:
            size, yaw = ((4.0, 1.2, 0.8), rng.choice([0, 90]))
        r = max(size[0], size[2]) * 0.5
        if not clear(x, z, r):
            continue
        if any(math.hypot(x - o[0], z - o[1]) < r + max(o[2][0], o[2][2]) * 0.5 + 1.5 for o in out):
            continue
        out.append((x, z, size, yaw))
    if kind == "streets":
        # Two building corners walling the street in, east and west.
        out += [(-22.0, 0.0, (14.0, 9.0, 40.0), 0.0), (22.0, 0.0, (14.0, 9.0, 40.0), 0.0)]
    return out


def scene(zone, display, kind, rng):
    nodes = []
    ext = [
        '[ext_resource type="Script" path="res://world/battle_field.gd" id="1_field"]',
        '[ext_resource type="PackedScene" path="res://world/proto_block.tscn" id="2_block"]',
        '[ext_resource type="PackedScene" path="res://systems/camera_system/crpg_camera.tscn" id="3_camera"]',
        '[ext_resource type="Environment" path="res://world/combat_environment.tres" id="4_env"]',
    ]
    root = "Battle" + zone.capitalize()
    nodes.append('[node name="%s" type="Node3D"]\nscript = ExtResource("1_field")' % root)
    nodes.append('[node name="LevelGeometry" type="Node3D" parent="."]')
    nodes.append('[node name="Floor" parent="LevelGeometry" instance=ExtResource("2_block")]\n'
                 'size = Vector3(%s, 1, %s)' % (f(HALF * 2), f(HALF * 2)))
    for i, (x, z, size, yaw) in enumerate(cover(kind, rng)):
        nodes.append('[node name="Cover%d" parent="LevelGeometry" instance=ExtResource("2_block")]\n'
                     'transform = %s\nsize = Vector3(%s, %s, %s)' % (
                         i, xform(x, 0.5 + size[1] / 2, z, yaw), f(size[0]), f(size[1]), f(size[2])))
    nodes.append('[node name="PartySpawnPoint" type="Marker3D" parent="."]\ntransform = %s'
                 % xform(PARTY[0], 0.5, PARTY[1]))
    nodes.append('[node name="EnemySpawns" type="Node3D" parent="."]')
    for i, (x, z) in enumerate(ENEMIES):
        # Facing the party: -Z forward turned to look south.
        nodes.append('[node name="Enemy%d" type="Marker3D" parent="EnemySpawns"]\ntransform = %s'
                     % (i, xform(x, 0.5, z, 180.0)))
    nodes.append('[node name="CRPGCamera" parent="." instance=ExtResource("3_camera")]\n'
                 'transform = Transform3D(1, 0, 0, 0, 0.707107, 0.707107, 0, -0.707107, 0.707107, 0, 10, -18)\n'
                 'max_pan_radius = %s' % f(HALF))
    nodes.append('[node name="WorldEnvironment" type="WorldEnvironment" parent="."]\n'
                 'environment = ExtResource("4_env")')
    nodes.append('[node name="DirectionalLight3D" type="DirectionalLight3D" parent="."]\n'
                 'transform = Transform3D(0.866025, -0.25, 0.433013, 0, 0.866025, 0.5, -0.5, -0.433013, 0.75, 0, 10, 0)\n'
                 'shadow_enabled = true')
    out = ["[gd_scene load_steps=%d format=3]" % (len(ext) + 1), ""] + ext + [""]
    out += [n + "\n" for n in nodes]
    path = os.path.join(ROOT, "world", "battle_%s.tscn" % zone)
    with open(path, "w", newline="\n") as fh:
        fh.write("\n".join(out))

    area = '''[gd_resource type="Resource" script_class="AreaDefinition" load_steps=3 format=3]

[ext_resource type="Script" uid="uid://dxjfu3gj225jt" path="res://systems/world_system/area_definition.gd" id="1_def"]
[ext_resource type="PackedScene" path="res://world/battle_%s.tscn" id="2_scene"]

[resource]
script = ExtResource("1_def")
id = &"battle_%s"
display_name = "%s"
world_scene = ExtResource("2_scene")
''' % (zone, zone, display)
    with open(os.path.join(ROOT, "data", "areas", "battle_%s.tres" % zone), "w", newline="\n") as fh:
        fh.write(area)
    print("wrote", os.path.normpath(path))


rng = random.Random(SEED)
for zone, (display, kind) in ZONES.items():
    scene(zone, display, kind, rng)
