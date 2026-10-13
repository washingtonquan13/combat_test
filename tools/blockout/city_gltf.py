"""Writes the city osm_city.py built as a glTF binary that Godot imports
like any other model, with the fields its shaders read as ordinary
textures beside it.

    python -I tools/blockout/city_gltf.py data/blockouts/<name> world/<dir> \
        [--pitch 60 --range 120 --icon 10 --speed 10.67]

Into <dir>, every time:
  city.glb      one node per tile: Ground_X_Z (the ground and the water
                surface, no collision), Tile_X_Z-col (blocks and decks,
                drawn and walked on), Water_X_Z-colonly (the water's
                sides, collision only), and Floor-colonly, the slab under
                the ground with a wall at the map's four edges, and
                BoundaryWall-colonly along the city line. Godot reads the
                -col suffixes itself and makes the bodies.
  city.glb.import  maps the glb's materials (ground, water, blocks, deck)
                to the project's world/materials/city_*.tres, so the
                city's look is edited there, never in a generated file.
  shore.png, edge.exr  the water and edge fields from shore_field.py as
                textures, with .import files that keep them uncompressed.
  city.json     where the two fields lie in metres, for city_geometry.gd,
                which hands them to the shaders as global uniforms.

And once, <dir>_overworld.tscn beside <dir> (or --scene): the editable area that
instances the glb, with its spawn, camera, fog sheets, light and
environment. Doors and spawn points placed by hand survive a rebuild
because the file is never written again.

The glb is true metres, x east, y up, z south, the frame of osm_city.py.
Each vertex carries its position, a flat normal, the colour of its kind
(COLOR_0, sRGB) and (kind, tint / 255) in TEXCOORD_1, which Godot imports
as UV2, for the shaders that colour by kind. Map data (c) OpenStreetMap
contributors, ODbL.
"""
import argparse
import json
import math
import os
import shutil
import struct

import numpy as np

## Vertex colours by triangle kind, in osm_city.py's order: ground classes,
## building wall and roof, then decks_mesh.py's road surface, side, pier,
## rail.
GROUND_COLORS = [(150, 150, 146), (92, 108, 88), (98, 124, 84), (150, 150, 144),
                 (92, 86, 80), (78, 80, 84), (64, 66, 70), (52, 78, 96)]
BUILDING_COLORS = [(204, 199, 189), (140, 138, 133)]
DECK_COLORS = [(70, 72, 76), (156, 154, 148), (138, 136, 130), (176, 174, 166)]
## The ground class osm_city.py gives water.
WATER = 7
EDGE_WALL = 4.0
## The drifting fog over the edge fade: sheets at these heights in metres,
## the metres outside the boundary where each starts to thicken, negative
## for inside, the low ones reaching farthest in so the bank rises outward,
## and how far the sheets run on past the map.
FOG_HEIGHTS = [0.6, 3.0, 7.0]
FOG_MARGIN = 600.0
## The scene's haze, which the fog matches.
HAZE = (0.72, 0.76, 0.80)
MATERIALS = {
    "ground": "res://world/materials/city_ground.tres",
    "water": "res://world/materials/city_water.tres",
    "blocks": "res://world/materials/city_blocks.tres",
    "deck": "res://world/materials/city_deck.tres",
}
FOG_MATERIALS = ["res://world/materials/city_fog_%d.tres" % i for i in range(3)]

GLB_MAGIC = 0x46546C67
GLB_JSON = 0x4E4F534A
GLB_BIN = 0x004E4942
FLOAT, UBYTE, UINT = 5126, 5121, 5125


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--pitch", type=float, default=60.0)
    ap.add_argument("--range", type=float, default=120.0, help="metres from camera to avatar along the view")
    ap.add_argument("--icon", type=float, default=10.0)
    ap.add_argument("--speed", type=float, default=10.666667)
    ap.add_argument("--cutaway", type=float, default=14.0)
    ap.add_argument("--scene", help="the editable area scene, written only if missing (default <out>_overworld.tscn)")
    args = ap.parse_args()
    with open(os.path.join(args.src, "city.json"), encoding="utf-8") as f:
        meta = json.load(f)
    os.makedirs(args.out, exist_ok=True)

    gltf = Gltf()
    corner = np.array(meta["corner"], dtype=np.float64)
    size = np.array(meta["extent"], dtype=np.float64)
    tris = 0
    for tile in meta["tiles"]:
        name = "%d_%d" % (tile["x"], tile["z"])
        prims = []
        if "ground" in tile:
            pos, kind, tint = _read(os.path.join(args.src, "tiles", tile["ground"]))
            water = kind == WATER
            if (~water).any():
                prims.append(_prim(pos[~water], kind[~water], tint[~water], GROUND_COLORS, "ground"))
            if water.any():
                prims.append(_prim(pos[water], kind[water], tint[water], GROUND_COLORS, "water"))
        if prims:
            gltf.node("Ground_" + name, gltf.mesh(prims))
        prims = []
        if "blocks" in tile:
            pos, kind, tint = _read(os.path.join(args.src, "tiles", tile["blocks"]))
            tris += len(pos)
            prims.append(_prim(pos, kind, tint, BUILDING_COLORS, "blocks"))
        if "decks" in tile:
            pos, kind, tint = _read(os.path.join(args.src, "tiles", tile["decks"]))
            prims.append(_prim(pos, kind, tint, DECK_COLORS, "deck"))
        if prims:
            gltf.node("Tile_%s-col" % name, gltf.mesh(prims))
        if "water" in tile:
            pos, kind, tint = _read(os.path.join(args.src, "tiles", tile["water"]))
            if len(pos):
                gltf.node("Water_%s-colonly" % name, gltf.mesh([_prim(pos, kind, tint, GROUND_COLORS, "collision")]))
    gltf.node("Floor-colonly", gltf.mesh([_prim(_floor(corner, size), None, None, None, "collision")]))
    if "boundary" in meta:
        gltf.node("BoundaryWall-colonly", gltf.mesh([_prim(_boundary(meta["boundary"]), None, None, None, "collision")]))
    glb = os.path.join(args.out, "city.glb")
    gltf.write(glb)
    _write_text(glb + ".import", _glb_import(args.out))

    sidecar = {"attribution": meta["attribution"], "corner": meta["corner"], "extent": meta["extent"]}
    if "shore" in meta:
        shore = meta["shore"]
        shutil.copyfile(os.path.join(args.src, shore["file"]), os.path.join(args.out, "shore.png"))
        _write_text(os.path.join(args.out, "shore.png.import"), _texture_import(args.out, "shore.png", mipmaps=True))
        sidecar["shore"] = {"file": "shore.png", "origin": meta["corner"], "size": _field_size(args.src, shore)}
    if "edge" in meta:
        edge = meta["edge"]
        if edge.get("format") != "half":
            raise SystemExit("%s: an edge field from before half floats; rerun shore_field.py" % args.src)
        with open(os.path.join(args.src, edge["file"]), "rb") as f:
            field = np.frombuffer(f.read(), dtype="<f2").reshape(edge["size"][1], edge["size"][0])
        _write_exr(os.path.join(args.out, "edge.exr"), field)
        _write_text(os.path.join(args.out, "edge.exr.import"), _texture_import(args.out, "edge.exr", mipmaps=False))
        sidecar["edge"] = {"file": "edge.exr", "origin": meta["corner"],
                           "size": [edge["size"][0] * edge["res"], edge["size"][1] * edge["res"]]}
    with open(os.path.join(args.out, "city.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(sidecar, f, indent=1)
    print("city: %d tiles, %d building triangles, %d vertices -> %s" % (len(meta["tiles"]), tris, gltf.vertices, glb))

    area = args.scene or os.path.normpath(args.out).rstrip("/\\") + "_overworld.tscn"
    if not os.path.exists(area):
        _write_text(area, _area_scene(os.path.basename(area), args, meta, corner, size))
        print("overworld -> %s" % area)


def _read(path):
    """A tile file: n triangles as (n, 3, 3) float32, their kinds and tints."""
    with open(path, "rb") as f:
        data = f.read()
    n = struct.unpack_from("<i", data, 0)[0]
    pos = np.frombuffer(data, dtype="<f4", count=n * 9, offset=4).reshape(n, 3, 3)
    kind = np.frombuffer(data, dtype=np.uint8, count=n, offset=4 + n * 36)
    tint = np.frombuffer(data, dtype=np.uint8, count=n, offset=4 + n * 37)
    return pos, kind, tint


def _prim(pos, kind, tint, colors, material):
    """A primitive's vertex arrays, welded. kind and tint are None for
    collision-only geometry, which carries only positions and normals."""
    n = len(pos)
    nrm = np.cross(pos[:, 1] - pos[:, 0], pos[:, 2] - pos[:, 0])
    nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-12)
    nrm = np.repeat(nrm.astype(np.float32), 3, axis=0)
    p = pos.reshape(-1, 3).astype(np.float32)
    if kind is None:
        rows = np.concatenate([p, nrm], axis=1)
        unique, index = np.unique(rows, axis=0, return_inverse=True)
        return {"POSITION": unique[:, :3], "NORMAL": unique[:, 3:6], "indices": index.astype(np.uint32), "material": material}
    table = np.array(colors, dtype=np.uint8)
    col = np.empty((n, 4), dtype=np.uint8)
    col[:, :3] = table[kind]
    col[:, 3] = 255
    col = np.repeat(col, 3, axis=0)
    uv2 = np.repeat(np.stack([kind.astype(np.float32), tint.astype(np.float32) / 255.0], axis=1), 3, axis=0)
    rows = np.concatenate([p, nrm, uv2, col.view(np.float32)], axis=1)
    unique, index = np.unique(rows, axis=0, return_inverse=True)
    return {"POSITION": unique[:, :3], "NORMAL": unique[:, 3:6], "TEXCOORD_1": unique[:, 6:8],
            "COLOR_0": np.ascontiguousarray(unique[:, 8]).view(np.uint8).reshape(-1, 4),
            "indices": index.astype(np.uint32), "material": material}


def _box(centre, size):
    """A box's twelve triangles, facing out."""
    c = np.asarray(centre, dtype=np.float64)
    h = np.asarray(size, dtype=np.float64) * 0.5
    x, y, z = h
    v = np.array([[-x, -y, -z], [x, -y, -z], [x, y, -z], [-x, y, -z],
                  [-x, -y, z], [x, -y, z], [x, y, z], [-x, y, z]]) + c
    faces = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
             (2, 3, 7), (2, 7, 6), (1, 2, 6), (1, 6, 5), (0, 4, 7), (0, 7, 3)]
    return v[np.array(faces)]


def _floor(corner, size):
    """A slab under the ground to stand on, and a wall round the map."""
    centre = corner + size * 0.5
    h = EDGE_WALL
    boxes = [_box((centre[0], -0.5, centre[1]), (size[0], 1.0, size[1])),
             _box((centre[0], h * 0.5, corner[1]), (size[0], h, 1.0)),
             _box((centre[0], h * 0.5, corner[1] + size[1]), (size[0], h, 1.0)),
             _box((corner[0], h * 0.5, centre[1]), (1.0, h, size[1])),
             _box((corner[0] + size[0], h * 0.5, centre[1]), (1.0, h, size[1]))]
    return np.concatenate(boxes).astype(np.float32)


def _boundary(rings):
    """The city line as a wall, both faces, so it blocks from either side."""
    quads = []
    for ring in rings:
        r = np.asarray(ring, dtype=np.float64)
        a = np.stack([r[:, 0], np.zeros(len(r)), r[:, 1]], axis=1)
        b = np.roll(a, -1, axis=0)
        up = np.array([0.0, EDGE_WALL, 0.0])
        quads.append(np.stack([a, b, b + up], axis=1))
        quads.append(np.stack([a, b + up, a + up], axis=1))
        quads.append(np.stack([a, b + up, b], axis=1))
        quads.append(np.stack([a, a + up, b + up], axis=1))
    return np.concatenate(quads).astype(np.float32)


def _field_size(src, shore):
    """The metres a field image covers: its pixels times its resolution."""
    w, h = _png_size(os.path.join(src, shore["file"]))
    return [w * shore["res"], h * shore["res"]]


def _png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("%s: not a PNG" % path)
    return struct.unpack(">II", head[16:24])


class Gltf:
    """A glTF binary under construction: one buffer, nodes all at the root."""

    def __init__(self):
        self.chunks = []
        self.offset = 0
        self.views = []
        self.accessors = []
        self.meshes = []
        self.nodes = []
        self.materials = {}
        self.vertices = 0

    def _view(self, data, target):
        data = np.ascontiguousarray(data).tobytes()
        pad = (-len(data)) % 4
        self.chunks.append(data + b"\0" * pad)
        self.views.append({"buffer": 0, "byteOffset": self.offset, "byteLength": len(data), "target": target})
        self.offset += len(data) + pad
        return len(self.views) - 1

    def _accessor(self, data, ctype, atype, target, normalized=False, bounds=False):
        acc = {"bufferView": self._view(data, target), "componentType": ctype, "count": len(data), "type": atype}
        if normalized:
            acc["normalized"] = True
        if bounds:
            acc["min"] = [float(v) for v in data.min(axis=0)]
            acc["max"] = [float(v) for v in data.max(axis=0)]
        self.accessors.append(acc)
        return len(self.accessors) - 1

    def material(self, name):
        if name not in self.materials:
            self.materials[name] = {"name": name, "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0], "metallicFactor": 0.0, "roughnessFactor": 1.0}}
        return list(self.materials).index(name)

    def mesh(self, prims):
        out = []
        for p in prims:
            attrs = {"POSITION": self._accessor(p["POSITION"], FLOAT, "VEC3", 34962, bounds=True),
                     "NORMAL": self._accessor(p["NORMAL"], FLOAT, "VEC3", 34962)}
            if "COLOR_0" in p:
                attrs["COLOR_0"] = self._accessor(p["COLOR_0"], UBYTE, "VEC4", 34962, normalized=True)
                attrs["TEXCOORD_1"] = self._accessor(p["TEXCOORD_1"], FLOAT, "VEC2", 34962)
            self.vertices += len(p["POSITION"])
            out.append({"attributes": attrs, "indices": self._accessor(p["indices"], UINT, "SCALAR", 34963),
                        "material": self.material(p["material"]), "mode": 4})
        self.meshes.append({"primitives": out})
        return len(self.meshes) - 1

    def node(self, name, mesh):
        self.nodes.append({"name": name, "mesh": mesh})

    def write(self, path):
        doc = {"asset": {"version": "2.0", "generator": "city_gltf.py",
                         "copyright": "Map data (c) OpenStreetMap contributors, ODbL 1.0"},
               "scene": 0, "scenes": [{"name": "CityGeometry", "nodes": list(range(len(self.nodes)))}],
               "nodes": self.nodes, "meshes": self.meshes, "materials": list(self.materials.values()),
               "accessors": self.accessors, "bufferViews": self.views, "buffers": [{"byteLength": self.offset}]}
        js = json.dumps(doc, separators=(",", ":")).encode("utf-8")
        js += b" " * ((-len(js)) % 4)
        binary = b"".join(self.chunks)
        total = 12 + 8 + len(js) + 8 + len(binary)
        with open(path, "wb") as f:
            f.write(struct.pack("<III", GLB_MAGIC, 2, total))
            f.write(struct.pack("<II", len(js), GLB_JSON))
            f.write(js)
            f.write(struct.pack("<II", len(binary), GLB_BIN))
            f.write(binary)


def _write_exr(path, field):
    """A single half-float channel R as an uncompressed scanline EXR,
    which Godot imports as a texture that keeps the signed metres."""
    h, w = field.shape
    data = np.ascontiguousarray(field, dtype="<f2")

    def attr(name, kind, value):
        return name.encode() + b"\0" + kind.encode() + b"\0" + struct.pack("<i", len(value)) + value

    chlist = b"R\0" + struct.pack("<iB3xii", 1, 0, 1, 1) + b"\0"
    box = struct.pack("<iiii", 0, 0, w - 1, h - 1)
    header = (attr("channels", "chlist", chlist) + attr("compression", "compression", b"\0")
              + attr("dataWindow", "box2i", box) + attr("displayWindow", "box2i", box)
              + attr("lineOrder", "lineOrder", b"\0") + attr("pixelAspectRatio", "float", struct.pack("<f", 1.0))
              + attr("screenWindowCenter", "v2f", struct.pack("<ff", 0.0, 0.0))
              + attr("screenWindowWidth", "float", struct.pack("<f", 1.0)) + b"\0")
    start = 8 + len(header) + 8 * h
    line = 8 + w * 2
    offsets = struct.pack("<%dQ" % h, *[start + y * line for y in range(h)])
    with open(path, "wb") as f:
        f.write(struct.pack("<Ii", 0x01312F76, 2))
        f.write(header)
        f.write(offsets)
        for y in range(h):
            f.write(struct.pack("<ii", y, w * 2))
            f.write(data[y].tobytes())


def _res(out, name):
    rel = os.path.relpath(os.path.join(out, name), os.getcwd()).replace("\\", "/")
    return "res://" + rel


def _glb_import(out):
    materials = ",\n".join('"%s": {\n"use_external/enabled": true,\n"use_external/path": "%s"\n}' % (k, v)
                           for k, v in MATERIALS.items())
    return """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="%s"

[params]

nodes/root_type=""
nodes/root_name=""
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=false
meshes/generate_lods=false
meshes/create_shadow_meshes=true
meshes/light_baking=1
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=true
skins/use_named_skins=true
animation/import=false
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
_subresources={
"materials": {
%s
}
}
gltf/naming_version=1
gltf/embedded_image_handling=1
""" % (_res(out, "city.glb"), materials)


def _texture_import(out, name, mipmaps):
    """Lossless, never switched to VRAM compression when a 3D material
    picks the texture up, since both fields are data, not pictures."""
    return """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="%s"

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/hdr_compression=0
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=%s
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/fix_alpha_border=false
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
""" % (_res(out, name), "true" if mipmaps else "false")


def _area_scene(file_name, args, meta, corner, size):
    """The editable overworld, framed the SMT IV way: the shared overworld
    script, a Start spawn in Jackson Square (or inside the city line when
    the build does not reach it), the camera at --pitch and
    --range, the fog sheets, haze and sun."""
    root = "".join(w.capitalize() for w in file_name[:-len(".tscn")].split("_"))
    pitch = math.radians(args.pitch)
    along = math.cos(pitch)
    distance = args.range * along
    height = distance * math.tan(pitch)
    # The haze starts past the farthest ground the camera can frame, a
    # top corner at full zoom out, so it colours only the horizon of wider
    # views and never a road in play.
    fov_tan = math.tan(math.radians(75.0 * 0.5))
    corner_ray = math.sqrt((fov_tan * 16.0 / 9.0) ** 2 + fov_tan ** 2 + 1.0)
    farthest = args.range * 1.5 * math.sin(pitch) * corner_ray / (math.sin(pitch) - fov_tan * math.cos(pitch))
    start = _start(meta)
    centre = corner + size * 0.5
    sheet = size + FOG_MARGIN * 2.0
    haze = "Color(%g, %g, %g, 1)" % HAZE
    fog_ext = "".join('[ext_resource type="Material" path="%s" id="fog%d"]\n' % (p, i) for i, p in enumerate(FOG_MATERIALS))
    sheets = "".join("""
[node name="Sheet%d" type="MeshInstance3D" parent="BoundaryFog"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)
cast_shadow = 0
mesh = SubResource("fog_plane")
surface_material_override/0 = ExtResource("fog%d")
""" % (i, centre[0], FOG_HEIGHTS[i], centre[1], i) for i in range(3))
    return """[gd_scene format=3]

[ext_resource type="Script" path="res://world/overworld.gd" id="overworld"]
[ext_resource type="Script" path="res://world/city_geometry.gd" id="geometry"]
[ext_resource type="PackedScene" path="%s" id="city"]
[ext_resource type="PackedScene" path="res://systems/camera_system/overworld_camera.tscn" id="camera"]
%s
[sub_resource type="Environment" id="env"]
background_mode = 1
background_color = %s
ambient_light_source = 2
ambient_light_color = Color(0.78, 0.84, 0.95, 1)
ambient_light_energy = 0.55
tonemap_mode = 2
tonemap_exposure = 1.05
tonemap_white = 6.0
ssao_enabled = true
ssao_radius = 2.5
ssao_intensity = 2.5
ssao_detail = 0.5
fog_enabled = true
fog_mode = 1
fog_light_color = %s
fog_depth_curve = 1.6
fog_depth_begin = %g
fog_depth_end = %g
adjustment_enabled = true
adjustment_contrast = 1.08
adjustment_saturation = 0.92

[sub_resource type="PlaneMesh" id="fog_plane"]
size = Vector2(%g, %g)

[node name="%s" type="Node3D"]
script = ExtResource("overworld")
avatar_speed_scale = %g
avatar_icon_scale = %g
deck_cutaway_radius = %g
metadata/osm_attribution = %s

[node name="CityGeometry" parent="." instance=ExtResource("city")]
script = ExtResource("geometry")

[node name="BoundaryFog" type="Node3D" parent="."]
%s
[node name="SpawnPoints" type="Node3D" parent="."]

[node name="Start" type="Marker3D" parent="SpawnPoints"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, 0.5, %g)

[node name="OverworldCamera" parent="." instance=ExtResource("camera")]
height = %g
distance = %g
pitch_degrees = %g
min_distance = %g
max_distance = %g
zoom_step = %g

[node name="WorldEnvironment" type="WorldEnvironment" parent="."]
environment = SubResource("env")

[node name="DirectionalLight3D" type="DirectionalLight3D" parent="."]
rotation = Vector3(%g, %g, 0)
light_color = Color(1, 0.94, 0.84, 1)
light_energy = 1.25
shadow_enabled = true
shadow_blur = 1.5
directional_shadow_max_distance = %g
""" % (_res(args.out, "city.glb"), fog_ext, haze, haze, farthest * 1.1, farthest * 6.6, sheet[0], sheet[1],
       root, args.speed, args.icon, args.cutaway, json.dumps(meta["attribution"]), sheets,
       start[0], start[1], height, distance, args.pitch, distance * 0.5, distance * 1.5, distance * 0.125,
       math.radians(-50.0), math.radians(-40.0), args.range * 3.0)


def _inside(rings, x, z):
    """Even-odd test of points (x, z) against the city line's rings."""
    hit = np.zeros(np.shape(x), bool)
    for ring in rings:
        r = np.asarray(ring, dtype=np.float64)
        a, b = r, np.roll(r, -1, axis=0)
        for (ax, az), (bx, bz) in zip(a, b):
            cross = (az > z) != (bz > z)
            with np.errstate(divide="ignore", invalid="ignore"):
                xs = ax + (z - az) * (bx - ax) / (bz - az)
            hit ^= cross & (x < xs)
    return hit


def _start(meta):
    """Jackson Square, or, for a build that does not reach it, the point
    inside the city line farthest from it (on a 50 x 50 grid)."""
    start = _local(meta, 29.9574, -90.0630)
    rings = meta.get("boundary")
    if not rings or _inside(rings, np.array(start[0]), np.array(start[1])):
        return start
    pts = np.vstack(rings)
    lo, hi = pts.min(0), pts.max(0)
    gx, gz = np.meshgrid(np.linspace(lo[0], hi[0], 50), np.linspace(lo[1], hi[1], 50))
    gx, gz = gx.ravel(), gz.ravel()
    ok = _inside(rings, gx, gz)
    gx, gz = gx[ok], gz[ok]
    clear = np.full(len(gx), np.inf)
    for ring in rings:
        r = np.asarray(ring, dtype=np.float64)
        a, d = r, np.roll(r, -1, axis=0) - r
        q = np.stack([gx, gz], 1)[:, None, :] - a[None]
        t = np.clip((q * d[None]).sum(2) / np.maximum((d * d).sum(1), 1e-9)[None], 0.0, 1.0)
        clear = np.minimum(clear, np.hypot(*(q - t[..., None] * d[None]).transpose(2, 0, 1)).min(1))
    k = int(np.argmax(clear))
    return float(gx[k]), float(gz[k])


def _local(meta, lat, lon):
    """A lat/lon as (x, z) metres on the map."""
    lat0, lon0 = meta["origin"]
    m_lat = 111320.0
    m_lon = 111320.0 * math.cos(math.radians(lat0))
    return (lon - lon0) * m_lon, -(lat - lat0) * m_lat


def _write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


if __name__ == "__main__":
    main()
