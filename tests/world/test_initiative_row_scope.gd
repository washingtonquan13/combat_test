extends AiTestCase
## The initiative row belongs to the world on screen.
##
## Reported from play: leaving a battle to look at a member in the
## overworld left the battle's turn order sitting on screen.
##
## Two things caused it, and both are the same shape as the rest of this
## pass — a rule that was right while there was one world. The row was the
## ONLY panel not connected to world_focused (party_panel, interact_prompt,
## the overworld and the music manager all were), so nothing told it to
## look again. And focusing another world does not deselect whoever was
## selected in the one you left, so its "a selection is an opinion" rule
## kept answering with a fight the player had walked away from.
##
## Asserted on visibility rather than on the internals, per the standing
## rule here: a green suite once shipped panels that were never on screen.

const HOME := &"test_arena"
const AWAY := &"test_area_2"

var _row: HBoxContainer
var _host: Control
var _fight: Encounter
var _foe: Unit
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _saved_factions: Array = []


func run() -> void:
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
		check("SETUP: two party members", false, "%d" % party.size())
		_restore()
		return
	var fighter: Unit = party[0]
	var traveller: Unit = party[1]

	# A real fight in HOME, with the player commanding one of its combatants.
	_foe = spawn_unit(&"enemy", 12, 12, 30, [melee()],
		fighter.global_position + Vector3(2.0, 0.0, 0.0))
	_foe.reparent(fighter.get_parent(), false)
	await get_tree().physics_frame

	var combatants: Array[Unit] = [fighter, _foe]
	_fight = CombatManager.start_combat(combatants)
	SelectionManager.select(fighter)
	await get_tree().process_frame

	_row = load("res://systems/combat_system/initiative_row.gd").new()
	_row.portrait_scene = load("res://ui/unit_portrait.tscn")
	_root.add_child(_row)
	await get_tree().process_frame

	_row._refresh()
	check("the row shows the fight you are looking at",
		_row.visible, "hidden with a battle on screen")

	# Walk somebody else into another area, which focuses it. Nothing is
	# refreshed by hand from here on: whether the row notices AT ALL is
	# half of what is being tested.
	WorldManager.load_area(AWAY, &"", [traveller] as Array[Unit])
	await get_tree().process_frame
	await get_tree().process_frame

	check("and hides it once you are looking somewhere else",
		not _row.visible,
		"the battle's turn order followed the player out of its world")
	check("without touching the fight itself",
		is_instance_valid(_fight) and _fight.is_running,
		"looking away ended a battle")

	# And back: a row that hides and never returns would pass the check
	# above and be just as broken.
	WorldManager.reveal(fighter, PartyManager.group_of(fighter))
	await get_tree().process_frame
	await get_tree().process_frame

	check("and shows it again when you come back",
		_row.visible, "the row never returned")

	_restore()


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
	if is_instance_valid(_row):
		_row.queue_free()
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
