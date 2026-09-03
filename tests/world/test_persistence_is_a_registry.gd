extends AiTestCase
## Anything can persist itself, and SaveManager never learns its name.
##
## The save system used to carry a hand-written list of the five systems
## it saved — five set_value() calls in save(), five load_state() calls in
## _perform_load(), in a fixed order. That list was a second place to
## remember something, and forgetting it was silent: a new system with a
## perfectly good save_state()/load_state() pair simply never appeared in
## a save file, and nothing anywhere said so.
##
## What replaces it is a registry each system registers ITSELF with, so
## these checks are deliberately written against systems SaveManager has
## never heard of. A fake registered here goes through the real save() and
## the real load_file(), and if the registry is doing the work it must
## come back — which is a thing the old code could not do at all.
##
## The three properties underneath that:
##   1. A registered system round-trips without being named anywhere.
##   2. `after` orders the load, not registration order.
##   3. A target that cannot be read back is refused at registration
##      rather than discovered when somebody opens the save.
## Plus the compatibility one: a section with nobody to receive it is a
## warning, not a failed load. An old save must keep opening.

const HOME := &"test_arena"

## Distinctive enough that they cannot collide with a real section name,
## in a file or in the table.
const SOLO := &"registry_probe_solo"
const FIRST := &"registry_probe_a"
const SECOND := &"registry_probe_b"
const HALF := &"registry_probe_half"
const ORPHAN := "registry_probe_a_system_that_is_gone"

const PAYLOAD := "written by a system SaveManager cannot name"


## A perfectly ordinary persistable that happens not to be a Node, an
## autoload, or anything SaveManager has ever heard of. RefCounted on
## purpose: the registry's contract is a pair of methods, not a base
## class or a place in the scene tree.
class FakePersistable extends RefCounted:
	var payload: String = ""
	## Set by load_state, read by whoever declared itself `after` this one.
	var loaded: bool = false
	## The one this must load after, if any. Untyped so an inner class can
	## refer to its own kind.
	var dependency = null
	## What `dependency.loaded` said at the moment THIS one was loaded.
	var dependency_was_loaded: bool = false

	func save_state() -> Dictionary:
		return {"payload": payload}

	func load_state(state: Dictionary) -> void:
		payload = state.get("payload", "")
		loaded = true
		if dependency != null:
			dependency_was_loaded = dependency.loaded


## Half a contract: it can be read back and never written. Registering
## this is the mistake the check exists to catch at the door.
class HalfPersistable extends RefCounted:
	func load_state(_state: Dictionary) -> void:
		pass


var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _overview: Node = null
var _snapshot: Dictionary = {}
var _save_path: String = ""

var _solo: FakePersistable = FakePersistable.new()
var _first: FakePersistable = FakePersistable.new()
var _second: FakePersistable = FakePersistable.new()
var _half: HalfPersistable = HalfPersistable.new()


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return

	# load_file() replaces the flags, the party, the roster and the purse
	# wholesale, and AreaState lives inside FlagManager — so a load here can
	# quietly rewrite what other suites find in their areas. Put back through
	# the same pair the save file itself uses.
	_snapshot_globals()
	_install_party_overview()

	_register_probes()

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	if not _a_stranger_is_written_to_the_save():
		_restore()
		return

	await _and_comes_back_out_of_it()
	await _an_unclaimed_section_does_not_stop_a_load()

	_restore()


# --- the checks -------------------------------------------------------

## Registered LAST-to-first on purpose: SECOND declares itself `after`
## FIRST and is registered BEFORE it, so registration order and load order
## disagree and only a real sort can tell them apart.
func _register_probes() -> void:
	_solo.payload = PAYLOAD
	SaveManager.register(SOLO, _solo)

	var after_first: Array[StringName] = [FIRST]
	_second.dependency = _first
	SaveManager.register(SECOND, _second, after_first)
	SaveManager.register(FIRST, _first)

	# The refusal. Nothing about this is recoverable later: a target that
	# can be written and not read back produces a save file that looks
	# perfectly fine until somebody opens it.
	SaveManager.register(HALF, _half)
	check("a target holding only half the contract is refused at registration",
		not SaveManager.is_registered(HALF),
		"a persistable with no save_state() is in the table")

	check("and `after` is what orders the load, not the order things registered in",
		SaveManager._load_order().find(FIRST) < SaveManager._load_order().find(SECOND),
		"%s" % str(SaveManager._load_order()))


func _a_stranger_is_written_to_the_save() -> bool:
	if not SaveManager.save("registry round trip"):
		check("SETUP: the save was written", false)
		return false

	var saves: Array[Dictionary] = SaveManager.list_saves()
	if saves.is_empty():
		check("SETUP: the save can be found again", false)
		return false
	_save_path = saves[0]["path"]

	var cfg := ConfigFile.new()
	if cfg.load(_save_path) != OK:
		check("SETUP: the save file can be re-read", false)
		return false

	# The headline for save(): SaveManager does not contain the string
	# "registry_probe_solo" anywhere, and it wrote it anyway.
	check("a system SaveManager has never heard of gets its own section in the file",
		cfg.get_value(String(SOLO), "data", {}).get("payload", "") == PAYLOAD,
		"section '%s' holds %s" % [SOLO, str(cfg.get_value(String(SOLO), "data", {}))])

	check("and the refused target got no section at all",
		not cfg.has_section(String(HALF)),
		"a target that was never registered was written anyway")

	# The five real ones are still there under the names they always had —
	# which is the whole compatibility requirement, checked from the file
	# rather than from a comment.
	check("and the sections existing saves are written in are unchanged",
		cfg.has_section("flags") and cfg.has_section("party")
			and cfg.has_section("demons") and cfg.has_section("currency")
			and cfg.has_section("inventory"),
		"sections written: %s" % str(cfg.get_sections()))
	return true


func _and_comes_back_out_of_it() -> void:
	# Mutated AFTER the save, so "restored" cannot be confused with "never
	# changed".
	_solo.payload = "clobbered since the save"
	_first.loaded = false
	_second.loaded = false
	_second.dependency_was_loaded = false

	if not SaveManager.load_file(_save_path):
		check("SETUP: the save loads", false)
		return
	await get_tree().process_frame

	check("and it is handed its state back when the save is opened",
		_solo.payload == PAYLOAD,
		"came back as '%s'" % _solo.payload)

	check("a system that declared itself `after` another is loaded after it",
		_second.dependency_was_loaded,
		"it loaded while the one it depends on had not")


## An old save naming a system this build no longer has must still open.
## Written by hand into the file rather than by removing a real system,
## because "the build changed" is precisely the case that cannot be
## reproduced from inside one build.
func _an_unclaimed_section_does_not_stop_a_load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_save_path) != OK:
		check("SETUP: the save file can be rewritten", false)
		return
	cfg.set_value(ORPHAN, "data", {"left_behind": true})
	if cfg.save(_save_path) != OK:
		check("SETUP: the doctored save was written", false)
		return

	_solo.payload = "clobbered again"

	check("a section with no system left to receive it does not stop the load",
		SaveManager.load_file(_save_path),
		"the load refused over a section it could simply have skipped")
	await get_tree().process_frame

	check("and everything that DOES still have a home was loaded anyway",
		_solo.payload == PAYLOAD,
		"came back as '%s'" % _solo.payload)


# --- harness ----------------------------------------------------------

## SaveManager reaches the party's shared Inventory through the
## "party_overview" group, and PartyOverview is what registers it. In the
## game that node is a permanent child of MainRoot's CanvasLayer; this
## scene has no MainRoot, so without it a load refuses before reaching
## anything under test.
func _install_party_overview() -> void:
	_overview = preload("res://ui/party_overview.tscn").instantiate()
	_root.add_child(_overview)


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


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


## The probes go FIRST: a fake left in the table would be saved and loaded
## by every suite that runs after this one, which is exactly the kind of
## leak the registry makes possible for the first time.
func _restore() -> void:
	SaveManager.unregister(SOLO, _solo)
	SaveManager.unregister(FIRST, _first)
	SaveManager.unregister(SECOND, _second)
	SaveManager.unregister(HALF)

	if _save_path != "":
		DirAccess.remove_absolute(_save_path)
	WorldManager.discard_worlds()
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
