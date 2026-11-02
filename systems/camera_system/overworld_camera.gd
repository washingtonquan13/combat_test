class_name OverworldCamera
extends Camera3D
## Fixed-pitch follow camera for the overworld — orbits target at a
## constant downward pitch, locked to its position, with
## player-driven yaw rotation and zoom. Satisfies WorldManager's
## duck-typed get_tactical_camera() contract exactly like crpg_camera.gd
## does for test_arena.tscn, so CameraDirector registration is unchanged.
##
## Deliberately NOT crpg_camera.gd reused in a new mode: that script is
## 600+ lines tuned specifically for tactical play (leash radius,
## height-lift, a zoom-to-pitch curve, shapecast collision) and polls the
## SAME camera_pan_* actions for its own free-roam pan. No runtime
## conflict exists either way — crpg_camera only ever lives inside
## test_arena.tscn, which is freed before this loads — but a small
## dedicated script is simpler to reason about and doesn't risk the
## combat camera for an unrelated job.

@export var target: Node3D
@export var height: float = 12.0
@export var distance: float = 8.0
@export var pitch_degrees: float = 55.0
@export var rotate_speed_degrees: float = 90.0
@export var min_distance: float = 4.0
@export var max_distance: float = 16.0
@export var zoom_step: float = 2.0

@export_group("Tactical view")
## BG3's tactical view: camera_tactical swings the camera up to look
## nearly straight down from far above, for reading the map, and back.
## Still locked to the avatar, so walking works the same in it.
@export var tactical_pitch_degrees: float = 80.0
## Metres from the camera to the avatar along the view.
@export var tactical_range: float = 900.0
@export var tactical_min_range: float = 400.0
@export var tactical_max_range: float = 2400.0
## Each zoom step multiplies or divides the range by this.
@export var tactical_zoom_factor: float = 1.25
## Seconds the swing up or down takes.
@export var tactical_blend_time: float = 0.45

var _yaw: float = 0.0
## height per unit of distance, from the authored pair, so zooming moves
## along the line of sight and the target stays where the pitch puts it.
var _height_per_distance: float = 1.5
var _tactical := false
## 0 in the follow view, 1 in the tactical view, between while swinging.
var _blend := 0.0
var _base_far: float


func _ready() -> void:
	rotation.x = -deg_to_rad(pitch_degrees)
	_height_per_distance = height / distance
	_base_far = far
	snap_to_target()


## Jumps straight to the ideal follow position with no smoothing — called
## once by overworld.gd right after target is assigned (this camera's own
## _ready() runs before that assignment, since children ready before
## their parent), so the very first frame doesn't visibly lerp in from
## the origin.
func snap_to_target() -> void:
	if target:
		global_position = _desired_position()


## Locked to the target with no easing: a camera that trails and then
## drifts in after the avatar stops reads as the avatar itself building up
## and bleeding off speed, which the overworld walk deliberately does not
## do (see OverworldAvatar.move_speed). Run on the physics tick because the
## avatar moves on it; following per render frame would judder against a
## body that only moves 60 times a second.
func _physics_process(delta: float) -> void:
	if not target:
		return

	if GameMode.current_mode() != GameMode.Mode.OVERWORLD:
		return

	# A blocking screen (the party sheet) has Q/E for itself.
	if UIStack.can_open():
		if Input.is_action_pressed("camera_rotate_left"):
			_yaw += deg_to_rad(rotate_speed_degrees) * delta
		if Input.is_action_pressed("camera_rotate_right"):
			_yaw -= deg_to_rad(rotate_speed_degrees) * delta
	_blend = move_toward(_blend, 1.0 if _tactical else 0.0, delta / maxf(tactical_blend_time, 0.001))

	global_position = _desired_position()
	rotation.x = -lerpf(deg_to_rad(pitch_degrees), deg_to_rad(tactical_pitch_degrees), _eased())
	rotation.y = _yaw
	# Far enough to reach the ground at the top of a view from high up.
	far = _base_far * view_scale()


func _unhandled_input(event: InputEvent) -> void:
	if GameMode.current_mode() != GameMode.Mode.OVERWORLD:
		return
	if event.is_action_pressed("camera_tactical"):
		_tactical = not _tactical
	elif _tactical and event.is_action_pressed("camera_zoom_in"):
		tactical_range = clampf(tactical_range / tactical_zoom_factor, tactical_min_range, tactical_max_range)
	elif _tactical and event.is_action_pressed("camera_zoom_out"):
		tactical_range = clampf(tactical_range * tactical_zoom_factor, tactical_min_range, tactical_max_range)
	elif event.is_action_pressed("camera_zoom_in"):
		distance = clamp(distance - zoom_step, min_distance, max_distance)
		height = distance * _height_per_distance
	elif event.is_action_pressed("camera_zoom_out"):
		distance = clamp(distance + zoom_step, min_distance, max_distance)
		height = distance * _height_per_distance
	else:
		return
	get_viewport().set_input_as_handled()


## Read by OverworldAvatar every physics frame so WASD input maps to
## "away from the camera" regardless of how far the player has rotated
## it — see that script's own header.
func get_yaw() -> float:
	return _yaw


func is_tactical() -> bool:
	return _tactical


## How many times farther from the avatar the camera is than in the
## follow view at its current zoom: 1 there, rising through the swing
## into the tactical view. The overworld scales what is sized for the
## follow view by it (the distance haze, sun shadows, the avatar's icon).
func view_scale() -> float:
	return exp(lerpf(0.0, log(tactical_range / Vector2(distance, height).length()), _eased()))


## 0 in the follow view, 1 in the tactical view, eased through the swing.
func tactical_blend() -> float:
	return _eased()


func _eased() -> float:
	return smoothstep(0.0, 1.0, _blend)


## Swung between the follow view's own offset and the tactical one in
## elevation and (geometrically) in range, so the start and end are each
## exactly as authored.
func _desired_position() -> Vector3:
	var s := _eased()
	var elevation := lerpf(atan2(height, distance), deg_to_rad(tactical_pitch_degrees), s)
	var reach := Vector2(distance, height).length() * view_scale()
	var offset := Vector3(sin(_yaw), 0.0, cos(_yaw)) * reach * cos(elevation)
	return target.global_position + offset + Vector3.UP * reach * sin(elevation)
