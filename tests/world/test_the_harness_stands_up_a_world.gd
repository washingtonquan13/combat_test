extends AiTestCase
## The harness can stand up a real world — and this is what proves it.
##
## Every other suite in this project runs against a bare Node3D and a
## floor, with no world loaded at all. That is cheap and it is honest for
## what those suites test, but it means every branch in the codebase that
## reads WorldManager takes its "nothing is loaded" fallback, forever.
## SurfaceManager hands back its detached array. CombatManager answers
## from nowhere. WorldContext is null, so the one assertion in
## test_world_scoping that checks the managers really do delegate is
## early-returned past — its own comment says so.
##
## So AiTestCase now has wants_world(), and this suite is the proof that
## what it stands up is a world rather than a plausible-looking shell.
## Each check below is a separate claim about that, because "the world
## loaded" is not one fact:
##
##   1. there is a context at all;
##   2. a unit spawned by the harness is INSIDE it (the trap: parenting
##      into _root while a world is loaded puts units outside the
##      viewport that mints the World3D, and every world-scoped query
##      would then be right to ignore them);
##   3. SurfaceManager's array is the context's array, by IDENTITY — not
##      merely non-null, which the detached fallback satisfies too;
##   4. the navigation grid bakes the fixture's floor;
##   5. spawn points resolve to the marker rather than to the origin.
##
## (5) is here because of what happened without it. Disabling spawn-point
## resolution outright — `if false:` at the head of
## WorldManager._resolve_spawn_point — left an earlier draft of this suite
## entirely green: the fixture's marker was authored at the origin, so
## "resolved correctly" and "fell back to the world root" were the same
## coordinates. The marker sits at (7, 0.5, -4) for that reason alone.

const MARKER := Vector3(7.0, 0.5, -4.0)
## Both on the fixture's floor and a comfortable walk apart, so an empty
## route means the grid did not bake rather than that the endpoints were
## unreachable.
const FROM := Vector3(-6.0, 0.0, 0.0)
const TO := Vector3(6.0, 0.0, 0.0)

var _walker: Unit = null


func wants_world() -> bool:
	return true


func run() -> void:
	var context: WorldContext = WorldManager.context()
	check("the harness stands up a world with a real context",
		context != null,
		"WorldManager.context() is null — wants_world() did not load the "
			+ "fixture, and every check below is testing the no-world "
			+ "fallback it exists to get past")
	if context == null:
		return

	_a_spawned_unit_lands_in_it(context)
	_the_managers_really_delegate(context)
	await _the_grid_bakes_the_fixture_floor()
	await _spawn_points_resolve_to_the_marker()


## The unit has to be in the world's World3D, not merely alive. This is
## the check that would have caught spawn_unit() still parenting into
## _root: everything else about such a unit works perfectly, and only a
## world-scoped query can tell.
func _a_spawned_unit_lands_in_it(context: WorldContext) -> void:
	var brute: Unit = spawn_brute(0.0, 0.0)
	_walker = brute
	check("a unit the harness spawns lands inside the loaded world",
		brute.get_world_3d() == context.world_3d,
		"the unit's World3D is not the context's — it was parented outside "
			+ "the viewport that mints one")
	check("and the context agrees that it holds that unit",
		context.contains(brute),
		"WorldContext.contains() says no, which is what every world-scoped "
			+ "query in the game asks")


## By IDENTITY. `!= null` passes against the detached fallback too, which
## is precisely the state this whole exercise exists to stop testing.
func _the_managers_really_delegate(context: WorldContext) -> void:
	check("SurfaceManager reads the loaded world's own surface list, not a "
			+ "detached one",
		is_same(SurfaceManager.active_surfaces, context.surfaces),
		"active_surfaces is a different array object from context.surfaces "
			+ "— the getter is answering from _detached_surfaces with a "
			+ "world loaded")
	check("CombatManager reads the loaded world's own encounter list",
		is_same(CombatManager.encounters, context.encounters),
		"encounters is a different array object from context.encounters")


## The open question an earlier plan for this could not settle: does the
## grid bake a world mounted inside WorldManager's viewport the way it
## bakes one built by hand? Two physics frames and an invalidate() first,
## the same preparation tests/world/test_nav_grid_worlds.gd gives its own
## authored-area case.
func _the_grid_bakes_the_fixture_floor() -> void:
	NavigationGrid.invalidate()
	await get_tree().physics_frame
	await get_tree().physics_frame

	var route: PackedVector3Array = NavigationGrid.find_path(
		get_tree(), FROM, TO, _walker, false)
	check("the navigation grid bakes the fixture floor inside the world's "
			+ "viewport",
		route.size() > 0,
		"empty route between %s and %s on a 400x400 floor — the grid does "
			% [FROM, TO]
			+ "not see geometry mounted in a WorldManager SubViewport")


## Re-enters the fixture naming a spawn point explicitly, then asks
## WorldManager to resolve it the way _embody_into does.
##
## Asked through _resolve_spawn_point rather than through the party,
## because the fixture deliberately does not spawn a party (see
## test_world_area.gd) — and because that function IS the thing under
## test: it is where the sabotage that left this suite green went.
func _spawn_points_resolve_to_the_marker() -> void:
	WorldManager.load_world(WORLD_FIXTURE_SCENE, &"PartySpawnPoint", WORLD_FIXTURE_AREA)
	await get_tree().process_frame

	check("re-entering the fixture carries the requested spawn point",
		WorldManager.pending_spawn_point_name() == &"PartySpawnPoint",
		"pending spawn point is '%s'" % WorldManager.pending_spawn_point_name())

	var world: Node = WorldManager.current_world()
	var point: Node3D = WorldManager._resolve_spawn_point(
		world, WorldManager.pending_spawn_point_name())
	var where: Vector3 = point.global_position if point else Vector3.INF
	check("and the named spawn point resolves to the marker, not to the "
			+ "world origin",
		point != null and where.distance_to(MARKER) <= 0.5,
		"resolved to %s, expected %s. %s means resolution fell through to "
			% [where, MARKER, Vector3.ZERO]
			+ "the world root — the marker is off-origin precisely so that "
			+ "fallback is distinguishable from a correct answer")
