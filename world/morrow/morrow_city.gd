class_name MorrowCity
extends Node3D
## The Morrow overworld's buildings, built on load from the lots stage 3
## wrote (tools/blockout/morrow_city.py, world/morrow/city.json): each
## footprint extruded from below the ground it stands on to its storeys,
## walls drawn with `morrow_facade.gdshader` (the windows are painted, in
## 3 m bays), a flat roof behind a parapet downtown and a gable out of town,
## its ridge along the street. One mesh per wall style, one for each roof
## kind, and one trimesh collision shape for the lot.
##
## Built at run time like MorrowTerrain, so the scene stays text. Not under
## the overworld's Ground node: encounters must not spawn on roofs.

const DATA := "res://world/morrow/city.json"
## How far a flat roof's walls rise above it.
const PARAPET := 0.8
## A gable roof's overhang at the eaves and the gable ends.
const EAVES := 0.6
## A gable's rise over its half-depth.
const PITCH := 0.75

## Wall material per style named in city.json ("brick", "plaster", ...).
@export var wall_materials: Dictionary = {}
@export var flat_roof_material: Material
@export var gable_roof_material: Material

var _ground_floor := 4.5
var _storey := 3.5
var _walls := {}
var _flat := SurfaceTool.new()
var _gable := SurfaceTool.new()
var _faces := PackedVector3Array()


func _ready() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	if not data is Dictionary:
		push_error("MorrowCity: %s is missing or unreadable; run morrow_city.py" % DATA)
		return
	_ground_floor = data.ground_floor
	_storey = data.storey
	_flat.begin(Mesh.PRIMITIVE_TRIANGLES)
	_gable.begin(Mesh.PRIMITIVE_TRIANGLES)
	var buildings: Array = data.buildings
	for i in buildings.size():
		_add_building(buildings[i], i)
	for style in _walls:
		_commit(_walls[style], "Walls_" + style, wall_materials.get(style))
	_commit(_flat, "FlatRoofs", flat_roof_material)
	_commit(_gable, "GableRoofs", gable_roof_material)
	var body := StaticBody3D.new()
	body.name = "Solid"
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(_faces)
	var holder := CollisionShape3D.new()
	holder.shape = shape
	body.add_child(holder)
	add_child(body)


func _add_building(b: Dictionary, index: int) -> void:
	var pts := PackedVector2Array()
	for p in b.points:
		pts.append(Vector2(p[0], p[1]))
	var storeys: int = b.storeys
	var floor_y: float = b.floor
	var base: float = b.base
	var top := floor_y + _ground_floor + (storeys - 1) * _storey
	var gable: bool = b.roof == "gable"
	var front: int = b.front
	var shops: bool = b.district == "downtown" and storeys >= 2
	var style: String = b.style
	if not _walls.has(style):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_walls[style] = st
	var walls: SurfaceTool = _walls[style]
	# A steady tint per building, so neighbours in one style differ.
	var rng := RandomNumberGenerator.new()
	rng.seed = index * 7919 + 17
	var shade := rng.randf_range(0.8, 1.08)
	var tint := Color(shade * rng.randf_range(0.97, 1.03), shade, shade * rng.randf_range(0.95, 1.02))

	var n := pts.size()
	var wall_top := top if gable else top + PARAPET
	for i in n:
		var p := pts[i]
		var q := pts[(i + 1) % n]
		var length := p.distance_to(q)
		var out := Vector3(q.y - p.y, 0.0, p.x - q.x).normalized()
		var colour := tint
		colour.a = 1.0 if shops and i == front else 0.0
		var uv2 := Vector2(storeys, length)
		var a := Vector3(p.x, base, p.y)
		var bb := Vector3(q.x, base, q.y)
		var c := Vector3(q.x, wall_top, q.y)
		var d := Vector3(p.x, wall_top, p.y)
		var ua := Vector2(0.0, base - floor_y)
		var ub := Vector2(length, base - floor_y)
		var uc := Vector2(length, wall_top - floor_y)
		var ud := Vector2(0.0, wall_top - floor_y)
		_tri(walls, [a, bb, c], [ua, ub, uc], out, colour, uv2)
		_tri(walls, [a, c, d], [ua, uc, ud], out, colour, uv2)

	if gable and n == 4:
		_add_gable(pts, front, floor_y, top, walls, tint, storeys)
	else:
		var tris := Geometry2D.triangulate_polygon(pts)
		for k in range(0, tris.size(), 3):
			var vs: Array = []
			var uvs: Array = []
			for m in 3:
				var p := pts[tris[k + m]]
				vs.append(Vector3(p.x, top, p.y))
				uvs.append(p)
			_tri(_flat, vs, uvs, Vector3.UP, Color.WHITE, Vector2.ZERO)


## A rectangle's gable roof, its ridge parallel to the front (street) edge,
## and the two triangles of wall that close its ends.
func _add_gable(pts: PackedVector2Array, front: int, floor_y: float, top: float, walls: SurfaceTool, tint: Color, storeys: int) -> void:
	var a := pts[front]
	var b := pts[(front + 1) % 4]
	var c := pts[(front + 2) % 4]
	var d := pts[(front + 3) % 4]
	var along := (b - a).normalized()
	var depth := a.distance_to(d)
	var back := (d - a) / depth
	var rise := depth * 0.5 * PITCH
	var ridge := top + rise
	var ma := (a + d) * 0.5
	var mb := (b + c) * 0.5
	# The gable ends' walls.
	for end in [[d, a, ma], [b, c, mb]]:
		var p: Vector2 = end[0]
		var q: Vector2 = end[1]
		var m: Vector2 = end[2]
		var out := Vector3(q.y - p.y, 0.0, p.x - q.x).normalized()
		var colour := tint
		colour.a = 0.0
		var length := p.distance_to(q)
		_tri(walls, [Vector3(p.x, top, p.y), Vector3(q.x, top, q.y), Vector3(m.x, ridge, m.y)],
			[Vector2(0.0, top - floor_y), Vector2(length, top - floor_y), Vector2(length * 0.5, ridge - floor_y)], out, colour,
			Vector2(storeys, length))
	# The two slopes, overhanging every edge.
	var e := EAVES
	var drop := e * PITCH
	var slope_len := sqrt(pow(depth * 0.5 + e, 2.0) + pow(rise + drop, 2.0))
	var run := b.distance_to(a) + e * 2.0
	for side in [[a - along * e - back * e, b + along * e - back * e],
			[d - along * e + back * e, c + along * e + back * e]]:
		var p: Vector2 = side[0]
		var q: Vector2 = side[1]
		var rp := ma - along * e
		var rq := mb + along * e
		var lo := top - drop
		var verts: Array[Vector3] = [Vector3(p.x, lo, p.y), Vector3(q.x, lo, q.y), Vector3(rq.x, ridge, rq.y), Vector3(rp.x, ridge, rp.y)]
		var up: Vector3 = (verts[1] - verts[0]).cross(verts[3] - verts[0]).normalized()
		if up.y < 0.0:
			up = -up
		var uvs := [Vector2(0.0, slope_len), Vector2(run, slope_len), Vector2(run, 0.0), Vector2(0.0, 0.0)]
		_tri(_gable, [verts[0], verts[1], verts[2]], [uvs[0], uvs[1], uvs[2]], up, Color.WHITE, Vector2.ZERO)
		_tri(_gable, [verts[0], verts[2], verts[3]], [uvs[0], uvs[2], uvs[3]], up, Color.WHITE, Vector2.ZERO)


## One triangle facing `normal`: wound clockwise seen from that side (Godot's
## front face) whatever order the corners came in. Also kept for collision.
func _tri(st: SurfaceTool, verts: Array, uvs: Array, normal: Vector3, colour: Color, uv2: Vector2) -> void:
	var order := [0, 1, 2]
	var v0: Vector3 = verts[0]
	var v1: Vector3 = verts[1]
	var v2: Vector3 = verts[2]
	if (v1 - v0).cross(v2 - v0).dot(normal) > 0.0:
		order = [0, 2, 1]
	for k in order:
		st.set_normal(normal)
		st.set_color(colour)
		st.set_uv(uvs[k])
		st.set_uv2(uv2)
		st.add_vertex(verts[k])
		_faces.append(verts[k])


func _commit(st: SurfaceTool, node_name: String, material: Material) -> void:
	st.generate_tangents()
	var mesh := st.commit()
	if mesh.get_surface_count() == 0:
		return
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	add_child(instance)
