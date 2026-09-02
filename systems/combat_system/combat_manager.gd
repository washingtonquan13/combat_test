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

## The set of fights waiting on a player who isn't watching them changed.
## See _note_attention — this is what makes a split party's off-screen
## fight visible instead of silently stalled.
signal attention_changed()

## Where a fight just ended. combat_ended carries only the winner, and
## anything reacting per-world needs to know WHICH world — asking the
## encounter is too late, since finish() clears its combatants before
## announcing (see Encounter.world_3d).
signal combat_ended_in_world(world: World3D)

## How close another unit needs to be to the attacker OR the target (same
## faction as whichever one it's near) to get pulled into a freshly
## triggered fight. A plain tunable constant, same convention as
## combat_ai.gd's MAX_MOVE_ATTEMPTS_PER_TURN.
const AGGRO_PULL_RADIUS: float = 10.0

## Every fight currently running IN THE LOADED WORLD — backed by its
## WorldContext rather than stored here, so fights belong to a world and
## end with it. Arrays are references in GDScript, so append/erase through
## this property mutate the context's own list; no writer changes.
##
## Falls back to a local array when no world is loaded, which is both the
## main menu and the headless test harness — neither has a world, and both
## legitimately start fights.
var encounters: Array[Encounter]:
	get:
		var context: WorldContext = WorldManager.context()
		return context.encounters if context else _detached_encounters

var _detached_encounters: Array[Encounter] = []


## Every fight in every loaded world, not just the one on screen.
##
## `encounters` above is deliberately the FOCUSED world's list, because
## that is what the UI means by "the fights". Anything reasoning about
## whether a fight exists at all — is anything running, does the mode
## need to change, has this one ended — has to look wider than the
## player is looking, or a battle in another world is invisible to the
## systems that are supposed to be managing it.
func all_encounters() -> Array[Encounter]:
	var out: Array[Encounter] = []
	for context in WorldManager.all_contexts():
		for encounter in context.encounters:
			if is_instance_valid(encounter) and not out.has(encounter):
				out.append(encounter)
	for encounter in _detached_encounters:
		if is_instance_valid(encounter) and not out.has(encounter):
			out.append(encounter)
	return out


## Where a fight among these combatants belongs: the world they are
## standing in, NOT the world the player happens to be watching.
## Getting this wrong files the fight under someone else's world,
## where its own world's teardown will not end it and its own world's
## residency will not count it.
func _encounter_list_for(combatants: Array[Unit]) -> Array[Encounter]:
	for unit in combatants:
		if is_instance_valid(unit):
			var context: WorldContext = WorldManager.context_for(unit)
			if context:
				return context.encounters
	return _detached_encounters

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
	for encounter in all_encounters():
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
	_encounter_list_for(combatants).append(encounter)
	_relay(encounter)

	if _involves_player(combatants):
		focused_encounter = encounter

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
	for unit in UnitQuery.living_units_near(attacker, roster):
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
		# The fight where this unit IS, not the one on screen. Falling back
		# to focused_encounter enrolled a unit in a battle in another area
		# entirely — the debug spawner did exactly this.
		target = running_encounter_in_world_of(unit)
	if not target:
		return

	# The choke point, guarded so no caller can do it again. ONE
	# cross-world member is enough to poison an encounter: from then on
	# _draw_in_latecomers finds a legitimately same-world combatant inside
	# it and pulls in more, and two areas' fights become one — which looks
	# exactly like "the system only supports a single combat".
	if not _shares_world_with(unit, target):
		push_warning("CombatManager.add_unit_to_combat refused: %s is not in that fight's world." % unit.name)
		return
	target.add_unit(unit, after_unit)
	# A fight can BECOME the player's after it started — walking into an
	# NPC scrap is a supported way to join one (see DetectionManager). The
	# mode has to follow, or the player is in a fight with an exploration
	# HUD and no turn controls.
	if unit.is_player_controlled():
		if focused_encounter == null:
			focused_encounter = target


## Rebuilds a saved fight in whatever world is now loaded, and picks it
## up where it was. Returns null when it cannot be rebuilt.
##
## A fight needs at least two sides present to still be a fight: if the
## save named combatants who are not here — an unnamed one that could
## not be written down, or one that has since died — restoring a
## one-sided battle would leave the player stuck in a fight with nobody.
## Better to let it not resume.
func restore_combat(state: Dictionary) -> Encounter:
	var units: Array[Unit] = []
	for id in state.get("turn_order", []):
		var unit: Unit = _find_by_id(StringName(id))
		if unit:
			units.append(unit)

	var factions: Array[StringName] = []
	for unit in units:
		if not factions.has(unit.faction):
			factions.append(unit.faction)
	if units.size() < 2 or factions.size() < 2:
		if not units.is_empty():
			push_warning("CombatManager.restore_combat: only %d combatant(s) found; not resuming." % units.size())
		return null

	var encounter := Encounter.new()
	encounter.name = "Encounter%d" % (encounters.size() + 1)
	add_child(encounter)
	_encounter_list_for(units).append(encounter)
	_relay(encounter)

	if _involves_player(units):
		focused_encounter = encounter

	encounter.resume(units, int(state.get("turn_index", 0)), int(state.get("round", 1)))
	return encounter


## In the world on screen, which is the one a restore is rebuilding.
## Whether a fight is running in this unit's own world.
##
## The question any_combat_running() used to be asked for. That one is
## "is anything happening anywhere", which was the same question while
## there was one world and is a different one now: a battle two areas
## away is no reason for nothing to be able to start here.
## Takes any Node3D, not just a Unit: an overlay drawn into a world wants
## the same question about the world it is drawn in.
func combat_running_in_world_of(node: Node3D) -> bool:
	if not is_instance_valid(node) or not node.is_inside_tree():
		return false
	var world: World3D = node.get_world_3d()
	for encounter in all_encounters():
		if not is_instance_valid(encounter) or not encounter.is_running:
			continue
		for combatant in encounter.turn_order:
			if is_instance_valid(combatant) and combatant.is_inside_tree() \
					and combatant.get_world_3d() == world:
				return true
	return false


func _find_by_id(id: StringName) -> Unit:
	if id == &"":
		return null
	var context: WorldContext = WorldManager.context()
	for unit in UnitQuery.living_units(get_tree()):
		if context and not context.contains(unit):
			continue
		if unit.persistent_id == id:
			return unit
	return null


## The running fight in this unit's own world, or null.
##
## What "which fight should this unit join" actually means. It used to
## be answered with focused_encounter, which is "the fight the player is
## looking at" — the same answer while there was one world, and a
## different question once there was more than one.
func running_encounter_in_world_of(unit: Unit) -> Encounter:
	if not is_instance_valid(unit) or not unit.is_inside_tree():
		return null
	for candidate in all_encounters():
		if not is_instance_valid(candidate) or not candidate.is_running:
			continue
		if _shares_world_with(unit, candidate):
			return candidate
	return null


## Whether this fight is happening where this unit is standing.
func _shares_world_with(unit: Unit, encounter: Encounter) -> bool:
	if not is_instance_valid(unit) or not unit.is_inside_tree():
		return false
	if not is_instance_valid(encounter):
		return false
	var world: World3D = unit.get_world_3d()
	for combatant in encounter.turn_order:
		if is_instance_valid(combatant) and combatant.is_inside_tree() \
				and combatant.get_world_3d() == world:
			return true
	# A fight with nobody left in a world cannot be joined in one.
	return encounter.world_3d() == world


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
	encounter.turn_started.connect(func(unit):
		_note_attention(encounter, unit)
		turn_started.emit(unit)
	)
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
	# From wherever it actually lives, which may not be the world on screen.
	for context in WorldManager.all_contexts():
		context.encounters.erase(encounter)
	_detached_encounters.erase(encounter)
	if _awaiting.has(encounter):
		_awaiting.erase(encounter)
		attention_changed.emit()
	if focused_encounter == encounter:
		# Hand focus to another fight the player is still in, if there is
		# one, so the UI follows them rather than going blank mid-battle.
		focused_encounter = null
		for other in encounters:
			if other.is_running and _involves_player(other.turn_order):
				focused_encounter = other
				break

	var where: World3D = encounter.world_3d()
	combat_ended.emit(winning_faction)
	combat_ended_in_world.emit(where)
	encounter.queue_free()


# --- Mode -------------------------------------------------------------
# Reference-counted rather than pushed per encounter. GameMode is a STACK,
# so pushing COMBAT for each of two simultaneous fights and popping as each
# ends leaves it unbalanced — the mode would still read COMBAT after both
# finished. One push when the first fight starts, one pop when the last
# ends.

## Whether a fight the player is both PART OF and LOOKING AT is running.
##
## This is what makes the game's mode COMBAT. GameMode asks it; nothing
## tells GameMode anything. It used to be pushed — _mode_claims tracked
## which encounters held the mode, _combat_mode_depth counted the pushes,
## and GameMode kept a third copy in its stack. All three could disagree,
## and reliably did (see game_mode.gd's own header).
##
## Two conditions, and both were learned the hard way. It must involve a
## player unit — two NPCs going at it never put the player in combat mode,
## which was always true in principle and became reachable the moment
## worlds stayed live. And it must be in the world on screen: once the
## party can split, the player can be in a fight in one world and walking
## around peacefully in another, and claiming mode for the fight they
## cannot see would freeze the world they can — including refusing to let
## them travel to the fight that wants them.
##
## Answered fresh on every call, because the answer changes for reasons
## that are not events on any encounter at all: the player looking
## somewhere else changes it without anything happening in the fight. That
## is precisely what a pushed mode could not express.
func a_watched_fight_is_running() -> bool:
	for encounter in all_encounters():
		if not is_instance_valid(encounter):
			continue
		if encounter.is_running 				and _involves_player(encounter.turn_order) 				and _is_in_focused_world(encounter):
			return true
	return false


func _is_in_focused_world(encounter: Encounter) -> bool:
	var context: WorldContext = WorldManager.context()
	if context == null:
		# No world loaded means nowhere else to be, so every fight is the
		# one on screen. Keeps a fight staged outside the world system —
		# the headless harness, the debug combat harness — behaving exactly
		# as it did before worlds could be elsewhere.
		return true
	for unit in encounter.turn_order:
		if is_instance_valid(unit) and context.contains(unit):
			return true
	return false


# --- Attention --------------------------------------------------------
# A fight in a world the player isn't looking at runs perfectly well right
# up to the moment it reaches one of THEIR units, and then it simply waits
# — correctly, since the turn loop blocks on input, but silently. With the
# party able to split across live worlds, that is a fight stalled off
# screen with nothing anywhere saying so.
#
# Deliberately NOT resolved by stealing focus. Yanking the camera out of
# whatever the player is doing to drop them into a fight they didn't know
# existed is worse than the silence. This raises a flag and leaves the
# decision with them; the party panel renders it, and clicking the
# portrait is already the way to go there (see unit_portrait._on_pressed).

var _awaiting: Array[Encounter] = []


func _ready() -> void:
	# Deferred, NOT connected here directly. This autoload is constructed
	# long before WorldManager (2nd vs 18th in project.godot), so reaching
	# for it during _ready finds nothing and the connection silently never
	# happens — which shows up much later as combat mode simply failing to
	# follow the player between worlds. A deferred call runs once every
	# autoload exists.
	_connect_to_world.call_deferred()


func _connect_to_world() -> void:
	# Switching worlds is the other half of both things below: which fight
	# is on screen decides combat mode, and a fight stops waiting the moment
	# the player is actually looking at it.
	if not WorldManager.world_focused.is_connected(_on_world_focused):
		WorldManager.world_focused.connect(_on_world_focused)


## Fights currently waiting on a player unit the player cannot see.
func encounters_awaiting_attention() -> Array[Encounter]:
	return _awaiting


## Whether this unit is the one an unwatched fight is waiting on — what
## the party panel asks to decide how to render a portrait.
func unit_awaiting_attention(unit: Unit) -> bool:
	for encounter in _awaiting:
		if is_instance_valid(encounter) and encounter.current_unit == unit:
			return true
	return false


func _note_attention(encounter: Encounter, unit: Unit) -> void:
	var waiting: bool = is_instance_valid(unit) and unit.is_player_controlled() 		and not _is_watched(unit)

	if waiting:
		if _awaiting.has(encounter):
			return
		_awaiting.append(encounter)
		SystemLog.print("%s is waiting for orders%s." % [
			LogFormat.unit_name(unit), _where(unit)])
		attention_changed.emit()
		return

	if _awaiting.has(encounter):
		_awaiting.erase(encounter)
		attention_changed.emit()


func _on_world_focused(_world: Node) -> void:
	var changed: bool = false
	for encounter in _awaiting.duplicate():
		# current_unit is validated HERE and not left to _is_watched's own
		# guard: a typed Unit parameter rejects a previously-freed object
		# at the call boundary, so the check inside it never gets to run.
		# A fight whose unit was freed while it waited for attention
		# crashed this loop outright.
		if not is_instance_valid(encounter) 				or not is_instance_valid(encounter.current_unit) 				or _is_watched(encounter.current_unit):
			_awaiting.erase(encounter)
			changed = true
	if changed:
		attention_changed.emit()


## Whether the player can actually see this unit right now. Not "is it in
## the focused world" spelled out at every call site — a unit with no
## context at all (no world loaded) counts as unwatched.
##
## The is_instance_valid guard below only catches a null. A FREED unit
## never reaches it: the typed parameter rejects the object first. Callers
## holding a unit that may have been freed have to check before calling.
func _is_watched(unit: Unit) -> bool:
	if not is_instance_valid(unit):
		return true
	var context: WorldContext = WorldManager.context()
	return context != null and context.contains(unit)


## " in the Cathedral", or "" when the area has no name to give.
func _where(unit: Unit) -> String:
	var area: AreaDefinition = WorldManager.area_of(unit)
	if area == null or area.display_name == "":
		return ""
	return " in %s" % area.display_name
