extends Node
## Autoload singleton. Register as "WorldManager" under
## Project > Project Settings > AutoLoad.
##
## Owns loading/unloading THE single active world under MainRoot's
## SceneRoot container. Replaces the old SceneManager (a push/pop
## suspend-stack) entirely — see the git history on that file if the
## reasoning behind the change needs revisiting. Short version: a
## suspended world never actually stopped participating in global systems
## (groups, autoload signals, PartyManager's own roster), so "two worlds
## alive at once" was a correctness hazard, not just a memory one. What
## made a real free-and-reload safe is PartyMemberData (see PartyManager's
## own capture()/clear_members()/spawn_party() trio) — nothing the party
## owns lives inside the world being freed anymore.
##
## A "world" is a 3D environment ONLY — test_arena.tscn today, a future
## overworld/fusion room, and (when there's art for one) a non-interactive
## backdrop behind the main menu or a framing set for character creation.
## The main menu and character creation THEMSELVES are deliberately NOT
## worlds: they're UIScreens plus a GameMode (see main_root.gd, which
## pushes the menu screen and sets the mode without loading any world at
## all). Collapsing a UI screen into the world layer is exactly the
## conflation the three-layer split exists to prevent — a screen that
## happens to have a backdrop still belongs to the UI layer, and its
## backdrop is an ordinary world loaded independently underneath it.
##
## A world may implement one duck-typed method, get_base_mode() ->
## GameMode.Mode, forwarded to GameMode.set_base_mode(). A backdrop world
## with no gameplay of its own simply doesn't implement it, leaving
## whatever mode its screen already set intact.
##
## Does NOT touch SceneTree.current_scene — see MainRoot.tscn's own note
## for why that's a hard, unavoidable Godot constraint (current_scene can
## only ever be a DIRECT child of the true tree root, and everything
## loaded here sits under MainRoot/SceneRoot, two levels deep).

signal world_loading(scene: PackedScene)
signal world_loaded(world: Node)

var _scene_root: Node = null
var _current_world: Node = null

## Set for the duration of a single load_world() call, the instant the
## incoming world is known to have a party pending restoration — see
## is_restoring_party() below. Exists because a world's own _ready() runs
## SYNCHRONOUSLY inside _scene_root.add_child(world), before spawn_party()
## ever gets called (spawn_party needs the world already in the tree) —
## so a world that wants to skip its own hardcoded bootstrap content on a
## reload (see test_arena.gd) has no other way to know a real spawn is
## about to follow.
var _pending_party_records: Array[PartyMemberData] = []


## Called once by MainRoot's own script. SceneRoot boots empty (see
## MainRoot.tscn's own header) — MainRoot kicks off the very first
## load_world() itself (the main menu), it doesn't adopt anything
## pre-placed the way the old SceneManager used to.
func register_scene_root(root: Node) -> void:
	_scene_root = root


## Whether a load is currently allowed — a world can't safely be swapped
## out from under a live fight, conversation, negotiation, or loot
## screen. GameMode.can_transition() answers exactly this (true only when
## nothing is overlaid on the current base mode); InteractionMenu is
## checked directly alongside it, same as CameraDirector.has_control()
## does, since it was deliberately never folded into GameMode (a brief
## context menu, not a real mode transition). Naturally always true
## during the menu/chargen hops (nothing has started either of those
## things yet).
func can_load() -> bool:
	return not InteractionMenu.is_open() and GameMode.can_transition()


## Frees whatever world is currently loaded (if any) and instantiates
## scene in its place. If a world with a real party was loaded (i.e. this
## isn't the very first load), the party is captured before the old world
## is freed and respawned into the new one at spawn_point_name — see
## PartyManager's own capture()/spawn_party(). Returns the new world, or
## null if the load was refused.
func load_world(scene: PackedScene, spawn_point_name: StringName = &"default") -> Node:
	if not can_load():
		push_warning("WorldManager.load_world refused (current_mode=%s)" % GameMode.Mode.keys()[GameMode.current_mode()])
		return null

	world_loading.emit(scene)

	var records: Array[PartyMemberData] = []
	if _current_world:
		records = PartyManager.capture()
		_dismiss_fielded_demons()
		PartyManager.clear_members()

		SelectionManager.deselect_all()
		InteractionMenu.close()
		UIStack.close_all()
		if _current_world.has_method("get_tactical_camera"):
			var old_cam: Camera3D = _current_world.get_tactical_camera()
			if is_instance_valid(old_cam):
				CameraDirector.unregister_tactical_camera(old_cam)

		# remove_child() immediately, THEN queue_free() — not queue_free()
		# alone. queue_free() defers the actual removal, so the outgoing
		# world would still occupy its name among _scene_root's children
		# at the moment the new world is added below, and Godot silently
		# renames the newcomer (e.g. "TestArena" -> "TestArena2") to avoid
		# the collision. Freeing is still safe to defer; only staying
		# IN THE TREE needs to end synchronously here.
		_scene_root.remove_child(_current_world)
		_current_world.queue_free()
		_current_world = null

	_pending_party_records = records

	var world: Node = scene.instantiate()
	_scene_root.add_child(world)
	_current_world = world
	if world.has_method("get_base_mode"):
		GameMode.set_base_mode(world.get_base_mode())

	if world.has_method("get_tactical_camera"):
		var cam: Camera3D = world.get_tactical_camera()
		if is_instance_valid(cam):
			CameraDirector.register_tactical_camera(cam)
			cam.make_current()

	if not records.is_empty():
		var spawn_point: Node3D = _resolve_spawn_point(world, spawn_point_name)
		PartyManager.spawn_party(records, world, spawn_point)

	_pending_party_records = []

	world_loaded.emit(world)
	return world


func current_world() -> Node:
	return _current_world


## Whether the world currently being loaded (mid-load_world() call) has a
## captured party about to be spawned into it — see this file's own
## _pending_party_records header for why a world needs to be able to ask
## this from inside its own _ready(). False outside of an active
## load_world() call, and false for the very first load (nothing to
## restore yet).
func is_restoring_party() -> bool:
	return not _pending_party_records.is_empty()


## Withdraws every currently-fielded demon through the same path a
## voluntary Dismiss uses (see DismissEffect) — syncing current_hp/
## current_fp back onto its OwnedDemon roster entry first, so a demon
## standing in the world at the moment it unloads doesn't leave
## DemonRoster thinking it's still out. A summoned demon is never a
## PartyManager member (add_member() refuses anything with summoned_by
## set), so capture()/clear_members() above never see it at all — this is
## the separate cleanup that actually has to happen for it.
func _dismiss_fielded_demons() -> void:
	for unit in UnitQuery.all_units(get_tree()):
		if unit.is_alive() and unit.owned_demon:
			unit.owned_demon.current_hp = unit.current_hp
			unit.owned_demon.current_fp = unit.current_fp
			unit.expire()


## Duck-typed, same convention as get_tactical_camera(): a world that
## cares about naming its own spawn points implements this; one that
## doesn't (or is being loaded for the very first time, with nothing to
## respawn) never needs it called at all. Falls back to the world's own
## root as a last resort so a missing/misnamed spawn point degrades to
## "everyone lands at the origin" instead of a hard error.
func _resolve_spawn_point(world: Node, spawn_point_name: StringName) -> Node3D:
	if world.has_method("get_spawn_point"):
		var point: Node3D = world.get_spawn_point(spawn_point_name)
		if point:
			return point
	push_warning("WorldManager: %s has no spawn point '%s' — spawning at world origin." % [world.name, spawn_point_name])
	return world
