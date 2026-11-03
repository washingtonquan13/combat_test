extends Node
## Autoload singleton. Register as "SurfaceManager" under
## Project > Project Settings > AutoLoad, alongside CombatManager/
## AbilityManager/SelectionManager.
##
## Tracks every surface currently in any loaded world — ground surfaces
## (Grease) as cells of the world's SurfaceGrid, clouds (Fog) as
## ActiveSurface spheres: the world-persistent counterpart to
## StatusManager (which tracks status effects owned by a unit); a surface
## is instead anchored to a position, with no owning unit at all.
##
## EVERY ONE BELONGS TO A WORLD. spawn() files it into the caster's
## WorldContext and parents it under that world, and every reader below
## asks the context of the unit or point it is about — never the focused
## world, which is only the one on screen.
##
## GROUND SURFACES are BG3's grid. A cast spills over the floor cell by
## cell from where it lands (_spill(): physics rays, so it stops at walls
## and won't run up a wall or off a ledge), overwrites cells of any other
## kind and merges with touching cells of its own kind into one
## SurfacePatch, drawn as one film. Units are checked against the cells
## under their footprint every frame (_process): stepping onto a cell
## applies its status, stepping off takes a status_only_inside one back
## off. Cells age one by one; the cells that run out recede from the film.
##
## CLOUDS checkpoints:
##  - Area3D.body_entered (built per-cloud in spawn(), see
##    _on_body_entered): applies status_effect the INSTANT a unit
##    physically walks into it, mid-move. Real physics overlap against the
##    unit's own collision shape, so it fires correctly from any
##    direction, and for a cloud spawned directly on top of a stationary
##    unit.
##  - Area3D.body_exited: takes a status_only_inside status (Blinded)
##    back off, unless another surface still holds the unit.
##
## BOTH:
##  - CombatManager.turn_started(unit): re-applies status_effect to
##    whoever's still inside at the START of their own turn — entering
##    fires once per stay, so without this Burning would run out under a
##    unit standing in the fire.
##  - Rounds (see _on_round_started_in / _on_quiet_round): one clock per
##    world. While a fight runs there, its rounds age the world's
##    surfaces; with none running, a round is ROUND_SECONDS of real time
##    (BG3's rule), so a surface cast outside combat still runs out.
##    Combat ending does NOT clear them — they finish their time.

## One round outside combat, in seconds. BG3's turn.
const ROUND_SECONDS: float = 6.0
## How far up or down a spill flows from one cell to the next: a kerb,
## not a ledge.
const MAX_STEP: float = 0.45
## A ray hit flatter than this is floor; steeper is wall.
const FLOOR_NORMAL: float = 0.6

## The focused world's clouds — what's on screen. Kept for readers that
## really mean that (the world-scoping suite); everything here goes
## through _list_for() with the world it is actually about.
var active_surfaces: Array[ActiveSurface]:
	get:
		return _list_for(WorldManager.context())

## Surfaces cast with no world loaded (the main menu, headless tests).
var _detached_surfaces: Array[ActiveSurface] = []
var _detached_grid := SurfaceGrid.new()

## Unit -> the ground surfaces under it last frame.
var _standing: Dictionary = {}


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
##
## A ground surface (DISC) spills into the grid and returns its
## SurfacePatch; a cloud (SPHERE) returns its ActiveSurface.
func spawn(surface: Surface, position: Vector3, radius: float, caster: Node = null) -> RefCounted:
	var context: WorldContext = WorldManager.context_for(caster) if caster else WorldManager.context()

	# The caster's world; failing that, wherever the caster stands (a bare
	# test scene has no world and no scene root).
	var parent: Node = WorldManager.spawn_parent()
	if context and is_instance_valid(context.world_root):
		parent = context.world_root
	elif parent == null and caster and caster.is_inside_tree():
		parent = caster.get_parent()

	if surface.spawn_vfx:
		surface.spawn_vfx.play(parent, position, position)
	if surface.spawn_sfx:
		surface.spawn_sfx.play(parent, position)

	if surface.shape == Surface.Shape.DISC:
		return _spill(surface, position, radius, context, parent)

	var instance := ActiveSurface.new(surface, position, radius, surface.duration_rounds)
	instance.context = context
	_list_for(context).append(instance)

	if surface.ambient_scene:
		var visual := surface.ambient_scene.instantiate()
		parent.add_child(visual)
		if visual is Node3D:
			visual.global_position = position
			if surface.scale_ambient_to_radius:
				visual.scale = Vector3.ONE * radius / max(surface.authored_radius, 0.001)
		instance.visual_node = visual

	var area := _build_detection_area(radius, instance)
	parent.add_child(area)
	area.global_position = position
	instance.area = area
	return instance


## A cloud's sphere, built purely from the radius, not from ambient_scene
## — the detection volume is automatic from the exact same radius the
## targeting indicator already showed the player.
##
## Does NOT set the area's position — global_position can't be set
## before a Node3D is inside the scene tree, so spawn() adds this first
## and positions it after. input_ray_pickable is turned off explicitly:
## CollisionObject3D defaults it to true, which would make this
## detection-only area intercept clicks meant for the ground underneath
## it (see ground_click_target.gd).
func _build_detection_area(radius: float, instance: ActiveSurface) -> Area3D:
	var area := Area3D.new()
	area.monitorable = false
	area.input_ray_pickable = false
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape.shape = sphere
	area.add_child(shape)
	area.body_entered.connect(_on_body_entered.bind(instance))
	area.body_exited.connect(_on_body_exited.bind(instance))
	return area


## Fills the cells within radius of position that a liquid poured there
## would reach: flooding out from the cell it lands in, one step at a
## time, each step only onto floor (a ray down finds it) no more than a
## kerb up or down, and not through a wall (a ray across at shin height).
## Units don't count as either. With no floor under the cast at all (a
## bare test scene), it fills the flat disc.
##
## Lands on the grid: cells of another surface are overwritten, cells of
## this one topped up to the longer time, and every patch of this
## surface the new cells overlap or touch merges into the biggest.
func _spill(surface: Surface, position: Vector3, radius: float, context: WorldContext, parent: Node) -> SurfacePatch:
	var grid: SurfaceGrid = _grid_for(context)
	var space: PhysicsDirectSpaceState3D = _space_of(parent)
	var exclude: Array[RID] = []
	for unit in UnitQuery.all_units(get_tree()):
		exclude.append(unit.get_rid())

	var start: Vector2i = SurfaceGrid.key_of(position)
	var start_y: float = _floor_under(space, SurfaceGrid.centre_of(start, position.y), exclude) if space else NAN
	var flat: bool = is_nan(start_y)
	var reached: Dictionary = {start: position.y if flat else start_y}
	var frontier: Array[Vector2i] = [start]
	while not frontier.is_empty():
		var key: Vector2i = frontier.pop_front()
		var from: Vector3 = SurfaceGrid.centre_of(key, reached[key])
		for step in SurfaceGrid.NEIGHBOURS:
			var next: Vector2i = key + step
			if reached.has(next):
				continue
			var to: Vector3 = SurfaceGrid.centre_of(next, from.y)
			if Vector2(to.x - position.x, to.z - position.z).length() > radius:
				continue
			var y: float = from.y if flat else _step(space, from, to, exclude)
			if not is_nan(y):
				reached[next] = y
				frontier.append(next)

	var fresh: Array[SurfaceCell] = []
	var merging: Array[SurfacePatch] = []
	var robbed: Array[SurfacePatch] = []
	for key: Vector2i in reached:
		var cell: SurfaceCell = grid.cell_at(key, reached[key])
		if cell and cell.surface == surface:
			if cell.rounds < 0 or surface.duration_rounds < 0:
				cell.rounds = -1
			else:
				cell.rounds = maxi(cell.rounds, surface.duration_rounds)
			if not merging.has(cell.patch):
				merging.append(cell.patch)
			continue
		if cell:
			cell.patch.cells.erase(cell)
			grid.remove(cell)
			if not robbed.has(cell.patch):
				robbed.append(cell.patch)
		cell = SurfaceCell.new(surface, key, reached[key], surface.duration_rounds)
		grid.add(cell)
		fresh.append(cell)
	for cell in fresh:
		for step in SurfaceGrid.NEIGHBOURS:
			var beside: SurfaceCell = grid.cell_at(cell.key + step, cell.y)
			if beside and beside.patch and beside.surface == surface and not merging.has(beside.patch):
				merging.append(beside.patch)

	var patch: SurfacePatch = null
	for other in merging:
		if patch == null or other.cells.size() > patch.cells.size():
			patch = other
	if patch == null:
		patch = SurfacePatch.new(surface, context)
		grid.patches.append(patch)
		if surface.ambient_scene:
			patch.visual = surface.ambient_scene.instantiate()
			parent.add_child(patch.visual)
			if not patch.visual.has_method("show_cells"):
				patch.visual.global_position = position
	for other in merging:
		if other == patch:
			continue
		for cell in other.cells:
			cell.patch = patch
		patch.cells.append_array(other.cells)
		grid.patches.erase(other)
		# Its cells are in the merged film from that film's next picture.
		if other.visual and patch.visual and patch.visual.has_signal("drawn"):
			patch.visual.drawn.connect(other.visual.queue_free, CONNECT_ONE_SHOT)
		elif other.visual:
			other.visual.queue_free()
	for cell in fresh:
		cell.patch = patch
	patch.cells.append_array(fresh)
	if patch.visual and patch.visual.has_method("show_cells"):
		patch.visual.show_cells(patch.cells, fresh, position, radius)

	for other in robbed:
		if other.cells.is_empty():
			grid.patches.erase(other)
		if not other.visual:
			continue
		if not other.visual.has_method("set_cells"):
			if other.cells.is_empty():
				other.visual.queue_free()
			continue
		# The overwritten cells go once the new film has spread over them.
		var keep: Array[SurfaceCell] = other.cells.duplicate()
		var seconds: float = patch.visual.spread_seconds if patch.visual is DecalSurface else 0.0
		# Bound to the visual, so the call is dropped if it's freed first.
		get_tree().create_timer(seconds).timeout.connect(other.visual.set_cells.bind(keep))
	return patch


## Where the floor is under point (the ray starts half a meter above it,
## so a ceiling overhead doesn't count), or NAN for none.
func _floor_under(space: PhysicsDirectSpaceState3D, point: Vector3, exclude: Array[RID]) -> float:
	var down := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.5, point + Vector3.DOWN * 1.5, 1, exclude)
	var hit: Dictionary = space.intersect_ray(down)
	if hit.is_empty() or hit.normal.y < FLOOR_NORMAL:
		return NAN
	return hit.position.y


## The floor height a spill reaches stepping from one cell centre to the
## next, or NAN if a wall is in the way, there's no floor, or it's more
## than a kerb up or down.
func _step(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, exclude: Array[RID]) -> float:
	var lift := Vector3.UP * 0.5
	var across := PhysicsRayQueryParameters3D.create(from + lift, to + lift, 1, exclude)
	if not space.intersect_ray(across).is_empty():
		return NAN
	var y: float = _floor_under(space, to, exclude)
	if is_nan(y) or absf(y - from.y) > MAX_STEP:
		return NAN
	return y


func _space_of(node: Node) -> PhysicsDirectSpaceState3D:
	if node == null or not node.is_inside_tree():
		return null
	if node is Node3D:
		return (node as Node3D).get_world_3d().direct_space_state
	return node.get_viewport().find_world_3d().direct_space_state


## Every frame: steps units on and off ground surfaces. Reads the cells
## under each unit's footprint, so it is the cell, not an Area3D, that
## decides — the same answer movement cost and turn start get.
func _process(_delta: float) -> void:
	for unit in _standing.keys():
		if not is_instance_valid(unit):
			_standing.erase(unit)
	if _standing.is_empty() and _no_ground_surfaces():
		return
	for unit: Unit in UnitQuery.all_units(get_tree()):
		var under: Array[Surface] = _surfaces_under(unit) if unit.is_alive() else ([] as Array[Surface])
		var before: Array[Surface] = _standing.get(unit, [] as Array[Surface])
		if under == before:
			continue
		if under.is_empty():
			_standing.erase(unit)
		else:
			_standing[unit] = under
		for surface in under:
			if not before.has(surface) and surface.status_effect and not _sees_through(unit, surface):
				unit.inflict_status(surface.status_effect, null)
		for surface in before:
			if not under.has(surface):
				_release(unit, surface)


func _no_ground_surfaces() -> bool:
	if not _detached_grid.is_empty():
		return false
	for context in WorldManager.all_contexts():
		if not context.surface_grid.is_empty():
			return false
	return true


## The ground surfaces under any part of unit's footprint, in its world.
func _surfaces_under(unit: Unit) -> Array[Surface]:
	var found: Array[Surface] = []
	var grid: SurfaceGrid = _grid_for(WorldManager.context_for(unit))
	if grid.is_empty():
		return found
	var feet: Vector3 = unit.global_position
	var reach := Vector3(unit.radius, 0.0, unit.radius)
	var low: Vector2i = SurfaceGrid.key_of(feet - reach)
	var high: Vector2i = SurfaceGrid.key_of(feet + reach)
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			var cell: SurfaceCell = grid.cell_at(Vector2i(x, z), feet.y)
			if cell == null or found.has(cell.surface):
				continue
			# The nearest point of the square to the footprint's centre.
			var near := Vector2(clampf(feet.x, x * SurfaceGrid.CELL, (x + 1) * SurfaceGrid.CELL),
					clampf(feet.z, z * SurfaceGrid.CELL, (z + 1) * SurfaceGrid.CELL))
			if near.distance_to(Vector2(feet.x, feet.z)) <= unit.radius:
				found.append(cell.surface)
	return found


## The ground surface on the floor at point in context, or null.
func surface_at(point: Vector3, context: WorldContext) -> Surface:
	var cell: SurfaceCell = _grid_for(context).cell_under(point)
	return cell.surface if cell else null


## Fires the instant a unit's own collision shape overlaps a cloud —
## including a cloud spawned directly on top of a stationary unit, which
## Godot reports as an immediate overlap.
func _on_body_entered(body: Node3D, active: ActiveSurface) -> void:
	if not body is Unit or not body.is_alive():
		return
	if not active.surface.status_effect or _sees_through(body, active.surface):
		return
	body.inflict_status(active.surface.status_effect, null)


func _on_body_exited(body: Node3D, active: ActiveSurface) -> void:
	if body is Unit and is_instance_valid(body):
		_release(body, active.surface, active)


## Takes surface's inside-only status off unit, unless something else in
## its world that gives the same status still holds them: another cloud
## (not `leaving`, the one they just left) or a cell underfoot.
func _release(unit: Unit, surface: Surface, leaving: ActiveSurface = null) -> void:
	var effect: StatusEffect = surface.status_effect
	if not effect or not surface.status_only_inside:
		return
	for other in _list_for(WorldManager.context_for(unit)):
		if other != leaving and other.surface.status_effect == effect and _contains(other, unit):
			return
	for under in _surfaces_under(unit):
		if under.status_effect == effect:
			return
	unit.remove_status(effect)


## Whether unit's body is inside a cloud: the nearest point of the unit's
## upright body (feet to eyes) — a cloud hanging at head height covers a
## unit whose feet are well below it.
func _contains(active: ActiveSurface, unit: Unit) -> bool:
	var feet: Vector3 = unit.global_position
	var nearest: Vector3 = Geometry3D.get_closest_point_to_segment(active.position, feet, unit.anchor(CharacterModel.Anchor.EYE))
	return nearest.distance_to(active.position) - unit.radius <= active.radius


## Whether a sight line from `from` to `to` passes through a sight-
## blocking cloud in viewer's world. Starting or ending inside counts:
## that is BG3's "blocks ranged attacks in, out and across". Read by
## LineOfSight after its wall raycast.
func blocks_sight(viewer: Node, from: Vector3, to: Vector3) -> bool:
	for active in _list_for(WorldManager.context_for(viewer)):
		if not active.surface.blocks_sight or _sees_through(viewer, active.surface):
			continue
		var nearest: Vector3 = Geometry3D.get_closest_point_to_segment(active.position, from, to)
		if nearest.distance_to(active.position) <= active.radius:
			return true
	return false


## Dark Vision ignores a darkness surface: no wall, no Blinded.
func _sees_through(viewer: Node, surface: Surface) -> bool:
	return surface.dark_vision_sees_through and viewer is Unit and viewer.dark_vision


## The terrain-cost sampler for a route planned by mover — RoutePlanner.
## plan's cost_sampler, reading only the surfaces in mover's own world.
func cost_sampler(mover: Node) -> Callable:
	return movement_cost_multiplier_at.bind(WorldManager.context_for(mover))


## point is a bare sample point along a simulated path, not a unit. Highest
## multiplier of the cell under it and any cloud covering it wins;
## overlapping clouds don't stack. 1.0 (no effect) if nothing covers it.
## Call through cost_sampler(), which supplies the context.
func movement_cost_multiplier_at(point: Vector3, context: WorldContext) -> float:
	var multiplier: float = 1.0
	var cell: SurfaceCell = _grid_for(context).cell_under(point)
	if cell:
		multiplier = cell.surface.movement_cost_multiplier
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
				_age_grid(_grid_for(context))
			return


## A world with no fight running ages by real time instead.
func _on_quiet_round() -> void:
	for context in WorldManager.all_contexts():
		if not _fighting(context.encounters):
			_age(context.surfaces)
			_age_grid(context.surface_grid)
	if WorldManager.context() == null and not _fighting(CombatManager.encounters):
		_age(_detached_surfaces)
		_age_grid(_detached_grid)


func _age(surfaces: Array[ActiveSurface]) -> void:
	for active in surfaces.duplicate():
		if active.rounds_remaining < 0:
			continue  # permanent surface — never ages out this way
		active.rounds_remaining -= 1
		if active.rounds_remaining <= 0:
			_expire(active)


## Every cell runs out on its own clock; a patch loses the cells that ran
## out, which recede from its film, and goes when it has none left.
func _age_grid(grid: SurfaceGrid) -> void:
	for patch in grid.patches.duplicate():
		var ran_out: Array[SurfaceCell] = []
		for cell in patch.cells:
			if cell.rounds < 0:
				continue  # permanent
			cell.rounds -= 1
			if cell.rounds <= 0:
				ran_out.append(cell)
		if not ran_out.is_empty():
			expire_cells(grid, patch, ran_out)


## Takes cells off the grid and out of patch's film. Whoever stood on
## them steps off on the next frame's check.
func expire_cells(grid: SurfaceGrid, patch: SurfacePatch, cells: Array[SurfaceCell]) -> void:
	var at: Vector3 = patch.centroid(cells)
	for cell in cells:
		grid.remove(cell)
		patch.cells.erase(cell)
	if patch.cells.is_empty():
		grid.patches.erase(patch)
	var alive: bool = patch.visual != null and is_instance_valid(patch.visual)
	var parent: Node = patch.visual.get_parent() if alive else WorldManager.spawn_parent()
	if patch.surface.expire_vfx:
		patch.surface.expire_vfx.play(parent, at, at)
	if patch.surface.expire_sfx:
		patch.surface.expire_sfx.play(parent, at)
	if not alive:
		return
	if patch.cells.is_empty() and patch.visual.has_method("dissipate"):
		patch.visual.dissipate()
	elif patch.visual.has_method("recede_cells"):
		patch.visual.recede_cells(cells)
	elif patch.cells.is_empty():
		patch.visual.queue_free()


## Runs every ground patch in context out at once.
func expire_all_ground(context: WorldContext) -> void:
	var grid: SurfaceGrid = _grid_for(context)
	for patch in grid.patches.duplicate():
		expire_cells(grid, patch, patch.cells.duplicate())


func _on_turn_started(unit: Unit) -> void:
	if not unit.is_alive():
		return
	for active in _list_for(WorldManager.context_for(unit)):
		if active.surface.status_effect and _contains(active, unit) and not _sees_through(unit, active.surface):
			unit.inflict_status(active.surface.status_effect, null)
	for surface in _surfaces_under(unit):
		if surface.status_effect and not _sees_through(unit, surface):
			unit.inflict_status(surface.status_effect, null)


func _expire(active: ActiveSurface) -> void:
	var inside: Array[Node3D] = []
	if active.area and is_instance_valid(active.area) and active.area.is_inside_tree():
		inside = active.area.get_overlapping_bodies()
	_list_for(active.context).erase(active)
	for body in inside:
		if body is Unit:
			_release(body, active.surface, active)

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


func _grid_for(context: WorldContext) -> SurfaceGrid:
	return context.surface_grid if context else _detached_grid


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
