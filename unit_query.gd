class_name UnitQuery
extends RefCounted
## Every real "units" group scan in this project — CombatAI's targeting,
## drag-select, party_panel's roster, the area-effect trio, ... — used to
## hand-loop get_tree().get_nodes_in_group("units"), cast each node to
## Unit, and reimplement its own alive/hostile/faction/distance
## filtering on top. This collects the shapes real callers actually use
## today, not every conceivable filter — same "don't keep speculative
## surface area" discipline PathAvoidance's own header describes.
##
## Every method takes tree: SceneTree explicitly rather than reaching for
## a global, matching PathAvoidance.gather_obstacles's own convention —
## this is a RefCounted with no scene-tree access of its own, and every
## real caller already has a tree at hand (a Node's own get_tree(), or
## unit.get_tree()/attacker.get_tree() from anywhere holding a Unit).
##
## Every returned Array is a freshly built snapshot, decoupled from the
## live "units" group the instant a method returns — the same guarantee
## get_nodes_in_group() itself already provides, so a caller iterating a
## returned array stays safe even if something it does mid-iteration
## (UnitDeath.handle_death's dependent cascade, notably) removes a unit
## from the group.
##
## WORLD SCOPING. The "units" group is SceneTree-GLOBAL, so once more than
## one world is resident every scan here sees all of them at once — an AI
## targeting an enemy in another area, a detection sweep spotting someone
## a level away, an occupancy update blocking cells in a world nobody is
## standing in. That is the single biggest obstacle to running worlds
## simultaneously, and it is plain GDScript rather than anything to do
## with the navigation extension.
##
## The scoping key is World3D, taken from a reference unit — deliberately
## not a new id field. Node3D.get_world_3d() already returns the
## viewport's world, and a SubViewport with own_world_3d gets a distinct
## one, so a key derived this way cannot drift out of sync with reality
## the way a hand-maintained id could. With one world it is a no-op; the
## moment a second viewport exists it starts separating them with no
## further work.
##
## Two flavours on purpose:
##   *_near(unit)  — scoped to that unit's world. What gameplay wants.
##   plain(tree)   — every unit that exists, in every world. What the
##                   camera, drag-select, the demon roster and area
##                   teardown want, and they say so at the call site
##                   rather than getting it by accident.

## Every Node currently in the "units" group, cast to Unit and null-
## checked — the bare floor, for callers whose real filtering (screen-
## space visibility, RID extraction, an arbitrary targeting predicate, a
## narrow compound count check, ...) is too specific to belong in a
## shared query.
static func all_units(tree: SceneTree) -> Array[Unit]:
	var units: Array[Unit] = []
	# A caller can reach here holding a unit that has already left the
	# tree — get_tree() on one returns null — and a null tree here used to
	# take the call down with a "Cannot call method on a null value".
	if tree == null:
		return units
	for node in tree.get_nodes_in_group("units"):
		var unit := node as Unit
		# Group membership outlives the tree by a frame: queue_free is
		# deferred, and a unit removed from the tree but not yet freed is
		# still listed here. Every caller immediately reads its
		# global_position, which errors on a node outside the tree, so
		# filtering once at the source beats guarding at each call site.
		#
		# is_queued_for_deletion is the OTHER half of that, and it was
		# missing. queue_free does not remove a node — is_inside_tree stays
		# true right up until the frame ends — so a unit on its way out was
		# still being returned, and returned FIRST if it happened to sit
		# earlier in the group.
		#
		# That is not merely untidy. CombatManager._find_by_id takes the
		# first unit carrying an id, and a replacement stamped with a freed
		# unit's id (see PartyManager.spawn_member, which does exactly that
		# when an area rebuilds its party) then loses the lookup to the
		# corpse. The fight resumes around a lookalike whose turn state is
		# still at its untouched defaults.
		if unit and unit.is_inside_tree() and not unit.is_queued_for_deletion():
			units.append(unit)
	return units


## Every living unit, minus whatever's in excluded (defaults to none).
## excluded is a plain Array, not Array[Unit], matching PathAvoidance.
## gather_obstacles's own param — callers hand it anything from a
## single-unit literal to a whole roster.
static func living_units(tree: SceneTree, excluded: Array = []) -> Array[Unit]:
	var units: Array[Unit] = []
	for unit in all_units(tree):
		if unit.is_alive() and unit not in excluded:
			units.append(unit)
	return units


## The world-scoped forms. `near` reads better than "in the same World3D
## as" at a call site, and every one of them already had the reference
## unit in hand — most literally passed `unit.get_tree()`.
static func all_units_near(unit: Unit) -> Array[Unit]:
	if unit == null or not unit.is_inside_tree():
		return [] as Array[Unit]
	return _in_world_of(unit, all_units(unit.get_tree()))


static func living_units_near(unit: Unit, excluded: Array = []) -> Array[Unit]:
	if unit == null or not unit.is_inside_tree():
		return [] as Array[Unit]
	return _in_world_of(unit, living_units(unit.get_tree(), excluded))


## Keeps only the units sharing `unit`'s World3D.
##
## Compared by object identity rather than by any id — World3D instances
## are unique per viewport, so this is exact. A unit outside the tree is
## dropped: get_world_3d() errors on one, and all_units already filters
## them, but the guard is cheap and this is reachable from paths that
## build their own arrays.
static func _in_world_of(unit: Unit, candidates: Array[Unit]) -> Array[Unit]:
	var world: World3D = unit.get_world_3d()
	var scoped: Array[Unit] = []
	for other in candidates:
		if not is_instance_valid(other) or not other.is_inside_tree():
			continue
		if other.get_world_3d() == world:
			scoped.append(other)
	return scoped


## Every player-controlled unit that wasn't itself summoned — the "core
## roster" (see party_panel.gd's own _rebuild_core). Deliberately NOT
## filtered on is_alive(): neither original call site checked it, and a
## dead core member leaves the "units" group entirely the instant it
## dies (see UnitDeath.handle_death) — there's nothing left for a check
## here to catch. Don't add one.
static func core_party_units(tree: SceneTree) -> Array[Unit]:
	var units: Array[Unit] = []
	for unit in all_units(tree):
		if unit.is_player_controlled() and unit.summoned_by == null:
			units.append(unit)
	return units


## Closest living unit hostile to `unit`, or null if none — CombatAI's
## baseline targeting rule (see that file's own header). Factored out
## here rather than left private to CombatAI so a future smarter
## targeting heuristic still has "nearest hostile" available as a
## building block instead of re-deriving it.
## World-scoped via `unit`, with no signature change — a unit can never
## target something in another world, however close it looks in raw
## coordinates (two worlds routinely occupy the same coordinates, since
## every area is authored around the origin).
static func nearest_hostile(tree: SceneTree, unit: Unit) -> Unit:
	var nearest: Unit = null
	var nearest_dist: float = INF
	for other in _in_world_of(unit, living_units(tree)):
		if not unit.is_hostile_to(other):
			continue
		var dist: float = unit.distance_to(other)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = other
	return nearest


## Every living unit whose EDGE (not center) lies within radius of
## center, gated by hostile/ally-to-attacker — the exact scan
## AreaDamageEffect/AreaHealEffect/AreaApplyStatusEffect each
## reimplemented identically. What happens to a matched unit (a damage
## roll, a heal roll, a status application) stays on the caller — that's
## the only real difference between the three.
static func area_affected(tree: SceneTree, attacker: Unit, center: Vector3, radius: float, affects_hostiles: bool, affects_allies: bool) -> Array[Unit]:
	var affected: Array[Unit] = []
	for unit in _in_world_of(attacker, living_units(tree)):
		var edge_dist: float = center.distance_to(unit.global_position) - unit.radius
		if edge_dist > radius:
			continue
		var is_hostile: bool = attacker.is_hostile_to(unit)
		if is_hostile and not affects_hostiles:
			continue
		if not is_hostile and not affects_allies:
			continue
		affected.append(unit)
	return affected


## Every unit summoned_by summoner — living or not (see UnitDeath's own
## comment on why an already-dead dependent still needs its own expire()
## call; don't add an is_alive() filter here).
static func dependents_of(tree: SceneTree, summoner: Unit) -> Array[Unit]:
	var dependents: Array[Unit] = []
	for unit in _in_world_of(summoner, all_units(tree)):
		if unit.summoned_by == summoner:
			dependents.append(unit)
	return dependents


## Every living unit NOT hostile to `unit` (allies, by this project's
## faction rules — see Unit.is_hostile_to), excluding unit itself.
static func living_allies(tree: SceneTree, unit: Unit) -> Array[Unit]:
	var allies: Array[Unit] = []
	for other in _in_world_of(unit, living_units(tree)):
		if other != unit and not unit.is_hostile_to(other):
			allies.append(other)
	return allies
