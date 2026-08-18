class_name UnitFacing
extends RefCounted
## Handles rotating ONE unit to face a direction/point — smoothly
## (following the movement path, tracking an aimed target) or instantly
## (snapping to face a target the moment an attack resolves). Owned by
## that Unit (see Unit._facing), same pattern as StatusManager/
## UnitActionState.
##
## rotation_speed/facing_offset_degrees deliberately stay as plain
## @export vars directly on Unit rather than moving in here — Godot's
## editor reads/writes @export values at design time, before _ready()
## has ever run and before this component even exists; a computed
## property forwarding to a not-yet-created component (the pattern
## move_remaining/has_attacked use, safe for THOSE since they're not
## @export) would crash the Inspector for an @export var. This component
## just reads _owner.rotation_speed/facing_offset_degrees directly when
## it needs them — same composition-over-ownership reasoning
## UnitActionState uses for is_moving()/status_prevents_turn().
##
## Also can't set its own rotation — a RefCounted has no transform at
## all — so every method here writes to _owner.rotation.y directly, the
## one piece of this that fundamentally has to reach back into the
## owning Node3D rather than being fully self-contained.

var _owner: Unit


func _init(owner: Unit) -> void:
	_owner = owner


## Smoothly rotates toward facing `direction` (ground-plane only — Y is
## ignored, since facing is a yaw-only concept for a walking character)
## over `delta` seconds, at _owner.rotation_speed.
func face_direction(direction: Vector3, delta: float) -> void:
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		return
	var target_yaw: float = atan2(-direction.x, -direction.z) + deg_to_rad(_owner.facing_offset_degrees)
	_owner.rotation.y = lerp_angle(_owner.rotation.y, target_yaw, 1.0 - exp(-_owner.rotation_speed * delta))


## Convenience wrapper — faces smoothly toward a world-space point
## instead of a raw direction.
func face_point(point: Vector3, delta: float) -> void:
	face_direction(point - _owner.global_position, delta)


## Instantly snaps to face a direction, no smoothing — used where a
## gradual turn would look wrong, e.g. facing your target the instant an
## attack resolves rather than still turning mid-swing (see
## Unit.use_ability).
func snap_face_direction(direction: Vector3) -> void:
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		return
	_owner.rotation.y = atan2(-direction.x, -direction.z) + deg_to_rad(_owner.facing_offset_degrees)


func snap_face_point(point: Vector3) -> void:
	snap_face_direction(point - _owner.global_position)


## The direction this unit's MODEL actually, visually faces right now —
## NOT -_owner.global_transform.basis.z, Godot's own "forward" for the
## node's transform. Every method above bakes facing_offset_degrees
## into _owner.rotation.y specifically so the visual model ends up
## facing the intended direction despite the model's own forward not
## matching Godot's -Z convention (unit.tscn's real rig needs 180° —
## its forward is its BACK, by this convention) — which means
## basis.z itself is now offset from the true visual direction by that
## same amount, the opposite way. Rotating back by -facing_offset_degrees
## undoes exactly that. Added for dialogue_camera_rig.gd's shot framing,
## which was reading basis.z directly and ending up on the wrong side
## of the model entirely (180° off) — anything else that ever needs
## "which way is this unit's face actually pointing" should call this
## too, not re-derive it.
func visual_forward() -> Vector3:
	var raw_forward: Vector3 = -_owner.global_transform.basis.z
	return raw_forward.rotated(Vector3.UP, -deg_to_rad(_owner.facing_offset_degrees))
