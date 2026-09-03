extends AiTestCase
## Cross-world isolation, proven with two live World3Ds.
##
## The game runs one world, so world filtering is a no-op in it — which is
## exactly why this suite exists. A filter that never filters, or one that
## filters everything away, passes every other test in the project
## identically. Nothing else here can tell the difference.
##
## So this builds two SubViewports with own_world_3d, puts units in each,
## and asserts they cannot see one another. When a later pass makes worlds
## genuinely simultaneous, it inherits a verified mechanism rather than a
## hypothesis.


var _viewport_a: SubViewport
var _viewport_b: SubViewport
var _a1: Unit
var _a2: Unit
var _b1: Unit
var _b2: Unit


## Opted in so _managers_delegate_to_the_context() below finally runs its
## real branch. Its no-world half was never wrong, it was just the only
## half that ever executed: headless runs load no world, so the two lines
## asserting that SurfaceManager and CombatManager read THROUGH the
## context were dead code guarded by an early return. The two SubViewports
## this suite builds are its own and are unaffected by a world being
## loaded alongside them.
func wants_world() -> bool:
	return true


func run() -> void:
	await _build_two_worlds()
	if _a1 == null:
		check("SETUP: two worlds built", false, "viewport setup failed")
		return

	_worlds_are_actually_distinct()
	_scoped_queries_stay_home()
	_targeting_never_crosses()
	_allies_and_areas_stay_home()
	_global_forms_still_see_everything()
	_context_owns_world_state()
	_managers_delegate_to_the_context()
	_nav_grid_is_owned_by_the_context()

	_teardown_worlds()


## Two SubViewports, each with its own World3D, each holding two units at
## IDENTICAL coordinates. Same coordinates on purpose: every area in this
## project is authored around the origin, so two live worlds genuinely do
## overlap in raw position. Any filter that quietly used distance instead
## of world identity would pass with separated coordinates and fail here.
func _build_two_worlds() -> void:
	_viewport_a = _make_world_viewport()
	_viewport_b = _make_world_viewport()
	await get_tree().process_frame
	await get_tree().physics_frame

	_a1 = _spawn_in(_viewport_a, &"player", Vector3(0.0, 0.0, 0.0))
	_a2 = _spawn_in(_viewport_a, &"enemy", Vector3(6.0, 0.0, 0.0))
	_b1 = _spawn_in(_viewport_b, &"player", Vector3(0.0, 0.0, 0.0))
	_b2 = _spawn_in(_viewport_b, &"enemy", Vector3(1.0, 0.0, 0.0))
	await get_tree().physics_frame


func _make_world_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	_root.add_child(viewport)
	return viewport


func _spawn_in(viewport: SubViewport, faction: StringName, position: Vector3) -> Unit:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	viewport.add_child(unit)
	unit.faction = faction
	unit.strength = 12
	unit.dexterity = 12
	unit.maximum_hp = 20
	unit.current_hp = 20
	var abilities: Array[Ability] = [melee()]
	unit.abilities = abilities
	unit.global_position = position
	unit.reset_turn_actions()
	return unit


func _worlds_are_actually_distinct() -> void:
	check("the two viewports really do have separate World3Ds",
		_a1.get_world_3d() != _b1.get_world_3d())
	check("units within one viewport share a World3D",
		_a1.get_world_3d() == _a2.get_world_3d())
	# If this fails, every other check below is vacuous.
	check("both worlds are populated",
		_a1.is_inside_tree() and _b1.is_inside_tree())


func _scoped_queries_stay_home() -> void:
	var from_a: Array[Unit] = UnitQuery.living_units_near(_a1)
	var from_b: Array[Unit] = UnitQuery.living_units_near(_b1)

	check("living_units_near sees its own world",
		from_a.has(_a1) and from_a.has(_a2))
	check("living_units_near does NOT see the other world",
		not from_a.has(_b1) and not from_a.has(_b2),
		"leaked %d" % from_a.size())
	check("and symmetrically from the other side",
		from_b.has(_b1) and from_b.has(_b2) and not from_b.has(_a1))

	var all_a: Array[Unit] = UnitQuery.all_units_near(_a1)
	check("all_units_near is scoped too",
		all_a.has(_a2) and not all_a.has(_b2))


## The case that would silently make an AI attack across worlds: the
## other world's enemy is CLOSER in raw coordinates than its own.
func _targeting_never_crosses() -> void:
	check("setup: the foreign enemy really is nearer",
		_a1.global_position.distance_to(_b2.global_position)
			< _a1.global_position.distance_to(_a2.global_position))

	var target: Unit = UnitQuery.nearest_hostile(_a1.get_tree(), _a1)
	check("nearest_hostile picks its own world's enemy, not the closer foreign one",
		target == _a2, "picked %s" % ("foreign" if target == _b2 else str(target)))


func _allies_and_areas_stay_home() -> void:
	var allies: Array[Unit] = UnitQuery.living_allies(_a1.get_tree(), _a1)
	check("living_allies does not adopt the other world's ally",
		not allies.has(_b1), "found %d allies" % allies.size())

	# A blast centred on the shared origin would catch both worlds' units
	# if area effects weren't scoped — the most damaging possible leak.
	var caught: Array[Unit] = UnitQuery.area_affected(
		_a1.get_tree(), _a1, Vector3.ZERO, 50.0, true, true)
	check("area_affected cannot splash into another world",
		not caught.has(_b1) and not caught.has(_b2),
		"caught %d" % caught.size())
	check("but it does catch its own world's units", caught.has(_a2))


## Scoping is opt-in. The camera, drag-select, the demon roster and area
## teardown all legitimately want every unit that exists.
func _global_forms_still_see_everything() -> void:
	var everything: Array[Unit] = UnitQuery.living_units(_a1.get_tree())
	check("the plain tree-taking form still spans worlds",
		everything.has(_a1) and everything.has(_b1),
		"saw %d" % everything.size())


func _teardown_worlds() -> void:
	for unit in [_a1, _a2, _b1, _b2]:
		if is_instance_valid(unit):
			if unit.is_in_group("units"):
				unit.remove_from_group("units")
			unit.get_parent().remove_child(unit)
			unit.queue_free()
	for viewport in [_viewport_a, _viewport_b]:
		if is_instance_valid(viewport):
			_root.remove_child(viewport)
			viewport.queue_free()


## --- WorldContext -------------------------------------------------
## The other half of this pass: one object owning world-scoped state, so
## it dies with its world instead of being cleaned up by three unrelated
## mechanisms (one of which didn't run at all).

func _context_owns_world_state() -> void:
	var root := Node3D.new()
	_root.add_child(root)
	var context := WorldContext.new(root)
	add_child(context)

	check("a context takes its identity from its world root",
		context.world_3d == root.get_world_3d())
	check("and knows what lives in it", context.contains(root))

	var other := Node3D.new()
	_viewport_b.add_child(other)
	check("and what doesn't", not context.contains(other))
	other.queue_free()

	# THE LEAK. ActiveSurface holds a visual_node and an Area3D parented to
	# the world; SurfaceManager only ever cleared them on combat_ended, so
	# a surface cast outside combat survived the world being freed and left
	# this array pointing at nodes that went with it.
	context.surfaces.append(ActiveSurface.new(null, Vector3.ZERO, 1.0, 3))
	context.surfaces.append(ActiveSurface.new(null, Vector3.ZERO, 1.0, 3))
	check("surfaces live on the context", context.surfaces.size() == 2)

	context.dispose()
	check("disposing the context drops them, with no combat signal involved",
		context.surfaces.is_empty())
	check("and drops its encounters too", context.encounters.is_empty())

	context.queue_free()
	root.queue_free()


## The managers keep their public names and read through the context — if
## that delegation is dishonest, every existing reader silently sees the
## wrong list.
func _managers_delegate_to_the_context() -> void:
	var context: WorldContext = WorldManager.context()
	if context == null:
		# Headless tests load no world, which is itself worth asserting:
		# both managers must stay usable with no world at all (the main
		# menu is in exactly this state).
		check("with no world loaded, SurfaceManager still answers",
			SurfaceManager.active_surfaces != null)
		check("with no world loaded, CombatManager still answers",
			CombatManager.encounters != null)
		return

	check("SurfaceManager reads the context's surfaces",
		is_same(SurfaceManager.active_surfaces, context.surfaces))
	check("CombatManager reads the context's encounters",
		is_same(CombatManager.encounters, context.encounters))


## The nav grid is reached through the context, and since rung 3a it is
## genuinely per-world rather than one shared grid. The proof of THAT
## needs two live worlds with different geometry and lives in
## tests/world/test_nav_grid_worlds.gd.
##
## What belongs here is the half that suite cannot show: a context
## registers its world on construction and hands it back on dispose. That
## symmetry is what makes a grid die with the world whose geometry it
## points into, rather than outliving it holding raw CollisionShape3D
## pointers — the native crash invalidate() was written to paper over.
func _nav_grid_is_owned_by_the_context() -> void:
	var root := Node3D.new()
	_root.add_child(root)
	var context := WorldContext.new(root)

	check("the context exposes a navigation grid", context.navigation_grid() != null)
	check("still the engine singleton object, now keeping one grid per world",
		context.navigation_grid() == NavigationGrid)
	# Held because a World3D cannot be walked back to a node, so this is
	# the only record of where this world's geometry gets scanned from.
	check("and it remembers the root its grid is scanned from",
		context.world_root == root)

	context.dispose()
	check("disposing hands the world back, leaving nothing pointing into it",
		context.world_root == null)

	context.free()
	root.queue_free()
