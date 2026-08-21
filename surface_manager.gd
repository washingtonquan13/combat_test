extends Node
## Autoload singleton. Register as "SurfaceManager" under
## Project > Project Settings > AutoLoad, alongside CombatManager/
## AbilityManager/SelectionManager.
##
## Tracks every ActiveSurface currently on the battlefield — the
## world-persistent counterpart to StatusManager (which tracks status
## effects owned by a unit); a surface is instead anchored to a position,
## with no owning unit at all. Three checkpoints:
##  - Area3D.body_entered (built per-surface in spawn(), see
##    _on_body_entered): applies status_effect the INSTANT a unit
##    physically walks into the surface, mid-move — this is what
##    actually punishes a movement decision as it happens, rather than
##    waiting for a turn boundary to notice. Real physics overlap against
##    the unit's own collision shape, so it fires correctly regardless of
##    which direction a unit crosses the boundary from, or whether a
##    surface spawns directly under an already-stationary unit (that
##    counts as an immediate overlap the same way).
##  - CombatManager.turn_started(unit) (see _on_turn_started): re-applies
##    status_effect to whoever's still standing inside at the START of
##    their own turn. Necessary IN ADDITION to body_entered, not instead
##    of it — body_entered only fires once per continuous stay, so
##    without this a unit that just stands in Fire for several turns
##    would have Burning expire on its own normal duration instead of
##    being kept alive by the fire that's still under them.
##  - CombatManager.round_started: age every active surface by one round,
##    expiring (and freeing its ambient visual + detection Area3D)
##    anything that hits zero — rides on the signal CombatManager already
##    emits rather than a separate scheduler of its own.

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

	var area := _build_detection_area(surface, radius, instance)
	context.add_child(area)
	area.global_position = position
	instance.area = area

	if surface.spawn_vfx:
		surface.spawn_vfx.play(context, position, position)
	if surface.spawn_sfx:
		surface.spawn_sfx.play(context, position)

	return instance


## Built purely from radius/detection_height, not from ambient_scene — a
## surface's detection volume is never hand-authored per scene the way
## its visual is; it's automatic from the exact same radius the
## targeting indicator already showed the player. A CylinderShape3D
## rather than a box for the same reason AreaDamageEffect/
## AreaApplyStatusEffect use radial distance: a surface's footprint is a
## circle, not a square.
##
## Does NOT set the area's position — global_position can't be set
## before a Node3D is inside the scene tree (no parent to resolve
## "global" against yet), so the caller (spawn()) adds this to the tree
## first and positions it after. input_ray_pickable is turned off
## explicitly: CollisionObject3D (Area3D's base) defaults that to true,
## which would otherwise make this purely-for-detection area silently
## eligible for Godot's built-in mouse-picking raycast too — intercepting
## clicks meant for the ground StaticBody3D underneath it (see
## ground_click_target.gd) even though nothing here ever listens for
## that. Note this is a SEPARATE system from the manual intersect_ray
## calls indicator_base.gd's own raycasts make for hover previews — those
## default to collide_with_areas = false already, which is why the
## movement PREVIEW line was never affected by this even while real
## clicks were.
func _build_detection_area(surface: Surface, radius: float, instance: ActiveSurface) -> Area3D:
	var area := Area3D.new()
	area.monitorable = false
	area.input_ray_pickable = false

	var shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = radius
	cylinder.height = surface.detection_height
	shape.shape = cylinder
	shape.position = Vector3(0.0, surface.detection_height / 2.0, 0.0)
	area.add_child(shape)

	area.body_entered.connect(_on_body_entered.bind(instance))
	return area


## Fires the instant a unit's own collision shape overlaps the surface's
## detection volume — real shape-vs-shape physics overlap, which is why
## this needs no manual edge-to-edge distance math the way
## _on_turn_started does; the physics engine already accounts for the
## unit's own collision radius correctly. Also fires for a surface
## spawned directly under an already-stationary unit (Godot reports that
## as an immediate overlap, functionally the same as walking in), so
## there's no separate "was already standing here at spawn time" case to
## handle.
func _on_body_entered(body: Node3D, active: ActiveSurface) -> void:
	if not body is Unit or not body.is_alive():
		return
	if not active.surface.status_effect:
		return
	body.apply_status(active.surface.status_effect)


## Read by RoutePlanner.plan (via a Callable passed in by
## UnitMovement.move_to/movement_indicator.gd — see Surface.
## movement_cost_multiplier's doc comment) while planning a route. point
## is a bare sample point along the simulated path, not a unit — no
## edge-to-edge radius adjustment the way _on_turn_started does for an
## actual unit's body. Highest multiplier of any surface currently
## covering point wins if more than one does; difficult terrain doesn't
## stack multiplicatively just because two patches happen to overlap.
## Returns 1.0 (no effect) if nothing covers point.
func movement_cost_multiplier_at(point: Vector3) -> float:
	var multiplier: float = 1.0
	for active in active_surfaces:
		if active.position.distance_to(point) <= active.radius:
			multiplier = max(multiplier, active.surface.movement_cost_multiplier)
	return multiplier


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
	if active.area and is_instance_valid(active.area):
		active.area.queue_free()
