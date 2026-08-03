extends Node3D
## Smoothly rotates the current turn's player-controlled unit to face
## wherever they're currently aiming, while ANY ability is armed —
## melee, ranged, area, or ground-point/jump, all of them, since facing
## your intended direction is useful regardless of ability shape. Purely
## cosmetic — doesn't affect targeting/range/LoS logic at all, which is
## entirely unconcerned with which way the character model happens to
## be facing.
##
## Only checks AbilityManager.armed_ability directly, no fallback to the
## acting unit's default_ability() — same deliberate choice as
## line_of_sight_indicator.gd: this only activates once something is
## explicitly armed via the hotbar, not on every ordinary click-to-
## attack.
##
## Mirrors the OTHER indicator scripts' hover-detection pattern (raycast
## against units first, fall back to ground) as its own independent
## copy rather than sharing their logic directly — kept separate so it
## can't risk disrupting the already-working indicators.
##
## Scene setup: attach to a plain Node anywhere in your main scene — no
## visuals of its own, so nothing to build in code the way the other
## indicators do.

@export var unit_collision_mask: int = 1
@export var ground_collision_mask: int = 1


func _process(delta: float) -> void:
	var unit := _get_active_unit()
	if not unit:
		return

	var aim_point = _get_aim_point()
	if aim_point == null:
		return

	unit.face_point(aim_point, delta)


## Only the acting unit, only if player-controlled, only if something's
## explicitly armed, only if not already mid-move — movement-follow-path
## rotation (see Unit._physics_process) already owns facing while
## walking, and both trying to set rotation.y in the same frame would
## just fight each other.
func _get_active_unit() -> Unit:
	if not CombatManager.in_combat:
		return null

	var unit: Unit = CombatManager.current_unit
	if not unit or not is_instance_valid(unit) or not unit.is_alive():
		return null
	if not unit.is_player_controlled():
		return null
	if unit.is_moving():
		return null
	if not AbilityManager.armed_ability:
		return null

	return unit


func _get_aim_point():
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 1000.0

	var space_state := get_world_3d().direct_space_state

	var unit_query := PhysicsRayQueryParameters3D.create(from, to)
	unit_query.collision_mask = unit_collision_mask
	var unit_result := space_state.intersect_ray(unit_query)
	if not unit_result.is_empty():
		var hovered := unit_result.get("collider") as Unit
		if hovered:
			return hovered.global_position

	var ground_query := PhysicsRayQueryParameters3D.create(from, to)
	ground_query.collision_mask = ground_collision_mask
	var ground_result := space_state.intersect_ray(ground_query)
	if ground_result.is_empty():
		return null
	return ground_result.position
