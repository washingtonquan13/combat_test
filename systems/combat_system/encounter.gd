class_name Encounter
extends Node
## One fight. Owns its own turn order, round count and phase — everything
## that used to be a single set of fields on the CombatManager autoload.
##
## Splitting it out is what allows more than one fight to run at once, and
## more importantly what allows a unit to be in NO fight while another is
## running. Before this, "is combat happening" was a global truth consulted
## in 37 places, so a party member standing outside a battle was still
## bound by its turn order — it could not be commanded at all, which made
## ambushes, flanking and held reserves unreachable rather than merely
## awkward (see ground_click_target._command_move).
##
## A Node rather than a RefCounted, deliberately, for two practical
## reasons: get_tree() is needed on nearly every path (NavigationGrid,
## UnitQuery), and the turn loop leans on call_deferred to keep each turn's
## resolution its own step rather than a nested call frame (see end_turn).
## A RefCounted with a deferred call pending is a freed object waiting to
## happen the moment the owner drops its last reference; a Node's lifetime
## is explicit, and CombatManager parents it.
##
## THREE THINGS THIS MUST NOT DO, because they are cheap to honour now and
## expensive to unpick later:
##
##   - Never touch GameMode. Which mode owns input and the camera is a
##     global, player-facing question; an encounter has no business knowing
##     a camera exists. CombatManager decides mode from whether ANY
##     encounter involves the player (see its own push/pop refcounting).
##   - Never read CombatManager. Dependencies point one way — the manager
##     owns encounters, encounters know nothing above themselves.
##   - Stateless helpers are fine to call directly (SystemLog, LineOfSight,
##     FactionRelations via Unit.is_hostile_to). NavigationGrid is the one
##     exception worth flagging: it holds WORLD state, and it is the single
##     seam that changes when multiple worlds become live. Left as a direct
##     global call here — one implementation doesn't justify an injection
##     layer — but marked so it's found rather than hunted for.
##
## Turn flow is an explicit state machine (see Phase) rather than a bare
## bool plus scattered busy/idle checks — what that replaced was a real bug
## class, not a hypothetical one: a mass-kill AoE fires one died signal per
## corpse, synchronously, in the same call stack, and whichever death
## happened to end combat flipped the bool out from under every death
## handler still to run in that batch, each of which then hit an early
## return and never finished its own cleanup. One authoritative phase
## value, transitioned in exactly one place per edge, is what makes that
## structurally hard to reintroduce.
##
## Deliberately only 4 phases: "awaiting action" and "action resolving"
## collapse into ACTIVE (Unit.is_busy() already answers the difference
## everywhere it's actually asked), and "combat ending" collapses into the
## OUT_OF_COMBAT transition itself (_check_combat_end calling finish() is
## one synchronous call — there is no interval where "ending" is separately
## observable).
enum Phase {
	OUT_OF_COMBAT,  ## Not running. is_running reads false.
	TURN_STARTING,  ## Between _advance_turn beginning and the eventual live unit's turn_started — may loop on itself if tick_statuses kills whoever's up next.
	ACTIVE,         ## A unit's turn is live. See Unit.is_busy() for idle-vs-mid-action.
	TURN_ENDING,    ## end_turn called; waiting on the acting unit to finish anything in flight.
}

signal combat_started(turn_order: Array[Unit])
signal turn_started(unit: Unit)
signal turn_ended(unit: Unit)
## The faction of whichever side survived, or &"" on a mutual wipe.
signal combat_ended(winning_faction: StringName)
## Fired every time turn_order wraps back to its start. Nothing here
## consumes it; it exists for anything ageing over ROUNDS rather than turns
## (SurfaceManager, notably).
signal round_started(round_number: int)
signal phase_changed(phase: Phase)
## A unit joining a fight already in progress — a summon, or someone who
## walked into it. Deliberately separate from combat_started (the initial
## roster): anything building its own view of "who is in this fight" off
## that snapshot alone needs a hook for later arrivals.
signal unit_joined_combat(unit: Unit)
## A combatant leaving the fight ALIVE rather than dying out of it — see
## _try_disengage. Distinct from died on purpose: "it got away" and "it is
## dead" are very different facts to UI and quest logic.
signal unit_left_combat(unit: Unit)

## How far from every living hostile a combatant must get before it drops
## out. Comfortably larger than CombatManager.AGGRO_PULL_RADIUS so escaping
## and being pulled back in can't oscillate.
const DISENGAGE_DISTANCE: float = 25.0
## The shorter range at which breaking line of sight is enough on its own —
## ducking behind something counts as getting away without outrunning
## anyone.
const DISENGAGE_WITH_COVER_DISTANCE: float = 14.0

var turn_order: Array[Unit] = []
## Full passes through turn_order — 1 for the very first turn, incrementing
## each time _turn_index wraps to 0. Unaffected by delay_turn, which only
## reorders within the same pass.
var round_number: int = 0

var phase: Phase = Phase.OUT_OF_COMBAT:
	set(value):
		if phase == value:
			return
		phase = value
		phase_changed.emit(value)

var is_running: bool:
	get: return phase != Phase.OUT_OF_COMBAT

var current_unit: Unit:
	get:
		if _turn_index >= 0 and _turn_index < turn_order.size():
			return turn_order[_turn_index]
		return null

var _turn_index: int = -1
var _pending_delay_positions: int = -1

## Set by CombatManager.start_from_hostile_act — this unit's triggering
## attack already spent an attack action out of combat (see
## UnitCombat._maybe_trigger_combat), so _begin_unit_turn_actions
## re-applies that the first time its own turn starts, undoing the fresh
## has_attacked=false that reset_turn_actions would otherwise hand it.
## Self-clearing: read and nulled the one time it's consumed.
var _skip_first_action_for: Unit = null


## Builds initiative order and starts. Initiative = dexterity, highest
## first; ties broken by a value rolled once per unit BEFOREHAND, not
## inside the comparator — a sort comparator can be called more than once
## for the same pair, and one that re-rolls each call gives inconsistent
## answers, which Godot flags as a bad comparison function and can leave
## the sort broken.
func begin(combatants: Array[Unit], skip_first_action_for: Unit = null) -> void:
	turn_order = combatants.filter(func(u): return is_instance_valid(u) and u.is_alive())

	var tiebreak: Dictionary = {}
	for unit in turn_order:
		tiebreak[unit] = randi_range(1, 6)

	turn_order.sort_custom(func(a: Unit, b: Unit) -> bool:
		if a.get_stat("DX") != b.get_stat("DX"):
			return a.get_stat("DX") > b.get_stat("DX")
		return tiebreak[a] > tiebreak[b]
	)

	for unit in turn_order:
		_adopt(unit)

	_skip_first_action_for = skip_first_action_for
	_turn_index = -1
	round_number = 0
	phase = Phase.TURN_STARTING
	SystemLog.print("[b]--- Combat started ---[/b]")
	combat_started.emit(turn_order)
	_advance_turn.call_deferred()


## Claims a unit for this encounter — the per-unit signal wiring plus the
## back-reference that lets any code holding a Unit ask which fight it is
## in without searching every encounter (see Unit.encounter).
func _adopt(unit: Unit) -> void:
	unit.encounter = self
	if not unit.died.is_connected(_on_unit_died):
		unit.died.connect(_on_unit_died)
	# Anything that displaces a unit mid-turn (Knockback, Shove, Jump's
	# move_caster_effect) finishes by emitting ability_used and none of them
	# go through Unit.move_to(), so none trigger an occupancy update alone.
	if not unit.ability_used.is_connected(_on_ability_used):
		unit.ability_used.connect(_on_ability_used)


## Untyped parameter on purpose. A typed `unit: Unit` is validated at the
## CALL, before the body runs, so passing an already-freed unit errors
## there rather than hitting the guard below — and finish() legitimately
## iterates a turn_order that can contain units freed this same frame
## (death_cleanup_delay of 0 frees immediately). The guard has to be
## reachable to be useful.
func _release(unit) -> void:
	if not is_instance_valid(unit):
		return
	if unit.encounter == self:
		unit.encounter = null
	if unit.died.is_connected(_on_unit_died):
		unit.died.disconnect(_on_unit_died)
	if unit.ability_used.is_connected(_on_ability_used):
		unit.ability_used.disconnect(_on_ability_used)


## Injects a unit into this running fight — a summon, or someone who walked
## in. Slots in right after after_unit (defaults to whoever is acting,
## since that's the summoner in the common case) rather than re-rolling
## into initiative order: simpler bookkeeping, and summoning gives
## near-immediate tempo instead of a slot that might land far away.
##
## Does NOT reset_turn_actions — that happens once, when its own turn
## naturally comes up, same as any other combatant.
func add_unit(unit: Unit, after_unit: Unit = null) -> void:
	if phase == Phase.OUT_OF_COMBAT or turn_order.has(unit):
		return

	_adopt(unit)

	var insert_index: int = _turn_index + 1
	if after_unit:
		var after_index: int = turn_order.find(after_unit)
		if after_index != -1:
			insert_index = after_index + 1

	turn_order.insert(insert_index, unit)

	# Inserting AT OR BEFORE the current slot pushes whoever sits there one
	# place further along — without this, current_unit silently starts
	# pointing at the wrong combatant.
	if insert_index <= _turn_index:
		_turn_index += 1

	unit_joined_combat.emit(unit)


## The inverse, with the same _turn_index correction for the same reason:
## removing an entry at or before the current slot shifts everything after
## it down one.
##
## Deliberately does NOT clear temporary faction hostility (FactionRelations
## clears that when combat properly ends). Something you ran away from is
## still angry with you when you come back.
func remove_unit(unit: Unit) -> void:
	var index: int = turn_order.find(unit)
	if index == -1:
		return

	turn_order.remove_at(index)
	if index <= _turn_index:
		_turn_index -= 1

	_release(unit)
	unit_left_combat.emit(unit)
	_check_combat_end()


func finish(winning_faction: StringName = &"") -> void:
	if winning_faction == &"":
		SystemLog.print("[b]--- Combat ended: mutual wipe ---[/b]")
	else:
		SystemLog.print("[b]--- Combat ended: %s wins ---[/b]" % LogFormat.faction_name(winning_faction))

	phase = Phase.OUT_OF_COMBAT
	for unit in turn_order:
		_release(unit)
	turn_order.clear()
	_turn_index = -1
	combat_ended.emit(winning_faction)


## Call once the acting unit is done (attacked, moved, passed).
##
## If it still has something in flight (mid-move, or an async ability
## effect like Jump's arc), the request is ACCEPTED but deferred: this
## connects to became_idle and re-calls itself, rather than cutting the
## action off or silently dropping the request.
##
## Advancing then goes through call_deferred rather than a direct call: if
## the next unit resolves instantly (AI already in reach, attacks, ends its
## turn immediately), calling _advance_turn synchronously would nest that
## whole resolution inside this frame — and several units doing that
## back-to-back gives an effectively recursive chain with no base case.
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

	# Catches anything that displaced a unit at the tail end of this turn
	# without going through ability_used/move_to's own occupancy update.
	NavigationGrid.update_occupancy(get_tree(), [unit])
	turn_ended.emit(unit)
	_try_disengage(unit)
	_advance_turn.call_deferred()


## Gives up the current slot and reinserts `positions` further along the
## SAME pass — positions=1 swaps with whoever would go next. Not an extra
## turn; still exactly one activation per cycle, just relocated.
##
## Only the unit stepping into the vacated slot gets reset_turn_actions.
## Whatever the delaying unit already did is done; it gets a full fresh
## turn when its now-later slot comes up.
##
## Same busy-deferral as end_turn. Can only be called by whoever's turn it
## currently is.
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
	_begin_unit_turn_actions(next_unit)
	_log_and_emit_turn_started(next_unit)


## reset_turn_actions plus immediately re-consuming the attack action if
## this is _skip_first_action_for. BOTH places a turn actually begins route
## through here, so a triggering attacker's turn-skip can't apply on one
## path and silently not the other.
func _begin_unit_turn_actions(unit: Unit) -> void:
	unit.reset_turn_actions()
	if unit == _skip_first_action_for:
		unit.has_attacked = true
		_skip_first_action_for = null


func _advance_turn() -> void:
	if phase == Phase.OUT_OF_COMBAT:
		return

	# Captured before turn_order is reassigned — filter() returns a NEW
	# array, so this keeps the original unfiltered ordering (and the index
	# to resume from) even after turn_order is replaced below.
	var pre_filter_order: Array[Unit] = turn_order
	var search_start: int = _turn_index + 1

	# is_instance_valid guards a unit whose node was already freed
	# (death_cleanup_delay == 0 frees immediately) — this array is this
	# encounter's own snapshot, not tied to the "units" group, so it doesn't
	# automatically stop referencing a freed node.
	turn_order = turn_order.filter(func(u): return is_instance_valid(u) and u.is_alive())

	if _check_combat_end():
		return

	# Walk forward from where the finished turn left off, in the ORIGINAL
	# pre-filter order, taking the first unit still alive — correct however
	# many died this pass, including whoever just acted. Deriving the new
	# index from that unit's post-filter position instead broke when it died
	# in the same synchronous batch as someone EARLIER in turn_order (an AoE
	# catching its own caster and a nearby ally — AreaDamageEffect's
	# affects_allies supports exactly that): the stale index landed one slot
	# short and silently skipped whoever should have gone next. Needs no
	# special case for the first call either — _turn_index starts at -1, so
	# search_start is already 0.
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
	if unit == null:
		return
	phase = Phase.TURN_STARTING
	# Marks every OTHER living unit's footprint occupied, and this unit's
	# own excluded (its standing position can't block its own path query).
	# Once per turn is the right cadence: nothing else moves until this
	# turn ends.
	NavigationGrid.update_occupancy(get_tree(), [unit])
	_begin_unit_turn_actions(unit)
	unit.tick_statuses()

	# tick_statuses can kill the unit outright (a Bleeding tick) or, through
	# that death, end the fight — re-check rather than assuming the state
	# from a few lines up still holds.
	if phase == Phase.OUT_OF_COMBAT:
		return
	if not is_instance_valid(unit) or not unit.is_alive():
		_advance_turn.call_deferred()
		return

	_log_and_emit_turn_started(unit)


## Shared by both places a turn starts, and the one place ACTIVE is
## entered from.
func _log_and_emit_turn_started(unit: Unit) -> void:
	phase = Phase.ACTIVE
	SystemLog.print("[u]%s's turn[/u]" % LogFormat.unit_name(unit))
	turn_started.emit(unit)


## Drops a unit that has genuinely got away — far enough from every living
## hostile that none of them can see it. Checked at the end of its own
## turn, the only moment its position is settled.
##
## Per-character, the same rule BG3 uses: you leave a fight by putting
## distance and cover between yourself and everyone in it, and you leave
## alone rather than dragging the party out with you.
##
## This is what makes FleeBehavior mean anything. It scored retreats
## correctly long before this existed, but nothing could end a fight except
## a total wipe — so a demon that decided to run had nowhere to run TO, and
## jogged in place until something killed it.
func _try_disengage(unit: Unit) -> void:
	if phase == Phase.OUT_OF_COMBAT or not is_instance_valid(unit) or not unit.is_alive():
		return
	if turn_order.size() <= 1:
		return

	for other in turn_order:
		if other == unit or not is_instance_valid(other) or not other.is_alive():
			continue
		if not unit.is_hostile_to(other):
			continue
		var distance: float = unit.distance_to(other)
		if distance >= DISENGAGE_DISTANCE:
			continue
		# Short of that, cover finishes the job. Requiring BOTH distance and
		# no-line-of-sight at every range was the first version of this rule
		# and it was wrong — across open ground nobody could ever escape,
		# because a clear sightline persists long past any sane running
		# distance.
		if distance >= DISENGAGE_WITH_COVER_DISTANCE and not LineOfSight.has_clear_shot(other, unit):
			continue
		return

	SystemLog.print("%s slips away from the fight." % LogFormat.unit_name(unit))
	remove_unit(unit)


## Ends the moment no two living combatants are still hostile to each
## other, rather than waiting for one side to be wiped out. Without it, one
## side dying just left the other cycling turns forever with nothing to do
## — not a crash, but an unrecoverable stall with no way back to player
## control.
##
## Relation-based (pairwise is_hostile_to), not faction-tag-based: counting
## distinct faction strings meant a non-hostile bystander pulled into the
## same turn_order could keep a finished fight running forever.
func _check_combat_end() -> bool:
	var living: Array[Unit] = []
	for unit in turn_order:
		if is_instance_valid(unit) and unit.is_alive():
			living.append(unit)

	for i in living.size():
		for j in range(i + 1, living.size()):
			if living[i].is_hostile_to(living[j]):
				return false  # somebody here still wants to fight somebody else here

	finish(living[0].faction if not living.is_empty() else &"")
	return true


func _on_unit_died(_unit: Unit) -> void:
	# Deliberately BEFORE the phase check and unconditional on it: an AoE
	# that wipes a faction fires one died signal per kill, synchronously, in
	# the same call stack — if THIS death ends the fight, every death after
	# it in that batch would otherwise hit the early return and never get
	# occupancy updated. See this class's header on why one phase value is
	# what actually prevents that class of bug.
	NavigationGrid.update_occupancy(get_tree(), [current_unit] if current_unit else [])

	if phase == Phase.OUT_OF_COMBAT:
		return

	# Check win/loss the instant anyone dies rather than at the next turn
	# boundary — a death on someone else's turn would otherwise leave the
	# fight "running" with a side already eliminated.
	if _check_combat_end():
		return

	# If whoever is acting dies mid-turn, move along instead of waiting on
	# an end_turn that may never come.
	#
	# Gated on ACTIVE specifically, NOT TURN_STARTING: tick_statuses (called
	# from _advance_turn while still TURN_STARTING) can itself kill the unit
	# it just ticked, and _advance_turn already re-checks for exactly that.
	# Without this gate BOTH fire for the same death, queuing two deferred
	# advances instead of one, which silently skips the next unit entirely.
	# Confirmed by testing summon expiry — not hypothetical.
	if phase == Phase.ACTIVE and current_unit != null and not current_unit.is_alive():
		_advance_turn.call_deferred()


## Knockback, Shove, Jump's move_caster_effect and anything else that
## displaces a unit through an ability rather than Unit.move_to() — this is
## the catch-all for "what just resolved might have moved someone."
func _on_ability_used(attacker: Unit, _target, _result: Dictionary) -> void:
	NavigationGrid.update_occupancy(get_tree(), [attacker])
