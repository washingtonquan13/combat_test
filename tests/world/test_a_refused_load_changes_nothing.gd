extends AiTestCase
## A load that cannot succeed refuses before it touches anything, and says
## so out loud.
##
## load_file() used to write FlagManager, PartyManager, DemonRoster,
## CurrencyManager and the shared inventory BEFORE anything that could
## still refuse. A failure past that point — and a save naming an area that
## no longer exists is one — left the game holding the save file's flags,
## party, demons and money with no world at all, and the only recovery was
## to load again. The visible symptom was a stuck title screen; the actual
## state was worse than it looked.
##
## Two properties, and they are separate bugs:
##
## 1. NOTHING CHANGES. Everything that can refuse is asked before the first
##    thing that writes (see SaveManager._why_load_would_fail).
## 2. THE REFUSAL IS AN EVENT. load_completed only ever fires for a load
##    that worked, so five `return false` paths were invisible to every
##    listener — a push_warning is not something a screen can connect to.
##    load_finished(path, ok) fires either way.
##
## The flag below is set AFTER the save is written, on purpose: it is not
## in the file, so it survives a refused load and could not survive a load
## that got as far as injecting FlagManager. That is what makes it evidence
## rather than decoration.

const HOME := &"test_arena"
const CANARY := "refused_load_canary"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _save_path: String = ""
var _overview: Node = null
var _snapshot: Dictionary = {}
var _finished: Array = []
var _completed: int = 0


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return

	_snapshot_globals()
	_install_party_overview()

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var members_before: int = PartyManager.members.size()
	if members_before < 1:
		check("SETUP: a party exists", false)
		_restore()
		return

	if not SaveManager.save("refusal check"):
		check("SETUP: the save was written", false)
		_restore()
		return
	var saves: Array[Dictionary] = SaveManager.list_saves()
	if saves.is_empty():
		check("SETUP: the save can be found again", false)
		_restore()
		return
	_save_path = saves[0]["path"]

	# Point the save at an area the game no longer has — the shape of a
	# save written before an area was renamed or removed.
	var cfg := ConfigFile.new()
	if cfg.load(_save_path) != OK:
		check("SETUP: the save could be re-read for tampering", false)
		_restore()
		return
	cfg.set_value("world", "area_id", "an_area_that_was_deleted")
	cfg.save(_save_path)

	# Set AFTER the save, so it is not in the file. Survives a refusal;
	# cannot survive FlagManager being overwritten from disk.
	FlagManager.set_flag(CANARY, true)
	var gold_before: int = CurrencyManager.gold

	SaveManager.load_finished.connect(_on_finished)
	SaveManager.load_completed.connect(_on_completed)

	var ok: bool = SaveManager.load_file(_save_path)
	await get_tree().process_frame

	check("a save naming a missing area is refused",
		not ok,
		"load_file returned true for an area that does not exist")

	# Property 2: the refusal is observable.
	check("and the refusal is reported as an event, not just a warning",
		_finished.size() == 1 and _finished[0] == false,
		"load_finished fired %d time(s)%s" % [
			_finished.size(),
			"" if _finished.is_empty() else " with ok=%s" % str(_finished[0])])
	check("and load_completed stays quiet, because nothing completed",
		_completed == 0,
		"load_completed fired %d time(s)" % _completed)

	# Property 1: nothing was taken apart on the way to finding out.
	var area: AreaDefinition = WorldManager.current_area()
	check("the world the player was in is still standing",
		area != null and area.id == HOME,
		"looking at %s — the worlds were discarded before the refusal" % \
			("nothing" if area == null else String(area.id)))

	check("and the party was not replaced from the file",
		PartyManager.members.size() == members_before,
		"%d member(s), was %d" % [PartyManager.members.size(), members_before])

	check("and the flags were not overwritten from the file",
		FlagManager.has_flag(CANARY),
		"the canary is gone, so FlagManager.load_state ran before the refusal")

	check("and the purse was not overwritten from the file",
		CurrencyManager.gold == gold_before,
		"%d gold, was %d" % [CurrencyManager.gold, gold_before])

	_restore()


func _on_finished(_path: String, ok: bool) -> void:
	_finished.append(ok)


func _on_completed(_path: String) -> void:
	_completed += 1


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


## See test_load_restores_every_area's own note: a load replaces
## FlagManager, the party, the roster and the purse wholesale for
## everything that runs after it, and AreaState lives inside FlagManager.
## Snapshotted even though this suite expects the load to be REFUSED —
## precisely because a regression here means it was not.
func _snapshot_globals() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
		"demons": DemonRoster.save_state(),
		"currency": CurrencyManager.save_state(),
	}


func _install_party_overview() -> void:
	_overview = preload("res://party_overview.tscn").instantiate()
	_root.add_child(_overview)


func _restore() -> void:
	if SaveManager.load_finished.is_connected(_on_finished):
		SaveManager.load_finished.disconnect(_on_finished)
	if SaveManager.load_completed.is_connected(_on_completed):
		SaveManager.load_completed.disconnect(_on_completed)
	FlagManager.clear_flag(CANARY)
	if _save_path != "":
		DirAccess.remove_absolute(_save_path)
	WorldManager.discard_worlds()
	if not _snapshot.is_empty():
		FlagManager.load_state(_snapshot["flags"])
		PartyManager.load_state(_snapshot["party"])
		DemonRoster.load_state(_snapshot["demons"])
		CurrencyManager.load_state(_snapshot["currency"])
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
