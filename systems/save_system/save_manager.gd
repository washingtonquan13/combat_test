extends Node
## Autoload singleton. Register as "SaveManager" under
## Project > Project Settings > AutoLoad. Must be registered AFTER
## WorldManager — this file's own _ready() connects to it.
##
## Being LAST has one consequence worth stating. Autoload _ready() runs in
## registration order, so while FlagManager, DemonRoster, CurrencyManager
## and PartyManager run theirs, this autoload does not exist yet and the
## `SaveManager` identifier cannot be resolved from them at all. Each of
## them therefore registers itself with a DEFERRED call, which lands once
## every autoload is up and still long before anything can ask for a save.
## The other half of that bargain is here: _persistables below is
## initialised at its declaration, not in _ready(), so register() works on
## an instance whose own _ready() has not run.
##
## Coordinates, but never itself HOLDS, game state — and, since the
## registry below, does not NAME the holders either. Every actual value
## lives in exactly one place already (FlagManager, PartyManager,
## DemonRoster, CurrencyManager, WorldManager, and the party's own shared
## Inventory), each carrying a duck-typed save_state()/load_state() pair
## (see those files, and Inventory's own — that pair now lives there
## rather than on StashComponent, specifically so the party's Inventory
## could reuse it instead of a second, parallel implementation).
##
## Each of those systems calls register() on ITSELF, naming the section it
## owns. This file's only job is: walk the registry, write what each
## target hands back to one ConfigFile, and do the reverse in an order
## that doesn't stomp itself (see load_file()'s own header on the capture
## trap that ordering exists to avoid). Adding a persistent system is a
## register() call in that system and no edit here — which is the whole
## point: the hand-maintained list this file used to carry was a second
## place to remember something, and forgetting it was silent.
##
## [meta], [world] and [combat] stay hand-written below. Those are
## DERIVED — read off WorldManager and off the save's own metadata —
## rather than any one system's own state, so there is nothing to
## register them from.
##
## The party's shared Inventory (registered by PartyOverview, see
## party_overview.gd) is a PERMANENT child of MainRoot's CanvasLayer,
## inside party_overview.tscn — not part of any world, and therefore
## never captured/cleared by anything WorldManager's own teardown does.
## Without it being saved, items taken from a chest into it would
## silently vanish the moment the application actually restarts (a real,
## shipped bug this comment exists to keep from happening again): the
## chest correctly persists having lost them, and nothing correctly
## persists where they went. It is also the only registered target that
## is not an autoload, which is what unregister() exists for.
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
## `reason` is a player-readable explanation, empty on success. It travels
## WITH the event rather than being parked on a `last_load_error` property
## for a listener to fetch afterwards — that would be a second copy of the
## same fact, which is the shape of defect this whole pass exists to
## remove.
##
## Emitted from the wrapper rather than at each exit, so a future early
## return cannot forget to fire it.
signal load_finished(path: String, ok: bool, reason: String)

## A brand new game has just been started: every registered system is
## empty, every world is gone, and nothing of the previous game is live.
##
## OBSERVERS ONLY. new_game() emits it last and does not await it, and
## nothing handling it can refuse or amend the new game — by the time it
## fires the old game is already gone. It exists for the screens that keep
## state of their own outside the registry (the character-creation screen's
## part-built character being the one that matters today), so they can
## reset themselves without this file, or the menu, having to know they
## exist.
signal new_game_started

const SAVE_DIR: String = "user://saves/"
const SAVE_EXTENSION: String = ".save"
const FORMAT_VERSION: int = 1

## Where each party member was standing, BY ID rather than by position
## in a list. Index-matching worked only while there was one party in
## one place; with a split party the list spans groups and areas, and
## the units present in the world being loaded are some arbitrary
## subset of it. Keyed by persistent_id, only the ones actually here
## match, and the rest are simply not applied.
var _pending_party_transforms: Dictionary = {}

## Fights from the save that have not been rebuilt yet, by area id.
## Outlives the load itself: a battle in an area the player was not in
## waits here until they go there.
var _pending_encounters: Dictionary = {}


# --- The registry -------------------------------------------------------

## Every system that persists itself, keyed by the save-file section it
## owns. Values are {"target": Object, "after": Array[StringName]}.
##
## THE single table. Registration order is insertion order (Godot
## Dictionaries preserve it, and re-assigning an existing key keeps that
## key's place), and registration order is the tiebreak _load_order()
## falls back to wherever nothing declares a dependency.
##
## Initialised HERE at its declaration rather than in _ready(), because
## this autoload is created last and a system registering itself as early
## as it can must find a table already standing (see this file's header).
var _persistables: Dictionary = {}

## Sections save() writes itself, derived rather than owned by any system.
## Listed so a load can tell "a section whose system is gone" from "a
## section that never had one".
const DERIVED_SECTIONS: Array = ["meta", "world", "combat"]


## Adds a system to the save file, under `key` as its section name.
##
## `key` is part of the save FORMAT, not an implementation detail:
## renaming one orphans that system's data in every save already written.
##
## `target` must implement save_state() -> Variant and load_state(state)
## -> void. Duck-typed rather than against an interface because the
## implementors have nothing else in common — four autoloads extending
## Node, a Control living in the UI scene, and (through AreaState's own
## reconciliation pass, which duck-types against the same pair) a
## StashComponent.
##
## `after` names keys this one must load AFTER. Declare one only where
## load_state() genuinely READS another system's restored state; anything
## else is left to registration order, which _load_order() preserves.
func register(key: StringName, target: Object, after: Array[StringName] = []) -> void:
	if key == &"":
		push_error("SaveManager.register: a persistable needs a section name.")
		return
	if not is_instance_valid(target):
		push_error("SaveManager.register('%s'): the target is not a valid object." % key)
		return
	# BOTH halves, checked at registration rather than discovered at save
	# time — a target that can be written and not read back is a save file
	# that looks fine until somebody opens it.
	if not target.has_method("save_state") or not target.has_method("load_state"):
		push_error("SaveManager.register('%s'): a %s must implement both save_state() and load_state()." % [
			key, target.get_class()])
		return

	if _persistables.has(key):
		var held: Object = _persistables[key]["target"]
		if held == target:
			# Re-registering the same object is how a target revises its own
			# declared dependencies. Not an error, and it keeps its place.
			_persistables[key]["after"] = after.duplicate()
			return
		if is_instance_valid(held) and not _is_departing(held):
			push_error("SaveManager.register('%s'): already held by a live %s. Unregister it first." % [
				key, held.get_class()])
			return

	_persistables[key] = {"target": target, "after": after.duplicate()}


## For a target that does not outlive the game. The party's shared
## Inventory belongs to a scene, and a freed node left in the table would
## be called on the next save.
##
## `target` is optional and guards a HANDOVER: a node unregisters in
## _exit_tree(), which for a queue_free() runs late, and without this it
## would cheerfully delete the entry its own replacement had already
## claimed.
func unregister(key: StringName, target: Object = null) -> void:
	if not _persistables.has(key):
		return
	if target != null and _persistables[key]["target"] != target:
		return
	_persistables.erase(key)


func is_registered(key: StringName) -> bool:
	return _persistables.has(key)


## The registered keys in the order they are saved and loaded in:
## registration order, with every `after` respected.
##
## Stable by construction — each pass walks the table in registration
## order and appends every key whose dependencies are already placed — so
## keys that declare nothing come out exactly as they went in.
func _load_order() -> Array[StringName]:
	var ordered: Array[StringName] = []
	var pending: Array[StringName] = []
	for key in _persistables:
		pending.append(key)

	while not pending.is_empty():
		var placed: int = 0
		var index: int = 0
		while index < pending.size():
			if _dependencies_placed(pending[index], ordered):
				ordered.append(pending[index])
				pending.remove_at(index)
				placed += 1
			else:
				index += 1
		if placed == 0:
			# A cycle. Reported rather than hung, and the remainder is kept
			# in registration order so the save is still written — a wrong
			# order beats losing the data while somebody untangles the loop.
			push_error("SaveManager: circular load-order dependency among %s." % str(pending))
			ordered.append_array(pending)
			break

	return ordered


## An `after` naming a key nobody registered is treated as SATISFIED, not
## as blocking: a system can legitimately declare an order against one
## that only some builds have, and blocking would strand the whole load
## over an absence.
func _dependencies_placed(key: StringName, ordered: Array[StringName]) -> bool:
	for dependency in _persistables[key]["after"]:
		if _persistables.has(dependency) and not ordered.has(dependency):
			return false
	return true


## A Node stays is_instance_valid() until the frame it was queue_free()d
## in actually ends, and its _exit_tree() has not run yet either — so a
## replacement arriving in the same frame (a test suite tearing down one
## PartyOverview and standing the next one up) would otherwise be refused
## as a duplicate of something already on its way out.
func _is_departing(target: Object) -> bool:
	var node: Node = target as Node
	return node != null and node.is_queued_for_deletion()


## Names every section of a save file that no registered system will
## read. A WARNING and not a refusal: a save written by a build that had
## a system this one no longer does is still a perfectly good save of
## everything else in it.
func _warn_about_unclaimed_sections(cfg: ConfigFile) -> void:
	for section in cfg.get_sections():
		if DERIVED_SECTIONS.has(section):
			continue
		if not _persistables.has(StringName(section)):
			push_warning("SaveManager: nothing is registered for save section '%s'; it was not loaded." % section)


# --- Lifecycle ----------------------------------------------------------

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
	# Every registered system, in dependency order. The section name IS the
	# key it registered under — which is why those keys are part of the
	# save format and not an implementation detail (see register()).
	for key in _load_order():
		var target: Object = _persistables[key]["target"]
		if not is_instance_valid(target):
			push_warning("SaveManager.save: '%s' was freed without unregistering; its state is not in this save." % key)
			continue
		cfg.set_value(String(key), "data", target.save_state())
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
## -> rebuild_area per area, focused one last -> apply saved positions as
## each world arrives. "As each world arrives" is safe because every world
## built this way announces itself as WorldManager.Entry.REBUILD, so
## _on_world_loaded can tell them from an ordinary walk through a door
## without this having to remember that a load is in progress.
func load_file(path: String) -> bool:
	var reason: String = _perform_load(path)
	var ok: bool = reason == ""
	if ok:
		load_completed.emit(path)
	else:
		push_warning("SaveManager.load_file failed: %s" % reason)
	load_finished.emit(path, ok, reason)
	return ok


## The load itself. Returns "" on success, or WHY it did not happen.
##
## A reason rather than a bool, so each exit states its own case once and
## the wrapper above does the reporting — both the warning and the signal.
## Phrased for a player reading it on the load screen, not for a log.
func _perform_load(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "That save file is missing."

	var cfg := ConfigFile.new()
	var err: Error = cfg.load(path)
	if err != OK:
		return "That save file could not be read (%s)." % error_string(err)

	# EVERYTHING THAT CAN REFUSE, BEFORE ANYTHING THAT WRITES. Below this
	# line the game is being taken apart and rebuilt; a failure past it
	# leaves the save's flags, party, demons and purse live with no world
	# to stand in, which is a worse state than the refusal it reports.
	var refusal: String = _why_load_would_fail(cfg)
	if refusal != "":
		return "That save cannot be opened: %s. Nothing was changed." % refusal

	# discard_worlds(), not unload(): a restore is not the player leaving
	# somewhere, so the travel gate has no jurisdiction here. It used to be
	# unload(true), where the `true` meant exactly that and said so only in
	# a comment.
	if not WorldManager.discard_worlds():
		return "The current worlds could not be cleared, so the save was not opened."

	_warn_about_unclaimed_sections(cfg)

	# Not gated on _current_world/area the way party_transforms is below.
	# Every registered target is either an autoload or a permanent
	# CanvasLayer child (the party's shared Inventory) — never something a
	# destination world creates — so no "wait for world_loaded" step is
	# needed for any of them.
	#
	# A section the file does not have loads as {} rather than being
	# skipped, which is deliberate and is exactly what the named calls this
	# replaced already did: load_state() means "become what this save says",
	# and a save that says nothing about a system means that system was
	# empty.
	for key in _load_order():
		var target: Object = _persistables[key]["target"]
		if not is_instance_valid(target):
			push_warning("SaveManager: '%s' was freed without unregistering; that section of the save was not loaded." % key)
			continue
		target.load_state(cfg.get_value(String(key), "data", {}))

	# Consumed by _on_world_loaded() the moment the area below finishes
	# loading — can't apply these here, since the destination world (and
	# therefore the Units to apply them TO) doesn't exist until
	# load_area() below actually finishes instantiating it.
	_pending_party_transforms = cfg.get_value("world", "party_transforms", {})
	# Kept until each area is actually visited, NOT consumed in one go:
	# only the area being loaded now can have its fight rebuilt, and the
	# others are rebuilt whenever the player travels to them.
	_pending_encounters = cfg.get_value("combat", "encounters", {})

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
		# Handed over outright rather than steered into place. This used to
		# set active_group and hope: rebuild_area inferred who was coming
		# from whoever was embodied in the previously focused world, so each
		# iteration could sweep up the people the last one had just put
		# down. Naming the group is the fix; the assignment below only says
		# who the player is commanding.
		PartyManager.active_group = claimant
		if WorldManager.rebuild_area(other, claimant) == null:
			push_warning("SaveManager.load_file: could not restore area '%s'." % other)

	# The saved area LAST, so the player ends up looking at the world they
	# saved in and commanding the group that was there.
	var homecoming: PartyGroup = _group_claiming(area_id)
	if homecoming:
		PartyManager.active_group = homecoming
	# May legitimately be null — the saved area need not be one anybody is
	# standing in — and rebuild_area now has a way to be told that, rather
	# than reading it as "bring whoever is around".
	var world: Node = WorldManager.rebuild_area(area_id, homecoming)

	# Every world this load will ever build has been built (world_loaded
	# is emitted synchronously inside rebuild_area), so anything still
	# sitting here belongs to a member in an area nothing rebuilt. Dropped
	# rather than kept: a transform left in the table would otherwise be
	# waiting to land on somebody during an unrelated load later.
	_pending_party_transforms = {}

	if not world:
		return "Area '%s' could not be built. The game is part-way through loading and should be loaded again." % area_id

	return ""


## Begins a NEW game: every registered system emptied, every world torn
## down, and the live leftovers no section of a save owns cleared with
## them. Returns false — having changed nothing — when the game shell
## cannot host a game right now.
##
## Here, and not in WorldManager or in the menu, for the same reason
## _perform_load is here.
##
## This file owns the registry, so it is the only thing that knows WHAT a
## game's state IS — and, since the registry, knows it without naming the
## holders (see the header). WorldManager owns worlds, which is a strict
## subset of a game: it can free every last one and leave a party roster, a
## purse, a stock of demons and a wall of flags standing behind it. And the
## menu owns the BUTTON, which is exactly as much as it should know; the
## order below is knowledge, and a second copy of it on a screen is a
## second thing to get wrong.
##
## That absence was the bug. Starting a game was a pure screen change
## (`close(); push(character_creation)`), so there was no new-game
## operation ANYWHERE, and a second New Game resumed the first: Esc → main
## menu runs WorldManager.unload(), whose teardown calls
## PartyManager.capture() and folds the live party into group.records, and
## nothing ever cleared what that wrote. The starting-area bootstrap guards
## on roster.is_empty(), so it early-returned, pending_leader was never
## consumed, and the OLD party was respawned around the OLD flags and the
## OLD dead enemies.
##
## A new game is a LOAD OF NOTHING, and is sequenced exactly like one
## (refuse → discard worlds → inject state), for exactly the same reasons.
## The one thing it deliberately does not do is touch the disk: no save
## file is deleted and no setting is written. Starting a game is about LIVE
## state only, and a player who starts one has not asked to lose the ones
## they already have.
func new_game() -> bool:
	# EVERYTHING THAT CAN REFUSE, BEFORE ANYTHING THAT WRITES — the same
	# bargain _perform_load makes above, and the same two structural
	# questions, asked through the same function so the two cannot drift.
	# Past this line the game is being emptied, and a refusal after it
	# would leave a half-cleared game with no world to stand in.
	var refusal: String = _structural_refusal()
	if refusal != "":
		push_warning("SaveManager.new_game refused: %s. Nothing was changed." % refusal)
		return false

	# WORLDS FIRST. Not a preference — the teardown WRITES to the party.
	# _tear_down_worlds() calls _disembody() on every group, and _disembody()
	# opens with PartyManager.capture(), which folds the live party straight
	# back into group.records. Empty the party first and tear down second
	# and that capture lands on the far side of the wipe, restoring the old
	# party into the roster this function just cleared: precisely the defect
	# being fixed, reintroduced one step later. discard_worlds() rather than
	# unload() for the same reason a load uses it — this is not the player
	# travelling, so the travel gate has no jurisdiction, and a fight in
	# progress is part of what is being replaced (see WorldManager.
	# can_rebuild()).
	if not WorldManager.discard_worlds():
		push_warning("SaveManager.new_game refused: the current worlds could not be cleared. The game may be part-way torn down.")
		return false

	# Told to become empty, every one of them, in the same dependency order
	# a real load uses. {} is not a special case invented here: it is this
	# file's own standing contract, stated in _perform_load above —
	# "load_state() means 'become what this save says', and a save that says
	# nothing about a system means that system was empty". A new game is a
	# save that says nothing about anything.
	#
	# So nothing is special-cased below. A registered target whose
	# load_state({}) does not leave it empty is a bug in that TARGET, and
	# teaching this loop about it would put the fix in the wrong file and
	# hide the next one. Iterating the registry rather than a list of names
	# is also what makes this stay correct: whatever is in the table on the
	# day is what a new game clears, with no second list to update.
	for key in _load_order():
		var target: Object = _persistables[key]["target"]
		if not is_instance_valid(target):
			push_warning("SaveManager.new_game: '%s' was freed without unregistering; it was not cleared." % key)
			continue
		target.load_state({})

	# The live leftovers the registry does not own. A LOAD never had to
	# clear any of these, because a load overwrites them on the way in with
	# the save's own values; a new game has nothing to overwrite them WITH,
	# which is why this block exists here and nowhere else.

	# This file's OWN two, and the easiest pair to forget because a load
	# does not clear them either — deliberately. _pending_encounters
	# outlives the load that filled it (see its declaration): a fight in an
	# area nobody visited waits there until somebody walks in. Across a new
	# game that patience becomes a haunting, rebuilding the previous game's
	# battle the first time the player enters that area, so both are dropped
	# with everything else that game consisted of.
	_pending_party_transforms = {}
	_pending_encounters = {}

	# A character that was confirmed in creation but never spawned — an
	# abandoned run, or the one being superseded right now. Left standing,
	# it is consumed by the next world that spawns a party, so the new game
	# would begin as the previous game's would-be leader.
	PartyManager.pending_leader = null

	# Already empty by construction: discard_worlds() above ran _disembody()
	# over EVERY group (embodied or not), which clears group.units, and
	# PartyManager.members is derived from those. Called anyway for the one
	# thing it does unconditionally that _disembody() does not — nulling
	# PartyManager.leader, which _disembody() only clears for a unit it
	# actually found in a group.
	PartyManager.clear_members()

	# An ability still armed from the world just discarded, and a selection
	# pointing at units that no longer exist. WorldManager's teardown
	# deselects too, but only if a world was FOCUSED; from the main menu
	# (with nothing focused) that branch never runs, and the main menu is
	# where New Game is pressed.
	AbilityManager.disarm()
	SelectionManager.deselect_all()

	# The combat log is a transcript of the game that just ended.
	SystemLog.clear_log()

	# Deliberately NO separate FlagManager call, and deliberately no
	# AreaState.clear_area(). FlagManager is REGISTERED, so the loop above
	# already handed it {} — and that single assignment takes quest flags,
	# cinematic play-once flags and every "areastate/" record with it,
	# because AreaState is stored INSIDE FlagManager's dictionary rather
	# than beside it (see area_state.gd's header). The previous game's dead
	# enemies and looted chests are gone with the flags. Clearing areas by
	# hand here would be a second path to state that already has exactly one
	# home, and it would need a list of every area to walk.

	# Last, and awaited by nobody: see the signal's own doc.
	new_game_started.emit()
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


func _current_leader_name() -> String:
	if PartyManager.leader:
		return PartyManager.leader.display_name
	for record in PartyManager.roster:
		if record.is_leader:
			return record.display_name
	return ""


## Empty for the overworld: spawns_party() == false there, so there is
## nothing in PartyManager.members to capture. A group standing on the
## overworld carries its own position in PartyGroup.overworld_position,
## which PartyManager saves and restores PER GROUP — this only ever
## describes embodied Units.
func _capture_party_transforms() -> Dictionary:
	var transforms: Dictionary = {}
	for unit in PartyManager.members:
		if is_instance_valid(unit) and unit.persistent_id != &"":
			transforms[String(unit.persistent_id)] = unit.global_transform
	return transforms



## world_loaded fires for EVERY world built, an ordinary walk through a
## door included — and one of those must not try to apply stale saved
## positions to whoever went through it. The reason says which is which,
## and it arrives WITH the signal rather than being remembered here.
##
## This used to be _awaiting_position_restore: a bool set true in
## _perform_load and false some forty lines later, guarding this exact
## branch. It was correct, but correct by inspection rather than by
## construction — a single early return added anywhere inside that span
## would have left it latched true, and the next unrelated door
## transition would have moved the party to positions out of an old save.
## A reason carried on the call has no span to leave open.
func _on_world_loaded(_world: Node, reason: WorldManager.Entry) -> void:
	if reason != WorldManager.Entry.REBUILD:
		_restore_encounters_here()
		return

	# Not emptied wholesale: one load builds every area the party is
	# standing in, and each arrives in its own world_loaded. Clearing on
	# the first would leave everyone in the second area at their spawn
	# point. Only what was actually applied is removed here; _perform_load
	# drops the rest once there are no more worlds coming.
	for unit in PartyManager.members:
		var key: String = String(unit.persistent_id)
		if _pending_party_transforms.has(key):
			unit.global_transform = _pending_party_transforms[key]
			_pending_party_transforms.erase(key)


	# Last: a turn order is meaningless until the units it names exist and
	# are where they belong.
	_restore_encounters_here()


## Whether the game SHELL can host a game being taken apart and rebuilt
## into it, or WHY it cannot ("" when it can).
##
## Shared by _why_load_would_fail() (a load) and new_game() (a load of
## nothing). Both operations empty every registered system before building
## anything back, so both have exactly the same two things to establish
## first, and neither may ask them of a particular save file — nothing
## here reads a ConfigFile.
##
## STRICTLY READ-ONLY, for the same reason its caller is: it runs before
## the first thing that writes.
func _structural_refusal() -> String:
	if not WorldManager.can_rebuild():
		return "no world host is registered to build a world into"

	# The one by-name check that outlives the by-name save/load calls, and
	# it is a check on the game SHELL rather than on any system: the party's
	# shared Inventory is the only persistable that belongs to a scene, and
	# PartyOverview is what registers it (see party_overview.gd). With no
	# PartyOverview in the tree the registry simply has no [inventory]
	# entry, so a load would warn and carry on — quietly dropping every item
	# the party is carrying, AFTER the flags, party, demons and purse had
	# already been overwritten, and a new game would just as quietly start
	# holding the last game's inventory. Refusing up front is the same
	# bargain every other clause here makes.
	if get_tree().get_first_node_in_group("party_overview") == null:
		return "no party overview in the tree, so the shared inventory cannot be reached"

	return ""


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
	# The two clauses that are not about this save file at all live in
	# _structural_refusal(), because new_game() has to ask exactly the same
	# two questions and two copies of a refusal is how the two answers
	# drift apart.
	var structural: String = _structural_refusal()
	if structural != "":
		return structural

	var area_id: StringName = StringName(cfg.get_value("world", "area_id", ""))
	if area_id == &"":
		return "the save names no area to open in"

	var area: AreaDefinition = AreaDatabase.find(area_id)
	if area == null:
		return "it was taken in area '%s', which no longer exists" % area_id
	if area.world_scene == null:
		return "area '%s' has no world scene to build" % area_id

	return ""


## Every area a party group is standing in, minus one — the caller loads
## that one last so the player ends up looking at it.
##
## Collected UP FRONT, because loading an area merges the groups that
## claim it, and iterating the live list while that happens would walk a
## collection being rewritten underneath.
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
