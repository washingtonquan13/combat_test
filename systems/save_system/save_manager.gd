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

## Emitted on EVERY exit from load_file(), successful or not — `ok` says
## which. load_completed only ever fires for a load that worked, which is
## right for anything acting ON the loaded game and wrong for anything
## cleaning up after the ATTEMPT.
##
## That gap had a visible cost. The title screen closed itself on
## load_completed, so a refused load left it sitting over a world that had
## already loaded and started its music, with no way forward but to load
## again. Five paths through load_file() return false, and every one of
## them was invisible to a listener: a push_warning is not an event.
##
## Emitted from the wrapper rather than at each exit, so a future early
## return cannot forget to fire it.
signal load_finished(path: String, ok: bool)

const SAVE_DIR: String = "user://saves/"
const SAVE_EXTENSION: String = ".save"
const FORMAT_VERSION: int = 1

## Non-empty only for the duration of a load_file() call that named an
## overworld save — consumed and cleared the moment world_loaded fires
## for that load. See _on_world_loaded()'s own header for why this can't
## just be a local variable inside load_file().
## Where each party member was standing, BY ID rather than by position
## in a list. Index-matching worked only while there was one party in
## one place; with a split party the list spans groups and areas, and
## the units present in the world being loaded are some arbitrary
## subset of it. Keyed by persistent_id, only the ones actually here
## match, and the rest are simply not applied.
var _pending_party_transforms: Dictionary = {}
var _pending_avatar_transform: Variant = null
var _awaiting_position_restore: bool = false

## Fights from the save that have not been rebuilt yet, by area id.
## Outlives the load itself: a battle in an area the player was not in
## waits here until they go there.
var _pending_encounters: Dictionary = {}


func _ready() -> void:
	WorldManager.world_loaded.connect(_on_world_loaded)


## Mirrors WorldManager.can_travel()'s own reasoning at one level up: a
## save mid-combat would need to capture turn order, initiative and
## status effects, none of which any save_state() here writes — refusing
## up front is honest about that gap rather than writing a save that
## silently can't restore it. GameMode.can_transition() (nothing
## overlaid) is the same "no live sub-flow to interrupt" check
## WorldManager itself uses; the explicit mode check narrows that further
## to the two base modes an save can actually make sense of.
func can_save() -> bool:
	var mode: GameMode.Mode = GameMode.current_mode()
	# COMBAT is allowed now: a fight is written down as who is in it, in
	# what order, and how far through (see Encounter.save_state), with
	# every combatant's own state travelling with the unit. Dialogue,
	# negotiation and looting still refuse — those are live conversations
	# and open panels with nothing serializing them, and they need their
	# own review before that changes.
	return mode == GameMode.Mode.EXPLORATION \
		or mode == GameMode.Mode.OVERWORLD \
		or mode == GameMode.Mode.COMBAT


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

	# Before anything is written. capture() is what MINTS a party member an
	# id (see PartyManager._capture_one), and the transform table below is
	# keyed by id — captured first, every key would be the empty string and
	# every position would collapse onto a single entry. save_state() calls
	# it again harmlessly; what matters is that it has happened by now.
	PartyManager.capture()

	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

	var timestamp: int = int(Time.get_unix_time_from_system())
	var path: String = "%s%d%s" % [SAVE_DIR, timestamp, SAVE_EXTENSION]

	var cfg := ConfigFile.new()
	cfg.set_value("meta", "name", save_name)
	cfg.set_value("meta", "timestamp", timestamp)
	cfg.set_value("meta", "area_display_name", area.display_name)
	cfg.set_value("meta", "leader_name", _current_leader_name())
	cfg.set_value("meta", "format_version", FORMAT_VERSION)

	# The area the player is LOOKING at, which is the one a load rebuilds.
	# Every other group carries its own area_id (see
	# PartyManager.save_state), and its world is rebuilt from authored
	# content plus AreaState when the player next travels there — which,
	# now that units remember, means rebuilt as it was left.
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
	# By area, so a fight nobody was watching comes back when the player
	# next walks into it rather than needing its world kept alive.
	cfg.set_value("combat", "encounters", WorldManager.encounters_by_area())

	var err: Error = cfg.save(path)
	if err != OK:
		push_warning("SaveManager.save failed writing '%s': %s" % [path, error_string(err)])
		return false

	save_completed.emit(path)
	return true


## Load order matters, and is the whole reason the restore path has its
## own WorldManager entry points. An ordinary load_world() calls
## PartyManager.capture() on whatever world it is REPLACING, which would
## immediately overwrite the roster this function is about to inject from
## the save file with a fresh (and wrong) capture of the OLD world.
## discard_worlds() frees everything without capturing, so by the time
## PartyManager.load_state() runs there is nothing left to capture over
## it.
##
## The restore entry points also ask a different permission question than
## travel does — can_rebuild() rather than can_travel(). That is not a
## convenience: asking the travel gate here deadlocked the load outright,
## because a fight restored into the first area rebuilt then refused every
## rebuild after it. See WorldManager.can_rebuild().
##
## Sequence: discard_worlds (no capture) -> inject state into every system
## -> rebuild_area per area, focused one last -> apply saved positions once
## world_loaded fires for THIS load.
func load_file(path: String) -> bool:
	var ok: bool = _perform_load(path)
	if ok:
		load_completed.emit(path)
	load_finished.emit(path, ok)
	return ok


## The load itself. Every `return false` in here is reported by the
## wrapper above; none of them needs to remember to say so.
func _perform_load(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_warning("SaveManager.load_file: no file at '%s'" % path)
		return false

	var cfg := ConfigFile.new()
	var err: Error = cfg.load(path)
	if err != OK:
		push_warning("SaveManager.load_file failed reading '%s': %s" % [path, error_string(err)])
		return false

	# EVERYTHING THAT CAN REFUSE, BEFORE ANYTHING THAT WRITES. Below this
	# line the game is being taken apart and rebuilt; a failure past it
	# leaves the save's flags, party, demons and purse live with no world
	# to stand in, which is a worse state than the refusal it reports.
	var refusal: String = _why_load_would_fail(cfg)
	if refusal != "":
		push_warning("SaveManager.load_file refused, nothing changed: %s" % refusal)
		return false

	# discard_worlds(), not unload(): a restore is not the player leaving
	# somewhere, so the travel gate has no jurisdiction here. It used to be
	# unload(true), where the `true` meant exactly that and said so only in
	# a comment.
	if not WorldManager.discard_worlds():
		push_warning("SaveManager.load_file refused: WorldManager.discard_worlds() was refused.")
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
	_pending_party_transforms = cfg.get_value("world", "party_transforms", {})
	if cfg.has_section_key("world", "avatar_transform"):
		_pending_avatar_transform = cfg.get_value("world", "avatar_transform")
	else:
		_pending_avatar_transform = null
	# Kept until each area is actually visited, NOT consumed in one go:
	# only the area being loaded now can have its fight rebuilt, and the
	# others are rebuilt whenever the player travels to them.
	_pending_encounters = cfg.get_value("combat", "encounters", {})
	_awaiting_position_restore = true

	var area_id: StringName = cfg.get_value("world", "area_id", &"")

	# Every area a group is standing in, not just the one on screen.
	#
	# Residency here is EARNED, and party presence earns it — so a load that
	# built only the focused world put the game in a state the rest of the
	# engine treats as impossible: members listed in the party panel whose
	# area nothing was holding. Clicking one answered "somewhere not
	# currently loaded", and the only way to reach them was to walk another
	# unit over, which is not travel, it is repair. They are standing there
	# in the save; they should be standing there when it opens.
	for other in _areas_holding_party(area_id):
		var claimant: PartyGroup = _group_claiming(other)
		if claimant == null:
			continue
		# Named BEFORE the call. load_area with no travellers embodies the
		# ACTIVE group and rewrites its remembered area to wherever it is
		# sent, so leaving this alone would drag one group through every
		# other group's area in turn and end with the party merged.
		PartyManager.active_group = claimant
		if WorldManager.rebuild_area(other) == null:
			push_warning("SaveManager.load_file: could not restore area '%s'." % other)

	# The saved area LAST, so the player ends up looking at the world they
	# saved in and commanding the group that was there.
	var homecoming: PartyGroup = _group_claiming(area_id)
	if homecoming:
		PartyManager.active_group = homecoming
	var world: Node = WorldManager.rebuild_area(area_id)

	# Every world_loaded this load will ever emit has now been handled
	# (world_loaded is emitted synchronously inside load_area), so the
	# restore window closes here rather than on the first world to arrive.
	_awaiting_position_restore = false
	_pending_party_transforms = {}
	_pending_avatar_transform = null

	if not world:
		push_warning("SaveManager.load_file: rebuild_area('%s') failed after state was already injected." % area_id)
		return false

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
func _capture_party_transforms() -> Dictionary:
	var transforms: Dictionary = {}
	for unit in PartyManager.members:
		if is_instance_valid(unit) and unit.persistent_id != &"":
			transforms[String(unit.persistent_id)] = unit.global_transform
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
		_restore_encounters_here()
		return

	# The window stays OPEN across this whole load, and the table is not
	# emptied wholesale: one load_file now builds every area the party is
	# standing in, and each arrives in its own world_loaded. Closing on the
	# first would leave everyone in the second area at their spawn point.
	# Only what was actually applied is removed; load_file clears the rest
	# once there are no more worlds coming.
	for unit in PartyManager.members:
		var key: String = String(unit.persistent_id)
		if _pending_party_transforms.has(key):
			unit.global_transform = _pending_party_transforms[key]
			_pending_party_transforms.erase(key)

	if _pending_avatar_transform != null and world.has_method("get_avatar"):
		var avatar: Node3D = world.get_avatar()
		if is_instance_valid(avatar):
			avatar.global_transform = _pending_avatar_transform
	_pending_avatar_transform = null

	# Last: a turn order is meaningless until the units it names exist and
	# are where they belong.
	_restore_encounters_here()


## Every area a party group is standing in, minus one — the caller loads
## that one last so the player ends up looking at it.
##
## Collected UP FRONT, because loading an area merges the groups that
## claim it, and iterating the live list while that happens would walk a
## collection being rewritten underneath.
## Why this save cannot be opened, or "" if it can.
##
## STRICTLY READ-ONLY. Its entire purpose is to run before the first thing
## that writes, so anything added here must not change state — including
## indirectly, which is why the area id is read off the ConfigFile rather
## than out of PartyManager. Injecting the party to find out where it is
## standing would be the very mutation this exists to avoid.
##
## Only conditions that would ABORT the load belong here. A SECONDARY area
## that no longer exists is deliberately not one: further down it warns and
## leaves that group abstract, which is degraded but still playable, and
## failing the whole load over it would strand the player on the title
## screen for a problem they can walk away from.
func _why_load_would_fail(cfg: ConfigFile) -> String:
	if not WorldManager.can_rebuild():
		return "no world host is registered to build a world into"

	# _party_inventory() calls straight through this node with no guard, so
	# without it the load crashes — and it crashes AFTER the party, flags,
	# demons and purse have already been overwritten.
	if get_tree().get_first_node_in_group("party_overview") == null:
		return "no party overview in the tree, so the shared inventory cannot be reached"

	var area_id: StringName = StringName(cfg.get_value("world", "area_id", ""))
	if area_id == &"":
		return "the save names no area to open in"

	var area: AreaDefinition = AreaDatabase.find(area_id)
	if area == null:
		return "it was taken in area '%s', which no longer exists" % area_id
	if area.world_scene == null:
		return "area '%s' has no world scene to build" % area_id

	return ""


func _areas_holding_party(except: StringName) -> Array[StringName]:
	var areas: Array[StringName] = []
	for group in PartyManager.groups:
		var id: StringName = group.current_area_id()
		if id == &"" or id == except or areas.has(id):
			continue
		areas.append(id)
	return areas


## The group standing in an area. At this point in a load nobody is
## embodied anywhere, so every group answers with the area it was saved
## with, which is exactly the question being asked.
func _group_claiming(area_id: StringName) -> PartyGroup:
	for group in PartyManager.groups:
		if group.current_area_id() == area_id:
			return group
	return null


## Rebuilds any saved fight belonging to the area now on screen, and
## forgets it once rebuilt. Runs on EVERY world load, not only the one a
## load_file caused, because that is how a fight in an area the player
## was not in comes back when they finally walk into it.
func _restore_encounters_here() -> void:
	if _pending_encounters.is_empty():
		return
	var area: AreaDefinition = WorldManager.current_area()
	if area == null:
		return
	var key: String = String(area.id)
	if not _pending_encounters.has(key):
		return

	var states: Array = _pending_encounters[key]
	_pending_encounters.erase(key)
	for state in states:
		CombatManager.restore_combat(state)
