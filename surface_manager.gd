extends Node
## Autoload singleton. Register as "SurfaceManager" under
## Project > Project Settings > AutoLoad, alongside CombatManager/
## AbilityManager/SelectionManager.
##
## Tracks every ActiveSurface currently on the battlefield — the
## world-persistent counterpart to StatusManager (which tracks status
## effects owned by a unit); a surface is instead anchored to a position,
## with no owning unit at all. Two checkpoints, both riding on signals
## CombatManager already emits rather than a separate scheduler of its
## own:
##  - CombatManager.round_started: age every active surface by one round,
##    expiring (and freeing its ambient visual) anything that hits zero.
##  - CombatManager.turn_started(unit): check whether the unit whose turn
##    is starting is standing inside any still-active surface, and if so
##    apply that surface's status_effect — same edge-to-edge distance
##    convention AreaDamageEffect/AreaApplyStatusEffect already use.

var active_surfaces: Array[ActiveSurface] = []


func _ready() -> void:
	CombatManager.round_started.connect(_on_round_started)
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)


## Called by SpawnSurfaceEffect.apply() — see that file. radius is passed
## in rather than read here (same "targeting owns radius" source of truth
## AreaDamageEffect/AreaApplyStatusEffect already follow).
func spawn(surface: Surface, position: Vector3, radius: float) -> ActiveSurface:
	var instance := ActiveSurface.new(surface, position, radius, surface.duration_rounds)
	active_surfaces.append(instance)

	var context: Node = get_tree().current_scene

	if surface.ambient_scene:
		var visual := surface.ambient_scene.instantiate()
		context.add_child(visual)
		if visual is Node3D:
			visual.global_position = position
			if surface.scale_ambient_to_radius:
				var factor: float = radius / max(surface.authored_radius, 0.001)
				visual.scale = Vector3(factor, 1.0, factor)
		instance.visual_node = visual

	if surface.spawn_vfx:
		surface.spawn_vfx.play(context, position, position)
	if surface.spawn_sfx:
		surface.spawn_sfx.play(context, position)

	return instance


func _on_round_started(_round_number: int) -> void:
	for active in active_surfaces.duplicate():
		if active.rounds_remaining < 0:
			continue  # permanent surface — never ages out this way
		active.rounds_remaining -= 1
		if active.rounds_remaining <= 0:
			_expire(active)


func _on_turn_started(unit: Unit) -> void:
	if not unit.is_alive():
		return
	for active in active_surfaces:
		if not active.surface.status_effect:
			continue
		var edge_dist: float = active.position.distance_to(unit.global_position) - unit.radius
		if edge_dist <= active.radius:
			unit.apply_status(active.surface.status_effect)


## Combat ending doesn't leave battlefield hazards lingering into
## whatever comes next — every active surface is cleared out along with
## it, same as CombatManager already clearing turn_order.
func _on_combat_ended(_winning_faction: StringName) -> void:
	for active in active_surfaces.duplicate():
		_expire(active)


func _expire(active: ActiveSurface) -> void:
	active_surfaces.erase(active)

	var context: Node = get_tree().current_scene
	if active.surface.expire_vfx:
		active.surface.expire_vfx.play(context, active.position, active.position)
	if active.surface.expire_sfx:
		active.surface.expire_sfx.play(context, active.position)

	if active.visual_node and is_instance_valid(active.visual_node):
		active.visual_node.queue_free()
