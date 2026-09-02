extends AiTestCase
## A fight in a world the player isn't looking at knows how to ask for them.
##
## An unfocused world runs perfectly well right up to the moment its fight
## reaches one of the player's units, and then it waits — correctly, since
## the turn loop blocks on input, but silently. With the party able to
## split across live worlds, that is a battle stalled off screen with
## nothing anywhere saying so.
##
## Two claims, and the second matters more than the first: the game says
## it needs you, and it does NOT drag you there. Stealing focus out of
## whatever the player is doing to drop them into a fight they did not
## know existed is worse than the silence it fixes.
##
## Also pins down the mode rule that makes any of this reachable: COMBAT
## belongs to the fight on SCREEN. A fight the player cannot see must not
## freeze the world they can — least of all by refusing to let them
## travel to the fight that wants them.

const HOME := &"test_arena"
const AWAY := &"test_area_2"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _saved_factions: Array = []

var _stayer: Unit = null
var _enemy: Unit = null
var _fight: Encounter = null


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false, "WorldManager refused")
		return

	if await _split_the_party():
		await _a_stalled_fight_asks_for_the_player()
		_it_does_not_drag_the_player_there()
		_combat_mode_belongs_to_the_fight_on_screen()
		_indicators_do_not_draw_across_worlds()
		await _going_there_settles_it()
		_a_fight_only_detains_the_people_in_it()
		await _looking_away_from_a_fight_is_allowed()

	_cleanup()


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	# CombatAI off: turns must only advance when this suite says so, or the
	# fight resolves itself while the assertions are still being made.
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []

	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


## One member stays in HOME; everyone else goes to AWAY, which is where
## the player is looking.
func _split_the_party() -> bool:
	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var everyone: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			everyone.append(unit)
	if everyone.size() < 2:
		check("SETUP: a party big enough to split", false,
			"%d member(s)" % everyone.size())
		return false

	_stayer = everyone[0]
	var going: Array[Unit] = everyone.slice(1)

	WorldManager.load_area(AWAY, &"", going)
	await get_tree().process_frame

	var elsewhere: bool = is_instance_valid(_stayer) \
		and not WorldManager.context().contains(_stayer)
	check("SETUP: one member is left in a world the player isn't in", elsewhere)
	return elsewhere


## Start a fight around the member left behind and walk it to their turn.
func _a_stalled_fight_asks_for_the_player() -> void:
	_enemy = _spawn_enemy_beside(_stayer)
	await get_tree().physics_frame

	var combatants: Array[Unit] = [_stayer, _enemy]
	_fight = CombatManager.start_combat(combatants)
	await get_tree().process_frame

	# Walk the order round to the player's unit. With the AI off nothing
	# advances on its own, so this is exactly as many turns as it takes.
	var guard: int = 0
	while _fight.is_running and _fight.current_unit != _stayer and guard < 6:
		CombatManager.end_turn(_fight.current_unit)
		await get_tree().process_frame
		guard += 1

	check("SETUP: the off-screen fight reached the player's unit",
		_fight.is_running and _fight.current_unit == _stayer,
		"stopped at %s" % str(_fight.current_unit))

	check("a fight the player cannot see says it is waiting for them",
		CombatManager.encounters_awaiting_attention().has(_fight),
		"stalled silently — nothing anywhere would tell the player")
	check("and names WHO it is waiting on, so the panel can mark them",
		CombatManager.unit_awaiting_attention(_stayer))


## The important half.
func _it_does_not_drag_the_player_there() -> void:
	check("the player is still where they chose to be",
		WorldManager.current_area() != null
			and WorldManager.current_area().id == AWAY,
		"focus was stolen by the off-screen fight")


## The rule that makes going there possible at all.
func _combat_mode_belongs_to_the_fight_on_screen() -> void:
	check("a fight the player cannot see does not put them in combat mode",
		GameMode.current_mode() != GameMode.Mode.COMBAT,
		"the visible world was frozen by an invisible fight")
	check("so they are free to go and answer it",
		WorldManager.can_travel(),
		"locked out of travelling to the fight that wants them")


## Indicators draw for "the active unit", which OUT of combat is the
## selection (cleared on a focus switch) but IN combat is the focused
## encounter's current unit — and that encounter can be running in a
## world the player has looked away from. A line of sight, a movement
## range or a jump arc for somebody in another area then keeps being
## drawn over the area now on screen, pointing at geometry that is not
## there.
##
## Asserted at the shared base rather than per indicator: every 3D
## indicator inherits _get_active_unit, so this is the one place the
## guard can live and the one place it can be checked.
func _indicators_do_not_draw_across_worlds() -> void:
	check("SETUP: the fight the player is not watching owns current_unit",
		CombatManager.in_combat and CombatManager.current_unit == _stayer,
		"current_unit is %s" % str(CombatManager.current_unit))

	var probe := IndicatorBase.new()
	_root.add_child(probe)
	var drawn_for: Unit = probe._get_active_unit()
	probe.queue_free()

	check("indicators draw for nobody while their unit is in another world",
		drawn_for == null,
		"drawing for %s, who is not in the world on screen" % str(drawn_for))


func _going_there_settles_it() -> void:
	var went: bool = WorldManager.focus_world_of(_stayer)
	await get_tree().process_frame

	check("looking at the waiting fight is allowed", went)
	check("and it stops asking once the player is actually there",
		not CombatManager.encounters_awaiting_attention().has(_fight),
		"still flagged despite being on screen")
	check("now the player IS in combat, because this is the fight on screen",
		GameMode.current_mode() == GameMode.Mode.COMBAT,
		"arrived at the fight without entering combat mode")


## A fight detains the people IN it, not everyone who happens to be
## nearby. can_travel() used to refuse every load whenever anything on
## screen was fighting, which with a split party meant half of it could
## not walk out of a room the other half was brawling in.
func _a_fight_only_detains_the_people_in_it() -> void:
	var detained: Array[Unit] = [_stayer]
	check("someone in the fight cannot travel out of it",
		not WorldManager.can_travel(detained),
		"walked out mid-turn")

	var bystander: Unit = null
	for unit in PartyManager.members:
		if is_instance_valid(unit) and unit != _stayer and not unit.in_combat():
			bystander = unit
			break
	if bystander == null:
		check("SETUP: a party member outside the fight", false)
		return

	var free_to_go: Array[Unit] = [bystander]
	check("but someone who is not in it still can",
		WorldManager.can_travel(free_to_go),
		"a fight they are not part of refused their travel")


## Looking away is not leaving. Switching focus moves nobody, so a fight
## must not block it — gated on can_travel() (which asks whether people may
## LEAVE, and a fight detains the people in it), commanding a group in a
## battle meant never being able to look at the rest of the party again
## until it ended.
func _looking_away_from_a_fight_is_allowed() -> void:
	var here: PartyGroup = PartyManager.group_of(_stayer)
	var elsewhere: PartyGroup = null
	for group in PartyManager.groups:
		if group != here and not group.is_empty():
			elsewhere = group
			break
	if elsewhere == null:
		check("SETUP: a group somewhere else to look at", false)
		return

	check("a fight the player is IN still refuses to let them leave it",
		not WorldManager.can_travel(),
		"travel was allowed out of a live battle")
	check("but they can still look at a group somewhere else",
		WorldManager.can_switch_focus(),
		"the fight blocked switching to a group that is not in it")

	var stayer_world: Node = _stayer.get_parent()
	var switched: bool = WorldManager.focus_group(elsewhere)
	await get_tree().process_frame

	check("and switching actually works", switched)
	check("while the fight carries on where it was",
		is_instance_valid(_fight) and _fight.is_running,
		"looking away ended it")
	check("and nobody was carried out of it",
		is_instance_valid(_stayer) and _stayer.get_parent() == stayer_world,
		"a combatant moved because the player looked elsewhere")


func _spawn_enemy_beside(ally: Unit) -> Unit:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	ally.get_parent().add_child(unit)
	unit.faction = &"enemy"
	unit.strength = 10
	unit.dexterity = 10
	unit.maximum_hp = 20
	unit.current_hp = 20
	var abilities: Array[Ability] = [melee()]
	unit.abilities = abilities
	unit.global_position = ally.global_position + Vector3(3.0, 0.0, 0.0)
	unit.reset_turn_actions()
	return unit


func _cleanup() -> void:
	if is_instance_valid(_fight) and _fight.is_running:
		_fight.finish(&"")
	if is_instance_valid(_enemy):
		if _enemy.is_in_group("units"):
			_enemy.remove_from_group("units")
		if _enemy.get_parent():
			_enemy.get_parent().remove_child(_enemy)
		_enemy.queue_free()

	WorldManager.unload()
	CombatAi.ai_factions = _saved_factions
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()
