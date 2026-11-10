class_name GrassTrample
extends Node3D
## Grass bends under units and springs back after they leave.
##
## A float texture over the grass holds, per texel, the time a unit last
## stood there. The grass shader (quarry_grass.gdshader) reads it through
## global shader parameters: grass whose stamp is fresh lies flat, bent away
## from the middle of the trampled patch, and rises again over `recover`
## seconds once the stamp is `hold` seconds old. Storing a time rather than
## an amount means nothing has to decay texel by texel: only the spots under
## units are ever written, and the texture is uploaded only when one was.
##
## Covers the bounds of the MultiMeshInstance3D children of `grass`. Units
## in other worlds (encounters run in their own World3D), flying units and
## units off the ground leave no mark.

const TEXEL := 0.25
const HOLD := 2.0
const RECOVER := 6.0
## How often marks are written. Grass doesn't need every physics frame.
const RATE := 20.0

## The node holding the grass MultiMeshInstance3Ds.
@export var grass: Node3D

var _image: Image
var _texture: ImageTexture
var _origin := Vector2.ZERO
var _size := Vector2i.ZERO
var _clock := 0.0
var _since := 0.0
var _dirty := false


func _ready() -> void:
	var bounds := AABB()
	var first := true
	for child in grass.get_children():
		var mmi := child as MultiMeshInstance3D
		if mmi == null:
			continue
		var box := mmi.global_transform * mmi.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		set_physics_process(false)
		return
	_origin = Vector2(bounds.position.x, bounds.position.z)
	_size = Vector2i(ceili(bounds.size.x / TEXEL), ceili(bounds.size.z / TEXEL))
	_image = Image.create_empty(_size.x, _size.y, false, Image.FORMAT_RF)
	# Long enough ago that nothing starts flat.
	_image.fill(Color(-1000.0, 0, 0))
	_texture = ImageTexture.create_from_image(_image)
	RenderingServer.global_shader_parameter_set(&"grass_trample", _texture)
	RenderingServer.global_shader_parameter_set(&"grass_trample_rect",
			Vector4(_origin.x, _origin.y, _size.x * TEXEL, _size.y * TEXEL))
	_publish_clock()


func _exit_tree() -> void:
	if _image != null:
		RenderingServer.global_shader_parameter_set(&"grass_trample_rect", Vector4.ZERO)


func _physics_process(delta: float) -> void:
	_clock += delta
	_since += delta
	if _since < 1.0 / RATE:
		return
	_since = 0.0
	var world := get_world_3d()
	for node in get_tree().get_nodes_in_group(&"units"):
		var unit := node as Unit
		if unit == null or unit.get_world_3d() != world or unit.is_flying():
			continue
		if not _on_ground(unit):
			continue
		_mark(unit.global_position, unit.radius + 0.3)
	if _dirty:
		_texture.update(_image)
		_dirty = false
	_publish_clock()


func _publish_clock() -> void:
	RenderingServer.global_shader_parameter_set(&"grass_trample_now", _clock)


func _on_ground(unit: Unit) -> bool:
	var from := unit.global_position + Vector3.UP * 0.3
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 0.7)
	query.exclude = [unit.get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _mark(at: Vector3, radius: float) -> void:
	# The middle stays flat longest, the rim springs back sooner, so a path
	# reads as a soft trough rather than a stamped disc. A texel already
	# marked recently enough is left alone: a unit standing still rewrites
	# nothing, so the texture isn't re-uploaded every tick.
	var c := (Vector2(at.x, at.z) - _origin) / TEXEL
	var r := radius / TEXEL
	for y in range(maxi(floori(c.y - r), 0), mini(ceili(c.y + r) + 1, _size.y)):
		for x in range(maxi(floori(c.x - r), 0), mini(ceili(c.x + r) + 1, _size.x)):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / r
			if d > 1.0:
				continue
			var stamp := _clock - d * d * HOLD * 0.9
			if _image.get_pixel(x, y).r < stamp - 0.5:
				_image.set_pixel(x, y, Color(stamp, 0, 0))
				_dirty = true
