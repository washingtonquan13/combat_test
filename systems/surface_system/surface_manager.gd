extends Node
## Autoload singleton. Register as "SurfaceManager" under
## Project > Project Settings > AutoLoad, alongside CombatManager/
## AbilityManager/SelectionManager.
##
## Tracks every surface currently in any loaded world — ground surfaces
## (Grease) as cells of the world's SurfaceGrid, clouds (Fog) as cubes of
## its CloudGrid: the world-persistent counterpart to
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
## SurfacePatch, drawn as one film. Cells age one by one; the cells that
## run out recede from the film.
##
## CLOUDS are the same idea in 3D: a cast fills 1 m cubes out from where
## it lands (_fill(): rays again, so walls, floors and ceilings stop it),
## overwrites cubes of another cloud and tops up its own. Each cast keeps
## its own visual; cubes age one by one and recede from it. Sight lines
## are walked cube by cube (blocks_sight).
##
## BOTH:
##  - Every frame (_process), each unit is checked against the cells under
##    its footprint and the cubes its body touches (_holding): getting
##    into one applies its status, the INSTANT it happens, mid-move,
##    and the status's on_contact bites then too (fire burns at once);
##    getting out takes a status_only_inside one (Blinded) back off,
##    unless something else still holding the unit gives it too.
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
## How far across the ground a WALL cloud's cubes reach from its line, to
## their centres. Over half a cube's diagonal (0.71), so a wall run at an
## angle to the grid stays face-connected and floods end to end.
const WALL_HALF_THICKNESS: float = 0.75

## The focused world's clouds — what's on screen. Kept for readers that
## really mean that (the world-scoping suite); everything here goes
## through _clouds_for() with the world it is actually about.
var cloud_grid: CloudGrid:
	get:
		return _clouds_for(WorldManager.context())

## Surfaces cast with no world loaded (the main menu, headless tests).
var _detached_clouds := CloudGrid.new()
var _detached_grid := SurfaceGrid.new()

## Unit -> the surfaces holding it last frame (underfoot or around it).
var _inside: Dictionary = {}


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
## SurfacePatch; a cloud (SPHERE) fills the cloud grid and returns its
## CloudPatch.
func spawn(surface: Surface, position: Vector3, radius: float, caster: Node = null) -> RefCounted:
	var context: WorldContext = WorldManager.context_for(caster) if caster else WorldManager.context()
	var parent: Node = _parent_for(context, caster)
	_play_spawn_fx(surface, parent, position)
	if surface.shape == Surface.Shape.DISC:
		return _spill(surface, position, radius, context, parent)
	var squash := Vector3(1.0, 1.0 / surface.height_scale, 1.0)
	var inside := func(point: Vector3) -> bool: return ((point - position) * squash).length() <= radius
	# The cast point sits on the floor; lift it clear of it.
	var seeds: Dictionary[Vector3i, Vector3] = {CloudGrid.key_of(position): position + Vector3.UP * 0.1}
	return _fill(surface, seeds, inside, position, context, parent)


## Raises a WALL cloud (Wall of Fire) along the ground from from to to:
## every cube within WALL_HALF_THICKNESS of the line, from the ground up
## to the surface's wall_height, flooded out from both ends the way any
## cloud fills — so a wall it meets cuts it off — and standing on stairs
## and slopes, the ground lerped between the two ends. Returns its
## CloudPatch.
func spawn_wall(surface: Surface, from: Vector3, to: Vector3, caster: Node = null) -> CloudPatch:
	var context: WorldContext = WorldManager.context_for(caster) if caster else WorldManager.context()
	var parent: Node = _parent_for(context, caster)
	var middle: Vector3 = from.lerp(to, 0.5)
	_play_spawn_fx(surface, parent, middle)
	var seeds: Dictionary[Vector3i, Vector3] = {}
	for end: Vector3 in [from, to]:
		var lifted: Vector3 = end + Vector3.UP * 0.1
		seeds[CloudGrid.key_of(lifted)] = lifted
	var patch: CloudPatch = _fill(surface, seeds, _within_wall.bind(from, to, surface.wall_height), middle, context, parent, _wall_point.bind(from, to))
	if patch and surface.lays_ground_under and surface.leaves_behind and not patch.cells.is_empty():
		# Burns under the wall for as long as it stands, and its own
		# rounds after: the cubes running out only top it up.
		_leave_behind(patch, patch.cells, parent, surface.duration_rounds)
	return patch


## Lays a ground surface (Fire Breath's burning ground) wherever a cone
## from apex along direction (a unit vector), length long and opening at
## half_angle radians, washes over the floor: every cell whose floor is
## inside the cone with no wall between it and the apex, the same shadow
## the cone's damage casts. It spreads out from the apex, or, given
## front_seconds, with a front reaching the cone's end in that long (see
## DecalSurface.show_cells). Returns its SurfacePatch, or null if the cone
## touches no floor (breathed into the air).
func spawn_cone(surface: Surface, apex: Vector3, direction: Vector3, length: float, half_angle: float, caster: Node = null, front_seconds: float = 0.0) -> SurfacePatch:
	var context: WorldContext = WorldManager.context_for(caster) if caster else WorldManager.context()
	var parent: Node = _parent_for(context, caster)
	var space: PhysicsDirectSpaceState3D = _space_of(parent)
	if not space:
		return null
	var exclude: Array[RID] = []
	for unit in UnitQuery.all_units(get_tree()):
		exclude.append(unit.get_rid())
	# The highest the cone reaches, so a floor under any of it is found
	# from above and a ceiling over the apex is not mistaken for one.
	var top: float = apex.y + maxf(0.0, length * sin(asin(clampf(direction.y, -1.0, 1.0)) + half_angle)) + 0.1
	var reached: Dictionary = {}
	var low: Vector2i = SurfaceGrid.key_of(apex - Vector3(length, 0.0, length))
	var high: Vector2i = SurfaceGrid.key_of(apex + Vector3(length, 0.0, length))
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			var key := Vector2i(x, z)
			var column: Vector3 = SurfaceGrid.centre_of(key, apex.y)
			if Vector2(column.x - apex.x, column.z - apex.z).length() > length:
				continue
			var down := PhysicsRayQueryParameters3D.create(Vector3(column.x, top, column.z), Vector3(column.x, apex.y - length, column.z), 1, exclude)
			var hit: Dictionary = space.intersect_ray(down)
			if hit.is_empty() or hit.normal.y < FLOOR_NORMAL:
				continue
			var floor_point: Vector3 = hit.position + Vector3.UP * 0.05
			var to: Vector3 = floor_point - apex
			if to.length() > length or direction.angle_to(to) > half_angle:
				continue
			var sight := PhysicsRayQueryParameters3D.create(apex, floor_point, 1, exclude)
			if not space.intersect_ray(sight).is_empty():
				continue
			reached[key] = hit.position.y
	if reached.is_empty():
		return null
	if front_seconds > 0.0:
		return _land(surface, reached, context, parent, apex, length, 0, front_seconds)
	var ground_apex := Vector3(apex.x, reached.values().min(), apex.z)
	return _land(surface, reached, context, parent, ground_apex, length)


## Whether the cube centred on point is part of a wall from from to to:
## its centre within WALL_HALF_THICKNESS of the line, across the ground,
## and its height overlapping the ground there up to height.
func _within_wall(point: Vector3, from: Vector3, to: Vector3, height: float) -> bool:
	var on_line: Vector3 = from.lerp(to, _along(point, from, to))
	if Vector2(point.x - on_line.x, point.z - on_line.z).length() > WALL_HALF_THICKNESS:
		return false
	var ground: float = on_line.y
	var half: float = CloudGrid.CELL * 0.5
	return point.y + half > ground and point.y - half < ground + height


## Where the fill passes through a wall's cube: its centre, lifted clear
## of the ground line where the cube straddles it — a ground-row centre
## can sit right on the floor, and a ray along the floor hits it.
func _wall_point(key: Vector3i, from: Vector3, to: Vector3) -> Vector3:
	var centre: Vector3 = CloudGrid.centre_of(key)
	centre.y = maxf(centre.y, lerpf(from.y, to.y, _along(centre, from, to)) + 0.1)
	return centre


## How far along from-to, 0 to 1 across the ground, point lies.
func _along(point: Vector3, from: Vector3, to: Vector3) -> float:
	var along := Vector2(to.x - from.x, to.z - from.z)
	if along.length_squared() == 0.0:
		return 0.0
	return clampf((Vector2(point.x, point.z) - Vector2(from.x, from.z)).dot(along) / along.length_squared(), 0.0, 1.0)


## The caster's world; failing that, wherever the caster stands (a bare
## test scene has no world and no scene root).
func _parent_for(context: WorldContext, caster: Node) -> Node:
	var parent: Node = WorldManager.spawn_parent()
	if context and is_instance_valid(context.world_root):
		parent = context.world_root
	elif parent == null and caster and caster.is_inside_tree():
		parent = caster.get_parent()
	return parent


func _play_spawn_fx(surface: Surface, parent: Node, position: Vector3) -> void:
	if surface.spawn_vfx:
		surface.spawn_vfx.play(parent, position, position)
	if surface.spawn_sfx:
		surface.spawn_sfx.play(parent, position)


## Where the fill passes through the cube at key: point_of(key), or its
## centre.
func _fill_point(key: Vector3i, point_of: Callable) -> Vector3:
	return point_of.call(key) if point_of.is_valid() else CloudGrid.centre_of(key)


## Fills the cubes inside (a cube centre -> whether the shape holds it)
## that a gas let out at seeds (start cube -> the point it's let out at)
## would reach: flooding out from those cubes, one face at a
## time, each step only where a ray between the two cubes is clear (from
## point_of(key) to point_of(next), their centres by default)
## — so walls, floors and ceilings stop it, and it doesn't leak through
## them. Units don't block it. With no physics (a bare test scene), it
## fills the plain shape. The visual is placed at position.
##
## Lands on the grid: cubes of another cloud are taken (their old visual
## recedes them), cubes of this one topped up to the longer time and left
## with the visual already showing them. Returns this cast's patch — the
## first start cube's, if the cast only topped up.
func _fill(surface: Surface, seeds: Dictionary[Vector3i, Vector3], inside: Callable, position: Vector3, context: WorldContext, parent: Node, point_of: Callable = Callable()) -> CloudPatch:
	var grid: CloudGrid = _clouds_for(context)
	var space: PhysicsDirectSpaceState3D = _space_of(parent)
	var exclude: Array[RID] = []
	for unit in UnitQuery.all_units(get_tree()):
		exclude.append(unit.get_rid())

	var start: Vector3i = seeds.keys()[0]
	var reached: Dictionary[Vector3i, bool] = {}
	var frontier: Array[Vector3i] = []
	for key: Vector3i in seeds:
		reached[key] = true
		frontier.append(key)
	while not frontier.is_empty():
		var key: Vector3i = frontier.pop_front()
		var from: Vector3 = seeds.get(key, _fill_point(key, point_of))
		for step in CloudGrid.NEIGHBOURS:
			var next: Vector3i = key + step
			if reached.has(next):
				continue
			if not inside.call(CloudGrid.centre_of(next)):
				continue
			var to: Vector3 = _fill_point(next, point_of)
			if space:
				var ray := PhysicsRayQueryParameters3D.create(from, to, 1, exclude)
				if not space.intersect_ray(ray).is_empty():
					continue
			reached[next] = true
			frontier.append(next)

	var patch := CloudPatch.new(surface, context)
	var robbed: Array[CloudPatch] = []
	var taken: Dictionary = {}
	var start_patch: CloudPatch = null
	for key: Vector3i in reached:
		var cell: CloudCell = grid.cells.get(key)
		if cell and cell.surface == surface:
			if cell.rounds < 0 or surface.duration_rounds < 0:
				cell.rounds = -1
			else:
				cell.rounds = maxi(cell.rounds, surface.duration_rounds)
			if key == start:
				start_patch = cell.patch
			continue
		if cell:
			cell.patch.cells.erase(cell)
			grid.remove(cell)
			if not robbed.has(cell.patch):
				robbed.append(cell.patch)
				taken[cell.patch] = [] as Array[CloudCell]
			taken[cell.patch].append(cell)
		cell = CloudCell.new(surface, key, surface.duration_rounds)
		cell.patch = patch
		grid.add(cell)
		patch.cells.append(cell)

	for other: CloudPatch in robbed:
		if other.cells.is_empty():
			grid.patches.erase(other)
		_recede(other, taken[other])

	if patch.cells.is_empty():
		return start_patch
	grid.patches.append(patch)
	if surface.ambient_scene:
		patch.visual = surface.ambient_scene.instantiate()
		parent.add_child(patch.visual)
		patch.visual.global_position = position
		if patch.visual.has_method("show_cubes"):
			patch.visual.show_cubes(patch.cells)
	return patch


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
	return _land(surface, reached, context, parent, position, radius)


## Lands reached (SurfaceGrid key -> its floor y) on the grid as surface:
## cells of another surface are overwritten, cells of this one topped up
## to the longer time, and every patch of this surface the new cells
## overlap or touch merges into the biggest. position and radius are
## where the visual spreads from and how far. extra_rounds lengthens the
## surface's own duration_rounds; negative makes it permanent.
func _land(surface: Surface, reached: Dictionary, context: WorldContext, parent: Node, position: Vector3, radius: float, extra_rounds: int = 0, front_seconds: float = 0.0) -> SurfacePatch:
	var grid: SurfaceGrid = _grid_for(context)
	var rounds: int = surface.duration_rounds
	if rounds >= 0:
		rounds = -1 if extra_rounds < 0 else rounds + extra_rounds
	var fresh: Array[SurfaceCell] = []
	var merging: Array[SurfacePatch] = []
	var robbed: Array[SurfacePatch] = []
	for key: Vector2i in reached:
		var cell: SurfaceCell = grid.cell_at(key, reached[key])
		if cell and cell.surface == surface:
			if cell.rounds < 0 or rounds < 0:
				cell.rounds = -1
			else:
				cell.rounds = maxi(cell.rounds, rounds)
			if not merging.has(cell.patch):
				merging.append(cell.patch)
			continue
		if cell:
			cell.patch.cells.erase(cell)
			grid.remove(cell)
			if not robbed.has(cell.patch):
				robbed.append(cell.patch)
		cell = SurfaceCell.new(surface, key, reached[key], rounds)
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
		patch.visual.show_cells(patch.cells, fresh, position, radius, front_seconds)

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


## Every frame: moves units into and out of surfaces. Reads the cells
## under each unit's footprint and the cubes around its body, so it is
## the grid that decides — the same answer movement cost and turn start
## get.
func _process(_delta: float) -> void:
	for unit in _inside.keys():
		if not is_instance_valid(unit):
			_inside.erase(unit)
	if _inside.is_empty() and _no_surfaces():
		return
	for unit: Unit in UnitQuery.all_units(get_tree()):
		var now: Array[Surface] = _holding(unit) if unit.is_alive() else ([] as Array[Surface])
		var before: Array[Surface] = _inside.get(unit, [] as Array[Surface])
		if now == before:
			continue
		if now.is_empty():
			_inside.erase(unit)
		else:
			_inside[unit] = now
		var had: Array[StatusEffect] = _statuses(before, unit)
		for effect in _statuses(now, unit):
			if not had.has(effect) and unit.inflict_status(effect, null):
				unit.status_contact(effect)
		if unit.is_downed() and unit.is_moving():
			unit.stop_moving()
		for surface in before:
			if not now.has(surface):
				_release(unit, surface, now)


func _no_surfaces() -> bool:
	if not _detached_grid.is_empty() or not _detached_clouds.is_empty():
		return false
	for context in WorldManager.all_contexts():
		if not context.surface_grid.is_empty() or not context.cloud_grid.is_empty():
			return false
	return true


## Every surface holding unit: on the floor under it or in the air around
## it.
func _holding(unit: Unit) -> Array[Surface]:
	var found: Array[Surface] = _surfaces_under(unit)
	for surface in _clouds_holding(unit):
		if not found.has(surface):
			found.append(surface)
	return found


## The clouds around any part of unit's upright body (feet to eyes) — a
## cloud hanging at head height covers a unit whose feet are below it.
func _clouds_holding(unit: Unit) -> Array[Surface]:
	var found: Array[Surface] = []
	var grid: CloudGrid = _clouds_for(WorldManager.context_for(unit))
	for cell in grid.cells_touching(unit.global_position, unit.anchor(CharacterModel.Anchor.EYE), unit.radius):
		if not found.has(cell.surface):
			found.append(cell.surface)
	return found


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


## Takes surface's inside-only status off unit, unless one of the
## surfaces still holding them (`still`) gives the same status.
func _release(unit: Unit, surface: Surface, still: Array[Surface]) -> void:
	var effect: StatusEffect = surface.status_effect
	if not effect or not surface.status_only_inside:
		return
	for other in still:
		if other.status_effect == effect:
			return
	unit.remove_status(effect)


## Whether a sight line from `from` to `to` passes through a cube of a
## sight-blocking cloud in viewer's world. Starting or ending inside
## counts: that is BG3's "blocks ranged attacks in, out and across". Read
## by LineOfSight after its wall raycast.
func blocks_sight(viewer: Node, from: Vector3, to: Vector3) -> bool:
	for cell in _clouds_for(WorldManager.context_for(viewer)).cells_along(from, to):
		if cell.surface.blocks_sight and not _sees_through(viewer, cell.surface):
			return true
	return false


## The cloud in the cube at point in context, or null.
func cloud_at(point: Vector3, context: WorldContext) -> Surface:
	var cell: CloudCell = _clouds_for(context).cell_at(point)
	return cell.surface if cell else null


## Dark Vision ignores a darkness surface: no wall, no Blinded.
func _sees_through(viewer: Node, surface: Surface) -> bool:
	return surface.dark_vision_sees_through and viewer is Unit and viewer.dark_vision


## The terrain-cost sampler for a route planned by mover — RoutePlanner.
## plan's cost_sampler, reading only the surfaces in mover's own world.
func cost_sampler(mover: Node) -> Callable:
	return movement_cost_multiplier_at.bind(WorldManager.context_for(mover))


## point is a bare sample point along a simulated path, not a unit. The
## higher multiplier of the cell under it and the cube around it wins.
## 1.0 (no effect) if nothing covers it. Call through cost_sampler(),
## which supplies the context.
func movement_cost_multiplier_at(point: Vector3, context: WorldContext) -> float:
	var multiplier: float = 1.0
	var cell: SurfaceCell = _grid_for(context).cell_under(point)
	if cell:
		multiplier = cell.surface.movement_cost_multiplier
	var cube: CloudCell = _clouds_for(context).cell_at(point)
	if cube:
		multiplier = maxf(multiplier, cube.surface.movement_cost_multiplier)
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
				_age(_clouds_for(context), _grid_for(context))
			return


## A world with no fight running ages by real time instead.
func _on_quiet_round() -> void:
	for context in WorldManager.all_contexts():
		if not _fighting(context.encounters):
			_age(context.cloud_grid, context.surface_grid)
	if WorldManager.context() == null and not _fighting(CombatManager.encounters):
		_age(_detached_clouds, _detached_grid)


## One round off a world's surfaces. The ground goes first: ground a cloud
## leaves behind as it runs out (leaves_behind) then lands after this
## round's aging, and keeps its whole duration.
func _age(clouds: CloudGrid, ground: SurfaceGrid) -> void:
	_age_grid(ground)
	_age_clouds(clouds)


## Every cube runs out on its own clock, like ground cells.
func _age_clouds(grid: CloudGrid) -> void:
	for patch in grid.patches.duplicate():
		var ran_out: Array[CloudCell] = []
		for cell in patch.cells:
			if cell.rounds < 0:
				continue  # permanent
			cell.rounds -= 1
			if cell.rounds <= 0:
				ran_out.append(cell)
		if not ran_out.is_empty():
			expire_cloud_cells(grid, patch, ran_out)


## Takes cubes off the grid and out of patch's visual. Whoever was inside
## them is let go on the next frame's check.
func expire_cloud_cells(grid: CloudGrid, patch: CloudPatch, cells: Array[CloudCell]) -> void:
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
	_recede(patch, cells)
	if patch.surface.leaves_behind:
		_leave_behind(patch, cells, parent)


## Lands patch's leaves_behind ground surface (Wall of Fire's burning
## ground) on the floor under those of cells that touch it. A cube touches
## the floor when the floor passes through it — the ground row of a wall,
## not the cubes stacked above it, nor a cube hanging in the air.
## Lands as one spill, so the film spreads from under the whole run-out
## stretch at once. With no physics (a bare test scene), the lowest
## run-out cubes' bottoms are the floor. extra_rounds as for _land.
func _leave_behind(patch: CloudPatch, cells: Array[CloudCell], parent: Node, extra_rounds: int = 0) -> void:
	var space: PhysicsDirectSpaceState3D = _space_of(parent)
	var exclude: Array[RID] = []
	for unit in UnitQuery.all_units(get_tree()):
		exclude.append(unit.get_rid())
	var lowest: int = cells[0].key.y
	for cell in cells:
		lowest = mini(lowest, cell.key.y)
	var half: float = CloudGrid.CELL * 0.5
	var across: int = roundi(CloudGrid.CELL / SurfaceGrid.CELL)
	var reached: Dictionary = {}
	for cell in cells:
		if not space and cell.key.y != lowest:
			continue
		var bottom: float = cell.key.y * CloudGrid.CELL
		# The SurfaceGrid cells under the cube's footprint.
		var corner: Vector2i = SurfaceGrid.key_of(cell.centre() - Vector3(half, 0.0, half) + Vector3(0.01, 0.0, 0.01))
		for dx in across:
			for dz in across:
				var key: Vector2i = corner + Vector2i(dx, dz)
				var floor_y: float = bottom
				if space:
					floor_y = _floor_under(space, SurfaceGrid.centre_of(key, bottom + CloudGrid.CELL), exclude)
					if is_nan(floor_y) or floor_y < bottom - 0.05 or floor_y >= bottom + CloudGrid.CELL:
						continue
				reached[key] = floor_y
	if reached.is_empty():
		return
	var middle := Vector3.ZERO
	for key: Vector2i in reached:
		middle += SurfaceGrid.centre_of(key, reached[key])
	middle /= reached.size()
	var radius: float = 0.0
	for key: Vector2i in reached:
		radius = maxf(radius, SurfaceGrid.centre_of(key, middle.y).distance_to(middle))
	_land(patch.surface.leaves_behind, reached, patch.context, parent, middle, radius + SurfaceGrid.CELL, extra_rounds)


## Runs every cloud in context out at once.
func expire_all_clouds(context: WorldContext) -> void:
	var grid: CloudGrid = _clouds_for(context)
	for patch in grid.patches.duplicate():
		expire_cloud_cells(grid, patch, patch.cells.duplicate())


## patch's visual lets go of cells it no longer holds: all of them thins
## the whole cloud away, some recedes just those.
func _recede(patch: CloudPatch, cells: Array[CloudCell]) -> void:
	if patch.visual == null or not is_instance_valid(patch.visual):
		return
	if patch.cells.is_empty() and patch.visual.has_method("dissipate"):
		patch.visual.dissipate()
	elif patch.visual.has_method("recede_cubes"):
		patch.visual.recede_cubes(cells)
	elif patch.cells.is_empty():
		patch.visual.queue_free()


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
	for effect in _statuses(_holding(unit), unit):
		unit.inflict_status(effect, null)


## The statuses surfaces put on unit, each once however many of them give
## it - a walker in Wall of Fire stands in the wall and the ground fire
## under it - and of a StatusEffect.group only the highest rank, so it is
## rolled once and never knocked down to a weaker one by the order they
## are found in. A surface unit sees through gives nothing.
func _statuses(surfaces: Array[Surface], unit: Unit) -> Array[StatusEffect]:
	var found: Array[StatusEffect] = []
	for surface in surfaces:
		var effect: StatusEffect = surface.status_effect
		if not effect or found.has(effect) or _sees_through(unit, surface):
			continue
		var weaker: int = -1
		var outranked: bool = false
		for i in found.size():
			if effect.group != &"" and found[i].group == effect.group:
				if found[i].rank >= effect.rank:
					outranked = true
				else:
					weaker = i
		if outranked:
			continue
		if weaker >= 0:
			found.remove_at(weaker)
		found.append(effect)
	return found


## context's own clouds; the detached ones for no world.
func _clouds_for(context: WorldContext) -> CloudGrid:
	return context.cloud_grid if context else _detached_clouds


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
