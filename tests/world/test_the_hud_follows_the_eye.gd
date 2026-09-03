extends AiTestCase
## The combat HUD belongs to the world on screen.
##
## Reported from play: with the party split — one group fighting in
## test_arena, the player walking somebody else out to another area — the
## End Turn button stayed on screen, offering to end a turn in a fight the
## player could not see and could not reach.
##
## The mechanism is an ordering trap, and it is why a world filter alone
## was not the fix. WorldManager._leave_focused() calls
## SelectionManager.deselect_all() (world_manager.gd:370) while _focused
## STILL points at the world being left (it is cleared fifteen lines
## later). deselect_all() empties the array and emits selection_changed;
## the button refreshes, finds no selection, falls through to its
## PartyManager loop, asks WorldManager.context() — which is still the
## OUTGOING world's — finds the fighter whose turn it is, and latches
## visible = true. Focus then moves and world_focused fires, and the
## button was not listening. The fight it refers to is stalled waiting on
## that same absent player, so no turn_started and no combat_ended ever
## arrives to correct it either. It just stays.
##
## Two fixes, one per half, and this suite has a check for each:
##   * end_turn_button.gd subscribes to world_focused, which is the only
##     signal that fires at all after the button has latched;
##   * _acting_unit() reads the context FIRST and filters the selection
##     branch by it, so a unit selected in the world you left stops being
##     an opinion about the world you are in (mirrors initiative_row.gd).
##
## And one more of the same family, since it is reached the same way:
## CombatManager relays turn_started from EVERY encounter, including
## unwatched ones, so a far fight coming back around to a player unit put
## that unit's abilities on the hotbar while the player was elsewhere.
## ability_hotbar._on_turn_started now returns early when the unit is not
## in view.
##
## Both widgets are BUILT HERE. The HUD lives in MainRoot.tscn, which the
## test runner scene does not load. end_turn_button.gd extends Button, so
## .new() is a working instance. ability_hotbar.gd has @onready children
## and no scene of its own — it is authored inline in MainRoot.tscn — so
## _build_hotbar() reproduces that node layout (CommonGrid,
## DividerCommonAbilities, AbilitiesGrid, DividerAbilitiesCustom,
## CustomGrid) BEFORE the bar enters the tree, which is what makes its
## _ready() resolve. That is the real script, the real _ready(), and the
## real signal wiring; nothing here is a stand-in.
##
## Asserted with is_visible_in_tree(), not with `visible` and not with a
## manager's state: a green UI suite once shipped panels that were never
## on screen.

const HOME := &"test_arena"
const AWAY := &"test_area_2"

var _button: Button = null
var _hotbar: HBoxContainer = null
var _host: Control = null
var _fight: Encounter = null
var _foe: Unit = null
var _fighter: Unit = null
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _saved_factions: Array = []


func run() -> void:
	# No AI, so the far fight stalls on the player exactly the way the
	# reported one did — which is the whole reason nothing corrects the
	# button once it has latched.
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []

	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var party: Array[Unit] = _live_members()
	if party.size() < 2:
		check("SETUP: a party big enough to split", false, "%d member(s)" % party.size())
		_restore()
		return
	_fighter = party[0]
	var traveller: Unit = party[1]

	# Built before combat starts, so both widgets hear the fight's first
	# turn_started the way the real HUD does.
	_button = load("res://systems/combat_system/end_turn_button.gd").new()
	_root.add_child(_button)
	_hotbar = _build_hotbar()
	_root.add_child(_hotbar)
	await get_tree().process_frame

	# DX 4 against a party member's default, so the player's unit takes
	# the first turn rather than the initiative roll deciding whether this
	# suite tests anything.
	_foe = spawn_unit(&"enemy", 12, 4, 30, [melee()],
		_fighter.global_position + Vector3(2.0, 0.0, 0.0))
	_foe.reparent(_fighter.get_parent(), false)
	await get_tree().physics_frame

	var combatants: Array[Unit] = [_fighter, _foe]
	_fight = CombatManager.start_combat(combatants)
	await get_tree().process_frame
	await get_tree().process_frame
	await _hand_the_turn_to(_fighter)

	var staged: bool = is_instance_valid(_fight) and _fight.is_running and _fighter.is_my_turn()
	check("SETUP: a fight in this world is waiting on a player-controlled unit",
		staged, _state())
	if not staged:
		_restore()
		return

	SelectionManager.select(_fighter)
	await get_tree().process_frame

	check("SETUP: the End Turn button is on screen for the fight you are standing in",
		_button.is_visible_in_tree(),
		"nothing to hide later — the button never appeared. " + _state())
	check("SETUP: and the hotbar is showing that unit's abilities",
		_hotbar.is_visible_in_tree(),
		"nothing to hide later — the bar never appeared. " + _state())

	# Walk somebody else out. Nothing below is refreshed by hand: whether
	# the widgets notice AT ALL is half of what is under test.
	WorldManager.load_area(AWAY, &"", [traveller] as Array[Unit])
	await get_tree().process_frame
	await get_tree().process_frame

	check("the End Turn button does not follow the player out of the fight's world",
		not _button.is_visible_in_tree(),
		"the button is still offering to end a turn in a fight the player "
			+ "cannot see. " + _state())
	check("and it travelled rather than ended the fight",
		is_instance_valid(_fight) and _fight.is_running and _fighter.is_my_turn(),
		"the check above passed for the wrong reason. " + _state())
	check("and the hotbar leaves with it",
		not _hotbar.is_visible_in_tree(),
		"the abilities of a unit in another world are still on the bar. " + _state())

	await _the_far_fight_comes_back_around_to(_fighter)
	check("SETUP: the far fight really did reach the player's unit again",
		is_instance_valid(_fight) and _fight.is_running and _fighter.is_my_turn(),
		"no unwatched player turn ever started, so the two checks below "
			+ "cannot fail. " + _state())
	check("a player turn starting in a fight you are not watching stays off the hotbar",
		not _hotbar.is_visible_in_tree(),
		"a turn relayed from an unwatched encounter put its unit's "
			+ "abilities on the bar. " + _state())
	check("and does not bring the End Turn button back",
		not _button.is_visible_in_tree(),
		"a turn relayed from an unwatched encounter re-showed the button. "
			+ _state())

	# The selection half. Travel cleared the selection on the way out, so
	# this puts the left-behind fighter back into it from here — which is
	# exactly what debug_combat_harness.gd:113 does off the unfiltered
	# turn relay, and what made the world filter necessary in the
	# selection branch and not only in the fall-back loop.
	SelectionManager.select(_fighter)
	await get_tree().process_frame
	check("SETUP: the unit left behind is genuinely selected",
		_fighter in SelectionManager.selected_units,
		"nothing was selected, so the check below proves nothing. " + _state())
	check("a unit selected in the world you left is not an opinion about the world you are in",
		not _button.is_visible_in_tree(),
		"the selection branch answered with a fighter in another world. "
			+ _state())

	# And back. A button that hides and never returns would pass every
	# check above and be just as broken.
	SelectionManager.deselect_all()
	await get_tree().process_frame
	var went_back: bool = WorldManager.revealed(
		WorldManager.reveal(_fighter, PartyManager.group_of(_fighter)))
	await get_tree().process_frame
	await get_tree().process_frame
	check("SETUP: the player can go back to the fight",
		went_back and _looking_at() == HOME,
		"reveal() refused. " + _state())

	check("and the button comes back when they do",
		_button.is_visible_in_tree(),
		"the fix hides the button instead of scoping it — it never "
			+ "returned. " + _state())

	SelectionManager.select(_fighter)
	await get_tree().process_frame
	check("and the hotbar comes back when somebody in this world is picked up",
		_hotbar.is_visible_in_tree(),
		"the world filter on the out-of-combat pick rejects a unit that "
			+ "IS in view. " + _state())

	_restore()


## The bar as MainRoot.tscn authors it: the script's five permanent
## children, named and ordered, added BEFORE the bar enters the tree so
## the @onready lookups in its _ready() resolve.
func _build_hotbar() -> HBoxContainer:
	var bar: HBoxContainer = load("res://ui/ability_hotbar.gd").new()
	bar.name = "AbilityHotbar"
	bar.slot_scene = load("res://ui/hotbar_slot.tscn")
	_add_grid(bar, "CommonGrid", 4)
	_add_divider(bar, "DividerCommonAbilities")
	_add_grid(bar, "AbilitiesGrid", 6)
	_add_divider(bar, "DividerAbilitiesCustom")
	_add_grid(bar, "CustomGrid", 6)
	return bar


func _add_grid(bar: HBoxContainer, node_name: String, columns: int) -> void:
	var grid := GridContainer.new()
	grid.name = node_name
	grid.columns = columns
	bar.add_child(grid)


func _add_divider(bar: HBoxContainer, node_name: String) -> void:
	var divider := HotbarDivider.new()
	divider.name = node_name
	bar.add_child(divider)


## Advances the fight until it is this unit's turn. The initiative sort is
## deterministic given the DX gap above; this is the guard that says so
## rather than assuming it.
func _hand_the_turn_to(unit: Unit) -> void:
	for _i in 4:
		if not (is_instance_valid(_fight) and _fight.is_running):
			return
		if unit.is_my_turn():
			return
		CombatManager.end_turn(_fight.current_unit)
		await get_tree().process_frame
		await get_tree().process_frame


## One full cycle of the unwatched fight, ending on a turn_started for
## `unit` — a player turn beginning in a world nobody is looking at, which
## is the signal the hotbar used to act on unconditionally.
func _the_far_fight_comes_back_around_to(unit: Unit) -> void:
	for i in 4:
		if not (is_instance_valid(_fight) and _fight.is_running):
			return
		if i > 0 and _fight.current_unit == unit:
			return
		CombatManager.end_turn(_fight.current_unit)
		await get_tree().process_frame
		await get_tree().process_frame


func _looking_at() -> StringName:
	var area: AreaDefinition = WorldManager.current_area()
	return area.id if area else &"<nothing>"


## Everything a failure here needs to be diagnosable from the log alone:
## which world is on screen, whether the fight survived, whose turn it is,
## what each widget actually renders as, and who is selected.
func _state() -> String:
	var turn: String = "nobody"
	if is_instance_valid(_fight) and _fight.is_running and is_instance_valid(_fight.current_unit):
		turn = _fight.current_unit.get_display_name()
	var who: Array[String] = []
	for unit in SelectionManager.selected_units:
		if is_instance_valid(unit):
			who.append(unit.get_display_name())
	return "looking at '%s'; fight %s, turn: %s; button on screen=%s, hotbar on screen=%s; selected: [%s]" % [
		_looking_at(),
		"running" if (is_instance_valid(_fight) and _fight.is_running) else "not running",
		turn,
		str(_button.is_visible_in_tree()) if is_instance_valid(_button) else "<no button>",
		str(_hotbar.is_visible_in_tree()) if is_instance_valid(_hotbar) else "<no hotbar>",
		", ".join(who)]


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


func _live_members() -> Array[Unit]:
	var live: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			live.append(unit)
	return live


func _restore() -> void:
	if is_instance_valid(_fight) and _fight.is_running:
		_fight.finish(&"")
	SelectionManager.deselect_all()
	if is_instance_valid(_button):
		_button.queue_free()
	if is_instance_valid(_hotbar):
		_hotbar.queue_free()
	if is_instance_valid(_foe):
		_spawned.erase(_foe)
		if _foe.is_in_group("units"):
			_foe.remove_from_group("units")
		if _foe.get_parent():
			_foe.get_parent().remove_child(_foe)
		_foe.queue_free()
	WorldManager.discard_worlds()
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	CombatAi.ai_factions = _saved_factions
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()
