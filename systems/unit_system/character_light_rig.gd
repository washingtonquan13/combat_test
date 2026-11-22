class_name CharacterLightRig
extends Node3D
## One character's own three-point lighting, after Larian's gameplay rigs in Baldur's Gate 3: a key, a fill
## and a rim that travel with the character, on top of the world's light.
##
## UNITS ONLY. The three spots reach Unit.RENDER_LAYER alone, and only that
## layer casts into their shadow maps, so the level neither receives the
## light nor pays to be drawn into its shadows. Every light casts a shadow:
## without one a rim bleeds round onto the face and the inside of a mouth
## lights up.
##
## ONE CHARACTER ONLY, on the patched engine (godot_patches/): the rig takes
## a light group of its own and gives it to its lights and to the host's
## meshes, and a grouped light lights and takes shadows from its own group
## alone. Stock Godot has no light groups; there the rig still works, but
## only reach keeps it off a neighbour: each spot ends a little past the
## character it is aimed at.
##
## Owned by the Unit it is a child of (Unit.light_as_body builds it and hands
## it the body and every held or carried item). It follows the unit's
## position and turns with the current camera's yaw, so the lit side faces
## the lens. It is sized to the unit: the constants below are for a body 2 m
## tall and scale with Unit.height and Unit.radius.
##
## EVERY CAMERA. The same rig lights the character in play, in a
## conversation and in a cutscene; whichever camera is on screen is the one
## it turns to. While a copy of the body is shown somewhere else (a StandIn,
## a CutsceneRole's body) the rig goes with the copy: whoever raises the
## copy says so through Unit.light_follows. A copy is a duplicate of the
## body, so its meshes already carry the rig's light group.

## A body this tall and this wide is lit at the sizes below.
const FIT_HEIGHT: float = 2.0
const FIT_RADIUS: float = 0.5
## Where the spots aim, above the character's feet.
const AIM_HEIGHT: float = 1.25
## How far each spot stands from the aim point.
const DISTANCE: float = 3.5
## How far past the aim point a spot still reaches.
const REACH_PAST: float = 1.2
const SPOT_ANGLE: float = 20.0

## Azimuth (degrees round the character, 0 = toward the camera, positive =
## camera's right) and elevation of each light.
const KEY_PLACE := Vector2(-40.0, 35.0)
const FILL_PLACE := Vector2(50.0, 10.0)
const RIM_PLACE := Vector2(155.0, 40.0)

@export var key_energy: float = 1.0
@export var fill_energy: float = 0.35
@export var rim_energy: float = 1.6
@export var key_color := Color(1.0, 0.96, 0.9)
@export var fill_color := Color(0.85, 0.9, 1.0)
@export var rim_color := Color(1.0, 0.97, 0.92)
@export var shadows: bool = true

## The copy of the host shown on screen in its place, when there is one; the
## rig stands on it until it is freed. Set through Unit.light_follows.
var shown_as: Node3D = null

static var _next_group: int = 1

var _host: Node3D = null
## This rig's light group; 0 on an engine without light groups.
var _group: int = 0
## [SpotLight3D, its KEY/FILL/RIM place].
var _lights: Array = []
## The size the lights are placed for now; 0 before the first fit.
var _fitted: float = 0.0


# In _init, not _ready: a unit hands over its body (adopt) while it is still
# entering the tree, before this node's _ready has run.
func _init() -> void:
	if ClassDB.class_has_method(&"Light3D", &"set_light_group"):
		_group = _next_group
		_next_group += 1


func _ready() -> void:
	_host = get_parent() as Node3D
	top_level = true
	_light("Key", key_color, key_energy, KEY_PLACE)
	_light("Fill", fill_color, fill_energy, FILL_PLACE)
	_light("Rim", rim_color, rim_energy, RIM_PLACE)
	_follow()


func _light(light_name: String, color: Color, energy: float, place: Vector2) -> void:
	var light := SpotLight3D.new()
	light.name = light_name
	light.light_color = color
	light.light_energy = energy
	light.spot_angle = SPOT_ANGLE
	light.spot_angle_attenuation = 0.6
	# No fall-off with distance inside the reach: the spot stands off the
	# character only so its cone covers the body.
	light.spot_attenuation = 0.0
	light.light_cull_mask = 1 << (Unit.RENDER_LAYER - 1)
	light.shadow_enabled = shadows
	light.shadow_caster_mask = 1 << (Unit.RENDER_LAYER - 1)
	light.shadow_bias = 0.03
	light.shadow_normal_bias = 1.0
	light.shadow_blur = 1.0
	if _group != 0:
		light.set(&"light_group", _group)
	# The rig is for the character, not the air round them.
	light.light_volumetric_fog_energy = 0.0
	add_child(light)
	_lights.append([light, place])


## Makes everything visible under node part of what this rig lights. For the
## body, and for anything the unit comes to hold or wear afterwards.
func adopt(node: Node) -> void:
	if _group == 0:
		return
	var parts: Array[Node] = node.find_children("*", "GeometryInstance3D", true, false)
	if node is GeometryInstance3D:
		parts.append(node)
	for part in parts:
		part.set(&"light_group", _group)


## Places the spots for a body `size` times the one the constants describe.
func _fit(size: float) -> void:
	_fitted = size
	for entry in _lights:
		var light: SpotLight3D = entry[0]
		var place: Vector2 = entry[1]
		var azimuth := deg_to_rad(place.x)
		var elevation := deg_to_rad(place.y)
		var offset := Vector3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation)) * DISTANCE * size
		light.spot_range = (DISTANCE + REACH_PAST) * size
		light.position = Vector3(0.0, AIM_HEIGHT * size, 0.0) + offset
		light.basis = Basis.looking_at(-offset.normalized())


func _process(_delta: float) -> void:
	_follow()


func _follow() -> void:
	if _host == null:
		return
	var camera := get_viewport().get_camera_3d()
	visible = camera != null
	if not visible:
		return
	var size := 1.0
	if _host is Unit:
		var unit := _host as Unit
		size = maxf(unit.height / FIT_HEIGHT, unit.radius / FIT_RADIUS)
	if not is_equal_approx(size, _fitted):
		_fit(size)
	var yaw := camera.global_rotation.y
	var seen: Node3D = shown_as if is_instance_valid(shown_as) and shown_as.is_inside_tree() else _host
	global_transform = Transform3D(Basis(Vector3.UP, yaw), seen.global_position)
