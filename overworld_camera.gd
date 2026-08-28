class_name OverworldCamera
extends Camera3D
## Fixed-pitch follow camera for the overworld — orbits target at a
## constant downward pitch, smoothly following its position, with
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
@export var follow_speed: float = 6.0
@export var rotate_speed_degrees: float = 90.0
@export var min_distance: float = 4.0
@export var max_distance: float = 16.0
@export var zoom_step: float = 2.0

var _yaw: float = 0.0


func _ready() -> void:
	rotation.x = -deg_to_rad(pitch_degrees)
	snap_to_target()


## Jumps straight to the ideal follow position with no smoothing — called
## once by overworld.gd right after target is assigned (this camera's own
## _ready() runs before that assignment, since children ready before
## their parent), so the very first frame doesn't visibly lerp in from
## the origin.
func snap_to_target() -> void:
	if target:
		global_position = _desired_position()


func _process(delta: float) -> void:
	if not target:
		return

	if GameMode.current_mode() != GameMode.Mode.OVERWORLD:
		return

	if Input.is_action_pressed("camera_rotate_left"):
		_yaw += deg_to_rad(rotate_speed_degrees) * delta
	if Input.is_action_pressed("camera_rotate_right"):
		_yaw -= deg_to_rad(rotate_speed_degrees) * delta

	global_position = global_position.lerp(_desired_position(), 1.0 - exp(-follow_speed * delta))
	rotation.y = _yaw


func _unhandled_input(event: InputEvent) -> void:
	if GameMode.current_mode() != GameMode.Mode.OVERWORLD:
		return
	if event.is_action_pressed("camera_zoom_in"):
		distance = clamp(distance - zoom_step, min_distance, max_distance)
	elif event.is_action_pressed("camera_zoom_out"):
		distance = clamp(distance + zoom_step, min_distance, max_distance)


## Read by OverworldAvatar every physics frame so WASD input maps to
## "away from the camera" regardless of how far the player has rotated
## it — see that script's own header.
func get_yaw() -> float:
	return _yaw


func _desired_position() -> Vector3:
	var offset := Vector3(sin(_yaw), 0.0, cos(_yaw)) * distance
	return target.global_position + offset + Vector3.UP * height
