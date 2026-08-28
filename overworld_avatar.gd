class_name OverworldAvatar
extends CharacterBody3D
## The single controllable overworld avatar — deliberately NOT a Unit:
## no nav-grid pathing, no turn budget, nothing that would make
## UnitQuery/SelectionManager pick it up. Direct WASD physics movement,
## relative to whatever the camera's current yaw is (see
## OverworldCamera.get_yaw()) so "forward" always means "away from the
## camera," the same convention any third-person camera-relative
## controller uses.
##
## Reuses the camera_pan_forward/backward/left/right actions (WASD) —
## those exist for crpg_camera.gd's own tactical free-pan, but that
## script only ever lives inside test_arena.tscn, which is freed before
## the overworld loads, so there's no real conflict repurposing the same
## keys here for a completely different job.
##
## The body itself never rotates toward its direction of travel — see
## SpinPivot below, which is a deliberately UNRELATED, always-on spin
## purely for visual interest as a placeholder token. Movement direction
## and the spin are intentionally decoupled: this is not a facing
## indicator.

@export var move_speed: float = 6.0
@export var acceleration: float = 24.0
@export var gravity: float = 18.0
@export var spin_speed_degrees: float = 120.0

## Set by overworld.gd right after instancing — the avatar reads this
## every physics frame to know which way "forward" currently means.
@export var camera: OverworldCamera

@onready var _spin_pivot: Node3D = $SpinPivot


func _physics_process(delta: float) -> void:
	var input_dir := Vector2.ZERO
	if Input.is_action_pressed("camera_pan_forward"):
		input_dir.y -= 1.0
	if Input.is_action_pressed("camera_pan_backward"):
		input_dir.y += 1.0
	if Input.is_action_pressed("camera_pan_left"):
		input_dir.x -= 1.0
	if Input.is_action_pressed("camera_pan_right"):
		input_dir.x += 1.0
	input_dir = input_dir.normalized()

	var yaw: float = camera.get_yaw() if camera else 0.0
	var basis := Basis(Vector3.UP, yaw)
	var direction: Vector3 = basis * Vector3(input_dir.x, 0.0, input_dir.y)
	var target_velocity: Vector3 = direction * move_speed

	velocity.x = move_toward(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, acceleration * delta)

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	move_and_slide()

	# Always-on, independent of movement/facing entirely — see this
	# file's own header.
	_spin_pivot.rotate_y(deg_to_rad(spin_speed_degrees) * delta)
