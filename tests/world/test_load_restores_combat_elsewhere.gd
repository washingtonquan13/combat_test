extends AiTestCase
## A save with a fight running somewhere the player is NOT standing opens
## in one attempt.
##
## Reported from play as "the main menu is still up, with the world
## audible underneath, unless I load the save twice in a row". The menu
## was the visible end of it; the load itself was refusing.
##
## load_file rebuilds every area holding party, the saved one LAST. When
## an earlier area brought a fight back with it, that fight claimed COMBAT
## mode — correctly, since it was the focused world at that instant — and
## the next rebuild was then refused by the travel gate, which saw units
## "leaving a fight". The claim only clears when focus moves off that
## area, and the refusal is what stops focus from moving. A deadlock, and
## the load returned false without ever emitting load_completed.
##
## The fix is that a restore no longer asks the travel question at all:
## rebuild_area() asks can_rebuild(), because nobody is travelling when
## the engine is rebuilding worlds from disk. See WorldManager.can_rebuild.
##
## This is the intersection nothing covered. test_persistence restores a
## fight through CombatManager directly rather than through a file, and
## test_load_restores_every_area opens a real save across two areas with
## no combat in it. Both passed throughout.

const HOME := &"test_arena"
const AWAY := &"test_area_2"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _saved_factions: Array[StringName] = []
var _save_path: String = ""
var _overview: Node = null
var _snapshot: Dictionary = {}
var _fight: Encounter = null


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

	# An enemy AUTHORED in the area, not one spawned here. A hand-spawned
	# unit has no persistent_id and is not in the scene file, so the world
	# rebuild would not bring it back and the restored fight would be
	# empty — which silently stops this suite from reproducing anything.
	# That exact mistake made an earlier version of this test pass under
	# sabotage.
	var enemy: Unit = _authored_enemy_in(WorldManager.current_world())
	if enemy == null:
		check("SETUP: an authored enemy to fight in %s" % String(HOME), false)
		_restore()
		return

	var combatants: Array[Unit] = [party[0], enemy]
	_fight = CombatManager.start_combat(combatants)
	await get_tree().process_frame
	if not (is_instance_valid(_fight) and _fight.is_running):
		check("SETUP: a fight is running in the home area", false)
		_restore()
		return

	# The OTHER member walks away and the player goes with them, leaving
	# the fight running somewhere nobody is watching. Allowed precisely
	# because the traveller is not in that fight — which is the travel
	# gate working correctly, and worth noting given what it does wrong
	# during a restore.
	var going: Array[Unit] = [party[1]]
	WorldManager.load_area(AWAY, &"", going)
	await get_tree().process_frame

	var standing_in: AreaDefinition = WorldManager.current_area()
	if standing_in == null or standing_in.id != AWAY:
		check("SETUP: the player really left the fight behind", false,
			"still looking at %s" % ("nothing" if standing_in == null else String(standing_in.id)))
		_restore()
		return

	# With the fight unfocused the mode is EXPLORATION, which can_save()
	# allows. If this starts failing, the mode is being reported for a
	# fight nobody is watching.
	if not SaveManager.save("combat elsewhere check"):
		check("SETUP: a save is allowed while a fight runs elsewhere", false,
			"can_save() refused, so the rest of this suite cannot run")
		_restore()
		return

	var saves: Array[Dictionary] = SaveManager.list_saves()
	if saves.is_empty():
		check("SETUP: the save can be found again", false)
		_restore()
		return
	_save_path = saves[0]["path"]

	# HOME holds party and is not the saved area, so load_file rebuilds it
	# FIRST. Its fight comes back while it is briefly the focused world and
	# claims COMBAT — and the rebuild of AWAY after it used to be refused
	# by the travel gate for "leaving a fight", with no way out: the claim
	# clears only when focus moves, and the refusal is what stops it.
	var loaded: bool = SaveManager.load_file(_save_path)
	check("the save loads on the first attempt",
		loaded,
		"load_file returned false — the rebuild was refused, so nothing " +
		"emitted load_completed and the title screen stayed up")
	if not loaded:
		_restore()
		return
	await get_tree().process_frame

	var area: AreaDefinition = WorldManager.current_area()
	check("and opens on the area it was saved in",
		area != null and area.id == AWAY,
		"opened on %s" % ("nothing" if area == null else String(area.id)))

	check("and the area holding the fight is standing too",
		WorldManager.is_area_resident(HOME),
		"nothing is holding it, so the fight is nowhere")

	# Restoring the world is only half of it — a rebuilt area with no
	# encounter would pass every check above, and would also mean this
	# suite never reproduced the deadlock at all.
	var resumed: Encounter = _running_fight_in(HOME)
	check("and the fight there is running again",
		resumed != null,
		"no running encounter in %s after the load" % String(HOME))

	check("and the player is not held in a fight they are not watching",
		WorldManager.can_travel(),
		"can_travel() is false where the player is standing, so the " +
		"restored fight is detaining somebody who is not in it")

	_restore()


## An enemy the AREA declares, found by walking the loaded world. Anything
## with a persistent_id survives a rebuild; anything without it does not.
func _authored_enemy_in(world: Node) -> Unit:
	if world == null:
		return null
	for unit in _all_units_under(world):
		if unit.faction == &"enemy" and unit.persistent_id != &"" and unit.is_alive():
			return unit
	return null


func _all_units_under(node: Node) -> Array[Unit]:
	var found: Array[Unit] = []
	if node is Unit:
		found.append(node)
	for child in node.get_children():
		found.append_array(_all_units_under(child))
	return found


## The running encounter in an area, or null. Asked by area rather than by
## unit because the units in that fight did not survive the load — only
## their records did, and the encounter is rebuilt around new instances.
func _running_fight_in(area_id: StringName) -> Encounter:
	for encounter in CombatManager.all_encounters():
		if not is_instance_valid(encounter) or not encounter.is_running:
			continue
		for unit in encounter.turn_order:
			if is_instance_valid(unit) and WorldManager.area_of(unit) != null \
					and WorldManager.area_of(unit).id == area_id:
				return encounter
	return null


## Held still on purpose. This suite is about whether a load is refused,
## not about what a fight does once it resumes — a driven turn would move
## units between the save and the assertions and prove nothing either way.
func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []
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


## See test_load_restores_every_area's own note: load_file() replaces
## FlagManager, the party, the roster and the purse wholesale for
## everything that runs after it, and AreaState lives inside FlagManager.
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
	_overview = preload("res://ui/party_overview.tscn").instantiate()
	_root.add_child(_overview)


func _restore() -> void:
	for encounter in CombatManager.all_encounters():
		if is_instance_valid(encounter) and encounter.is_running:
			encounter.finish(&"")
	if _save_path != "":
		DirAccess.remove_absolute(_save_path)
	WorldManager.discard_worlds()
	_restore_globals()
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	CombatAi.ai_factions = _saved_factions
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_overview):
		_overview.queue_free()
	if is_instance_valid(_host):
		_host.queue_free()
