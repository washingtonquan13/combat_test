extends AiTestCase
## An overworld random encounter, from the red avatar to the fight.
##
## The red avatar grows out of nothing (the reverse of a door's shrink);
## a district stops rolling once its encounter_limit is fought, until a
## rest clears it; and arriving at a battle area with a fight pending
## spawns that fight's enemies and starts it with the party in it.
##
## The roll, the chase and the touch are left to play: they are a few
## lines of distance arithmetic over the avatar, and what this suite
## guards is the hand-off between the overworld and the battlefield,
## which is where a rename or a lost flag would break it silently.
## See docs/systems/areas_bootstrap.md, "Random encounters".

const BATTLE := &"battle_greywood"
const WOLVES := "res://data/encounters/wolf_pack.tres"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _overview: Node = null
var _snapshot: Dictionary = {}
var _autosave_backup: PackedByteArray = PackedByteArray()
var _autosave_path: String = ""


func run() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
		"demons": DemonRoster.save_state(),
	}
	_appears()
	await _grows()
	_limit()
	await _battle()
	_restore()


func _appears() -> void:
	for path in ["goblin_pair", "goblin_band", "hobgoblin_patrol", "wolf_pack", "giant_spider"]:
		var group: EncounterGroup = load("res://data/encounters/%s.tres" % path)
		check("encounter group %s loads with units" % path, group != null and not group.units.is_empty()
			and group.units.all(func(u: UnitDefinition) -> bool: return u != null))
	for zone in ["downtown", "outskirts", "greywood"]:
		var area: AreaDefinition = AreaDatabase.find(StringName("battle_" + zone))
		check("battle_%s is an area" % zone, area != null and area.world_scene != null)


func _grows() -> void:
	var avatar: OverworldAvatar = preload("res://world/overworld_avatar.tscn").instantiate()
	avatar.hostile = true
	_root.add_child(avatar)
	await get_tree().process_frame
	var pivot: Node3D = avatar.get_node("SpinPivot")
	var standing := pivot.scale.x
	var done := [false]
	avatar.appear(func() -> void: done[0] = true)
	check("a red avatar starts from nothing", pivot.scale.x < standing * 0.2, "%.3f of %.3f" % [pivot.scale.x, standing])
	await get_tree().create_timer(avatar.enter_time * 1.2).timeout
	check("and grows to full size", is_equal_approx(pivot.scale.x, standing), "%.3f of %.3f" % [pivot.scale.x, standing])
	check("then says so", done[0] and not avatar.is_entering())
	avatar.queue_free()


func _limit() -> void:
	var driver := OverworldEncounters.new()
	var district := OverworldDistrict.new()
	district.name = "TestWilds"
	district.danger = 0.01
	district.battle_area = BATTLE
	district.encounter_limit = 2
	district.encounters.append(load(WOLVES))
	OverworldEncounters.clear_all()
	check("a dangerous district with a table can fight", driver.can_fight(district))
	for i in 2:
		FlagManager.set_flag(OverworldEncounters.PENDING_FLAG, {"group": WOLVES, "district": "TestWilds"})
		OverworldEncounters.finish_pending()
	check("two fights won count against it", OverworldEncounters.cleared_in("TestWilds") == 2)
	check("and at its limit it is quiet", not driver.can_fight(district))
	check("and nothing is left pending", OverworldEncounters.pending().is_empty())
	OverworldEncounters.clear_all()
	check("a rest fills it again", driver.can_fight(district))
	driver.free()
	district.free()


func _battle() -> void:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	if not WorldManager.can_travel():
		check("SETUP: synthetic world host installed", false)
		return
	# The fight's autosave writes the player's real Retry slot.
	_autosave_path = SaveManager.slot_path(SaveManager.FIGHT_AUTOSAVE)
	if _autosave_path != "":
		_autosave_backup = FileAccess.get_file_as_bytes(_autosave_path)
	_overview = preload("res://ui/party_overview.tscn").instantiate()
	_root.add_child(_overview)

	# test_arena builds the starting party; it walks to the battlefield.
	WorldManager.load_area(&"test_arena")
	await get_tree().process_frame
	var members: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			members.append(unit)
	if members.is_empty():
		check("SETUP: a party to fight with", false)
		return
	FlagManager.set_flag(OverworldEncounters.PENDING_FLAG, {"group": WOLVES, "district": "TestWilds"})
	WorldManager.load_area(BATTLE, &"", members)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	var field := WorldManager.current_world()
	check("the battle area loads as a BattleField", field is BattleField,
		"focused %s" % (field.name if field else "nothing"))
	if not field is BattleField:
		return
	var encounter: Encounter = field._encounter
	check("the fight starts on arrival", encounter != null, "pending %s, %d member(s), context %s, combat running %s" % [
		OverworldEncounters.pending(), PartyManager.members.size(), WorldManager.context_for(field),
		CombatManager.any_combat_running()])
	if encounter == null:
		return
	var wolves := 0
	var party := 0
	for unit: Unit in encounter.turn_order:
		if unit.faction == &"enemy":
			wolves += 1
		elif PartyManager.members.has(unit):
			party += 1
	check("with the pack's three wolves, as enemies", wolves == 3, "%d" % wolves)
	check("and the party in it", party >= 1, "%d" % party)
	CombatManager.end_combat(&"player", encounter)
	await get_tree().process_frame
	check("won, it counts against the district", OverworldEncounters.cleared_in("TestWilds") == 1)
	check("and is no longer pending", OverworldEncounters.pending().is_empty())


func _restore() -> void:
	WorldManager.discard_worlds()
	FlagManager.load_state(_snapshot["flags"])
	PartyManager.load_state(_snapshot["party"])
	DemonRoster.load_state(_snapshot["demons"])
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	var written := SaveManager.slot_path(SaveManager.FIGHT_AUTOSAVE)
	if _autosave_path != "":
		var out := FileAccess.open(_autosave_path, FileAccess.WRITE)
		out.store_buffer(_autosave_backup)
		out.close()
	elif written != "":
		DirAccess.remove_absolute(written)
	if _saved_host != null or is_instance_valid(_host):
		WorldManager._world_host = _saved_host
		WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_overview):
		_overview.queue_free()
	if is_instance_valid(_host):
		_host.queue_free()
