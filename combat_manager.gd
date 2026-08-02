extends Node
## Autoload singleton. Register as "CombatManager" under
## Project > Project Settings > AutoLoad (same pattern as SelectionManager).
##
## Owns turn order only — it doesn't move units or pick targets. It hands
## out "whose turn is it" via signals, and UI/AI code calls Unit.attack()
## (see unit_combat_additions.gd) then CombatManager.end_turn() when a unit
## is done acting. Dead units are dropped from the order automatically.

signal combat_started(turn_order: Array[Unit])
signal turn_started(unit: Unit)
signal turn_ended(unit: Unit)
## winning_faction is the faction of whichever side survived, or &"" if
## every remaining combatant died simultaneously (a mutual wipe) — see
## _check_combat_end.
signal combat_ended(winning_faction: StringName)

var turn_order: Array[Unit] = []
var in_combat: bool = false

var _turn_index: int = -1
## Set while a delay_turn() call is waiting on a busy unit to become
## idle before it can actually apply — see delay_turn/_on_unit_idle_for_delay.
var _pending_delay_positions: int = -1

var current_unit: Unit:
	get:
		if _turn_index >= 0 and _turn_index < turn_order.size():
			return turn_order[_turn_index]
		return null


## Builds initiative order from the given combatants and starts combat.
## Initiative = dexterity, highest first; ties broken by a tiebreak value
## rolled once per unit beforehand (not inside the comparator — a sort
## comparator can be called more than once for the same pair, and one that
## re-rolls randomness each call gives inconsistent answers, which Godot
## flags as a "bad comparison function" and can leave the sort broken).
func start_combat(combatants: Array[Unit]) -> void:
	turn_order = combatants.filter(func(u): return u.is_alive())

	var tiebreak: Dictionary = {}
	for unit in turn_order:
		tiebreak[unit] = randi_range(1, 6)

	turn_order.sort_custom(func(a: Unit, b: Unit) -> bool:
		if a.dexterity != b.dexterity:
			return a.dexterity > b.dexterity
		return tiebreak[a] > tiebreak[b]
	)

	for unit in turn_order:
		if not unit.died.is_connected(_on_unit_died):
			unit.died.connect(_on_unit_died)

	_turn_index = -1
	in_combat = true
	combat_started.emit(turn_order)
	_advance_turn.call_deferred()


func end_combat(winning_faction: StringName = &"") -> void:
	in_combat = false
	for unit in turn_order:
		if is_instance_valid(unit) and unit.died.is_connected(_on_unit_died):
			unit.died.disconnect(_on_unit_died)
	turn_order.clear()
	_turn_index = -1
	combat_ended.emit(winning_faction)


## Call once the active unit is done acting (attacked, moved, passed, etc).
##
## If the current unit still has something in flight (Unit.is_busy() —
## mid-move, or an async ability effect like Jump's arc animation still
## running), the request is accepted but DEFERRED: this connects to the
## unit's became_idle signal and re-calls itself once that fires, rather
## than either cutting the action off mid-resolution or silently dropping
## the end-turn request. This is the actual fix for turns being able to
## end while an action was still resolving — previously nothing checked
## this at all.
##
## Once not busy, advancing is deferred via call_deferred rather than
## called directly: if the next unit's turn resolves instantly (already
## in reach, AI attacks and calls end_turn again immediately), calling
## _advance_turn() synchronously here would nest that whole resolution
## inside this call — and with several units doing that back-to-back,
## inside THAT call, and so on, you get an effectively recursive chain
## with no base case. Deferring makes each turn's resolution its own step
## instead of a nested call frame.
func end_turn() -> void:
	if not in_combat:
		return

	var unit: Unit = current_unit
	if not unit:
		return

	if unit.is_busy():
		if not unit.became_idle.is_connected(end_turn):
			unit.became_idle.connect(end_turn, CONNECT_ONE_SHOT)
		return

	turn_ended.emit(unit)
	_advance_turn.call_deferred()


## Delays unit's turn instead of acting now: gives up its current slot
## and is reinserted `positions` further along the SAME pass through
## turn_order — e.g. positions=1 swaps it with whoever would go right
## after it, so that unit acts now instead and the delaying unit acts
## after them. This doesn't grant an extra turn; it's still exactly one
## activation per cycle through turn_order, just relocated within it.
##
## Only the unit stepping into the vacated slot gets reset_turn_actions()
## called (ordinary turn-start behavior) — the delaying unit deliberately
## does NOT get reset now. Whatever it already did or didn't do this pass
## is done; it gets a full fresh turn whenever its now-later slot comes
## up, exactly like any other turn.
##
## Same busy-deferral as end_turn() — if the unit still has something in
## flight, the delay is accepted but applied once it becomes idle, not
## cut in immediately mid-action.
##
## Can only be called by the unit whose turn it currently is (you delay
## your own upcoming turn, not someone else's). Returns false if that's
## not the case, combat isn't running, or positions < 1. positions
## defaults to 1 pending a real turn-order UI to choose a specific value.
func delay_turn(unit: Unit, positions: int = 1) -> bool:
	if not in_combat or unit != current_unit or positions < 1:
		return false

	if unit.is_busy():
		_pending_delay_positions = positions
		if not unit.became_idle.is_connected(_on_unit_idle_for_delay):
			unit.became_idle.connect(_on_unit_idle_for_delay, CONNECT_ONE_SHOT)
		return true

	_perform_delay(unit, positions)
	return true


func _on_unit_idle_for_delay() -> void:
	var positions: int = _pending_delay_positions
	_pending_delay_positions = -1
	if in_combat and current_unit:
		_perform_delay(current_unit, positions)


func _perform_delay(unit: Unit, positions: int) -> void:
	turn_order.remove_at(_turn_index)
	var insert_index: int = clamp(_turn_index + positions, 0, turn_order.size())
	turn_order.insert(insert_index, unit)

	var next_unit: Unit = turn_order[_turn_index]
	turn_ended.emit(unit)
	next_unit.reset_turn_actions()
	turn_started.emit(next_unit)


func _advance_turn() -> void:
	if not in_combat:
		return

	# is_instance_valid guards against a unit whose node has already been
	# freed (death_cleanup_delay == 0 frees immediately on death) — this
	# array is CombatManager's own snapshot from start_combat, not tied to
	# the "units" group, so it doesn't automatically stop referencing a
	# freed node the way group-based queries do.
	turn_order = turn_order.filter(func(u): return is_instance_valid(u) and u.is_alive())

	if _check_combat_end():
		return

	_turn_index = (_turn_index + 1) % turn_order.size()
	var unit: Unit = current_unit
	unit.reset_turn_actions()
	unit.tick_statuses()

	# tick_statuses() can kill the unit outright (a Bleeding/Burning tick)
	# or, via that death, end combat entirely (the last enemy bleeds out)
	# — re-check rather than assuming the state from a few lines up still
	# holds. Deferred re-advance for the same reason end_turn() defers:
	# calling _advance_turn() synchronously here would nest this turn's
	# resolution inside the current call frame instead of making it its
	# own step.
	if not in_combat:
		return
	if not is_instance_valid(unit) or not unit.is_alive():
		_advance_turn.call_deferred()
		return

	turn_started.emit(unit)


## Ends combat the moment only one faction (or none) remains among the
## living, rather than waiting for every combatant on both sides to die.
## Without this, one side being wiped out just left the other side's
## turns cycling forever with nothing to do — not a crash, but an
## unrecoverable stall with no way back to player control.
## Returns true if combat was ended.
func _check_combat_end() -> bool:
	var alive_factions: Dictionary = {}
	for unit in turn_order:
		if is_instance_valid(unit) and unit.is_alive():
			alive_factions[unit.faction] = true

	if alive_factions.size() > 1:
		return false

	var winner: StringName = &""
	if alive_factions.size() == 1:
		winner = alive_factions.keys()[0]

	end_combat(winner)
	return true


func _on_unit_died(_unit: Unit) -> void:
	if not in_combat:
		return

	# Check the win/loss condition the instant anyone dies — don't wait
	# for the next turn boundary. A death on someone else's turn (e.g. the
	# player's only unit dying to an enemy attack) would otherwise leave
	# combat "running" with a fully eliminated side until the next
	# _advance_turn happened to notice.
	if _check_combat_end():
		return

	# If the unit whose turn it currently is dies mid-turn (e.g. a
	# counterattack), move things along instead of waiting on an
	# end_turn() call that may never come. Deferred for the same reason
	# as end_turn() — see its comment.
	if current_unit != null and not current_unit.is_alive():
		_advance_turn.call_deferred()
