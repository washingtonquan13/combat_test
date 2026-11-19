class_name DialogueLighting
extends Node
## Film lighting on the speaker's face during a conversation, on top of the
## world's own light: a soft key off to one side, a faint fill from the
## camera, and a rim from behind to lift them off the background.
##
## UNITS ONLY. The three lights reach Unit.RENDER_LAYER alone (every unit
## body, its hair and clothes, a stand-in's copy), so the ground, walls and
## props keep exactly the world's light and shadows. They cast no shadow of
## their own: the world's shadows on a face stay the only ones, and nothing
## here can add a second set at odd angles.
##
## MOTIVATED. The key sits on the side the area's sun comes from, so it
## reads as the sun's light caught on the face, not a lamp nobody can see.
## An area with no sun keys from the camera's right.
##
## SUBTLE. Each light is a soft-edged spot, aimed at the head and gone by
## the floor, at energies that brighten a face by a stop or less in
## daylight. They fade in when a conversation starts, out when it ends, and
## out while a cutscene owns the screen (its own lighting is authored).
##
## Owned by the dialogue system; a child of DialogueStaging, which says who
## is speaking. The lights live under the cinematic camera, so they are in
## whichever World3D the conversation is seen in.

## Degrees off the camera's line to the face, and metres out and up.
const KEY_AZIMUTH: float = 50.0
const KEY_DISTANCE: float = 1.6
const KEY_HEIGHT: float = 0.55
const FILL_AZIMUTH: float = 8.0
const FILL_DISTANCE: float = 1.8
const FILL_HEIGHT: float = 0.15
const RIM_AZIMUTH: float = 145.0
const RIM_DISTANCE: float = 1.5
const RIM_HEIGHT: float = 0.75

## Energies at full weight. The fill has almost no specular, so it opens
## the shadows without a second catchlight; the rim is mostly specular, a
## line of light on hair and shoulders.
const KEY_ENERGY: float = 0.6
const FILL_ENERGY: float = 0.15
const FILL_SPECULAR: float = 0.1
const RIM_ENERGY: float = 0.9
const RIM_SPECULAR: float = 0.8
## Warm key and rim, a cooler fill, all near white.
const KEY_COLOR := Color(1.0, 0.95, 0.88)
const FILL_COLOR := Color(0.9, 0.94, 1.0)
const RIM_COLOR := Color(1.0, 0.97, 0.92)

## Wide, soft-edged spots: the edge never shows on a face. Each reaches
## only this far past the head, so a unit or prop behind the speaker stays
## in the world's light.
const SPOT_ANGLE: float = 30.0
const SPOT_EDGE: float = 2.5
const REACH_PAST_HEAD: float = 0.45

const FADE_IN_SECONDS: float = 0.8
const FADE_OUT_SECONDS: float = 0.6

var _staging: DialogueStaging = null
var _rig: Node3D = null
var _key: SpotLight3D = null
var _fill: SpotLight3D = null
var _rim: SpotLight3D = null
## 0 off to 1 full; every light's energy is its own times this.
var _weight: float = 0.0
## World3D instance id -> its sun (DirectionalLight3D), or null for none.
var _suns: Dictionary = {}


func _ready() -> void:
	_staging = get_parent() as DialogueStaging
	_rig = Node3D.new()
	_rig.name = "DialogueLights"
	_key = _light("Key", KEY_COLOR, 1.0)
	_fill = _light("Fill", FILL_COLOR, FILL_SPECULAR)
	_rim = _light("Rim", RIM_COLOR, RIM_SPECULAR)
	_rig.visible = false


func _exit_tree() -> void:
	if is_instance_valid(_rig):
		_rig.queue_free()


func _light(light_name: String, color: Color, specular: float) -> SpotLight3D:
	var light := SpotLight3D.new()
	light.name = light_name
	light.top_level = true
	light.light_color = color
	light.light_specular = specular
	light.shadow_enabled = false
	light.light_size = 0.0
	light.light_cull_mask = 1 << (Unit.RENDER_LAYER - 1)
	light.spot_angle = SPOT_ANGLE
	light.spot_angle_attenuation = SPOT_EDGE
	light.spot_attenuation = 1.0
	light.light_energy = 0.0
	_rig.add_child(light)
	return light


func _process(delta: float) -> void:
	var camera: CinematicCamera = CinematicDirector.camera()
	var speaker: Unit = _staging.speaker() if _staging else null
	var wanted: bool = camera != null and is_instance_valid(speaker) and not CinematicDirector.is_active()
	var seconds: float = FADE_IN_SECONDS if wanted else FADE_OUT_SECONDS
	_weight = move_toward(_weight, 1.0 if wanted else 0.0, delta / seconds)
	if camera and _rig.get_parent() != camera:
		if _rig.get_parent():
			_rig.get_parent().remove_child(_rig)
		camera.add_child(_rig)
	_rig.visible = _weight > 0.0 and _rig.is_inside_tree()
	if not _rig.visible:
		return
	if is_instance_valid(speaker):
		_place(speaker, camera.camera())
	var w: float = smoothstep(0.0, 1.0, _weight)
	_key.light_energy = KEY_ENERGY * w
	_fill.light_energy = FILL_ENERGY * w
	_rim.light_energy = RIM_ENERGY * w


## Puts the three lights around speaker's head as camera sees it.
func _place(speaker: Unit, camera: Camera3D) -> void:
	var stand: StandIn = StandIn.of(speaker)
	var head: Vector3 = stand.anchor(CharacterModel.Anchor.HEAD) if stand else speaker.anchor(CharacterModel.Anchor.HEAD)
	var to_camera: Vector3 = camera.global_position - head
	to_camera.y = 0.0
	if to_camera.length_squared() < 0.0001:
		to_camera = Vector3.BACK
	to_camera = to_camera.normalized()
	var side: float = _key_side(camera, to_camera)
	_aim(_key, head, to_camera.rotated(Vector3.UP, deg_to_rad(KEY_AZIMUTH) * side), KEY_DISTANCE, KEY_HEIGHT)
	_aim(_fill, head, to_camera.rotated(Vector3.UP, -deg_to_rad(FILL_AZIMUTH) * side), FILL_DISTANCE, FILL_HEIGHT)
	_aim(_rim, head, to_camera.rotated(Vector3.UP, -deg_to_rad(RIM_AZIMUTH) * side), RIM_DISTANCE, RIM_HEIGHT)


func _aim(light: SpotLight3D, head: Vector3, direction: Vector3, distance: float, height: float) -> void:
	var at: Vector3 = head + direction * distance + Vector3.UP * height
	light.global_transform = Transform3D(Basis.looking_at(head - at, Vector3.UP), at)
	light.spot_range = at.distance_to(head) + REACH_PAST_HEAD


## +1 to key from the camera's left of the face (turning to_camera
## counter-clockwise seen from above), -1 from its right: whichever side the
## sun shines from. No sun keys from the camera's right.
func _key_side(camera: Node3D, to_camera: Vector3) -> float:
	var sun: DirectionalLight3D = _sun_of(camera)
	if sun == null:
		return -1.0
	var toward_sun: Vector3 = sun.global_basis.z
	toward_sun.y = 0.0
	if toward_sun.length_squared() < 0.0001:
		return -1.0
	var left: Vector3 = to_camera.rotated(Vector3.UP, PI * 0.5)
	return 1.0 if toward_sun.dot(left) >= 0.0 else -1.0


func _sun_of(camera: Node3D) -> DirectionalLight3D:
	var world: World3D = camera.get_world_3d()
	var id: int = world.get_instance_id()
	var known = _suns.get(id)
	if known != null and is_instance_valid(known) and known.is_inside_tree():
		return known
	var found: DirectionalLight3D = null
	for light in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		var sun := light as DirectionalLight3D
		if sun.is_visible_in_tree() and sun.get_world_3d() == world:
			if found == null or sun.light_energy > found.light_energy:
				found = sun
	_suns[id] = found
	return found
