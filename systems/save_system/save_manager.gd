extends Node
## Autoload singleton. Register as "SaveManager" under
## Project > Project Settings > AutoLoad. Must be registered AFTER
## WorldManager and every system it coordinates (autoload _ready() runs
## in registration order) — nothing here calls another autoload from its
## own _ready(), but load_file()/save() below assume every system it
## reaches for already exists.
##
## Coordinates, but never itself HOLDS, game state — every actual value
## lives in exactly one place already (FlagManager, PartyManager,
## DemonRoster, CurrencyManager, WorldManager, and the party's own shared
## Inventory), each carrying a duck-typed save_state()/load_state() pair
## (see those files, and Inventory's own — that pair now lives there
## rather than on StashComponent, specifically so this file can reuse it
## for the party's Inventory too, instead of a second, parallel
## implementation). This file's only job is: gather those six
## Dictionaries, write them to one ConfigFile, and do the reverse in an
## order that doesn't stomp itself (see load_file()'s own header on the
## capture trap that ordering exists to avoid).
##
## The party's shared Inventory (see _party_inventory()) is a PERMANENT
## child of MainRoot's CanvasLayer, inside party_overview.tscn — not part
## of any world, and therefore never captured/cleared by anything
## WorldManager's own teardown does. Without saving it explicitly here,
## items taken from a chest into it would silently vanish the moment the
## application actually restarts (a real, shipped bug this comment
## exists to keep from happening again): the chest correctly persists
## having lost them, and nothing correctly persists where they went.
##
## FlagManager's own Dictionary carries quest progress AND all of
## AreaState's per-area records along for free — see that file's header.
## There is deliberately no separate "quest state" or "area state"
## section here; adding one would be a second, competing path for data
## that already has exactly one home.
##
## ConfigFile, not JSON — plain text, so a save is still inspectable, but
## (unlike JSON) round-trips a Variant exactly: an int stays an int, a
## nested Dictionary (a stash's item list, inside AreaState, inside
## FlagManager's own dictionary) survives structurally intact. JSON has
## no integer type, so grid positions/stack counts would silently come
## back as floats and break the typed int assignments StashComponent.
## load_state() depends on.

signal save_completed(path: String)
signal load_completed(path: String)

const SAVE_DIR: String = "user://saves/"
const SAVE_EXTENSION: String = ".save"
const FORMAT_VERSION: int = 1

## Non-empty only for the duration of a load_file() call that named an
## overworld save — consumed and cleared the moment world_loaded fires
## for that load. See _on_world_loaded()'s own header for why this can't
## just be a local variable inside load_file().
var _pending_party_transforms: Array[Transform3D] = []
var _pending_avatar_transform: Variant = null
var _awaiting_position_restore: bool = false


func _ready() -> void:
	WorldManager.world_loaded.connect(_on_world_loaded)


## Mirrors WorldManager.can_load()'s own reasoning at one level up: a
## save mid-combat would need to capture turn order, initiative and
## status effects, none of which any save_state() here writes — refusing
## up front is honest about that gap rather than writing a save that
## silently can't restore it. GameMode.can_transition() (nothing
## overlaid) is the same "no live sub-flow to interrupt" check
## WorldManager itself uses; the explicit mode check narrows that further
## to the two base modes an save can actually make sense of.
func can_save() -> bool:
	if not GameMode.can_transition():
		return false
	var mode: GameMode.Mode = GameMode.current_mode()
	return mode == GameMode.Mode.EXPLORATION or mode == GameMode.Mode.OVERWORLD


## save_name is the player-facing label shown in the save list — never
## the filename. The filename is generated from the timestamp, so two
## saves named identically by the player never collide and saves sort
## by filename exactly as they sort by their own recorded timestamp.
func save(save_name: String) -> bool:
	if not can_save():
		push_warning("SaveManager.save refused (current_mode=%s)" % GameMode.Mode.keys()[GameMode.current_mode()])
		return false

	var area: AreaDefinition = WorldManager.current_area()
	if not area:
		push_warning("SaveManager.save refused: no area currently loaded.")
		return false

	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

	var timestamp: int = int(Time.get_unix_time_from_system())
	var path: String = "%s%d%s" % [SAVE_DIR, timestamp, SAVE_EXTENSION]

	var cfg := ConfigFile.new()
	cfg.set_value("meta", "name", save_name)
	cfg.set_value("meta", "timestamp", timestamp)
	cfg.set_value("meta", "area_display_name", area.display_name)
	cfg.set_value("meta", "leader_name", _current_leader_name())
	cfg.set_value("meta", "format_version", FORMAT_VERSION)

	cfg.set_value("world", "area_id", area.id)
	cfg.set_value("world", "party_transforms", _capture_party_transforms())
	# Only written when non-null (an overworld save) — see load_file()'s
	# own has_section_key() check on the read side for why "the key is
	# absent" needs to actually mean absent, not present-with-value-NIL.
	var avatar_transform: Variant = _capture_avatar_transform()
	if avatar_transform != null:
		cfg.set_value("world", "avatar_transform", avatar_transform)

	cfg.set_value("flags", "data", FlagManager.save_state())
	cfg.set_value("party", "data", PartyManager.save_state())
	cfg.set_value("demons", "data", DemonRoster.save_state())
	cfg.set_value("currency", "data", CurrencyManager.save_state())
	cfg.set_value("inventory", "data", _party_inventory().save_state())

	var err: Error = cfg.save(path)
	if err != OK:
		push_warning("SaveManager.save failed writing '%s': %s" % [path, error_string(err)])
		return false

	save_completed.emit(path)
	return true


## Load order matters and is the whole reason unload() exists as a
## separate WorldManager entry point from load_world(): load_world()
## calls PartyManager.capture() on whatever world it's REPLACING, which
## would immediately overwrite the roster this function is about to
## inject from the save file with a fresh (and wrong) capture of the
## OLD world. unload() frees the current world without capturing, so by
## the time PartyManager.load_state() runs, there is nothing left for
## anything to capture over it.
##
## Sequence: unload (no capture) -> inject state into every system ->
## load_area (now safe: _current_world is null, so load_world()'s own
## teardown captures nothing) -> apply saved positions once world_loaded
## fires for THIS load.
func load_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_warning("SaveManager.load_file: no file at '%s'" % path)
		return false

	var cfg := ConfigFile.new()
	var err: Error = cfg.load(path)
	if err != OK:
		push_warning("SaveManager.load_file failed reading '%s': %s" % [path, error_string(err)])
		return false

	if not WorldManager.unload():
		push_warning("SaveManager.load_file refused: WorldManager.unload() was refused.")
		return false

	FlagManager.load_state(cfg.get_value("flags", "data", {}))
	PartyManager.load_state(cfg.get_value("party", "data", {}))
	DemonRoster.load_state(cfg.get_value("demons", "data", {}))
	CurrencyManager.load_state(cfg.get_value("currency", "data", {}))
	# Not gated on _current_world/area the way party_transforms/
	# avatar_transform are below — the party's shared Inventory is a
	# permanent CanvasLayer child, not something a destination world
	# creates, so there's no "wait for world_loaded" step needed here.
	_party_inventory().load_state(cfg.get_value("inventory", "data", {}))

	# Consumed by _on_world_loaded() the moment the area below finishes
	# loading — can't apply these here, since the destination world (and
	# therefore the Units/avatar to apply them TO) doesn't exist until
	# load_area() below actually finishes instantiating it.
	#
	# has_section_key() before reading avatar_transform, not
	# get_value(..., null) — ConfigFile treats a NIL-typed default as
	# "no default was given" and raises an error when the key is
	# genuinely absent (which it always is for an ordinary, non-overworld
	# save: _capture_avatar_transform() only ever writes a real value
	# when the world being saved has get_avatar(), so passing null
	# through as "the default" doesn't mean what it looks like it means).
	_pending_party_transforms = cfg.get_value("world", "party_transforms", [])
	if cfg.has_section_key("world", "avatar_transform"):
		_pending_avatar_transform = cfg.get_value("world", "avatar_transform")
	else:
		_pending_avatar_transform = null
	_awaiting_position_restore = true

	var area_id: StringName = cfg.get_value("world", "area_id", &"")
	var world: Node = WorldManager.load_area(area_id)
	if not world:
		_awaiting_position_restore = false
		push_warning("SaveManager.load_file: load_area('%s') failed after state was already injected." % area_id)
		return false

	load_completed.emit(path)
	return true


## Newest first. Reads only the [meta] section of each file — a full
## ConfigFile.load() still parses the file syntactically (ConfigFile has
## no partial-read mode), but this never calls a single system's
## load_state() to build the listing, so listing many saves stays cheap
## regardless of how much AreaState/roster data any one of them holds.
func list_saves() -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

	for file_name in DirAccess.get_files_at(SAVE_DIR):
		if not file_name.ends_with(SAVE_EXTENSION):
			continue
		var path: String = SAVE_DIR + file_name
		var cfg := ConfigFile.new()
		if cfg.load(path) != OK:
			continue
		results.append({
			"path": path,
			"name": cfg.get_value("meta", "name", file_name),
			"timestamp": cfg.get_value("meta", "timestamp", 0),
			"area_display_name": cfg.get_value("meta", "area_display_name", ""),
			"leader_name": cfg.get_value("meta", "leader_name", ""),
		})

	results.sort_custom(func(a, b): return a["timestamp"] > b["timestamp"])
	return results


func delete_save(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## "" when there are no saves — the sentinel CONTINUE's own visibility
## check reads directly (see main_menu.gd).
func most_recent() -> String:
	var saves: Array[Dictionary] = list_saves()
	return saves[0]["path"] if not saves.is_empty() else ""


## Found by role rather than a direct reference, same group-lookup idiom
## GiveItemEffect (give_item_effect.gd) already uses to reach this exact
## node — this file is an autoload with no scene-tree position of its
## own to hold a NodePath against, and PartyOverview isn't an autoload
## either. Never null in practice: PartyOverview is a permanent child of
## MainRoot's CanvasLayer, present from boot regardless of GameMode or
## whether a world is loaded (the main menu, e.g., where load_file() is
## a legitimate caller).
func _party_inventory() -> Inventory:
	var party_overview: Node = get_tree().get_first_node_in_group("party_overview")
	return party_overview.get_inventory()


func _current_leader_name() -> String:
	if PartyManager.leader:
		return PartyManager.leader.display_name
	for record in PartyManager.roster:
		if record.is_leader:
			return record.display_name
	return ""


## Empty array for the overworld (spawns_party() == false, nothing in
## PartyManager.members to capture) — avatar_transform below is what
## carries a position there instead.
func _capture_party_transforms() -> Array[Transform3D]:
	var transforms: Array[Transform3D] = []
	for unit in PartyManager.members:
		transforms.append(unit.global_transform)
	return transforms


## null when the current world isn't the overworld (an ordinary area has
## no avatar to ask) — get_avatar() is duck-typed the same way
## get_tactical_camera()/spawns_party() already are (see overworld.gd).
func _capture_avatar_transform() -> Variant:
	var world: Node = WorldManager.current_world()
	if world and world.has_method("get_avatar"):
		var avatar: Node3D = world.get_avatar()
		if is_instance_valid(avatar):
			return avatar.global_transform
	return null


## world_loaded fires for EVERY area load, not just one triggered by
## load_file() above — an ordinary door/travel transition must NOT try
## to apply stale (or absent) saved positions, which is exactly what
## _awaiting_position_restore guards against; it's true for only the one
## world_loaded firing that load_file() itself caused, and is cleared
## unconditionally below regardless of whether either array/value was
## actually present, so a save file with no avatar position (an ordinary
## area save) can't leave this latched on for the NEXT unrelated load.
func _on_world_loaded(world: Node) -> void:
	if not _awaiting_position_restore:
		return
	_awaiting_position_restore = false

	for i in range(min(_pending_party_transforms.size(), PartyManager.members.size())):
		PartyManager.members[i].global_transform = _pending_party_transforms[i]
	_pending_party_transforms = []

	if _pending_avatar_transform != null and world.has_method("get_avatar"):
		var avatar: Node3D = world.get_avatar()
		if is_instance_valid(avatar):
			avatar.global_transform = _pending_avatar_transform
	_pending_avatar_transform = null
