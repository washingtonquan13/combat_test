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
##  - CombatManager.turn_started(unit): re-applies status_effects to
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
## How far round the struck spot a single-target attack at the ground
## touches the floor (touch), meters.
const POINT_TOUCH_RADIUS: float = 0.4
## The physics layer of a blocks_movement cloud's barrier: the navigation
## grid bakes a body on any layer, but sight and shots only test layer 1,
## so the barrier stops walkers and nothing else.
const BARRIER_LAYER: int = 1 << 18

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
	# A wall with a front (Wall of Water's curl) faces away from its caster.
	if patch and caster is Node3D and is_instance_valid(patch.visual) and patch.visual.has_method("lean_away_from"):
		patch.visual.lean_away_from(caster.global_position)
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
	var reached: Dictionary = _cone_cells(_space_of(parent), apex, direction, length, half_angle)
	if reached.is_empty():
		return null
	if front_seconds > 0.0:
		return _land(surface, reached, context, parent, apex, length, 0, front_seconds)
	var ground_apex := Vector3(apex.x, reached.values().min(), apex.z)
	return _land(surface, reached, context, parent, ground_apex, length)


## An attack of element landing without leaving a surface of its own
## (Lightning Breath, a frost bolt): what's on the ground where it lands
## reacts to it all the same, as if a surface of that element had landed
## there (_react) — cold freezes the water a target stands in, fire lights
## the grease. Where: the target's footprint for a unit, else the
## ability's area — its cone, its blast's floor, its spill — or, for a
## single-target attack aimed at the ground, the spot it struck. Nothing of the
## element is left behind, so a reaction that would only let it TAKE the
## cells does nothing.
func touch(element: Surface.Element, ability: Ability, attacker: Unit, target) -> void:
	if element == Surface.Element.NONE:
		return
	var context: WorldContext = WorldManager.context_for(attacker) if attacker else WorldManager.context()
	var parent: Node = _parent_for(context, attacker)
	var space: PhysicsDirectSpaceState3D = _space_of(parent)
	# The air first, so a cloud the ground gives off now (steam off water
	# under fire) isn't touched by the same attack.
	_touch_clouds(element, ability, attacker, target, context, parent, space)
	var grid: SurfaceGrid = _grid_for(context)
	if grid.is_empty():
		return
	var reached: Dictionary = {}
	var position: Vector3
	var radius: float = 0.0
	if target is Unit:
		position = target.global_position
		radius = target.radius
		reached = _footprint_cells(grid, position, radius)
	elif target is Vector3:
		position = target
		var cone := ability.targeting as ConeTargeting
		var area := ability.targeting as AreaTargeting
		if cone:
			position = cone.origin(attacker)
			radius = cone.length
			reached = _cone_cells(space, position, cone.direction(attacker, target), cone.length, cone.half_angle())
		elif area is AerialAreaTargeting:
			radius = area.radius
			reached = _burst_cells(space, position, radius)
		elif area:
			radius = area.radius
			reached = _spill_cells(space, position, radius)
		else:
			# A single-target attack at the ground (Fire Bolt at a patch
			# of grease): the spot it struck. One cell is enough - a
			# spreading reaction floods the rest.
			radius = POINT_TOUCH_RADIUS
			reached = _footprint_cells(grid, position, radius)
	if reached.is_empty():
		return
	_land_turned(_react(element, null, reached, grid), context, parent, position, radius)


## touch() in the air: every cloud an attack of element reached reacts by
## its SurfaceReaction to that element (Surface.reactions, as on the
## ground) — lightning through steam electrifies it. Only BECOMES does
## anything to a cloud (nothing of the element is left in the air for
## TAKEN to land), and with spreads it runs through every touching cube
## of that cloud, so one cube reached is enough. What a cloud becomes is
## another cloud in its cubes, or nothing (cleared).
func _touch_clouds(element: Surface.Element, ability: Ability, attacker: Unit, target, context: WorldContext, parent: Node, space: PhysicsDirectSpaceState3D) -> void:
	var grid: CloudGrid = _clouds_for(context)
	if grid.is_empty():
		return
	var reach: Dictionary = _cloud_reach(grid, ability, attacker, target)
	var exclude: Array[RID] = []
	if space and reach.sight_from != null:
		for unit in UnitQuery.all_units(get_tree()):
			exclude.append(unit.get_rid())
	var done: Dictionary = {}  # Vector3i -> true: cubes already reacted
	for cell: CloudCell in reach.cells:
		if done.has(cell.key) or grid.cells.get(cell.key) != cell:
			continue
		var reaction: SurfaceReaction = cell.surface.reaction_to(element)
		if reaction == null or reaction.outcome != SurfaceReaction.Outcome.BECOMES:
			continue
		if space and reach.sight_from != null:
			var ray := PhysicsRayQueryParameters3D.create(reach.sight_from, cell.centre(), 1, exclude)
			if not space.intersect_ray(ray).is_empty():
				continue
		var cubes: Array[CloudCell] = [cell]
		if reaction.spreads:
			cubes = _cloud_through(grid, cell)
		for cube in cubes:
			done[cube.key] = true
		var becomes: Surface = reaction.becomes_surface()
		if becomes and becomes.shape == Surface.Shape.DISC:
			push_warning("SurfaceManager: a cloud can't become a ground surface (%s)" % becomes.surface_name)
			continue
		if becomes == null:
			var by_patch: Dictionary = {}  # CloudPatch -> Array[CloudCell]
			for cube in cubes:
				if not by_patch.has(cube.patch):
					var list: Array[CloudCell] = []
					by_patch[cube.patch] = list
				by_patch[cube.patch].append(cube)
			for patch: CloudPatch in by_patch:
				expire_cloud_cells(grid, patch, by_patch[patch])
			continue
		# The struck cube first: the new cloud thickens in from there.
		var seeds: Dictionary[Vector3i, Vector3] = {cell.key: cell.centre()}
		for cube in cubes:
			seeds[cube.key] = cube.centre()
		_play_spawn_fx(becomes, parent, cell.centre())
		_fill(becomes, seeds, func(point: Vector3) -> bool: return seeds.has(CloudGrid.key_of(point)),
				cell.centre(), context, parent, Callable(), true)


## The cloud cubes an attack reached (_touch_clouds), as {cells:
## Array[CloudCell], sight_from: Vector3 or null}: a cone's cubes or a
## blast's, each only if a ray from sight_from to it is clear (walls
## shadow them, as they do the ground); for a single-target attack the
## cubes along the shot, from the attacker's eye to where it landed — a
## bolt fired through steam reaches it with its target outside — and
## those round the target's body. The shot's own line is clear by
## construction, so it needs no sight test.
func _cloud_reach(grid: CloudGrid, ability: Ability, attacker: Unit, target) -> Dictionary:
	var cells: Array[CloudCell] = []
	var cone := ability.targeting as ConeTargeting if ability else null
	var area := ability.targeting as AreaTargeting if ability else null
	var point: Vector3 = target.global_position if target is Unit else (target if target is Vector3 else Vector3.ZERO)
	var half_cube: float = CloudGrid.CELL * 0.87
	if cone and attacker:
		var apex: Vector3 = cone.origin(attacker)
		var aim: Vector3 = cone.direction(attacker, point)
		var half: float = cone.half_angle()
		for cell: CloudCell in grid.cells.values():
			var to: Vector3 = cell.centre() - apex
			var dist: float = to.length()
			if dist - half_cube > cone.length:
				continue
			if dist > half_cube and aim.angle_to(to) > half + asin(half_cube / dist):
				continue
			cells.append(cell)
		return {cells = cells, sight_from = apex}
	if area:
		# Lifted a little, as _burst_cells sees the floor round a burst.
		var centre: Vector3 = point + Vector3.UP * 0.3
		for cell: CloudCell in grid.cells.values():
			if cell.centre().distance_to(centre) <= area.radius + half_cube:
				cells.append(cell)
		return {cells = cells, sight_from = centre}
	if attacker and (target is Unit or target is Vector3):
		cells.append_array(grid.cells_along(LineOfSight.shot_from(attacker), LineOfSight.shot_to(target)))
	if target is Unit:
		cells.append_array(grid.cells_touching(target.global_position, target.anchor(CharacterModel.Anchor.EYE), target.radius))
	elif target is Vector3:
		var struck: CloudCell = grid.cell_at(point)
		if struck:
			cells.append(struck)
	return {cells = cells, sight_from = null}


## Every cube of start's cloud joined to it face to face: the whole
## connected cloud, however many casts filled it.
func _cloud_through(grid: CloudGrid, start: CloudCell) -> Array[CloudCell]:
	var found: Array[CloudCell] = [start]
	var seen: Dictionary = {start.key: true}
	var i: int = 0
	while i < found.size():
		var key: Vector3i = found[i].key
		i += 1
		for step in CloudGrid.NEIGHBOURS:
			var next: Vector3i = key + step
			if seen.has(next):
				continue
			seen[next] = true
			var beside: CloudCell = grid.cells.get(next)
			if beside and beside.surface == start.surface:
				found.append(beside)
	return found


## The cells (SurfaceGrid key -> floor y) on the ground under a footprint
## of radius round feet, as surfaces_under reads them.
func _footprint_cells(grid: SurfaceGrid, feet: Vector3, radius: float) -> Dictionary:
	var reached: Dictionary = {}
	var reach := Vector3(radius, 0.0, radius)
	var low: Vector2i = SurfaceGrid.key_of(feet - reach)
	var high: Vector2i = SurfaceGrid.key_of(feet + reach)
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			var cell: SurfaceCell = grid.cell_at(Vector2i(x, z), feet.y)
			if cell == null:
				continue
			var near := Vector2(clampf(feet.x, x * SurfaceGrid.CELL, (x + 1) * SurfaceGrid.CELL),
					clampf(feet.z, z * SurfaceGrid.CELL, (z + 1) * SurfaceGrid.CELL))
			if near.distance_to(Vector2(feet.x, feet.z)) <= radius:
				reached[cell.key] = cell.y
	return reached


## The floor cells (SurfaceGrid key -> floor y) a cone from apex washes
## over, as spawn_cone lays them. Empty with no physics space.
func _cone_cells(space: PhysicsDirectSpaceState3D, apex: Vector3, direction: Vector3, length: float, half_angle: float) -> Dictionary:
	var reached: Dictionary = {}
	if not space:
		return reached
	var exclude: Array[RID] = []
	for unit in UnitQuery.all_units(get_tree()):
		exclude.append(unit.get_rid())
	# The highest the cone reaches, so a floor under any of it is found
	# from above and a ceiling over the apex is not mistaken for one.
	var top: float = apex.y + maxf(0.0, length * sin(asin(clampf(direction.y, -1.0, 1.0)) + half_angle)) + 0.1
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
	return reached


## Lays a ground surface (Explosive Fireball's burning ground) wherever a
## blast sphere of radius round centre reaches the floor: every cell whose
## floor is within radius of centre with no wall between, the same shadow
## the blast's damage casts. A burst on the ground burns a full patch, one
## in the air a smaller one the higher it is, and one higher than radius
## none. It spreads out from centre, or, given front_seconds, with a front
## reaching radius in that long (see DecalSurface.show_cells). Returns its
## SurfacePatch, or null if the blast touches no floor.
func spawn_burst(surface: Surface, centre: Vector3, radius: float, caster: Node = null, front_seconds: float = 0.0) -> SurfacePatch:
	var context: WorldContext = WorldManager.context_for(caster) if caster else WorldManager.context()
	var parent: Node = _parent_for(context, caster)
	var reached: Dictionary = _burst_cells(_space_of(parent), centre, radius)
	if reached.is_empty():
		return null
	return _land(surface, reached, context, parent, centre, radius, 0, front_seconds)


## The floor cells (SurfaceGrid key -> floor y) a blast round centre
## reaches, as spawn_burst lays them. Empty with no physics space.
func _burst_cells(space: PhysicsDirectSpaceState3D, centre: Vector3, radius: float) -> Dictionary:
	var reached: Dictionary = {}
	if not space:
		return reached
	var exclude: Array[RID] = []
	for unit in UnitQuery.all_units(get_tree()):
		exclude.append(unit.get_rid())
	# Lifted a little, so a burst on the ground sees the floor round it
	# rather than grazing it.
	var eye: Vector3 = centre + Vector3.UP * 0.3
	var low: Vector2i = SurfaceGrid.key_of(centre - Vector3(radius, 0.0, radius))
	var high: Vector2i = SurfaceGrid.key_of(centre + Vector3(radius, 0.0, radius))
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			var key := Vector2i(x, z)
			var column: Vector3 = SurfaceGrid.centre_of(key, centre.y)
			if Vector2(column.x - centre.x, column.z - centre.z).length() > radius:
				continue
			var down := PhysicsRayQueryParameters3D.create(column + Vector3.UP * 0.5, column + Vector3.DOWN * radius, 1, exclude)
			var hit: Dictionary = space.intersect_ray(down)
			if hit.is_empty() or hit.normal.y < FLOOR_NORMAL:
				continue
			var floor_point: Vector3 = hit.position + Vector3.UP * 0.05
			if floor_point.distance_to(centre) > radius:
				continue
			var sight := PhysicsRayQueryParameters3D.create(eye, floor_point, 1, exclude)
			if not space.intersect_ray(sight).is_empty():
				continue
			reached[key] = hit.position.y
	return reached


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
##
## A solid cloud (blocks_movement: a frozen Wall of Water) is rock to a
## gas: a fill neither floods into its cubes nor takes them, so fog cast
## over ice leaves the ice. A reaction turning those very cubes into
## something else (_touch_clouds: fire melting the ice) passes
## may_take_solid.
func _fill(surface: Surface, seeds: Dictionary[Vector3i, Vector3], inside: Callable, position: Vector3, context: WorldContext, parent: Node, point_of: Callable = Callable(), may_take_solid: bool = false) -> CloudPatch:
	var grid: CloudGrid = _clouds_for(context)
	var space: PhysicsDirectSpaceState3D = _space_of(parent)
	var exclude: Array[RID] = []
	for unit in UnitQuery.all_units(get_tree()):
		exclude.append(unit.get_rid())
	var solid := func(key: Vector3i) -> bool:
		if may_take_solid:
			return false
		var held: CloudCell = grid.cells.get(key)
		return held != null and held.surface != surface and held.surface.blocks_movement

	var start: Vector3i = seeds.keys()[0]
	var reached: Dictionary[Vector3i, bool] = {}
	var frontier: Array[Vector3i] = []
	var buried: Array[Vector3i] = []
	for key: Vector3i in seeds:
		if solid.call(key):
			buried.append(key)
			continue
		reached[key] = true
		frontier.append(key)
	# Let out inside the solid (fog aimed at the ice): it comes out at the
	# solid's surface, every free cube of the shape touching it from the
	# buried seeds' side.
	var dug: Dictionary[Vector3i, bool] = {}
	while not buried.is_empty():
		var key: Vector3i = buried.pop_front()
		dug[key] = true
		for step in CloudGrid.NEIGHBOURS:
			var next: Vector3i = key + step
			if dug.has(next) or reached.has(next) or not inside.call(CloudGrid.centre_of(next)):
				continue
			if solid.call(next):
				dug[next] = true
				buried.append(next)
			else:
				reached[next] = true
				frontier.append(next)
	while not frontier.is_empty():
		var key: Vector3i = frontier.pop_front()
		var from: Vector3 = seeds.get(key, _fill_point(key, point_of))
		for step in CloudGrid.NEIGHBOURS:
			var next: Vector3i = key + step
			if reached.has(next):
				continue
			if not inside.call(CloudGrid.centre_of(next)) or solid.call(next):
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
	_sync_barrier(patch, parent)
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
	return _land(surface, _spill_cells(_space_of(parent), position, radius), context, parent, position, radius)


## The floor cells (SurfaceGrid key -> floor y) a liquid poured at
## position reaches within radius, as _spill lays them.
func _spill_cells(space: PhysicsDirectSpaceState3D, position: Vector3, radius: float) -> Dictionary:
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
	return reached


## Lands reached (SurfaceGrid key -> its floor y) on the grid as surface:
## cells of another surface are overwritten, cells of this one topped up
## to the longer time, and every patch of this surface the new cells
## overlap or touch merges into the biggest. position and radius are
## where the visual spreads from and how far. extra_rounds lengthens the
## surface's own duration_rounds; negative makes it permanent.
##
## First, what's already there reacts to the landing surface's element
## (_react): fire spreads through the grease it touches, ice it touches
## turns to water, water it touches won't take it. Returns null if
## nothing of surface landed (fire poured wholly on water).
func _land(surface: Surface, reached: Dictionary, context: WorldContext, parent: Node, position: Vector3, radius: float, extra_rounds: int = 0, front_seconds: float = 0.0) -> SurfacePatch:
	var grid: SurfaceGrid = _grid_for(context)
	var cast: int = reached.size()
	_land_turned(_react(surface.element, surface, reached, grid), context, parent, position, radius, front_seconds)
	if reached.is_empty():
		return null
	if reached.size() > cast:
		# A reaction carried the surface past where it was cast (through
		# the whole grease patch): its film spreads that far.
		for key: Vector2i in reached:
			radius = maxf(radius, SurfaceGrid.centre_of(key, position.y).distance_to(position))
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


## Lands what a reaction turned the ground into (_react's result: Surface
## -> its reached): a ground surface onto those cells (_land), a cloud
## rising off them (_rise). position, radius and front_seconds as for
## _land; a cloud only gathers, so it takes none of them.
func _land_turned(turned: Dictionary, context: WorldContext, parent: Node, position: Vector3, radius: float, front_seconds: float = 0.0) -> void:
	for result: Surface in turned:
		if result.shape == Surface.Shape.DISC:
			_land(result, turned[result], context, parent, position, radius, 0, front_seconds)
		else:
			_rise(result, turned[result], context, parent)


## Raises cloud (steam) off the ground cells in reached (SurfaceGrid key
## -> floor y): the cubes over each cell, from its floor up to the
## cloud's wall_height, filled the way any cloud fills (_fill), so a
## ceiling lower than that stops it. The cloud grid's cubes are the
## surface grid's squares, so each cell is one column. _react has already
## cleared the cells. Returns its CloudPatch.
func _rise(cloud: Surface, reached: Dictionary, context: WorldContext, parent: Node) -> CloudPatch:
	var middle := Vector3.ZERO
	var seeds: Dictionary[Vector3i, Vector3] = {}
	for key: Vector2i in reached:
		var lifted: Vector3 = SurfaceGrid.centre_of(key, reached[key] + 0.1)
		seeds[CloudGrid.key_of(lifted)] = lifted
		middle += SurfaceGrid.centre_of(key, reached[key])
	middle /= reached.size()
	_play_spawn_fx(cloud, parent, middle)
	return _fill(cloud, seeds, _over_ground.bind(reached, cloud.wall_height), middle, context, parent, _ground_point.bind(reached))


## Whether the cube centred on point stands over one of the ground cells
## in reached (key -> floor y), its height overlapping that floor up to
## height.
func _over_ground(point: Vector3, reached: Dictionary, height: float) -> bool:
	var column: Vector2i = SurfaceGrid.key_of(point)
	if not reached.has(column):
		return false
	var ground: float = reached[column]
	var half: float = CloudGrid.CELL * 0.5
	return point.y + half > ground and point.y - half < ground + height


## Where a cloud rising off the ground passes through the cube at key:
## its centre, lifted clear of the floor where the cube straddles it, as
## _wall_point does for a wall.
func _ground_point(key: Vector3i, reached: Dictionary) -> Vector3:
	var centre: Vector3 = CloudGrid.centre_of(key)
	var column := Vector2i(key.x, key.z)
	if reached.has(column):
		centre.y = maxf(centre.y, reached[column] + 0.1)
	return centre


## What the ground already in reached (SurfaceGrid key -> floor y) does
## as something of element reaches it, by its SurfaceReaction to that
## element: landing, the surface landing there (null for an attack that
## only touches the ground, see touch()). Edits reached in place: cells
## that resist or turn into something else come out of it, and cells a
## TAKEN reaction spreads through (the rest of a grease patch) go into
## it. A cell that BECOMES the very surface landing is just taken by it.
## Cells a BECOMES reaction clears, or turns into a cloud rising off
## them, are expired here. Returns what the rest turn into: Surface ->
## its own reached, to be landed in turn (_land_turned).
func _react(element: Surface.Element, landing: Surface, reached: Dictionary, grid: SurfaceGrid) -> Dictionary:
	var turned: Dictionary = {}
	if element == Surface.Element.NONE:
		return turned
	var cleared: Dictionary = {}  # SurfacePatch -> Array[SurfaceCell]
	var frontier: Array[SurfaceCell] = []
	var into: Dictionary = {}  # SurfaceCell spreading -> the reached it spreads into
	for key: Vector2i in reached.keys():
		var cell: SurfaceCell = grid.cell_at(key, reached[key])
		if cell == null or (landing and cell.surface == landing):
			continue
		var reaction: SurfaceReaction = cell.surface.reaction_to(element)
		if reaction == null:
			continue
		var target: Dictionary = reached
		match reaction.outcome:
			SurfaceReaction.Outcome.RESISTS:
				reached.erase(key)
				continue
			SurfaceReaction.Outcome.BECOMES:
				var becomes: Surface = reaction.becomes_surface()
				if landing and becomes == landing:
					# Grease becoming the fire landing on it: just taken.
					if reaction.spreads:
						frontier.append(cell)
						into[cell] = reached
					continue
				reached.erase(key)
				if becomes == null:
					if not cleared.has(cell.patch):
						cleared[cell.patch] = [] as Array[SurfaceCell]
					cleared[cell.patch].append(cell)
					continue
				if not turned.has(becomes):
					turned[becomes] = {}
				target = turned[becomes]
				target[key] = cell.y
		if reaction.spreads:
			frontier.append(cell)
			into[cell] = target
	# Through every touching cell of the same surface, from those reached.
	while not frontier.is_empty():
		var cell: SurfaceCell = frontier.pop_back()
		var target: Dictionary = into[cell]
		for step in SurfaceGrid.NEIGHBOURS:
			var beside: SurfaceCell = grid.cell_at(cell.key + step, cell.y)
			if beside == null or beside.surface != cell.surface or into.has(beside):
				continue
			if reached.has(beside.key) or target.has(beside.key):
				continue
			into[beside] = target
			frontier.append(beside)
			target[beside.key] = beside.y
	# A cloud rising off cells (steam off water) leaves the floor bare.
	for result: Surface in turned:
		if result.shape == Surface.Shape.DISC:
			continue
		for key: Vector2i in turned[result]:
			var cell: SurfaceCell = grid.cell_at(key, turned[result][key])
			if cell == null:
				continue
			if not cleared.has(cell.patch):
				cleared[cell.patch] = [] as Array[SurfaceCell]
			cleared[cell.patch].append(cell)
	for patch: SurfacePatch in cleared:
		expire_cells(grid, patch, cleared[patch])
	return turned


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
	var found: Array[Surface] = surfaces_under(unit)
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
func surfaces_under(unit: Unit) -> Array[Surface]:
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


## Whether point in context is on element: a ground patch of it, or for
## SHADOW, shade (Shadows). The question a step between surfaces asks.
func element_at(element: Surface.Element, point: Vector3, context: WorldContext) -> bool:
	if element == Surface.Element.SHADOW:
		return Shadows.is_shadowed(point, context)
	var surface: Surface = surface_at(point, context)
	return surface != null and surface.element == element


## Whether unit stands on element, as element_at. Shade is read at the feet.
func stands_on_element(unit: Unit, element: Surface.Element) -> bool:
	if element == Surface.Element.SHADOW:
		return Shadows.is_shadowed(unit.global_position, WorldManager.context_for(unit))
	for surface in surfaces_under(unit):
		if surface.element == element:
			return true
	return false


## Takes surface's inside-only statuses off unit, each unless one of the
## surfaces still holding them (`still`) gives the same status.
func _release(unit: Unit, surface: Surface, still: Array[Surface]) -> void:
	if not surface.status_only_inside:
		return
	for effect in surface.status_effects:
		var held: bool = false
		for other in still:
			if other.status_effects.has(effect):
				held = true
				break
		if not held:
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


## The to-hit modifier for a ranged shot from from to to: the worst (most
## negative) ranged_penalty of any cloud cube on the line in viewer's
## world, once however many cubes it crosses. 0 if none.
func ranged_penalty_between(viewer: Node, from: Vector3, to: Vector3) -> int:
	var worst: int = 0
	for cell in _clouds_for(WorldManager.context_for(viewer)).cells_along(from, to):
		worst = mini(worst, cell.surface.ranged_penalty)
	return worst


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
	_sync_barrier(patch, null)
	if patch.visual == null or not is_instance_valid(patch.visual):
		return
	if patch.cells.is_empty() and patch.visual.has_method("dissipate"):
		patch.visual.dissipate()
	elif patch.visual.has_method("recede_cubes"):
		patch.visual.recede_cubes(cells)
	elif patch.cells.is_empty():
		patch.visual.queue_free()


## Rebuilds patch's barrier over the cubes it holds now (a blocks_movement
## cloud only): one box per column of cubes, floor to top, and has the
## navigation grid re-bake where the old one stood and the new one stands.
## The old body leaves the tree before the grid looks, so it never keeps a
## pointer to a freed shape. parent is where a first barrier goes. Anyone
## standing where it now stands is put out of it (_put_out).
func _sync_barrier(patch: CloudPatch, parent: Node) -> void:
	if not patch.surface.blocks_movement:
		return
	var region := AABB()
	var changed: bool = false
	var old: StaticBody3D = patch.barrier if is_instance_valid(patch.barrier) else null
	patch.barrier = null
	if old:
		region = _barrier_box(old)
		changed = true
		parent = old.get_parent()
		parent.remove_child(old)
		old.queue_free()
	if not patch.cells.is_empty() and parent:
		var columns: Dictionary[Vector2i, Vector2i] = {}  # column -> lowest, highest key.y
		for cell in patch.cells:
			var column := Vector2i(cell.key.x, cell.key.z)
			var span: Vector2i = columns.get(column, Vector2i(cell.key.y, cell.key.y))
			columns[column] = Vector2i(mini(span.x, cell.key.y), maxi(span.y, cell.key.y))
		var body := StaticBody3D.new()
		body.name = "Barrier"
		body.collision_layer = BARRIER_LAYER
		body.collision_mask = 0
		parent.add_child(body)
		body.global_transform = Transform3D.IDENTITY
		for column: Vector2i in columns:
			var span: Vector2i = columns[column]
			var low := Vector3(column.x, span.x, column.y) * CloudGrid.CELL
			var high := Vector3(column.x + 1, span.y + 1, column.y + 1) * CloudGrid.CELL
			var box := BoxShape3D.new()
			box.size = high - low
			var shape := CollisionShape3D.new()
			shape.shape = box
			shape.position = (low + high) * 0.5
			body.add_child(shape)
		patch.barrier = body
		var box: AABB = _barrier_box(body)
		region = region.merge(box) if changed else box
		changed = true
	if changed:
		var root: Node = patch.context.world_root if patch.context and patch.context.world_root else parent
		NavigationGrid.invalidate_region(root, region)
	if patch.barrier:
		_put_out(patch)


## Moves every walker whose footprint is in patch's barrier (a wave freezing
## round someone standing in it) to the nearest spot it can stand, which the
## navigation grid, re-baked round the barrier, knows. A flier hovers over
## or beside it and is left alone; one with nowhere to go stays put.
func _put_out(patch: CloudPatch) -> void:
	var body: StaticBody3D = patch.barrier
	for unit in UnitQuery.all_units(get_tree()):
		if unit.is_flying() or (patch.context and not patch.context.contains(unit)):
			continue
		var feet: Vector3 = unit.global_position
		var caught: bool = false
		for shape: CollisionShape3D in body.get_children():
			var half: Vector3 = (shape.shape as BoxShape3D).size * 0.5
			var centre: Vector3 = body.global_transform * shape.position
			var off: Vector3 = (feet - centre).abs()
			if off.x < half.x + unit.radius and off.z < half.z + unit.radius and feet.y > centre.y - half.y - 0.5 and feet.y < centre.y + half.y:
				caught = true
				break
		if not caught:
			continue
		var clearance: float = unit.radius + unit.avoidance_margin
		var snap: Dictionary = NavigationGrid.nearest_valid_point(get_tree(), feet, clearance, false, unit)
		if snap.found:
			unit.global_position = snap.point


func _barrier_box(body: StaticBody3D) -> AABB:
	var box := AABB()
	for shape: CollisionShape3D in body.get_children():
		var size: Vector3 = (shape.shape as BoxShape3D).size
		var one := AABB(body.global_transform * shape.position - size * 0.5, size)
		box = one if box.size == Vector3.ZERO else box.merge(one)
	return box


## Every cell runs out on its own clock; a patch loses the cells that ran
## out, which recede from its film, and goes when it has none left. What
## a surface leaves behind (leaves_behind) lands on its run-out cells
## after the whole grid has aged, so it keeps its whole duration and no
## patch it merges into is aged twice.
func _age_grid(grid: SurfaceGrid) -> void:
	var settling: Array[Array] = []  # [SurfacePatch, its run-out cells]
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
			if patch.surface.leaves_behind:
				settling.append([patch, ran_out])
	for each: Array in settling:
		_settle(each[0], each[1])


## Lands patch's leaves_behind on the floor where its cells ran out:
## electrified water settling back into plain water.
func _settle(patch: SurfacePatch, cells: Array[SurfaceCell]) -> void:
	var reached: Dictionary = {}
	for cell in cells:
		reached[cell.key] = cell.y
	var middle: Vector3 = patch.centroid(cells)
	var radius: float = 0.0
	for cell in cells:
		radius = maxf(radius, cell.centre().distance_to(middle))
	_land(patch.surface.leaves_behind, reached, patch.context, _parent_for(patch.context, null), middle, radius + SurfaceGrid.CELL)


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
		if _sees_through(unit, surface):
			continue
		for effect in surface.status_effects:
			if effect == null or found.has(effect):
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
