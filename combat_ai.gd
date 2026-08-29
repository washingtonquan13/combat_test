extends Node
## Autoload singleton. Register as "CombatAI" under
## Project > Project Settings > AutoLoad, alongside CombatManager and
## SelectionManager.
##
## On any AI-controlled unit's turn, ask AiScorer for the single best
## AiPlan it can act on (see that file's own header — every attack
## ability against every hostile, plus whatever the unit's authored
## ai_behaviors propose, scored and filtered against what it can
## actually afford/reach this turn), then execute it: move into position
## if the plan calls for it, act once possible, end the turn. This file
## itself owns none of the DECISION-making anymore — AiScorer does; this
## just drives the resulting plan through movement/action/turn-end,
## same responsibility split CombatManager has with CombatAI itself.

## Factions this AI controls. Anything NOT in this set is left alone
## (assumed player-controlled, or otherwise externally driven). Includes
## &"neutral" — not optional polish: once a neutral unit can actually
## become hostile (see FactionRelations/attacked_non_hostile_unit), it
## can end up with a live turn in turn_order. Without this, nothing would
## ever drive that turn (is_player_controlled() is false, and &"neutral"
## wasn't in this list), soft-locking CombatManager in Phase.ACTIVE
## forever with nobody calling end_turn(). Safe for an uninvolved
## bystander too — nobody's escalated against them, so AiScorer finds
## nothing to do and their turn just passes.
@export var ai_factions: Array[StringName] = [&"enemy", &"neutral"]

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


## Re-asks AiScorer for the best plan on every attempt rather than caching
## one across a turn — see the original version of this method's own
## header on why that's correct, not wasteful: under this project's
## deterministic movement planner, a single move_to() call already
## computes the exact reachable route up front, so a second attempt this
## same turn only ever happens after stuck_timeout (genuine physical
## obstruction), at which point the situation may have genuinely changed
## anyway.
func _attempt_action(unit: Unit) -> void:
	var plan: AiPlan = AiScorer.best_plan(unit)
	# A pure-repositioning plan (see AiPlan.pure_reposition — Flee, notably)
	# never carries a real ability to use, only somewhere to go; every
	# other plan still needs one.
	if not plan or plan.target == null or (not plan.has_destination and not plan.ability):
		CombatManager.end_turn()
		return

	if not is_nan(plan.flight_altitude):
		unit.set_flight_altitude(plan.flight_altitude)

	if plan.has_destination:
		_move_toward(unit, plan.destination)
		return

	# AiScorer only ever hands back a has_destination=false plan once it's
	# confirmed the ability is already usable from here (see that file's
	# _resolve_reach) — this check is belt-and-suspenders against state
	# changing between scoring and execution (an ally moved into the way,
	# say), not the primary gate.
	if plan.ability.is_in_range(unit, plan.target):
		unit.use_ability(plan.ability, plan.target)
	CombatManager.end_turn()


func _move_toward(unit: Unit, destination: Vector3) -> void:
	if unit.global_position.distance_to(destination) <= unit.arrival_tolerance:
		# Already there (e.g. a repositioning plan whose destination this
		# unit already occupies) — nothing left to walk toward, and
		# nothing to attack either (a has_destination plan never doubles
		# as an attack — see AiScorer._fallback_plan's own header), so the
		# turn is simply over.
		CombatManager.end_turn()
		return

	if not unit.has_move_remaining() or _move_attempts >= MAX_MOVE_ATTEMPTS_PER_TURN:
		CombatManager.end_turn()
		return

	_move_attempts += 1

	if unit.movement_finished.is_connected(_on_movement_finished):
		unit.movement_finished.disconnect(_on_movement_finished)
	unit.movement_finished.connect(_on_movement_finished, CONNECT_ONE_SHOT)

	if not unit.move_to(destination):
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


