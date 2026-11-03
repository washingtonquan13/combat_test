extends Node
## Autoload singleton. Register as "SurfaceManager" under
## Project > Project Settings > AutoLoad, alongside CombatManager/
## AbilityManager/SelectionManager.
##
## Tracks every ActiveSurface — a flat surface (Grease) or a cloud (Fog)
## — currently in any loaded world: the world-persistent counterpart to
## StatusManager (which tracks status effects owned by a unit); a surface
## is instead anchored to a position, with no owning unit at all.
##
## EVERY ONE BELONGS TO A WORLD. spawn() files it into the caster's
## WorldContext and parents it under that world, and every reader below
## asks the context of the unit or point it is about — never the focused
## world, which is only the one on screen. Checkpoints:
##  - Area3D.body_entered (built per-surface in spawn(), see
##    _on_body_entered): applies status_effect the INSTANT a unit
##    physically walks into it, mid-move — this is what actually
##    punishes a movement decision as it happens. Real physics overlap
##    against the unit's own collision shape, so it fires correctly from
##    any direction, and for a surface spawned directly on top of a
##    stationary unit.
##  - Area3D.body_exited: takes a status_only_inside status (Blinded)
##    back off, unless another such surface still holds the unit.
##  - CombatManager.turn_started(unit): re-applies status_effect to
##    whoever's still inside at the START of their own turn — body_entered
##    fires once per stay, so without this Burning would run out under a
##    unit standing in the fire.
##  - Rounds (see _on_round_started_in / _on_quiet_round): one clock per
##    world. While a fight runs there, its rounds age the world's
##    surfaces; with none running, a round is ROUND_SECONDS of real time
##    (BG3's rule), so a surface cast outside combat still runs out.
##    Combat ending does NOT clear them — they finish their time.

## One round outside combat, in seconds. BG3's turn.
const ROUND_SECONDS: float = 6.0

## The focused world's surfaces — what's on screen. Kept for readers that
## really mean that (the world-scoping suite); everything here goes
## through _list_for() with the world it is actually about.
var active_surfaces: Array[ActiveSurface]:
	get:
		return _list_for(WorldManager.context())

## Surfaces cast with no world loaded (the main menu, headless tests).
var _detached_surfaces: Array[ActiveSurface] = []


func _ready() -> void:
	CombatManager.round_started_in.connect(_on_round_started_in)
	CombatManager.turn_started.connect(_on_turn_started)
	var clock := Timer.new()
	clock.wait_time = ROUND_SECONDS
	clock.autostart = true
	clock.timeout.connect(_on_quiet_round)
	add_child(clock)


## Called by SpawnSurfaceEffect.apply() — see that file. radius is passed
## in rather than read here (same "targeting owns radius" source of truth
## AreaDamageEffect/AreaApplyStatusEffect already follow). caster decides
## the world; null means the focused one.
func spawn(surface: Surface, position: Vector3, radius: float, caster: Node = null) -> ActiveSurface:
	var context: WorldContext = WorldManager.context_for(caster) if caster else WorldManager.context()
	var instance := ActiveSurface.new(surface, position, radius, surface.duration_rounds)
	instance.context = context
	_list_for(context).append(instance)

	# The caster's world; failing that, wherever the caster stands (a bare
	# test scene has no world and no scene root).
	var parent: Node = WorldManager.spawn_parent()
	if context and is_instance_valid(context.world_root):
		parent = context.world_root
	elif parent == null and caster and caster.is_inside_tree():
		parent = caster.get_parent()

	if surface.ambient_scene:
		var visual := surface.ambient_scene.instantiate()
		parent.add_child(visual)
		if visual is Node3D:
			visual.global_position = position
			if surface.scale_ambient_to_radius:
				var factor: float = radius / max(surface.authored_radius, 0.001)
				if surface.shape == Surface.Shape.SPHERE:
					visual.scale = Vector3.ONE * factor
				else:
					visual.scale = Vector3(factor, 1.0, factor)
		instance.visual_node = visual

	var area := _build_detection_area(surface, radius, instance)
	parent.add_child(area)
	area.global_position = position
	instance.area = area

	if surface.spawn_vfx:
		surface.spawn_vfx.play(parent, position, position)
	if surface.spawn_sfx:
		surface.spawn_sfx.play(parent, position)

	return instance


## Built purely from the shape and radius, not from ambient_scene — the
## detection volume is automatic from the exact same radius the
## targeting indicator already showed the player. A disc is a
## detection_height cylinder standing on the point; a sphere is centered
## on it.
##
## Does NOT set the area's position — global_position can't be set
## before a Node3D is inside the scene tree, so spawn() adds this first
## and positions it after. input_ray_pickable is turned off explicitly:
## CollisionObject3D defaults it to true, which would make this
## detection-only area intercept clicks meant for the ground underneath
## it (see ground_click_target.gd).
func _build_detection_area(surface: Surface, radius: float, instance: ActiveSurface) -> Area3D:
	var area := Area3D.new()
	area.monitorable = false
	area.input_ray_pickable = false

	var shape := CollisionShape3D.new()
	if surface.shape == Surface.Shape.SPHERE:
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		shape.shape = sphere
	else:
		var cylinder := CylinderShape3D.new()
		cylinder.radius = radius
		cylinder.height = surface.detection_height
		shape.shape = cylinder
		shape.position = Vector3(0.0, surface.detection_height / 2.0, 0.0)
	area.add_child(shape)

	area.body_entered.connect(_on_body_entered.bind(instance))
	area.body_exited.connect(_on_body_exited.bind(instance))
	return area


## Fires the instant a unit's own collision shape overlaps the surface's
## detection volume — including a surface spawned directly on top of a
## stationary unit, which Godot reports as an immediate overlap.
func _on_body_entered(body: Node3D, active: ActiveSurface) -> void:
	if not body is Unit or not body.is_alive():
		return
	if not active.surface.status_effect:
		return
	body.inflict_status(active.surface.status_effect, null)


func _on_body_exited(body: Node3D, active: ActiveSurface) -> void:
	if body is Unit and is_instance_valid(body):
		_release(body, active)


## Takes active's inside-only status off unit, unless another surface in
## its world that gives the same status still has them inside.
func _release(unit: Unit, active: ActiveSurface) -> void:
	var effect: StatusEffect = active.surface.status_effect
	if not effect or not active.surface.status_only_inside:
		return
	for other in _list_for(active.context):
		if other != active and other.surface.status_effect == effect and _contains(other, unit):
			return
	unit.remove_status(effect)


## Whether unit's body is inside active. A disc reads the old edge-to-edge
## distance from its center; a sphere, the nearest point of the unit's
## upright body (feet to eyes) — a cloud hanging at head height covers a
## unit whose feet are well below it.
func _contains(active: ActiveSurface, unit: Unit) -> bool:
	if active.surface.shape == Surface.Shape.SPHERE:
		var feet: Vector3 = unit.global_position
		var nearest: Vector3 = Geometry3D.get_closest_point_to_segment(active.position, feet, unit.anchor(CharacterModel.Anchor.EYE))
		return nearest.distance_to(active.position) - unit.radius <= active.radius
	return active.position.distance_to(unit.global_position) - unit.radius <= active.radius


## Whether a sight line from `from` to `to` passes through a sight-
## blocking surface in viewer's world. Starting or ending inside counts:
## that is BG3's "blocks ranged attacks in, out and across". Read by
## LineOfSight after its wall raycast.
func blocks_sight(viewer: Node, from: Vector3, to: Vector3) -> bool:
	for active in _list_for(WorldManager.context_for(viewer)):
		if not active.surface.blocks_sight:
			continue
		var nearest: Vector3 = Geometry3D.get_closest_point_to_segment(active.position, from, to)
		if nearest.distance_to(active.position) <= active.radius:
			return true
	return false


## The terrain-cost sampler for a route planned by mover — RoutePlanner.
## plan's cost_sampler, reading only the surfaces in mover's own world.
func cost_sampler(mover: Node) -> Callable:
	return movement_cost_multiplier_at.bind(WorldManager.context_for(mover))


## point is a bare sample point along a simulated path, not a unit. Highest
## multiplier of any surface covering it wins; overlapping patches don't
## stack. 1.0 (no effect) if nothing covers it. Call through
## cost_sampler(), which supplies the context.
func movement_cost_multiplier_at(point: Vector3, context: WorldContext) -> float:
	var multiplier: float = 1.0
	for active in _list_for(context):
		if active.position.distance_to(point) <= active.radius:
			multiplier = max(multiplier, active.surface.movement_cost_multiplier)
	return multiplier


## A round of a fight ages the surfaces of the fight's own world — but
## only from that world's clock, its oldest running fight, so two fights
## side by side don't burn a Grease patch twice as fast.
func _on_round_started_in(encounter: Encounter, _round_number: int) -> void:
	var context: WorldContext = _context_of(encounter)
	var fights: Array[Encounter] = context.encounters if context else CombatManager.encounters
	for fight in fights:
		if is_instance_valid(fight) and fight.is_running:
			if fight == encounter:
				_age(_list_for(context))
			return


## A world with no fight running ages by real time instead.
func _on_quiet_round() -> void:
	for context in WorldManager.all_contexts():
		if not _fighting(context.encounters):
			_age(context.surfaces)
	if WorldManager.context() == null and not _fighting(CombatManager.encounters):
		_age(_detached_surfaces)


func _age(surfaces: Array[ActiveSurface]) -> void:
	for active in surfaces.duplicate():
		if active.rounds_remaining < 0:
			continue  # permanent surface — never ages out this way
		active.rounds_remaining -= 1
		if active.rounds_remaining <= 0:
			_expire(active)


func _on_turn_started(unit: Unit) -> void:
	if not unit.is_alive():
		return
	for active in _list_for(WorldManager.context_for(unit)):
		if active.surface.status_effect and _contains(active, unit):
			unit.inflict_status(active.surface.status_effect, null)


func _expire(active: ActiveSurface) -> void:
	var inside: Array[Node3D] = []
	if active.area and is_instance_valid(active.area) and active.area.is_inside_tree():
		inside = active.area.get_overlapping_bodies()
	_list_for(active.context).erase(active)
	for body in inside:
		if body is Unit:
			_release(body, active)

	var parent: Node = active.area.get_parent() if active.area and is_instance_valid(active.area) else WorldManager.spawn_parent()
	if active.surface.expire_vfx:
		active.surface.expire_vfx.play(parent, active.position, active.position)
	if active.surface.expire_sfx:
		active.surface.expire_sfx.play(parent, active.position)

	# A visual with its own way out (fog thinning away) frees itself.
	if active.visual_node and is_instance_valid(active.visual_node):
		if active.visual_node.has_method("dissipate"):
			active.visual_node.dissipate()
		else:
			active.visual_node.queue_free()
	if active.area and is_instance_valid(active.area):
		active.area.queue_free()


## context's own list; the detached one for no world.
func _list_for(context: WorldContext) -> Array[ActiveSurface]:
	return context.surfaces if context else _detached_surfaces


func _context_of(encounter: Encounter) -> WorldContext:
	for context in WorldManager.all_contexts():
		if context.encounters.has(encounter):
			return context
	return null


func _fighting(encounters: Array[Encounter]) -> bool:
	for fight in encounters:
		if is_instance_valid(fight) and fight.is_running:
			return true
	return false
