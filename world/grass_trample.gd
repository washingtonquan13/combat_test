class_name GrassTrample
extends Node3D
## Grass bends under units and springs back after they leave.
##
## A float texture over the grass holds, per texel, the time a unit last
## stood there (red) and the time this press began (green), so grass eases
## down over `DOWN` seconds as a foot arrives instead of snapping flat. The grass shader (quarry_grass.gdshader) reads it through
## global shader parameters: grass whose stamp is fresh lies curled flat,
## bent away from the middle of the trampled patch, and rises again with a
## small wobble once the stamp is `HOLD` seconds old, leaving a faint dent
## for a while after. Storing a time rather than an amount means nothing has
## to decay texel by texel: only the spots under units are ever written, and
## the texture is uploaded only when one was.
##
## The shader reads the texture in its vertex stage, in frames the GPU may
## still be drawing when the next upload comes. Rewriting a texture those
## frames read lost the Vulkan device on an RX 5700 XT within seconds, while
## uploads alone and reads alone were both fine. So uploads rotate through
## BUFFERS textures: each one writes the texture bound longest ago, then
## binds it, and no texture is written while a frame in flight reads it.
##
## Covers the bounds of the MultiMeshInstance3D children of `grass`. Units
## in other worlds (encounters run in their own World3D), flying units and
## units off the ground leave no mark.
##
## Smooth at any frame rate: marking runs on the fixed physics tick, and
## each mark sweeps the path a unit walked since its last one, giving every
## texel the time the unit passed it, so a trodden path is continuous rather
## than a row of discs. The clock the shader sees moves every rendered frame
## (interpolated between physics ticks) and runs LAG behind, so a mark is
## always uploaded before the time it holds comes round: grass starts to
## go down from upright instead of partway through its ease.

const TEXEL := 0.25
const HOLD := 2.0
const RECOVER := 6.0
## Seconds trodden grass takes to go down. Matches the shader's trample_down.
const DOWN := 0.35
## How often marks are written. Grass doesn't need every physics frame.
const RATE := 20.0
## At RATE, the oldest texture was last bound 2 / RATE seconds (6 frames at
## 60 fps) before it is written again, more than the frames in flight.
const BUFFERS := 3
## How far the shader's clock runs behind: one marking interval and a half.
const LAG := 1.5 / RATE
## A unit that moved further than this between marks teleported; its path
## isn't swept.
const MAX_SWEEP := 3.0

## The node holding the grass MultiMeshInstance3Ds.
@export var grass: Node3D

var _image: Image
var _textures: Array[ImageTexture] = []
var _bound := 0
var _origin := Vector2.ZERO
var _size := Vector2i.ZERO
var _clock := 0.0
var _since := 0.0
var _dirty := false
## Instance id -> [where on the ground (xz), when] at the unit's last mark.
var _last := {}


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
		set_process(false)
		return
	_origin = Vector2(bounds.position.x, bounds.position.z)
	_size = Vector2i(ceili(bounds.size.x / TEXEL), ceili(bounds.size.z / TEXEL))
	_image = Image.create_empty(_size.x, _size.y, false, Image.FORMAT_RGF)
	# Long enough ago that nothing starts flat.
	_image.fill(Color(-1000.0, -1000.0, 0))
	for i in BUFFERS:
		_textures.append(ImageTexture.create_from_image(_image))
	RenderingServer.global_shader_parameter_set(&"grass_trample", _textures[_bound])
	RenderingServer.global_shader_parameter_set(&"grass_trample_rect",
			Vector4(_origin.x, _origin.y, _size.x * TEXEL, _size.y * TEXEL))
	RenderingServer.global_shader_parameter_set(&"grass_trample_now", -LAG)


func _exit_tree() -> void:
	if _image != null:
		RenderingServer.global_shader_parameter_set(&"grass_trample_rect", Vector4.ZERO)


func _process(_delta: float) -> void:
	# The physics clock plus how far rendering is into the next tick: moves
	# every frame, at the same pace whatever the frame rate.
	var between := Engine.get_physics_interpolation_fraction() / Engine.physics_ticks_per_second
	RenderingServer.global_shader_parameter_set(&"grass_trample_now", _clock + between - LAG)


func _physics_process(delta: float) -> void:
	_clock += delta
	_since += delta
	if _since < 1.0 / RATE:
		return
	_since -= 1.0 / RATE
	var world := get_world_3d()
	var marked := {}
	for node in get_tree().get_nodes_in_group(&"units"):
		var unit := node as Unit
		if unit == null or unit.get_world_3d() != world or unit.is_flying():
			continue
		if not _on_ground(unit):
			continue
		var id := unit.get_instance_id()
		var at := Vector2(unit.global_position.x, unit.global_position.z)
		var from := at
		var since := _clock
		var last: Array = _last.get(id, [])
		if not last.is_empty() and (last[0] as Vector2).distance_to(at) <= MAX_SWEEP:
			from = last[0]
			since = last[1]
		_mark(from, since, at, _clock, unit.radius + 0.3)
		marked[id] = [at, _clock]
	# Units that left the ground or the world start a fresh path next time.
	_last = marked
	if _dirty:
		_bound = (_bound + 1) % BUFFERS
		_textures[_bound].update(_image)
		RenderingServer.global_shader_parameter_set(&"grass_trample", _textures[_bound])
		_dirty = false


func _on_ground(unit: Unit) -> bool:
	var from := unit.global_position + Vector3.UP * 0.3
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 0.7)
	query.exclude = [unit.get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _mark(from: Vector2, since: float, to: Vector2, until: float, radius: float) -> void:
	# Stamps the capsule a unit swept from `from` (at time `since`) to `to`
	# (at `until`); each texel gets the time the unit passed nearest it. The
	# middle stays flat longest, the rim springs back sooner, so a path reads
	# as a soft trough rather than a stamped track. A texel already marked
	# recently enough is left alone: a unit standing still rewrites nothing,
	# so the texture isn't re-uploaded every tick.
	var a := (from - _origin) / TEXEL
	var b := (to - _origin) / TEXEL
	var ab := b - a
	var length2 := ab.length_squared()
	var r := radius / TEXEL
	var lo := a.min(b) - Vector2(r, r)
	var hi := a.max(b) + Vector2(r, r)
	for y in range(maxi(floori(lo.y), 0), mini(ceili(hi.y) + 1, _size.y)):
		for x in range(maxi(floori(lo.x), 0), mini(ceili(hi.x) + 1, _size.x)):
			var p := Vector2(x + 0.5, y + 0.5)
			var u := 0.0 if length2 < 1e-6 else clampf((p - a).dot(ab) / length2, 0.0, 1.0)
			var d := p.distance_to(a + ab * u) / r
			if d > 1.0:
				continue
			var when := lerpf(since, until, u)
			var stamp := when - d * d * HOLD * 0.9
			var was := _image.get_pixel(x, y)
			if was.r >= stamp - 0.5:
				continue
			# A press that is still holding keeps its start; grass already
			# rising starts a new press from how flat it still lies, so it
			# eases back down from there instead of jumping.
			var begun := was.g
			var rising := when - was.r - HOLD
			if rising > 0.0:
				var flat := 1.0 - smoothstep(0.0, RECOVER, rising)
				begun = when - flat * DOWN
			_image.set_pixel(x, y, Color(stamp, begun, 0))
			_dirty = true
