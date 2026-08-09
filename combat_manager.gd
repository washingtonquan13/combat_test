extends Node
## Autoload singleton. Register as "CombatManager" under
## Project > Project Settings > AutoLoad (same pattern as SelectionManager).
##
## Owns turn order only — it doesn't move units or pick targets. It hands
## out "whose turn is it" via signals, and UI/AI code calls Unit.attack()
## (see unit_combat_additions.gd) then CombatManager.end_turn() when a unit
## is done acting. Dead units are dropped from the order automatically.
##
## Turn flow is an explicit state machine (see Phase) rather than a bare
## in_combat bool plus scattered busy/idle flag checks — the thing that
## replaced was a real bug class, not a hypothetical one: a mass-kill AoE
## fires one died signal per corpse, synchronously, in the same call
## stack, and whichever death happened to trigger _check_combat_end()
## flipped in_combat false out from under every death handler still to
## run in that same batch — each one hit an early-return guard and never
## finished its own cleanup. One authoritative phase value, transitioned
## in exactly one place per edge, is what makes that class of bug
## structurally harder to reintroduce, instead of relying on every new
## signal handler remembering to re-check a shared bool correctly.
##
## Deliberately only 4 phases, not the 6 in the design sketch this was
## drafted from — two of the sketch's boxes turned out not to be
## separately OBSERVABLE runtime states once actually built:
##   - "Awaiting Action" and "Action Resolving" collapse into ACTIVE here.
##     Nothing at the CombatManager level currently needs to react to
##     that specific transition — Unit.is_busy() already answers "is the
##     acting unit currently mid-move/mid-ability" at every point that
##     actually checks it (end_turn, delay_turn). Splitting ACTIVE in two
##     would mean wiring a new "became busy" signal (UnitActionState has
##     became_idle for the reverse direction, not this one) for a
##     distinction nothing consumes yet — exactly the kind of speculative
##     complexity worth skipping until something real needs it.
##   - "Combat Ending" collapses into the OUT_OF_COMBAT transition
##     itself. _check_combat_end() calling end_combat() is one
##     synchronous call, not two frames apart — there's no interval where
##     code could ever observe "ending" as distinct from "ended."
enum Phase {
	OUT_OF_COMBAT,  ## No combat running. in_combat reads false.
	TURN_STARTING,  ## Between _advance_turn() beginning and the eventual live unit's turn_started firing — may loop on itself if tick_statuses() kills whoever's up next.
	ACTIVE,         ## A unit's turn is live. See Unit.is_busy() for whether it's specifically idle (awaiting a click/AI decision) or mid-action.
	TURN_ENDING,    ## end_turn() has been called; waiting on the acting unit to finish anything in flight before the next _advance_turn() runs.
}

signal combat_started(turn_order: Array[Unit])
signal turn_started(unit: Unit)
signal turn_ended(unit: Unit)
## winning_faction is the faction of whichever side survived, or &"" if
## every remaining combatant died simultaneously (a mutual wipe) — see
## _check_combat_end.
signal combat_ended(winning_faction: StringName)
## Fired every time turn_order wraps back to its start — i.e. a full
## round has completed and a new one is beginning, right before that
## round's first unit gets turn_started. Nothing in this file consumes
## this itself; it exists as a checkpoint for anything that needs to age
## over ROUNDS rather than per-unit turns — SurfaceManager, notably,
## which ages every Surface's remaining duration here rather than
## inventing its own scheduler (see surface_manager.gd).
signal round_started(round_number: int)
## Fires on every transition, including the ones already covered by a
## more specific signal above (turn_started et al) — for anything that
## wants to react to phase generally (e.g. a debug HUD, or graying out
## the end-turn button while TURN_ENDING/TURN_STARTING) without needing
## to listen to every specific signal individually.
signal phase_changed(phase: Phase)
## Fired by add_unit_to_combat() — a summon joining a fight already in
## progress. Deliberately separate from combat_started (the initial
## roster): anything that builds its own view of "who's in this fight"
## off combat_started alone (see initiative_row.gd, which is exactly
## what missed this) needs a SEPARATE hook for a unit arriving after
## that initial snapshot, not a reason to re-derive from turn_order on
## every turn_started.
signal unit_joined_combat(unit: Unit)

var turn_order: Array[Unit] = []
## Counts full passes through turn_order — 1 for the very first turn of
## combat, incrementing each time _turn_index wraps back to 0. Not
## affected by delay_turn() (that only reorders turn_order/moves the
## delaying unit within the same pass, never touches _turn_index other
## than the ordinary advance already does).
var round_number: int = 0

## The single authoritative turn-flow state — see Phase and this file's
## header. Every transition happens in exactly one place (search for
## "phase =" to find all of them); nothing outside this file ever writes
## to it, only reads it via in_combat or phase_changed.
var phase: Phase = Phase.OUT_OF_COMBAT:
	set(value):
		if phase == value:
			return
		phase = value
		phase_changed.emit(value)

## Derived from phase rather than an independent flag — every external
## reader (there are over a dozen) keeps working completely unchanged;
## only the storage moved.
var in_combat: bool:
	get: return phase != Phase.OUT_OF_COMBAT

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
		_connect_unit_signals(unit)

	_turn_index = -1
	round_number = 0
	phase = Phase.TURN_STARTING
	SystemLog.print("[b]--- Combat started ---[/b]")
	combat_started.emit(turn_order)
	_advance_turn.call_deferred()


## Connects the two per-unit signals every combatant needs — shared by
## start_combat()'s initial roster and add_unit_to_combat() (a summon,
## say), so a unit joining mid-combat gets exactly the same wiring as one
## that was there from the start, rather than a second, easy-to-drift
## copy of the same two lines.
func _connect_unit_signals(unit: Unit) -> void:
	if not unit.died.is_connected(_on_unit_died):
		unit.died.connect(_on_unit_died)
	# Anything that can displace a unit mid-turn (Knockback, Shove,
	# Jump's move_caster_effect — none of which go through
	# Unit.move_to(), so none of them trigger an occupancy update on their
	# own) finishes by emitting ability_used — see this file's other
	# occupancy-update call sites for why the grid needs to stay current
	# with actual positions, not just at turn boundaries.
	if not unit.ability_used.is_connected(_on_ability_used):
		unit.ability_used.connect(_on_ability_used)


## Injects a new unit into the CURRENTLY RUNNING combat — a summon, most
## likely. Slots in right after after_unit (typically the summoner —
## defaults to whoever's turn it currently is, since that's who's
## casting the summon in the overwhelmingly common case), not re-sorted
## into full initiative order: simpler bookkeeping, and it means
## summoning something gives you near-immediate tempo rather than
## waiting on a freshly-rolled initiative slot that might land far away.
## Does NOT call reset_turn_actions() — that happens exactly once, at the
## normal point _advance_turn() already reaches every unit's turn, same
## as any other combatant; a summon gets a fresh move/attack budget when
## its own turn naturally comes up, not before.
##
## No-op outside combat (phase == OUT_OF_COMBAT) — there's no turn_order
## to inject into; a summon cast outside combat is just a unit that
## exists, nothing this method needs to be involved in.
func add_unit_to_combat(unit: Unit, after_unit: Unit = null) -> void:
	if phase == Phase.OUT_OF_COMBAT:
		return

	_connect_unit_signals(unit)

	var insert_index: int = _turn_index + 1
	if after_unit:
		var after_index: int = turn_order.find(after_unit)
		if after_index != -1:
			insert_index = after_index + 1

	turn_order.insert(insert_index, unit)

	# Inserting AT OR BEFORE the current slot pushes the unit already
	# sitting there (and every other index at/after the insertion point)
	# one place further along — without this, current_unit would silently
	# start pointing at the wrong combatant the instant that happens (only
	# reachable when after_unit is someone earlier in this round than
	# whoever's currently acting).
	if insert_index <= _turn_index:
		_turn_index += 1

	unit_joined_combat.emit(unit)


func end_combat(winning_faction: StringName = &"") -> void:
	if winning_faction == &"":
		SystemLog.print("[b]--- Combat ended: mutual wipe ---[/b]")
	else:
		SystemLog.print("[b]--- Combat ended: %s wins ---[/b]" % LogFormat.faction_name(winning_faction))

	phase = Phase.OUT_OF_COMBAT
	for unit in turn_order:
		if not is_instance_valid(unit):
			continue
		if unit.died.is_connected(_on_unit_died):
			unit.died.disconnect(_on_unit_died)
		if unit.ability_used.is_connected(_on_ability_used):
			unit.ability_used.disconnect(_on_ability_used)
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
	if phase != Phase.ACTIVE:
		return

	var unit: Unit = current_unit
	if not unit:
		return

	if unit.is_busy():
		if not unit.became_idle.is_connected(end_turn):
			unit.became_idle.connect(end_turn, CONNECT_ONE_SHOT)
		return

	phase = Phase.TURN_ENDING

	# Catches anything that displaced a unit right at the tail end of this
	# turn without going through ability_used/move_to's own occupancy
	# update (belt-and-suspenders alongside _advance_turn's own update
	# for whoever goes next — cheap, since this only runs once per turn
	# either way).
	NavigationGrid.update_occupancy(get_tree(), [unit])
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
	if phase != Phase.ACTIVE or unit != current_unit or positions < 1:
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
	if phase == Phase.ACTIVE and current_unit:
		_perform_delay(current_unit, positions)


func _perform_delay(unit: Unit, positions: int) -> void:
	turn_order.remove_at(_turn_index)
	var insert_index: int = clamp(_turn_index + positions, 0, turn_order.size())
	turn_order.insert(insert_index, unit)

	var next_unit: Unit = turn_order[_turn_index]
	phase = Phase.TURN_STARTING
	NavigationGrid.update_occupancy(get_tree(), [next_unit])
	turn_ended.emit(unit)
	next_unit.reset_turn_actions()
	_log_and_emit_turn_started(next_unit)


func _advance_turn() -> void:
	if phase == Phase.OUT_OF_COMBAT:
		return

	# Captured before turn_order is reassigned below — Array.filter()
	# returns a NEW array rather than mutating in place, so this keeps
	# referencing the original, unfiltered ordering (and search_start, the
	# index to resume searching from) even after turn_order is reassigned
	# to the filtered one a few lines down.
	var pre_filter_order: Array[Unit] = turn_order
	var search_start: int = _turn_index + 1

	# is_instance_valid guards against a unit whose node has already been
	# freed (death_cleanup_delay == 0 frees immediately on death) — this
	# array is CombatManager's own snapshot from start_combat, not tied to
	# the "units" group, so it doesn't automatically stop referencing a
	# freed node the way group-based queries do.
	turn_order = turn_order.filter(func(u): return is_instance_valid(u) and u.is_alive())

	if _check_combat_end():
		return

	# Walk forward from wherever the just-finished turn left off, in the
	# ORIGINAL pre-filter order, and take the first unit still alive —
	# correct no matter how many units died this pass, including whoever's
	# turn just ended. An earlier version derived the new index purely
	# from THAT unit's own post-filter position, which broke if it died in
	# the same synchronous batch as another unit EARLIER in turn_order
	# (e.g. an AoE that catches its own caster and an ally standing near
	# them — AreaDamageEffect's affects_allies supports exactly this, see
	# abilities/explosive_fireball.tres, so this isn't just hypothetical):
	# the stale index then landed one slot short, silently skipping
	# whoever should have gone next. This walk needs no separate case for
	# the very first call of combat either — _turn_index starts at -1, so
	# search_start is already 0, which is where the walk should start.
	var next_unit: Unit = null
	for i in range(pre_filter_order.size()):
		var candidate: Unit = pre_filter_order[(search_start + i) % pre_filter_order.size()]
		if is_instance_valid(candidate) and candidate.is_alive():
			next_unit = candidate
			break

	_turn_index = turn_order.find(next_unit)
	if _turn_index == 0:
		round_number += 1
		round_started.emit(round_number)

	var unit: Unit = current_unit
	phase = Phase.TURN_STARTING
	# Marks every OTHER living unit's footprint occupied on the shared
	# grid, and this unit's own footprint excluded (it can't have its own
	# standing position block its own path query) — see NavigationGrid.
	# Once per turn is exactly the cadence this is meant for: nothing else
	# moves again until this unit's turn ends.
	NavigationGrid.update_occupancy(get_tree(), [unit])
	unit.reset_turn_actions()
	unit.tick_statuses()

	# tick_statuses() can kill the unit outright (a Bleeding/Burning tick)
	# or, via that death, end combat entirely (the last enemy bleeds out)
	# — re-check rather than assuming the state from a few lines up still
	# holds. Deferred re-advance for the same reason end_turn() defers:
	# calling _advance_turn() synchronously here would nest this turn's
	# resolution inside the current call frame instead of making it its
	# own step.
	if phase == Phase.OUT_OF_COMBAT:
		return
	if not is_instance_valid(unit) or not unit.is_alive():
		_advance_turn.call_deferred()
		return

	_log_and_emit_turn_started(unit)


## Shared by both places a unit's turn actually starts (normal advance,
## and stepping into the slot vacated by a delay_turn call) so the log
## line isn't duplicated at each call site — and now the one place ACTIVE
## is ever entered from.
func _log_and_emit_turn_started(unit: Unit) -> void:
	phase = Phase.ACTIVE
	SystemLog.print("[u]%s's turn[/u]" % LogFormat.unit_name(unit))
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
	# A death can change what the grid's occupancy should look like — a
	# corpse that doesn't block movement (see Unit.corpse_blocks_movement/
	# _handle_death) removes from the "units" group immediately (see
	# _handle_death), so the very next update_occupancy call already skips
	# it — no bake, no per-frame coalescing needed the way the old navmesh
	# rebake required (that existed only to wait out
	# NavigationObstacle3D's own removal, which this system doesn't have).
	# Deliberately BEFORE the phase check below and unconditional on it:
	# an AoE that wipes a faction fires one died signal per kill,
	# synchronously, in the same call stack — if THIS death is what ends
	# combat (_check_combat_end, further down), every death after it in
	# that same batch would otherwise hit the early return and never get
	# the grid's occupancy updated for it. This is the exact bug class
	# this file's header describes — see there for why phase (one value,
	# one transition point per edge) is what actually prevents it rather
	# than just patching this one call site's ordering.
	NavigationGrid.update_occupancy(get_tree(), [current_unit] if current_unit else [])

	if phase == Phase.OUT_OF_COMBAT:
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
	#
	# Gated on Phase.ACTIVE specifically — NOT TURN_STARTING — because
	# tick_statuses() (called from _advance_turn while phase is still
	# TURN_STARTING) can itself kill the unit it just ticked, e.g. a
	# DamageOverTimeBehavior tick or a summon's DespawnOnExpireBehavior
	# expiring on the summon's own turn. _advance_turn already has its
	# own re-check for exactly that case right after tick_statuses()
	# returns (see its "may loop on itself" comment). Without this
	# gate, BOTH re-checks fire for the same death — this one via the
	# died signal firing synchronously from inside tick_statuses(),
	# _advance_turn's via its own post-tick check — queuing two
	# call_deferred(_advance_turn) calls instead of one, which silently
	# skips the next unit in turn_order entirely. Confirmed by testing
	# summon expiry, not a hypothetical: a summon dying on schedule ate
	# the following unit's turn until this gate was added.
	if phase == Phase.ACTIVE and current_unit != null and not current_unit.is_alive():
		_advance_turn.call_deferred()


## Knockback, Shove, Jump's move_caster_effect, and anything else an
## ability's effects do to displace a unit — none of them go through
## Unit.move_to(), so none of them trigger an occupancy update on their
## own the way an ordinary move does. This is the catch-all for "the
## ability that just resolved might have moved someone."
func _on_ability_used(attacker: Unit, _target, _result: Dictionary) -> void:
	NavigationGrid.update_occupancy(get_tree(), [attacker])
