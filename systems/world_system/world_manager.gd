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
## A world may implement up to three duck-typed methods:
## - get_base_mode() -> GameMode.Mode, forwarded to GameMode.set_base_mode().
##   A backdrop world with no gameplay of its own simply doesn't implement
##   it, leaving whatever mode its screen already set intact.
## - spawns_party() -> bool, defaulting to true when absent. A world like
##   the overworld — one controllable avatar, not four tactical Units —
##   returns false; PartyManager.roster survives untouched either way,
##   only whether it gets projected into live Units for THIS world varies.
## - get_spawn_point(name: StringName) -> Node3D, same as it's always been.
##
## Does NOT touch SceneTree.current_scene — see MainRoot.tscn's own note
## for why that's a hard, unavoidable Godot constraint (current_scene can
## only ever be a DIRECT child of the true tree root, and everything
## loaded here sits under MainRoot/SceneRoot, two levels deep).

signal world_loading(scene: PackedScene)
signal world_loaded(world: Node)

var _scene_root: Node = null
var _current_world: Node = null
## The AreaDefinition behind the currently loaded world, if it was loaded
## via load_area() — null for a world loaded through the raw load_world()
## primitive (nothing calls that directly anymore, but it stays a valid
## way to boot a world with no area data at all, e.g. a standalone test
## scene). Read by MusicManager to resolve per-area tracks. Assigned inside
## load_world() itself, BEFORE world_loaded emits — a listener reacting to
## that signal (MusicManager) is guaranteed this already names the world it
## was just handed, never the one just torn down.
var _current_area: AreaDefinition = null

## Set for the duration of a single load_world() call, the instant the
## incoming world is known to be about to have PartyManager.roster spawned
## into it — see is_restoring_party() below. Exists because a world's own
## _ready() runs SYNCHRONOUSLY inside _scene_root.add_child(world), before
## spawn_party() ever gets called (spawn_party needs the world already in
## the tree) — so a world that wants to skip its own hardcoded bootstrap
## content on a reload (see test_arena.gd) has no other way to know a real
## spawn is about to follow.
var _is_restoring_party: bool = false

## Which named spawn point THIS load_world() call resolved to — set once,
## right after the incoming world is instantiated (see load_world()),
## read by a world that needs it at _ready() time but doesn't spawn a
## tactical party (see overworld.gd's own _spawn_avatar()), so
## _resolve_spawn_point()'s own PartyManager.spawn_party() path never
## reaches it. Already the FINAL resolved name by the time anything reads
## it — see _resolve_entry_spawn_point()'s own comment for the three-tier
## resolution (explicit request > derived back-link > world's own
## "default" fallback) that produced it.
var _pending_spawn_point_name: StringName = &"default"


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


## Frees whatever world is currently loaded, WITHOUT capturing it into
## PartyManager.roster first — the one caller that needs this is
## SaveManager.load_file(): roster is about to be overwritten by the
## save file's own data one line later, so capturing the (about to be
## discarded) live world first would just be immediately undone. Every
## ordinary area transition still goes through load_world(), which calls
## the same teardown with capture_party=true — this does not change that
## path at all.
##
## No-op (returns true) when nothing is loaded — the main menu, e.g.,
## where SaveManager.load_file() can also be called from. Returns false,
## refused exactly like load_world(), if a load isn't currently allowed
## (mid-combat/dialogue/loot).
func unload() -> bool:
	if not can_load():
		push_warning("WorldManager.unload refused (current_mode=%s)" % GameMode.Mode.keys()[GameMode.current_mode()])
		return false

	world_loading.emit(null)
	_teardown_current_world(false)
	_current_area = null
	return true


## The shared half of leaving whatever world is currently loaded (if
## any) — extracted from load_world() so SaveManager.load_file() can
## reuse the exact same teardown via unload() above, with capture_party
## controlling only whether PartyManager.capture() runs. Every other
## step (dismissing fielded demons, clearing selection/menus/UI,
## unregistering the tactical camera, freeing the world node, invalidating
## NavigationGrid) happens unconditionally either way — none of that
## depends on whether the party gets captured first.
func _teardown_current_world(capture_party: bool) -> void:
	if not _current_world:
		return

	if capture_party:
		# A no-op when the outgoing world never spawned the party in the
		# first place (members is empty) — see PartyManager.capture()'s
		# own guard for why that's required, not just harmless.
		PartyManager.capture()
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
	# at the moment a new world is added right after, and Godot silently
	# renames the newcomer (e.g. "TestArena" -> "TestArena2") to avoid
	# the collision. Freeing is still safe to defer; only staying
	# IN THE TREE needs to end synchronously here.
	_scene_root.remove_child(_current_world)
	_current_world.queue_free()
	_current_world = null

	# NavigationGrid is an Engine singleton (see its own header) — it
	# outlives every world and caches raw CollisionShape3D* pointers
	# into whichever world it last scanned. Without this, those
	# pointers dangle into the geometry just freed above, and the next
	# query that lazily rasterizes a not-yet-touched chunk dereferences
	# freed memory — a real native crash this project shipped (no
	# GDScript error precedes it; shows as a bare signal 11). This
	# forces the next ensure_baked() call to do a real re-scan instead
	# of trusting stale state.
	NavigationGrid.invalidate()


## Frees whatever world is currently loaded (if any) and instantiates
## scene in its place. If the outgoing world actually had the party
## spawned into it, that's captured into PartyManager.roster before it's
## freed. Whether the roster gets spawned into the NEW world depends on
## that world's own duck-typed spawns_party() (default true when absent)
## — a world that opts out (the overworld's single avatar) is loaded with
## zero party Units regardless of what roster holds. Returns the new
## world, or null if the load was refused.
## spawn_point_name empty means "let the destination derive it" (see
## _resolve_entry_spawn_point()); area is the AreaDefinition behind scene,
## or null for a world with no area data at all (nothing calls it that way
## today, but it stays valid — see _current_area's own header). Also owns
## assigning _current_area, so it and _current_world always describe the
## same world together, before world_loaded ever fires — see _current_area's
## header for why that ordering is load-bearing, not incidental.
func load_world(scene: PackedScene, spawn_point_name: StringName = &"", area: AreaDefinition = null) -> Node:
	if not can_load():
		push_warning("WorldManager.load_world refused (current_mode=%s)" % GameMode.Mode.keys()[GameMode.current_mode()])
		return null

	world_loading.emit(scene)

	# Captured before any of the teardown below can touch _current_area —
	# this is "the area being left," read once, up front.
	var from_area_id: StringName = _current_area.id if _current_area else &""

	# true: an ordinary area transition, PartyManager.roster must stay
	# current against whatever was actually live. See _teardown_current_world's
	# own header for the false case (SaveManager.load_file(), via unload()).
	_teardown_current_world(true)

	# Assigned here — after the outgoing world is fully torn down, before the
	# incoming one is even instantiated — so _current_area and _current_world
	# change together with no window where one names the old world and the
	# other the new one. In particular this must land before world_loaded
	# emits below, since MusicManager's own handler reads current_area()
	# synchronously from inside it.
	_current_area = area

	var world: Node = scene.instantiate()
	# Resolved BEFORE entering the tree — instantiate() already built the
	# whole subtree structurally (children exist, get_children() works)
	# even though _ready() hasn't cascaded yet, so world's own doors/exits
	# are inspectable here. Must happen before add_child() below: a
	# world's _ready() (which runs synchronously inside add_child()) may
	# need the final answer immediately, and there's no other point where
	# both "the world exists to inspect" and "nothing has read it yet"
	# hold at once.
	_pending_spawn_point_name = _resolve_entry_spawn_point(world, spawn_point_name, from_area_id)

	# Same detached window _resolve_entry_spawn_point() above already
	# exploits — the subtree exists structurally but _ready() hasn't
	# cascaded, so a removed entity is freed here and NEVER enters the
	# tree at all (no spawn-then-despawn flicker, no CombatManager
	# registration to unwind). Guarded on area != null since load_world()
	# is legitimately callable with no area data (see _current_area's own
	# header) — AreaState has nothing to reconcile against in that case.
	if area:
		_reconcile_area_state(world, area.id)

	var world_wants_party: bool = not world.has_method("spawns_party") or world.spawns_party()
	_is_restoring_party = world_wants_party and not PartyManager.roster.is_empty()

	_scene_root.add_child(world)
	_current_world = world
	if world.has_method("get_base_mode"):
		GameMode.set_base_mode(world.get_base_mode())

	if world.has_method("get_tactical_camera"):
		var cam: Camera3D = world.get_tactical_camera()
		if is_instance_valid(cam):
			CameraDirector.register_tactical_camera(cam)
			cam.make_current()

	if _is_restoring_party:
		var spawn_point: Node3D = _resolve_spawn_point(world, _pending_spawn_point_name)
		PartyManager.spawn_party(world, spawn_point)

	_is_restoring_party = false

	world_loaded.emit(world)
	return world


## Applies AreaState against a just-instantiated, not-yet-in-tree world —
## see load_world()'s own call site for why this timing matters. Duck-
## types on "persistent_id" rather than checking node classes by name, so
## a future class besides Unit/InteractableProp can opt in by declaring
## the same field with no change needed here (see AreaState's own header
## on the intrinsic-id design this reads).
func _reconcile_area_state(world: Node, area_id: StringName) -> void:
	for node in _collect_persistent_nodes(world):
		var entity_id: StringName = node.persistent_id

		if AreaState.is_removed(area_id, entity_id):
			node.get_parent().remove_child(node)
			node.queue_free()
			continue

		# The save_state()/load_state() contract may live on a CHILD
		# component rather than the persistent_id-bearing node itself —
		# a chest's contents are owned by its StashComponent, not by the
		# InteractableProp directly (same "capability by composition"
		# reasoning StashComponent.find_on()'s own header gives). Direct
		# children only, so this can't accidentally reach into an
		# unrelated persistent node nested underneath.
		var target: Node = node
		if not target.has_method("load_state"):
			for child in node.get_children():
				if child.has_method("load_state"):
					target = child
					break

		if target.has_method("load_state"):
			var state: Variant = AreaState.stored_state(area_id, entity_id)
			if state != null:
				target.load_state(state)


## Recursive: an entity's persistent_id can sit at any depth (a Unit
## nested under formation logic, a StashComponent's owner nested under
## whatever an area's own hierarchy looks like) — same reasoning
## AreaValidator's own _collect_exits() walk already applies.
func _collect_persistent_nodes(node: Node) -> Array[Node]:
	var found: Array[Node] = []
	if "persistent_id" in node and node.persistent_id != &"":
		found.append(node)
	for child in node.get_children():
		found.append_array(_collect_persistent_nodes(child))
	return found


## The data-driven counterpart to load_world() — resolves area_id through
## AreaDatabase and loads its world_scene, so callers never hold a direct
## PackedScene/AreaDefinition reference to a destination (see
## AreaDefinition.world_scene's own doc comment for why that indirection
## matters). This is now the ONLY way anything in the game transitions
## between areas; load_world() stays public purely as the low-level
## primitive this delegates to.
##
## spawn_point_name is normally left empty — see
## _resolve_entry_spawn_point() for why the destination almost always
## derives the right answer on its own. Which area is being LEFT is derived
## by load_world() itself from current_area(), whatever's still loaded at
## the moment of the call; callers never track or supply it.
func load_area(area_id: StringName, spawn_point_name: StringName = &"") -> Node:
	var area: AreaDefinition = AreaDatabase.find(area_id)
	if not area:
		push_warning("WorldManager.load_area: unknown area id '%s'" % area_id)
		return null

	return load_world(area.world_scene, spawn_point_name, area)


func current_area() -> AreaDefinition:
	return _current_area


func pending_spawn_point_name() -> StringName:
	return _pending_spawn_point_name


## Null when nothing is loaded (the main menu, e.g.). Pre-existing —
## SaveManager's own _capture_avatar_transform() is a new caller that
## needs the live world node directly rather than just its
## AreaDefinition, since a saved position has to be read off whatever
## get_avatar() the CURRENT world happens to expose.
func current_world() -> Node:
	return _current_world


## Where a spawned Node belongs — the loaded world if one exists, the
## (empty) scene root otherwise, so a menu-time effect can't hard-error.
## Every one-off spawn (a debug unit, a projectile, a sound cue, a
## particle burst, a surface patch, a VFX sequence) should parent through
## this instead of get_tree().current_scene — current_scene is MainRoot
## for the entire game (see this file's own header on why load_world()
## deliberately never touches it), so that old idiom was silently
## parenting every one of those outside the world they actually belong
## to: they'd survive a world swap, be invisible to load_world()'s own
## teardown (capture/clear/free), and never get freed or recaptured.
func spawn_parent() -> Node:
	return _current_world if _current_world else _scene_root


## Whether the world currently being loaded (mid-load_world() call) is
## about to have PartyManager.roster spawned into it — see this file's
## own _is_restoring_party header for why a world needs to be able to ask
## this from inside its own _ready(). False outside of an active
## load_world() call, for the very first load (nothing to restore yet),
## and for a world that opts out via spawns_party() -> false.
func is_restoring_party() -> bool:
	return _is_restoring_party


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


## Which named spawn point to actually request from `world`, in three
## tiers: an explicit request always wins; otherwise, if we know which
## area is being LEFT, search world's own AreaExit components for one
## whose OWN target_area points back at it — that exit's arrival_point
## (or its own parent, see AreaExit's own header) is, by construction,
## the correct way back, no history required; otherwise fall through to
## the world's own "default" fallback marker (get_spawn_point() on every
## world already degrades gracefully from there).
##
## This is what makes even a FIRST-EVER trip into an area land in the
## right place — a fresh character-creation entry into test_arena has
## never been anywhere, so there's nothing to derive FROM there, but the
## very next trip TO the overworld already has a real from_area_id
## (test_arena), and the overworld's own DoorA already declares
## target_area = "test_arena" as authored content — no round trip needed
## to "prime" anything.
func _resolve_entry_spawn_point(world: Node, requested_name: StringName, from_area_id: StringName) -> StringName:
	if requested_name != &"":
		return requested_name
	if from_area_id != &"":
		var back_link: StringName = _find_back_link(world, from_area_id)
		if back_link != &"":
			return back_link
	return &"default"


## The name of whichever landing spot inside `world` leads back to
## from_area_id, or &"" if none does (an intentionally one-way link, or a
## world with no exits of its own at all).
func _find_back_link(world: Node, from_area_id: StringName) -> StringName:
	for exit in _find_area_exits(world):
		if exit.target_area == from_area_id:
			var landing: Node = exit.arrival_point if exit.arrival_point else exit.get_parent()
			return landing.name
	return &""


## Every AreaExit anywhere under root, at any depth — a door's own direct
## child, or nested under a prop the way test_arena's OverworldExit is.
## A raw recursive walk rather than get_tree().get_nodes_in_group(): this
## runs on a freshly instantiate()'d subtree that ISN'T in the tree yet
## (see load_world()'s own comment on why it has to run before add_child),
## so nothing has reached _ready() to register a group membership yet —
## get_children() is the only thing available at this point.
func _find_area_exits(root: Node) -> Array[AreaExit]:
	var result: Array[AreaExit] = []
	for child in root.get_children():
		if child is AreaExit:
			result.append(child)
		result.append_array(_find_area_exits(child))
	return result
