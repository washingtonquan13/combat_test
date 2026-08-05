extends Camera3D
class_name CRPGCamera

## Classic CRPG-style orbit camera (Baldur's Gate 3 / Pillars of Eternity style).
##
## There is exactly one behavior model — orbit an anchor point, zoom toward/
## away from it, auto-pitch downward as you zoom out, rotate with Q/E. Bound
## and unbound modes differ in exactly one respect: where the anchor point
## comes from.
##
##   BOUND (focus_target assigned):
##     anchor = focus_target's position (+ focus_offset), plus a WASD pan
##     offset that's leashed within max_pan_radius of the target.
##
##   UNBOUND (focus_target is null):
##     anchor = a free point in space that WASD moves directly, with no
##     leash — otherwise every control (Q/E, WASD, scroll, auto-pitch,
##     look_at) behaves identically to bound mode.
##
## Controls (identical in both modes) — bound to InputMap actions (see
## project.godot > Input Map, or Project Settings in the editor) rather
## than hardcoded keys/buttons, so rebinding any of these needs no code
## changes:
##   camera_rotate_left / camera_rotate_right (Q / E) — yaw around the anchor
##   camera_pan_forward/backward/left/right (W A S D) — move the anchor
##     (leashed in bound, free in unbound)
##   camera_zoom_in / camera_zoom_out (scroll wheel)  — zoom toward/away
##     from the anchor (clamped to min_distance/max_distance in both modes)
##
## Pitch is never controlled directly — it's always derived from zoom
## distance via min_pitch/max_pitch, in both modes, exactly like bound
## mode always has been.
##
## Because yaw/pitch/distance/anchor are all continuous shared state, gaining
## or losing focus_target at runtime never snaps the camera — unbound simply
## keeps orbiting whatever anchor point bound mode left it at, and vice versa.
##
## global_position eases toward a single desired_position every physics frame
## (the "swagger" lerp) — identical in both modes, since desired_position is
## built from the same distance/pitch/anchor smoothing pipeline either way.
##
## Written for Godot 4.x

enum Mode { BOUND, UNBOUND }

@export_group("Target")
## The node the camera orbits. Leave empty for free-roam (unbound) mode.
@export var focus_target: Node3D
## Offset applied to the focus target's position (e.g. raise anchor above the ground).
## Bound mode only — unbound mode's anchor has no base position to offset.
@export var focus_offset: Vector3 = Vector3(0, 1, 0)
## How quickly the camera's actual position catches up to desired_position.
## This is the main source of the camera's "swagger" — identical in both modes.
@export var follow_smoothing: float = 10.0

@export_group("Rotation (Q/E)")
@export var rotation_speed: float = 90.0
@export var rotation_smoothing: float = 10.0

@export_group("Anchor Movement (WASD)")
## Speed the anchor point moves at when panning (bound) or roaming (unbound).
@export var move_speed: float = 12.0
## How quickly the anchor eases toward its input-driven target position.
@export var move_smoothing: float = 10.0
## Max horizontal distance (XZ plane) the anchor may stray from focus_target.
## Bound mode only — unbound mode's anchor is never leashed.
@export var max_pan_radius: float = 8.0

@export_group("Zoom (Scroll)")
@export var zoom_speed: float = 10.0
@export var zoom_smoothing: float = 8.0
@export var min_distance: float = 5.0
@export var max_distance: float = 25.0

@export_group("Angle (Pitch) — tied to zoom, both modes")
## Downward pitch angle (degrees) when fully zoomed IN (close to the anchor).
@export var min_pitch: float = 30.0
## Downward pitch angle (degrees) when fully zoomed OUT (far from the anchor).
@export var max_pitch: float = 65.0
## Optional curve mapping zoom-in (0) to zoom-out (1) fraction to pitch interpolation.
@export var pitch_curve: Curve

# shared state (kept continuous across both modes so switching never snaps)
var current_yaw: float = 0.0        # degrees
var target_yaw: float = 0.0         # degrees
var current_pitch: float = 0.0      # degrees
var target_pitch: float = 0.0       # degrees
var current_distance: float
var target_distance: float

## Bound mode: offset from focus_target's position, leashed to max_pan_radius.
## Unbound mode: no target to offset from, so this IS the absolute anchor
## position in world space, and is never leashed.
var current_anchor_offset: Vector3 = Vector3.ZERO
var target_anchor_offset: Vector3 = Vector3.ZERO

## Where the camera should be right now, computed from the anchor/distance/
## pitch pipeline each physics frame. global_position eases toward this —
## see _physics_process. That one lerp is where all the "swagger" comes from.
var desired_position: Vector3 = Vector3.ZERO
var _last_anchor_point: Vector3 = Vector3.ZERO   # cached for look_at, applied after the shared position lerp


func _get_mode() -> Mode:
	return Mode.BOUND if focus_target != null else Mode.UNBOUND


func _ready() -> void:
	target_distance = clamp((min_distance + max_distance) * 0.5, min_distance, max_distance)
	current_distance = target_distance
	target_pitch = _calculate_pitch_for_distance(current_distance)
	current_pitch = target_pitch

	if focus_target:
		var dir: Vector3 = global_position - (focus_target.global_position + focus_offset)
		target_yaw = rad_to_deg(atan2(dir.x, dir.z))
	else:
		target_yaw = rotation_degrees.y
		# No target to anchor to: place the initial anchor out in front of
		# wherever the camera starts, so it doesn't snap on the first frame.
		var yaw_rad: float = deg_to_rad(target_yaw)
		var pitch_rad: float = deg_to_rad(target_pitch)
		var forward: Vector3 = Vector3(
			-sin(yaw_rad) * cos(pitch_rad),
			-sin(pitch_rad),
			-cos(yaw_rad) * cos(pitch_rad)
		)
		target_anchor_offset = global_position + forward * current_distance

	current_yaw = target_yaw
	current_anchor_offset = target_anchor_offset
	desired_position = global_position


func _unhandled_input(event: InputEvent) -> void:
	var scroll_up: bool = event.is_action_pressed("camera_zoom_in")
	var scroll_down: bool = event.is_action_pressed("camera_zoom_out")
	if not (scroll_up or scroll_down):
		return

	# Identical in both modes: zoom toward/away from the anchor, clamped.
	var step: float = zoom_speed * 0.1
	target_distance += (-step if scroll_up else step)
	target_distance = clamp(target_distance, min_distance, max_distance)


func _process(delta: float) -> void:
	_handle_rotation_input(delta)
	_handle_anchor_movement_input(delta)


func _physics_process(delta: float) -> void:
	# Yaw uses angle-aware lerping done correctly in radians (lerp_angle expects
	# radians; feeding it raw degrees causes rapid, incorrect wraparound).
	var yaw_rad: float = lerp_angle(deg_to_rad(current_yaw), deg_to_rad(target_yaw), 1.0 - exp(-rotation_smoothing * delta))
	current_yaw = rad_to_deg(yaw_rad)

	current_distance = lerp(current_distance, target_distance, 1.0 - exp(-zoom_smoothing * delta))

	target_pitch = _calculate_pitch_for_distance(current_distance)
	current_pitch = lerp(current_pitch, target_pitch, 1.0 - exp(-zoom_smoothing * delta))

	current_anchor_offset = current_anchor_offset.lerp(target_anchor_offset, 1.0 - exp(-move_smoothing * delta))

	var anchor_point: Vector3 = _get_anchor_point()
	_last_anchor_point = anchor_point

	var pitch_rad: float = deg_to_rad(current_pitch)
	# Matches Godot's real forward convention (-Z at yaw 0, pitch 0).
	var forward: Vector3 = Vector3(
		-sin(yaw_rad) * cos(pitch_rad),
		-sin(pitch_rad),
		-cos(yaw_rad) * cos(pitch_rad)
	)

	desired_position = anchor_point - (forward * current_distance)

	# Shared "swagger" step — identical lerp for both modes.
	global_position = global_position.lerp(desired_position, 1.0 - exp(-follow_smoothing * delta))

	look_at(anchor_point, Vector3.UP)


## Bound mode: anchor = focus_target + offset + leashed pan offset.
## Unbound mode: anchor = the pan offset itself, since there's no target.
func _get_anchor_point() -> Vector3:
	if focus_target:
		return focus_target.global_position + focus_offset + current_anchor_offset
	return current_anchor_offset


func _handle_rotation_input(delta: float) -> void:
	# Note: in Godot, increasing rotation_degrees.y turns the camera
	# counterclockwise (left) when viewed from above — the opposite of the
	# usual "E turns right" expectation. Q therefore increases yaw (turn
	# left) and E decreases it (turn right) to match that expectation.
	if Input.is_action_pressed("camera_rotate_left"):
		target_yaw += rotation_speed * delta
	if Input.is_action_pressed("camera_rotate_right"):
		target_yaw -= rotation_speed * delta


## Moves the anchor point with WASD, relative to the camera's current facing,
## flattened to the ground plane (yaw only — ignoring pitch keeps panning
## level instead of diving with the camera's tilt). In bound mode the result
## is leashed to max_pan_radius around focus_target; in unbound mode it's
## free, since target_anchor_offset IS the absolute anchor position there.
func _handle_anchor_movement_input(delta: float) -> void:
	var input_dir: Vector2 = _get_wasd_input()
	if input_dir == Vector2.ZERO:
		return

	var facing: Array = _get_flat_facing(current_yaw)
	var forward: Vector3 = facing[0]
	var right: Vector3 = facing[1]

	var move: Vector3 = (right * input_dir.x + forward * -input_dir.y) * move_speed * delta
	target_anchor_offset += move

	if _get_mode() == Mode.BOUND and target_anchor_offset.length() > max_pan_radius:
		target_anchor_offset = target_anchor_offset.normalized() * max_pan_radius


## Ground-plane forward/right for a given yaw, ignoring pitch. Signs match
## Godot's actual camera basis at pitch 0 (forward = -Z, right = +X).
func _get_flat_facing(yaw_deg: float) -> Array:
	var yaw_rad: float = deg_to_rad(yaw_deg)
	var forward: Vector3 = Vector3(-sin(yaw_rad), 0.0, -cos(yaw_rad))
	var right: Vector3 = Vector3(cos(yaw_rad), 0.0, -sin(yaw_rad))
	return [forward, right]


func _get_wasd_input() -> Vector2:
	var input_dir: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("camera_pan_forward"):
		input_dir.y -= 1.0
	if Input.is_action_pressed("camera_pan_backward"):
		input_dir.y += 1.0
	if Input.is_action_pressed("camera_pan_left"):
		input_dir.x -= 1.0
	if Input.is_action_pressed("camera_pan_right"):
		input_dir.x += 1.0
	return input_dir.normalized() if input_dir.length() > 0.0 else input_dir


## Maps the current zoom distance to a downward pitch angle. Used in both modes.
func _calculate_pitch_for_distance(distance: float) -> float:
	var t: float = inverse_lerp(min_distance, max_distance, distance)
	t = clamp(t, 0.0, 1.0)
	var curved: float = t
	if pitch_curve:
		curved = pitch_curve.sample(t)
	return lerp(min_pitch, max_pitch, curved)
