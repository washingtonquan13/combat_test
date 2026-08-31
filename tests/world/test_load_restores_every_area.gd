extends AiTestCase
## Opening a save puts the party where the save says they are.
##
## Reported from play: after loading, a member in another area answered
## "X is somewhere not currently loaded", and the only way to reach them
## was to walk somebody else over — which is not travel, it is repair.
##
## load_file built exactly one world, the one named in [world]/area_id,
## and left every other group abstract with a remembered area nothing was
## holding. That contradicts the residency rule the rest of the engine
## works by: residency is EARNED, and party presence earns it. A member
## listed in the party panel whose area is not resident is a state nothing
## else in the system expects to see.

const HOME := &"test_arena"
const AWAY := &"test_area_2"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _save_path: String = ""
var _overview: Node = null
var _marker: Vector3 = Vector3.ZERO
var _home_marker: Vector3 = Vector3.ZERO
var _away_id: StringName = &""
var _home_id: StringName = &""
var _snapshot: Dictionary = {}


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return

	_snapshot_globals()
	_install_party_overview()

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var party: Array[Unit] = _live_members()
	if party.size() < 2:
		check("SETUP: a party to split", false, "%d member(s)" % party.size())
		_restore()
		return

	# One member walks away, then the player goes back to HOME — so the
	# save names HOME and somebody is standing somewhere else.
	var going: Array[Unit] = [party[0]]
	WorldManager.load_area(AWAY, &"", going)
	await get_tree().process_frame
	# Moved somewhere distinctive BEFORE the save, so "restored" cannot be
	# mistaken for "spawned at the arrival point" — which is what the
	# arriving party would do if their transforms went missing.
	_marker = party[0].global_position + Vector3(6.0, 0.0, 6.0)
	party[0].global_position = _marker
	await get_tree().physics_frame

	WorldManager.reveal(party[1], PartyManager.group_of(party[1]))
	await get_tree().process_frame

	# BOTH of them, because the areas are built non-focused-first: a table
	# emptied by the first world to arrive would strand the members of the
	# LAST one, which is the focused area, and checking only the traveller
	# would miss it entirely.
	_home_marker = party[1].global_position + Vector3(0.0, 0.0, 7.0)
	party[1].global_position = _home_marker
	await get_tree().physics_frame

	if PartyManager.groups.size() != 2:
		check("SETUP: the party really is split", false,
			"%d group(s)" % PartyManager.groups.size())
		_restore()
		return
	if not SaveManager.save("area restore check"):
		check("SETUP: the save was written", false)
		_restore()
		return
	# After save(), which is what MINTS these — read any earlier and both
	# would be the empty string.
	_away_id = party[0].persistent_id
	_home_id = party[1].persistent_id

	var saves: Array[Dictionary] = SaveManager.list_saves()
	if saves.is_empty():
		check("SETUP: the save can be found again", false)
		_restore()
		return
	_save_path = saves[0]["path"]

	if not SaveManager.load_file(_save_path):
		check("SETUP: the save loads at all", false)
		_restore()
		return
	await get_tree().process_frame

	var area: AreaDefinition = WorldManager.current_area()
	check("the save opens on the area it was saved in",
		area != null and area.id == HOME,
		"opened on %s" % ("nothing" if area == null else String(area.id)))

	check("and the area somebody else was left in is standing too",
		WorldManager.is_area_resident(AWAY),
		"nothing is holding it, so they are nowhere until somebody walks over")

	# The reported symptom, asked exactly as the portrait asks it.
	var away_group: PartyGroup = _group_claiming(AWAY)
	var stranded: Unit = null
	if away_group and not away_group.units.is_empty():
		stranded = away_group.units[0]
	var result: int = WorldManager.reveal(stranded, away_group)
	check("and the member standing there is reachable without loading anything first",
		result != WorldManager.Reveal.AREA_NOT_LOADED,
		"answered AREA_NOT_LOADED — the reported bug")
	check("and they are really there, not just remembered",
		away_group != null and away_group.embodied,
		"the group came back as records with no world to stand in")

	# The other half of the fix, and the easier one to get wrong: the
	# transform table used to be emptied by the FIRST world to finish
	# loading, which with several worlds meant everyone in the others came
	# back standing on the arrival point.
	var away_drift: float = _drift_of(_away_id, _marker)
	check("and standing where they were, not at the arrival point",
		away_drift < 2.0,
		"%.1fm from where the save left them" % away_drift)

	var home_drift: float = _drift_of(_home_id, _home_marker)
	check("and so is the member in the area that loaded last",
		home_drift < 2.0,
		"%.1fm from where the save left them" % home_drift)

	_restore()


## SaveManager reaches the party's shared Inventory through the
## "party_overview" group. In the game that node is a permanent child of
## MainRoot's CanvasLayer; this scene has no MainRoot, so a save would
## crash on a null instance before reaching anything under test.
##
## The real scene, not a stand-in: it puts itself in the group and owns a
## fully built Inventory, and hand-assembling one only reproduces the
## scene badly — a bare Inventory.new() has none of the child nodes its
## @onready paths name.
## This is the only suite that opens a real save FILE, and load_file()
## replaces FlagManager, the party, the roster and the purse wholesale for
## everything that runs after it — AreaState lives inside FlagManager, so
## a load can quietly resurrect or remove entities in other suites' areas.
## Snapshotted through the same save_state/load_state pair the save file
## itself uses, so what is put back is exactly what a save would have
## written.
func _snapshot_globals() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
		"demons": DemonRoster.save_state(),
		"currency": CurrencyManager.save_state(),
	}


func _restore_globals() -> void:
	if _snapshot.is_empty():
		return
	FlagManager.load_state(_snapshot["flags"])
	PartyManager.load_state(_snapshot["party"])
	DemonRoster.load_state(_snapshot["demons"])
	CurrencyManager.load_state(_snapshot["currency"])


func _install_party_overview() -> void:
	_overview = preload("res://party_overview.tscn").instantiate()
	_root.add_child(_overview)


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_load()


func _live_members() -> Array[Unit]:
	var live: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			live.append(unit)
	return live


## How far a member ended up from where the save left them, by id — the
## units themselves do not survive a load, only their records do.
func _drift_of(id: StringName, expected: Vector3) -> float:
	if id == &"":
		return INF
	for unit in PartyManager.members:
		if is_instance_valid(unit) and unit.persistent_id == id:
			return unit.global_position.distance_to(expected)
	return INF


func _group_claiming(area_id: StringName) -> PartyGroup:
	for group in PartyManager.groups:
		if group.current_area_id() == area_id:
			return group
	return null


func _restore() -> void:
	if _save_path != "":
		DirAccess.remove_absolute(_save_path)
	WorldManager.unload(true)
	_restore_globals()
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_overview):
		_overview.queue_free()
	if is_instance_valid(_host):
		_host.queue_free()
