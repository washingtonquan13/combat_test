extends Node
## Autoload singleton. Register as "CombatAI" under
## Project > Project Settings > AutoLoad, alongside CombatManager and
## SelectionManager.
##
## Deliberately dumb baseline behavior: on any AI-controlled unit's turn,
## find the nearest living hostile unit, close the distance if not already
## in reach, attack once if possible, then end the turn. No targeting
## priorities beyond "closest," no positioning smarts, no multi-target
## consideration. Meant to make the combat loop testable end-to-end —
## replace _find_nearest_hostile / _take_turn with something smarter later
## without touching CombatManager or Unit.

## Factions this AI controls. Anything NOT in this set is left alone
## (assumed player-controlled, or otherwise externally driven).
@export var ai_factions: Array[StringName] = [&"enemy"]

## Safety cap on movement attempts within a single turn — guards against a
## pathological loop where a unit is fully wedged against something and
## every attempt makes ~0 progress (each attempt would still cost real
## time via Unit.stuck_timeout). Ordinary turns resolve in 1-2 attempts.
const MAX_MOVE_ATTEMPTS_PER_TURN: int = 5

var _acting_unit: Unit = null
var _move_attempts: int = 0


func _ready() -> void:
	CombatManager.turn_started.connect(_on_turn_started)


func _on_turn_started(unit: Unit) -> void:
	if unit.faction not in ai_factions:
		return
	_acting_unit = unit
	_move_attempts = 0
	_attempt_action(unit)


## Attacks if in reach, otherwise moves closer and tries again once that
## move finishes (see _on_movement_finished). Under the current
## deterministic movement planner (Unit.move_to / PathAvoidance.
## simulate_path), a single move_to() call already computes the exact
## reachable route up front — if the standoff point fits within
## move_remaining, one call gets there precisely; if it doesn't, the plan
## is truncated at exactly the budget, and a second call this same turn
## would just find has_move_remaining() false and get rejected (budget
## doesn't refill until this unit's next turn). So retrying isn't doing
## "incremental progress across attempts" anymore — it's a safety net
## for the one case that can still leave a unit short of a fully-budgeted
## move: stuck_timeout firing on genuine physical obstruction, not just
## running out of distance.
func _attempt_action(unit: Unit) -> void:
	var target: Unit = _find_nearest_hostile(unit)
	if not target:
		CombatManager.end_turn()
		return

	var ability: Ability = unit.default_ability()
	if not ability:
		CombatManager.end_turn()
		return

	if ability.is_in_range(unit, target):
		unit.use_ability(ability, target)
		CombatManager.end_turn()
		return

	if not unit.has_move_remaining() or _move_attempts >= MAX_MOVE_ATTEMPTS_PER_TURN:
		CombatManager.end_turn()
		return

	_move_attempts += 1

	if unit.movement_finished.is_connected(_on_movement_finished):
		unit.movement_finished.disconnect(_on_movement_finished)
	unit.movement_finished.connect(_on_movement_finished, CONNECT_ONE_SHOT)

	var destination: Vector3 = _standoff_goal(unit, target)
	# target is excluded from the plan's obstacle list so the route
	# doesn't try to go AROUND the very thing it's trying to get close to
	# — see Unit.move_to's extra_avoidance_exclusions.
	if not unit.move_to(destination, [target]):
		# Rejected outright (e.g. budget already at 0) — nothing more to
		# try this turn.
		if unit.movement_finished.is_connected(_on_movement_finished):
			unit.movement_finished.disconnect(_on_movement_finished)
		CombatManager.end_turn()


func _on_movement_finished(unit: Unit) -> void:
	if unit != _acting_unit:
		return

	if not unit.is_alive():
		CombatManager.end_turn()
		return

	_attempt_action(unit)


func _find_nearest_hostile(unit: Unit) -> Unit:
	var nearest: Unit = null
	var nearest_dist: float = INF
	for node in get_tree().get_nodes_in_group("units"):
		var other := node as Unit
		if not other or not other.is_alive():
			continue
		if not unit.is_hostile_to(other):
			continue
		var dist: float = unit.distance_to(other)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = other
	return nearest


## The point this unit is trying to reach: just inside MELEE reach of
## target, not target's exact position (walking onto the same point
## another unit occupies is exactly what causes units to get physically
## stuck against each other). Budget clamping and routing around OTHER
## units now happen inside Unit.move_to() itself (see PathAvoidance) —
## this only needs to say where the unit wants to end up, not how far it
## can actually get there this turn.
##
## Still hardcoded to unit.reach regardless of the equipped ability's
## actual target_type — a unit whose default_ability() is RANGED_ENEMY
## will still walk in to melee distance instead of stopping at
## ability.max_range, or not moving at all if already in range (that
## specific case IS handled correctly — see _attempt_action's
## ability.is_in_range() check, which is why a ranged unit that starts
## already in range won't move). Making approach behavior actually
## ability-aware (stand off at range instead of closing to melee) is
## real follow-up work, not something this pass tried to solve.
func _standoff_goal(unit: Unit, target: Unit) -> Vector3:
	var to_target: Vector3 = target.global_position - unit.global_position
	var distance: float = to_target.length()
	if distance <= 0.001:
		return unit.global_position

	var direction: Vector3 = to_target / distance
	# Center-to-center distance at which this unit's *edge* sits exactly
	# at reach from target's edge (mirrors Unit.edge_distance_to). The
	# margin must exceed arrival_tolerance, not just be some small
	# constant — Unit's nav agent considers itself "arrived" (i.e. moves
	# no further) once within arrival_tolerance of the destination, so a
	# smaller margin lets it legitimately stop just outside reach on the
	# very first approach, with no further progress possible on retry
	# (any remaining gap smaller than arrival_tolerance also counts as
	# "already arrived," so it would never move that last bit either).
	var margin: float = unit.arrival_tolerance + 0.05
	var standoff: float = max(unit.reach + unit.radius + target.radius - margin, 0.05)
	return target.global_position - direction * standoff
