extends Node
## Autoload singleton. Register as "CombatManager" under
## Project > Project Settings > AutoLoad (same pattern as SelectionManager).
##
## Owns the SET of running fights. One fight's own turn order, rounds and
## phase live on Encounter (see that file); this decides who starts one,
## which one the player is looking at, and what the rest of the game is
## told about them.
##
## It used to be one fight, stored directly here — and "is combat
## happening" was therefore a global truth consulted in 37 places. That had
## a concrete cost: a party member standing outside a battle was still
## bound by its turn order and could not be commanded at all, so ambushes,
## flanking and held reserves were unreachable rather than awkward.
##
## THE DELEGATING ACCESSORS BELOW ARE LOAD-BEARING, not convenience.
## in_combat/current_unit/turn_order/phase/round_number all forward to the
## focused encounter, which is what lets every UI reader — initiative_row,
## player_interaction_state, ability_manager, ability_hotbar,
## movement_indicator — keep working completely unchanged. Code that means
## "is THIS unit fighting" should ask the unit instead (Unit.in_combat()).
## The distinction is the whole point: those two questions were the same
## question before, and conflating them is what caused the bug above.

## Emitted for every encounter, relayed from whichever one fired it — so
## the ~26 existing connections keep working without learning that
## encounters exist. Anything that genuinely needs to know WHICH fight can
## take the encounter from the unit involved.
signal combat_started(turn_order: Array[Unit])
signal turn_started(unit: Unit)
signal turn_ended(unit: Unit)
signal combat_ended(winning_faction: StringName)
signal round_started(round_number: int)
signal phase_changed(phase: Encounter.Phase)
signal unit_joined_combat(unit: Unit)
signal unit_left_combat(unit: Unit)

## How close another unit needs to be to the attacker OR the target (same
## faction as whichever one it's near) to get pulled into a freshly
## triggered fight. A plain tunable constant, same convention as
## combat_ai.gd's MAX_MOVE_ATTEMPTS_PER_TURN.
const AGGRO_PULL_RADIUS: float = 10.0

## Every fight currently running.
var encounters: Array[Encounter] = []

## The one the player is currently commanding, and what every legacy
## accessor below reports on. Set when an encounter the player is part of
## begins; cleared when it ends.
var focused_encounter: Encounter = null


# --- Legacy accessors ------------------------------------------------
# Every one of these answers "what is the player looking at," which is what
# the UI has always been asking even when it read like a global.

var in_combat: bool:
	get: return focused_encounter != null and focused_encounter.is_running


var turn_order: Array[Unit]:
	get: return focused_encounter.turn_order if focused_encounter else ([] as Array[Unit])


var current_unit: Unit:
	get: return focused_encounter.current_unit if focused_encounter else null


var round_number: int:
	get: return focused_encounter.round_number if focused_encounter else 0


var phase: Encounter.Phase:
	get: return focused_encounter.phase if focused_encounter else Encounter.Phase.OUT_OF_COMBAT


## True while ANY fight is running, focused or not — distinct from
## in_combat, which is specifically about the player's view. Used for
## global concerns like music that shouldn't care which fight it is.
func any_combat_running() -> bool:
	for encounter in encounters:
		# An encounter is queue_free()d as it ends, so it can briefly be
		# both freed and still referenced — by a snapshot of this array, or
		# during the same frame it was erased.
		if is_instance_valid(encounter) and encounter.is_running:
			return true
	return false


# --- Starting fights -------------------------------------------------

## Builds a fresh encounter around these combatants and starts it.
## Returns it, so a caller that needs to keep track of a specific fight
## can.
func start_combat(combatants: Array[Unit], skip_first_action_for: Unit = null) -> Encounter:
	var encounter := Encounter.new()
	encounter.name = "Encounter%d" % (encounters.size() + 1)
	add_child(encounter)
	encounters.append(encounter)
	_relay(encounter)

	if _involves_player(combatants):
		focused_encounter = encounter
	_push_combat_mode()

	encounter.begin(combatants, skip_first_action_for)
	return encounter


## Starts a fight from an out-of-combat hostile act (see
## UnitCombat._maybe_trigger_combat) or from being spotted (see
## DetectionManager). attacker and target are always in the roster; anyone
## else within AGGRO_PULL_RADIUS of EITHER, sharing that one's faction, is
## pulled in too.
##
## No longer refuses when a fight is already running — that guard existed
## because there could only be one. A second, unrelated fight elsewhere is
## now a legitimate thing to start. It does still refuse if either party is
## already fighting, since they'd otherwise end up in two turn orders at
## once.
func start_combat_from_hostile_act(attacker: Unit, target: Unit) -> Encounter:
	if attacker.in_combat() or target.in_combat():
		return null

	var roster: Array[Unit] = [attacker, target]
	for unit in UnitQuery.living_units(attacker.get_tree(), roster):
		if unit.in_combat():
			continue
		var joins_attacker: bool = unit.faction == attacker.faction and unit.distance_to(attacker) <= AGGRO_PULL_RADIUS
		var joins_target: bool = unit.faction == target.faction and unit.distance_to(target) <= AGGRO_PULL_RADIUS
		if joins_attacker or joins_target:
			roster.append(unit)

	return start_combat(roster, attacker)


# --- Forwarding to the right encounter -------------------------------

## Ends the given unit's turn. Takes the unit rather than assuming "the"
## current one, since with several fights running there is no single
## current unit — the caller always knows whose turn it is finishing
## (CombatAI has _acting_unit; the UI has the selection).
##
## Defaults to the focused encounter's current unit so an end-turn button
## with nothing more specific to say still works.
func end_turn(unit: Unit = null) -> void:
	var encounter: Encounter = _encounter_for(unit)
	if encounter:
		encounter.end_turn()


func delay_turn(unit: Unit, positions: int = 1) -> bool:
	var encounter: Encounter = _encounter_for(unit)
	return encounter.delay_turn(unit, positions) if encounter else false


## Adds a unit to a running fight — a summon, or someone who walked in.
## Without an explicit encounter it joins after_unit's, falling back to the
## focused one, which keeps every existing summon call site working.
func add_unit_to_combat(unit: Unit, after_unit: Unit = null, encounter: Encounter = null) -> void:
	var target: Encounter = encounter
	if target == null and after_unit != null:
		target = after_unit.encounter
	if target == null:
		target = focused_encounter
	if target:
		target.add_unit(unit, after_unit)


func remove_unit_from_combat(unit: Unit) -> void:
	if unit.encounter:
		unit.encounter.remove_unit(unit)


## Ends a specific fight, or the focused one.
func end_combat(winning_faction: StringName = &"", encounter: Encounter = null) -> void:
	var target: Encounter = encounter if encounter else focused_encounter
	if target:
		target.finish(winning_faction)


func _encounter_for(unit: Unit) -> Encounter:
	if unit and unit.encounter:
		return unit.encounter
	return focused_encounter


func _involves_player(combatants: Array[Unit]) -> bool:
	for unit in combatants:
		if is_instance_valid(unit) and unit.is_player_controlled():
			return true
	return false


# --- Relaying ---------------------------------------------------------

func _relay(encounter: Encounter) -> void:
	encounter.combat_started.connect(func(order): combat_started.emit(order))
	encounter.turn_started.connect(func(unit): turn_started.emit(unit))
	encounter.turn_ended.connect(func(unit): turn_ended.emit(unit))
	encounter.phase_changed.connect(func(p): phase_changed.emit(p))
	encounter.unit_joined_combat.connect(func(unit): unit_joined_combat.emit(unit))
	encounter.unit_left_combat.connect(func(unit): unit_left_combat.emit(unit))

	# round_started is relayed ONLY from the focused encounter. Surfaces are
	# WORLD state, not encounter state, and SurfaceManager ages every active
	# surface by one round on this signal — relaying it from every running
	# fight would age them once per fight per round, so two simultaneous
	# battles would burn a Grease patch twice as fast as one. The proper
	# home for surfaces is a per-world context in a later pass; until then
	# this is the approximation that keeps the common case correct.
	encounter.round_started.connect(func(n):
		if encounter == focused_encounter:
			round_started.emit(n)
	)

	encounter.combat_ended.connect(func(faction): _on_encounter_ended(encounter, faction))


func _on_encounter_ended(encounter: Encounter, winning_faction: StringName) -> void:
	encounters.erase(encounter)
	if focused_encounter == encounter:
		# Hand focus to another fight the player is still in, if there is
		# one, so the UI follows them rather than going blank mid-battle.
		focused_encounter = null
		for other in encounters:
			if other.is_running and _involves_player(other.turn_order):
				focused_encounter = other
				break

	_pop_combat_mode()
	combat_ended.emit(winning_faction)
	encounter.queue_free()


# --- Mode -------------------------------------------------------------
# Reference-counted rather than pushed per encounter. GameMode is a STACK,
# so pushing COMBAT for each of two simultaneous fights and popping as each
# ends leaves it unbalanced — the mode would still read COMBAT after both
# finished. One push when the first fight starts, one pop when the last
# ends.

var _combat_mode_depth: int = 0


func _push_combat_mode() -> void:
	_combat_mode_depth += 1
	if _combat_mode_depth == 1:
		GameMode.push_mode(GameMode.Mode.COMBAT)


func _pop_combat_mode() -> void:
	if _combat_mode_depth <= 0:
		return
	_combat_mode_depth -= 1
	if _combat_mode_depth == 0:
		GameMode.pop_mode()
