extends MeshInstance3D
## A set of ice crystals, drawn as one mesh with ice_crystal.gdshader.
## add_crystal() each one, then build(). Each crystal grows out of its
## root when set_time() passes its delay; set_shatter() 0..1 breaks them
## all up. Positions are in this node's local space.
##
## Visual only, and shared: the frost cone grows them where it hits; a
## spike burst or a frozen unit can use them too.

const SHADER: Shader = preload("res://scenes/vfx/ice/ice_crystal.gdshader")

var material: ShaderMaterial
## The middle of each crystal, for shards to fly from.
var centres: PackedVector3Array = PackedVector3Array()

var _vertices: PackedVector3Array = PackedVector3Array()
var _normals: PackedVector3Array = PackedVector3Array()
var _uvs: PackedVector2Array = PackedVector2Array()
var _custom: PackedFloat32Array = PackedFloat32Array()


func _init() -> void:
	material = ShaderMaterial.new()
	material.shader = SHADER
	var noise := NoiseTexture2D.new()
	noise.seamless = true
	var fast := FastNoiseLite.new()
	fast.frequency = 0.03
	noise.noise = fast
	material.set_shader_parameter("noise", noise)
	material_override = material


## Sets the clock the crystals grow by, in seconds.
func set_time(seconds: float) -> void:
	material.set_shader_parameter("time", seconds)


## 0: whole. 1: gone.
func set_shatter(amount: float) -> void:
	material.set_shader_parameter("shatter", amount)


## A crystal standing on `root`, pointing along `axis`: a five- or
## six-sided prism with a pointed tip. Its base sinks a little into the
## surface, so it looks frozen onto it rather than set on it.
func add_crystal(root: Vector3, axis: Vector3, length: float, radius: float, delay: float) -> void:
	axis = axis.normalized()
	var u: Vector3 = axis.cross(Vector3.UP if absf(axis.y) < 0.95 else Vector3.RIGHT).normalized()
	var v: Vector3 = axis.cross(u)
	var base: Vector3 = root - axis * radius * 0.6
	var shoulder: Vector3 = base + axis * length * randf_range(0.6, 0.8)
	var tip: Vector3 = base + axis * length + (u * randfn(0.0, 1.0) + v * randfn(0.0, 1.0)) * radius * 0.12
	var sides: int = randi_range(5, 6)
	var spin: float = randf() * TAU
	var lower: Array[Vector3] = []
	var upper: Array[Vector3] = []
	for i in sides:
		var a: float = spin + TAU * i / sides
		var out: Vector3 = (u * cos(a) + v * sin(a)) * radius * randf_range(0.8, 1.15)
		lower.append(base + out * 0.75)
		upper.append(shoulder + out)
	var info := Vector4(base.x, base.y, base.z, delay)
	var crystal_random: float = randf()
	for i in sides:
		var j: int = (i + 1) % sides
		_face(lower[i], upper[i], upper[j], base, axis, length, info, crystal_random)
		_face(lower[i], upper[j], lower[j], base, axis, length, info, crystal_random)
		_face(upper[i], tip, upper[j], base, axis, length, info, crystal_random)
	centres.append(base + axis * length * 0.5)


## Makes the mesh from the crystals added so far.
func build() -> void:
	if _vertices.is_empty():
		mesh = null
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_CUSTOM0] = _custom
	var array_mesh := ArrayMesh.new()
	var flags: int = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	mesh = array_mesh


## One flat facet, wound so it faces away from the crystal's axis.
func _face(a: Vector3, b: Vector3, c: Vector3, base: Vector3, axis: Vector3, length: float, info: Vector4, crystal_random: float) -> void:
	var middle: Vector3 = (a + b + c) / 3.0
	var outward: Vector3 = middle - (base + axis * axis.dot(middle - base))
	var normal: Vector3 = (b - a).cross(c - a).normalized()
	# Godot draws clockwise faces: the winding's cross product points in.
	if normal.dot(outward) > 0.0:
		var swap: Vector3 = b
		b = c
		c = swap
	else:
		normal = -normal
	for p in [a, b, c]:
		_vertices.append(p)
		_normals.append(normal)
		_uvs.append(Vector2(clampf((p - base).dot(axis) / length, 0.0, 1.0), crystal_random))
		_custom.append_array([info.x, info.y, info.z, info.w])
