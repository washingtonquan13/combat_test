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
## - get_base_mode() -> GameMode.Mode, READ BY GameMode whenever it is
##   asked what the base mode is. A backdrop world with no gameplay of its
##   own simply doesn't implement it, and the mode then falls through to
##   the front end exactly as if no world were loaded.
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

## Why a world is being entered. Passed to _enter_world() and carried on
## world_loaded, because it is the one thing about a load that cannot be
## worked out after the fact.
##
## TRAVEL and REBUILD differ on more than permission, and every one of
## those differences was found the same way — as a bug. The gate was the
## first (can_travel vs can_rebuild, which deadlocked loading outright).
## Who is coming was the second: inferred from whoever was embodied in
## the focused world, so restoring areas one at a time swept up the
## people the previous iteration had just put down, and a party split
## between an area and the overworld came back standing in one place.
## Where they land was the third.
##
## What those share is that _enter_world had no way to know which
## operation it was performing, so each decision reconstructed the answer
## out of whatever ambient state was nearest — _focused, current_area(),
## an empty array. Ambient state always holds SOMETHING, which is why a
## wrong reconstruction reads exactly like a right one at the point it is
## made, and why all three surfaced as play reports rather than as
## failures here.
##
## A PARAMETER, deliberately, and not a flag anybody sets: it cannot
## outlive its call, so there is no window to close, and it cannot be
## omitted, so the next axis on which these two operations differ has to
## be answered while the line is being written.
enum Entry {
	## The player went somewhere. There is a world being left, the people
	## leaving it are the ones who were standing in it, and they arrive at
	## a door.
	TRAVEL,
	## A save file is being rebuilt. Nobody is travelling, there is no
	## world being "come from", and the save — not a doorway — says where
	## everyone stands.
	REBUILD,
}

signal world_loading(scene: PackedScene)
## `reason` says which operation built this world (see Entry).
##
## Carried ON the signal rather than left readable on the manager for
## listeners to fetch afterwards. A property would have a lifetime, and a
## fact with a lifetime is a window somebody eventually forgets to close
## — GameMode's mode stack was one, this manager's own deleted
## _is_restoring_party was another, and both were removed for that
## reason. An argument has a scope instead.
signal world_loaded(world: Node, reason: Entry)
## The player's attention moved to a different resident world. Distinct
## from world_loaded, which fires only when a world is newly built —
## re-entering a world that stayed loaded emits this and not that.
signal world_focused(world: Node)

## One world's viewport, as a scene so its settings stay editable rather
## than buried in code. Three of them are load-bearing and none is the
## default, so they are recorded here — .tscn has no comment syntax to
## hold the reasoning itself:
##
## - own_world_3d: the whole point. World3D is per-viewport, and it is
##   what every world-scoped system in this project keys off.
## - physics_object_picking: unit click-select is CollisionObject3D
##   input_event (see unit.gd), which is per-viewport. Off means units
##   silently stop being clickable.
## - audio_listener_enable_3d: without a listener in the viewport that
##   owns the world, every 3D sound in it goes silent, with no error.
##
## mouse_filter is left at the container default of STOP. It consumes the
## mouse event in the ROOT viewport's GUI pass, so nothing outside the
## world view reaches _unhandled_input for the mouse any more. That is not
## a bug to route around — it is the consequence of the world having its
## own viewport, and the answer is that a mouse tool operating on the
## world belongs INSIDE the world view. PASS does not help: it still marks
## the event consumed by GUI, and IGNORE stops the container forwarding
## into the SubViewport at all, so there is no filter value that both
## forwards and falls through. See register_attention_nodes().
const WORLD_VIEW_SCENE: PackedScene = preload("res://systems/world_system/world_view.tscn")

var _scene_root: Node = null

## Every world currently loaded, by area id — see ResidentWorld. Worlds
## are no longer swapped one-for-one: a world the player leaves stays here
## for as long as it has earned to (ResidentWorld.is_earned), and is
## re-entered rather than rebuilt.
##
## Keyed by area id because that is what load_area() is asked for. A world
## loaded through the raw load_world() primitive with no area data has no
## id, so it is never resident and always replaced — the same worlds that
## have never had AreaState either.
var _residents: Dictionary = {}

## The one the player is looking at. Null with nothing loaded (the main
## menu). Every "the current world" accessor on this file answers about
## this one.
var _focused: ResidentWorld = null

## Where per-world viewports get instanced — see MainRoot.tscn's own
## WorldHost note. A world lives in its own SubViewport because World3D is
## PER-VIEWPORT: that is the only mechanism Godot offers for two live
## worlds at once, and everything world-scoped in this project (see
## WorldContext, UnitQuery, and the navigation grid's registry) keys off
## World3D precisely because of it.
var _world_host: Control = null

## Nodes that represent THE PLAYER LOOKING AT THINGS rather than anything
## a world owns: the indicators, the click router, the dialogue camera
## rig. A Node3D only renders in — and only raycasts against — the World3D
## of the viewport it sits under, so these have to live inside whichever
## viewport is being looked at, and they move as it changes.
##
## Moved rather than duplicated per world, on the same reasoning rung 2
## used to decide what does NOT belong on WorldContext: there is one
## player, so there is one set of these. See register_attention_nodes().
var _attention_nodes: Array[Node] = []
## Each attention node's ORIGINAL parent, remembered per node rather than
## once for the group: they do not all come from the same place. The 3D
## ones hang off MainRoot; the drag-select box is a Control on the HUD
## canvas. Sending them all back to one home on unload would quietly
## relocate half of them.
var _attention_homes: Dictionary = {}


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


## Called once by MainRoot's own script, alongside register_scene_root.
## Boots empty — views are instanced here per world as they load.
func register_world_host(host: Control) -> void:
	_world_host = host


## Called once by MainRoot's own script with the player-attention nodes to
## carry between viewports (see _attention_nodes). Their CURRENT parent is
## remembered as the home they return to whenever no world is loaded — the
## main menu, where there is no viewport to sit in and nothing to point at.
func register_attention_nodes(nodes: Array[Node]) -> void:
	_attention_nodes = nodes
	_attention_homes.clear()
	for node in nodes:
		if node and node.get_parent():
			_attention_homes[node] = node.get_parent()


## The viewport the player is currently looking into, or null when no
## world is loaded. The one place anything outside a world should ask —
## a Control on the HUD canvas can't use get_viewport() to reach the
## world's camera anymore, since its own viewport is the root one.
func focused_viewport() -> Viewport:
	return _focused.viewport() if _focused else null


## The camera rendering the focused world, or null. Null is ordinary, not
## exceptional — the main menu loads no world and has no camera.
func focused_camera() -> Camera3D:
	var viewport: Viewport = focused_viewport()
	return viewport.get_camera_3d() if viewport else null


## Moves the attention nodes into `parent`, or home when it is null.
## reparent() keeps them alive across the view being freed — without this
## they would be freed alongside whichever world they were pointing at.
func _move_attention_to(parent: Node) -> void:
	for node in _attention_nodes:
		if not is_instance_valid(node):
			continue
		var destination: Node = parent if parent else _attention_homes.get(node)
		if destination and node.get_parent() != destination:
			# keep_global_transform = false: these sit at the origin with
			# identity transforms, and carrying a transform across two
			# different worlds' spaces means nothing.
			node.reparent(destination, false)


## Whether a load is currently allowed — a world can't safely be swapped
## out from under a live fight, conversation, negotiation, or loot
## screen. GameMode.can_transition() answers exactly this (true only when
## nothing is overlaid on the current base mode); InteractionMenu is
## checked directly alongside it, same as CameraDirector.has_control()
## does, since it was deliberately never folded into GameMode (a brief
## context menu, not a real mode transition). Naturally always true
## during the menu/chargen hops (nothing has started either of those
## things yet).
##
## Named for WHO it is about, not for what it happens to gate. It used to
## be can_load(), which read as "may a world be built" — so the save
## restore path asked it, got told a fight was in progress, and refused to
## rebuild the very world that fight lives in. Rebuilding from disk is not
## travel; it asks can_rebuild() instead. Same split, and the same
## reasoning, as can_switch_focus() further down.
func can_travel(travellers: Array[Unit] = []) -> bool:
	if InteractionMenu.is_open():
		return false
	if GameMode.can_transition():
		return true

	# Something is overlaid on the base mode. Combat is the one overlay
	# that is a question about WHO rather than about the player: a fight
	# detains the people IN it, and once the party can split, someone
	# standing across the room is not one of them. Everything else —
	# dialogue, negotiation, looting, a cutscene — is a modal the PLAYER
	# is in, and nobody travels out of those.
	if GameMode.current_mode() != GameMode.Mode.COMBAT:
		return false
	return not _any_traveller_fighting(travellers)


## Whether the engine can build a world at all — a STRUCTURAL question,
## deliberately with no opinion about what the player is doing.
##
## The restore path asks this. Loading a save is not a journey: nobody is
## walking anywhere, every world is about to be discarded and rebuilt from
## disk, and the fight the travel gate would refuse over is itself part of
## what is being replaced. Asking can_travel() there produced a genuine
## deadlock — a restored fight claimed COMBAT, the next rebuild was
## refused because those units were "travelling out of a fight", and the
## claim only clears when focus moves, which the refusal prevented.
##
## Asks for the world host and NOT the scene root, because the host is what
## a world is actually built into (see _enter_world: the view goes to
## _world_host, the world into its viewport). _scene_root is only
## spawn_parent()'s fallback for when nothing is focused. Requiring it here
## refused every restore in the test harness, which registers a host and no
## scene root — correctly, since it never needed one.
func can_rebuild() -> bool:
	return _world_host != null


## Whether anyone actually going is tied up in a fight. An empty list
## means everyone embodied here, matching _resolve_travellers, so the
## no-argument form still answers the old question: can the party leave.
func _any_traveller_fighting(travellers: Array[Unit]) -> bool:
	for unit in _resolve_travellers(travellers):
		if is_instance_valid(unit) and unit.in_combat():
			return true
	return false


## Frees whatever world is currently loaded, WITHOUT capturing it into
## PartyManager.roster first — the one caller that needs this is
## SaveManager.load_file(): roster is about to be overwritten by the
## save file's own data one line later, so capturing the (about to be
## discarded) live world first would just be immediately undone. Every
## ordinary area transition still goes through load_world(), which calls
## the same teardown with capture_party=true — this does not change that
## path at all.
##
## No-op (returns true) when nothing is loaded — the main menu, e.g.
## Refused exactly like load_world() when the player may not currently
## leave (mid-combat/dialogue/loot).
##
## The restore path wants discard_worlds() below, not this. Both do the
## same teardown; they differ only in which question they ask first, and
## that difference used to be a `force` boolean whose honest meaning was
## "ignore a rule that should not have applied to me".
func unload() -> bool:
	if not can_travel():
		push_warning("WorldManager.unload refused (current_mode=%s)" % GameMode.Mode.keys()[GameMode.current_mode()])
		return false
	return _tear_down_worlds()


## Frees every world so a save can be rebuilt over the top of it. The
## restore counterpart to unload(), gated on can_rebuild() rather than on
## whether the player may travel — see can_rebuild() for why a fight in
## progress must not refuse this.
func discard_worlds() -> bool:
	if not can_rebuild():
		push_warning("WorldManager.discard_worlds refused: no scene root or world host registered.")
		return false
	return _tear_down_worlds()


## The teardown itself, shared by both entry points above. Permission is
## settled before this is reached and is never re-asked here.
func _tear_down_worlds() -> bool:
	world_loading.emit(null)
	# false: SaveManager is about to overwrite roster from the save file,
	# so refreshing it from the world being discarded is work undone one
	# line later.
	# Every group, not just the active one: SaveManager is about to
	# replace the whole game state, and a party scattered across three
	# areas is part of what it is replacing.
	for group in PartyManager.groups.duplicate():
		_disembody(group)
	_leave_focused()
	# "Nothing is loaded," not "nothing is focused" — so every resident
	# goes, earned or not. SaveManager is about to replace the whole game
	# state, and a fight still running in some other area is part of what
	# it is replacing.
	for resident in _residents.values():
		if is_instance_valid(resident):
			_capture_area_state(resident)
			resident.dispose()
	_residents.clear()
	NavigationGrid.invalidate()
	return true


## Steps the player OUT of the focused world without deciding whether that
## world survives. Splitting those two apart is the whole of this rung:
## leaving used to mean freeing, and now it means the world carries on
## without an audience.
##
## capture_party controls only whether PartyManager.capture() runs first —
## SaveManager.load_file() is about to overwrite the roster anyway (see
## unload()). Everything else happens either way.
func _leave_focused() -> void:
	if not _focused:
		return

	SelectionManager.deselect_all()
	InteractionMenu.close()
	UIStack.close_all()

	var world: Node = _focused.world
	if world and world.has_method("get_tactical_camera"):
		var old_cam: Camera3D = world.get_tactical_camera()
		if is_instance_valid(old_cam):
			CameraDirector.unregister_tactical_camera(old_cam)

	# The attention nodes are children of this world's viewport and belong
	# to the player, not to the world, so they have to be out before it can
	# be freed under them.
	_move_attention_to(null)
	_focused.set_focused(false)
	_focused = null


## Folds one group down to records and frees its Units. The party stops
## having positions for these people.
##
## Only for a world with no place for Units - the overworld and its
## avatar (spawns_party() -> false). Per GROUP, not per party: an
## earlier version collected EVERYONE here, which quietly made the
## split unreachable, because every route in this game passes through
## the overworld and so every route reunited the party.
func _disembody(group: PartyGroup) -> void:
	# Refreshes records against whatever is actually live, for this
	# group and every other embodied one - see PartyManager.capture().
	PartyManager.capture()
	_dismiss_fielded_demons(group)

	var leaving: Array[Unit] = group.live_units()
	group.units.clear()
	group.embodied = false
	for unit in leaving:
		if not is_instance_valid(unit):
			continue
		if unit == PartyManager.leader:
			PartyManager.leader = null
		if unit.died.is_connected(PartyManager._on_member_died):
			unit.died.disconnect(PartyManager._on_member_died)
		# Out of the group first: a half-freed unit still answering group
		# queries is a shape of bug the suite has caught repeatedly.
		if unit.is_in_group("units"):
			unit.remove_from_group("units")
		if unit.get_parent():
			unit.get_parent().remove_child(unit)
		unit.queue_free()


## Who is actually travelling, as a GROUP. An empty request means
## everyone standing in the world being left, which is what walking out
## of a door with nobody selected should obviously do.
##
## Splitting happens here and needs no separate verb: travel with fewer
## than a whole group and the rest keep their group and their place.
func _travelling_group(requested: Array[Unit]) -> PartyGroup:
	var going: Array[Unit] = _resolve_travellers(requested)
	if going.is_empty():
		# Nobody embodied here - the party is abstract (the overworld), so
		# the group the player is commanding is the one that travels.
		return PartyManager.active()
	return PartyManager.split_off(going)


## Who is actually travelling. An empty request means everyone embodied
## in the world being left.
func _resolve_travellers(requested: Array[Unit]) -> Array[Unit]:
	var going: Array[Unit] = []
	var here: WorldContext = _focused.context if _focused else null

	if not requested.is_empty():
		for unit in requested:
			if is_instance_valid(unit) and PartyManager.is_member(unit):
				going.append(unit)
		return going

	for unit in PartyManager.members:
		if not is_instance_valid(unit):
			continue
		if here == null or here.contains(unit):
			going.append(unit)
	return going


## Puts the travelling group into the world now being focused.
##
## Which of the two forms applies is a property of the DESTINATION, not
## of how the player got here: a world that spawns Units embodies the
## group, one that does not folds it down to an avatar.
func _embody_into(resident: ResidentWorld, group: PartyGroup) -> void:
	if group == null:
		return
	var world: Node = resident.world
	# Remembered for when this group is folded down to records and has no
	# members left to derive it from.
	group.abstract_area_id = resident.area_id()
	PartyManager.active_group = group

	if world.has_method("spawns_party") and not world.spawns_party():
		_disembody(group)
		return

	# Merge BEFORE embodying, not after. Arriving in an ordinary area is
	# merging — everyone is embodied together and there is nothing left to
	# tell two groups apart — and what has to be made real is the whole of
	# the result. Merging afterwards left anyone absorbed from an abstract
	# group as records inside an embodied one, which nothing would ever
	# build.
	# The DESTINATION, named outright. Not the group's derived current area:
	# at this moment its members are still standing in the world they are
	# leaving, so deriving would merge them with whoever is back there.
	var arrived: PartyGroup = PartyManager.merge_in_area(resident.area_id())
	if arrived == null:
		arrived = group
	PartyManager.active_group = arrived

	var spawn_point: Node3D = _resolve_spawn_point(world, _pending_spawn_point_name)

	PartyManager.embody(arrived, world, spawn_point)

## Frees a world that has nothing left worth preserving — see
## ResidentWorld.is_earned for what counts. Safe to call with null, and
## with a world that is staying.
func _retire_if_unearned(resident: ResidentWorld) -> void:
	if resident == null or not is_instance_valid(resident) or resident.is_earned():
		return

	# Recorded before it is freed — this is the only moment its contents
	# still exist to be asked.
	_capture_area_state(resident)

	if _residents.get(resident.area_id()) == resident:
		_residents.erase(resident.area_id())
	resident.dispose()

	# Belt and braces. WorldContext.dispose() inside ResidentWorld is what
	# actually retires this world's navigation grid (it calls
	# NavigationGrid.unregister_world, dropping the raw CollisionShape3D*
	# into geometry about to be freed — the dangling pointers behind a real
	# native crash this project shipped, a bare signal 11 with no GDScript
	# error before it). This covers the one path that misses: a world that
	# never got a context because it wasn't a Node3D.
	NavigationGrid.invalidate()


## Sweeps every world that is not being looked at and frees the ones with
## nothing left to preserve.
##
## A sweep rather than only checking the world just left, because a world
## can stop being earned for reasons that have nothing to do with the
## player's route: collecting the party out of a distant area (see
## _disembody_all) removes the only thing keeping it, and so does its last
## fight ending. Cheap — there are never many residents, and the check is
## a couple of array walks.
func _retire_unearned() -> void:
	for resident in _residents.values().duplicate():
		if resident == _focused:
			continue
		_retire_if_unearned(resident)


## Points the player at a world that is already loaded and in the tree.
## The counterpart to _leave_focused, and the only place _focused is set.
func _focus(resident: ResidentWorld, group: PartyGroup = null) -> void:
	_focused = resident
	resident.set_focused(true)
	_move_attention_to(resident.viewport())

	var world: Node = resident.world
	# Nothing sets the mode here any more. GameMode asks current_world()
	# for its get_base_mode(), so focusing a world IS the mode changing —
	# and the old set_base_mode() call is what used to wipe a live COMBAT
	# overlay on its way past (see game_mode.gd's header).

	if world.has_method("get_tactical_camera"):
		var cam: Camera3D = world.get_tactical_camera()
		if is_instance_valid(cam):
			CameraDirector.register_tactical_camera(cam)
			# Per-viewport, so each world's camera can be current in its
			# own viewport at the same time — they do not fight.
			cam.make_current()

	_embody_into(resident, group)
	world_focused.emit(world)


## The resident world for an area, or null. Null for a null area on
## purpose: a world loaded through the raw load_world() primitive has no
## id to be found by, so it is never re-entered, only replaced.
func _resident_for(area: AreaDefinition) -> ResidentWorld:
	if area == null:
		return null
	var resident: ResidentWorld = _residents.get(area.id)
	# The WORLD too, not just the record. A resident whose world node has
	# been freed out from under it is not resident — and handing that freed
	# node on is an error at the CALL, since every consumer takes a typed
	# Node.
	if not is_instance_valid(resident) or not is_instance_valid(resident.world):
		return null
	return resident


## Puts `scene`'s world on screen, building it only if it isn't already
## loaded. The world the player is leaving is stepped out of first, then
## freed ONLY if it has nothing left to preserve — see
## ResidentWorld.is_earned. Returns the world now focused, or null if the
## load was refused.
##
## Re-entering a resident area emits world_focused and NOT world_loaded:
## nothing was loaded. A listener that must react to both (MusicManager)
## wants both signals; one that is really about construction (a world's
## own bootstrap) wants only world_loaded.
##
## spawn_point_name empty means "let the destination derive it" (see
## _resolve_entry_spawn_point()); area is the AreaDefinition behind scene,
## or null for a world with no area data at all — which is also what makes
## a world un-resident, since there is no id to find it by again.
func load_world(scene: PackedScene, spawn_point_name: StringName = &"", area: AreaDefinition = null, travellers: Array[Unit] = []) -> Node:
	# Who is going, resolved BEFORE the gate: a fight detains the people in
	# it, so whether this load is allowed depends on who is leaving. Also
	# before _leave_focused, while _focused still says which world these
	# people are standing in.
	var going: Array[Unit] = _resolve_travellers(travellers)

	if not can_travel(going):
		push_warning("WorldManager.load_world refused (current_mode=%s)" % GameMode.Mode.keys()[GameMode.current_mode()])
		return null

	# AFTER the gate, because splitting a group is a real change and a
	# refused load must not have made one.
	return _enter_world(scene, spawn_point_name, area, _travelling_group(travellers), Entry.TRAVEL)


## Rebuilds one area from a save file and puts the player in front of it.
##
## The restore counterpart to load_area(). Shares _enter_world() and
## differs from travelling on exactly three things, each of which was
## found as a bug before it was found as a difference:
##
## 1. THE GATE. can_rebuild() rather than can_travel(). Nobody is
##    travelling during a restore, so the travel gate has nothing true to
##    say about it, and what it did say deadlocked the load outright (see
##    can_rebuild()).
## 2. WHO COMES. The group is NAMED by the caller, never inferred — see
##    below.
## 3. WHERE THEY LAND. Nothing is derived; the save places people. Passing
##    Entry.REBUILD is what stops _enter_world deriving a doorway from
##    whichever area the restore loop happened to reach last.
##
## The list is expected to grow, which is the point of naming the reason
## rather than adding a fourth parameter each time: a new decision inside
## _enter_world has the reason in scope and has to answer for it.
##
## On (2), and it is not a convenience:
## _resolve_travellers() defines an empty list as "everyone embodied in the
## world being left", which is right for walking out of a door and
## catastrophic here. Restoring areas one at a time means an earlier
## iteration has already embodied somebody in the previously focused world
## — so rebuilding the NEXT area with "no travellers" swept them up and
## carried them along. A party split between an ordinary area and the
## overworld came back with the ordinary-world group standing on the
## overworld, because the overworld is restored last.
##
## `null` is a real answer and means nobody: an area no group claims is
## rebuilt empty rather than inheriting whoever happens to be standing
## around. That sentence could not be said at all before this.
##
## No spawn point either: a rebuilt world places its occupants from the
## save file, not from a doorway they walked through.
func rebuild_area(area_id: StringName, group: PartyGroup = null) -> Node:
	var area: AreaDefinition = AreaDatabase.find(area_id)
	if not area:
		push_warning("WorldManager.rebuild_area: unknown area id '%s'" % area_id)
		return null

	if not can_rebuild():
		push_warning("WorldManager.rebuild_area refused: no scene root or world host registered.")
		return null

	return _enter_world(area.world_scene, &"", area, group, Entry.REBUILD)


## Everything entering a world does once permission is settled. Shared by
## load_world() and rebuild_area(); neither gate is re-asked in here, so
## this must not be called without passing one of them first.
##
## `reason` is how it knows which of the two it is performing. Before it
## existed, every decision in here that differs between them reconstructed
## the answer from ambient state — and got it wrong three times, each one
## reaching you as a play report rather than as a failing test. Anything
## added below that would differ between a journey and a restore must
## consult it rather than reading _focused or current_area().
func _enter_world(scene: PackedScene, spawn_point_name: StringName, area: AreaDefinition, group: PartyGroup, reason: Entry) -> Node:
	# Read before _leave_focused, while _focused still says which world
	# these people are standing in.
	var outgoing: ResidentWorld = _focused

	world_loading.emit(scene)

	# "The area being left," read once, up front — before leaving clears
	# it. Only TRAVEL has one. A rebuild is not coming FROM anywhere, and
	# current_area() during a restore is whichever area the loop happened
	# to build last — an arbitrary answer that _resolve_entry_spawn_point
	# would then dutifully find a door back to. The question is not asked
	# rather than asked and discarded, so there is no branch further down
	# that has to remember to ignore it.
	var from_area_id: StringName = &""
	if reason == Entry.TRAVEL and current_area():
		from_area_id = current_area().id

	_leave_focused()

	var existing: ResidentWorld = _resident_for(area)

	# Already loaded: step back into it rather than rebuilding. This is the
	# whole point of residency — the world kept running while the player
	# was elsewhere, and rebuilding it would throw away exactly what was
	# being preserved.
	if existing:
		_pending_spawn_point_name = _resolve_entry_spawn_point(
			existing.world, spawn_point_name, from_area_id)
		_focus(existing, group)
		# AFTER the handover, not before: the travellers were still
		# standing in the outgoing world a moment ago, and a world with
		# party members in it has earned its keep (ResidentWorld.is_earned).
		# Retiring first would have counted them as reasons to stay.
		if existing != outgoing:
			_retire_if_unearned(outgoing)
		_retire_unearned()
		return existing.world

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
	# is legitimately callable with no area data — AreaState has nothing
	# to reconcile against in that case. Runs on construction only: a
	# resident world re-entered above is already reconciled, and running
	# it again would re-apply a saved state over live changes.
	if area:
		_reconcile_area_state(world, area.id)

	var resident := ResidentWorld.new()
	resident.name = "Resident_%s" % (area.id if area else &"anonymous")
	resident.area = area
	resident.world = world
	add_child(resident)

	# Into its own viewport, not straight into SceneRoot. Everything
	# world-scoped keys off World3D, and a viewport is what mints one.
	resident.view = WORLD_VIEW_SCENE.instantiate()
	_world_host.add_child(resident.view)
	resident.view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resident.viewport().add_child(world)

	# Built immediately after the world enters the tree, since World3D —
	# the context's identity — only exists once it has a viewport.
	resident.context = WorldContext.new(world if world is Node3D else null)
	resident.context.name = "WorldContext"
	resident.add_child(resident.context)

	if area:
		_residents[area.id] = resident

	_focus(resident, group)
	_retire_if_unearned(outgoing)
	_retire_unearned()
	world_loaded.emit(world, reason)
	return world


## The write half of _reconcile_area_state, and the half that was
## missing: before a world is freed, everything persistent in it records
## what it currently is. Without this, AreaState knew only who had died,
## so every other difference — wounds, positions, statuses — was lost the
## moment a world stopped being resident.
##
## Uses the same walk as reconciliation, and the same duck-typed
## save_state()-on-the-node-or-a-child convention, so a component that
## already answers load_state() is captured too.
func _capture_area_state(resident: ResidentWorld) -> void:
	if resident == null or resident.area == null or not is_instance_valid(resident.world):
		return

	for node in _collect_persistent_nodes(resident.world):
		var target: Node = node
		if not target.has_method("save_state"):
			for child in node.get_children():
				if child.has_method("save_state"):
					target = child
					break
		if target.has_method("save_state"):
			AreaState.store_state(resident.area.id, node.persistent_id, target.save_state())


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
func load_area(area_id: StringName, spawn_point_name: StringName = &"", travellers: Array[Unit] = []) -> Node:
	var area: AreaDefinition = AreaDatabase.find(area_id)
	if not area:
		push_warning("WorldManager.load_area: unknown area id '%s'" % area_id)
		return null

	return load_world(area.world_scene, spawn_point_name, area, travellers)


## The area behind the FOCUSED world, or null with nothing loaded. Read
## by MusicManager to resolve per-area tracks; it and current_world()
## always describe the same world, because both now read the same record.
func current_area() -> AreaDefinition:
	return _focused.area if _focused else null


func pending_spawn_point_name() -> StringName:
	return _pending_spawn_point_name


## Null when nothing is loaded (the main menu, e.g.). For anything that
## needs the live world node itself rather than just its AreaDefinition.
func current_world() -> Node:
	return _focused.world if _focused else null


## The loaded world's own state — its fights, its surfaces, its navigation
## grid. Null when nothing is loaded (the main menu). See WorldContext.
func context() -> WorldContext:
	return _focused.context if _focused else null


## The context owning `node`, or the focused one when nothing claims it.
## Was a stub returning the single context either way; now it really does
## search, and is what anything holding a node should ask instead of
## context() — a unit in an unfocused world has a context, and it is not
## the player's.
func context_for(node: Node) -> WorldContext:
	for resident in _residents.values():
		if is_instance_valid(resident) and resident.context and resident.context.contains(node):
			return resident.context
	return context()


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
	return _focused.world if _focused else _scene_root


## Why a reveal() call did or did not go anywhere. A bool cannot say
## which precondition failed, and four indistinguishable false-returns
## swallowed by a caller is why "a member became unclickable" has looked
## like a brand new bug each of the three times it happened.
enum Reveal {
	ALREADY_THERE,   ## Their world is the one on screen; nothing moved.
	MOVED,           ## Focus switched to their world.
	REFUSED_MODAL,   ## A conversation, negotiation or menu is open.
	AREA_NOT_LOADED, ## Nobody is holding their area in memory.
	NOT_FOUND,       ## Neither a live unit nor a group that knows where.
}


## Take the player to this member. The ONE way to reach somebody.
##
## A live unit resolves through its OWN world — the lookup that cannot
## go stale, because it asks the scene tree rather than a record kept in
## step by hand. Only a member with no unit falls back to the group's
## remembered area, which is the one case where nothing else can answer.
##
## Never returns silently: every refusal names itself, and callers are
## expected to say so rather than swallow it.
func reveal(unit: Unit, group: PartyGroup = null) -> Reveal:
	if is_instance_valid(unit) and unit.is_inside_tree():
		for resident in _residents.values():
			if not is_instance_valid(resident) or resident.context == null:
				continue
			if not resident.context.contains(unit):
				continue
			return _reveal_resident(resident, group)
		# A live unit whose world nobody is holding. Its group may still
		# know an area, so fall through rather than giving up here.

	if group != null:
		var area: StringName = group.current_area_id()
		if area == &"":
			push_warning("WorldManager.reveal: that group does not know where it is.")
			return Reveal.NOT_FOUND
		var by_area: ResidentWorld = _residents.get(area)
		if not is_instance_valid(by_area) or not is_instance_valid(by_area.world):
			push_warning("WorldManager.reveal: area '%s' is not loaded." % area)
			return Reveal.AREA_NOT_LOADED
		return _reveal_resident(by_area, group)

	push_warning("WorldManager.reveal: nothing to go to — no live unit and no group.")
	return Reveal.NOT_FOUND


func _reveal_resident(resident: ResidentWorld, group: PartyGroup) -> Reveal:
	if resident == _focused:
		if group != null:
			PartyManager.active_group = group
		# Already looking at it, but which group is being commanded may
		# have changed, and that is what draws the overworld.
		world_focused.emit(resident.world)
		return Reveal.ALREADY_THERE

	# Checked BEFORE anything is applied: a refusal must leave the world
	# exactly as it found it, not half-commit a new active group.
	if not can_switch_focus():
		push_warning("WorldManager.reveal refused: %s is open." % GameMode.Mode.keys()[GameMode.current_mode()])
		return Reveal.REFUSED_MODAL

	if group != null:
		PartyManager.active_group = group
	_leave_focused()
	_focus(resident)
	return Reveal.MOVED


## Whether a reveal actually put the player in front of them.
static func revealed(result: Reveal) -> bool:
	return result == Reveal.ALREADY_THERE or result == Reveal.MOVED


## Whether the player may look at a different world right now.
##
## NOT can_travel(). That gate asks whether people may LEAVE, and a fight
## detains the people in it — correct for travel, wrong here, because
## switching focus moves nobody. The third question in the same family is
## can_rebuild(), for a restore that moves nobody either.
##
## Combat is the one overlay a player can look away FROM: the fight simply
## waits, and says so (see CombatManager's Attention section). Dialogue,
## negotiation and looting are modals the player is INSIDE.
func can_switch_focus() -> bool:
	if InteractionMenu.is_open():
		return false
	if GameMode.can_transition():
		return true
	return GameMode.current_mode() == GameMode.Mode.COMBAT


## The area whose world contains this node, or null. The counterpart to
## context_for() for anything that needs to NAME where something is.
func area_of(node: Node) -> AreaDefinition:
	for resident in _residents.values():
		if is_instance_valid(resident) and resident.context and resident.context.contains(node):
			return resident.area
	return null


## Thin wrappers over reveal(), kept because they read well at call sites.
## The switching itself lives in ONE place now — three implementations of
## "go and look at that" is how they drifted apart in the first place.
##
## Prefers a live member as the anchor so the group takes the robust path:
## a unit knows its own world, a remembered area id only claims to.
func focus_group(group: PartyGroup) -> bool:
	if group == null:
		return false
	var anchor: Unit = null
	for unit in group.live_units():
		anchor = unit
		break
	return revealed(reveal(anchor, group))


## Takes any Node, for callers holding something that is not a Unit.
func focus_world_of(node: Node) -> bool:
	for resident in _residents.values():
		if not is_instance_valid(resident) or resident.context == null:
			continue
		if resident.context.contains(node):
			return revealed(_reveal_resident(resident, null))
	return false

## Every loaded world's context, focused or not — for the few systems
## that must reason about ALL worlds rather than the one on screen. A
## fight running where the player isn't looking is still a fight.
## Every running fight, by the area it is happening in.
##
## By AREA rather than by resident world, because that is what survives:
## a save records where a fight is, and it is rebuilt when that area is
## next loaded — which means a battle the player was not watching does
## not need its world kept alive to come back.
func encounters_by_area() -> Dictionary:
	var out: Dictionary = {}
	for id in _residents:
		var resident: ResidentWorld = _residents[id]
		if not is_instance_valid(resident) or resident.context == null:
			continue
		var states: Array = []
		for encounter in resident.context.encounters:
			if is_instance_valid(encounter) and encounter.is_running:
				states.append(encounter.save_state())
		if not states.is_empty():
			out[String(id)] = states
	return out


func all_contexts() -> Array[WorldContext]:
	var out: Array[WorldContext] = []
	for resident in _residents.values():
		if is_instance_valid(resident) and resident.context:
			out.append(resident.context)
	return out


## Every area currently loaded, focused or not. Debug and diagnostics —
## nothing in the game should be enumerating worlds to find something; ask
## context_for() with the node in hand instead.
func resident_area_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for id in _residents.keys():
		ids.append(id)
	return ids


## Keeps an area loaded even with nothing running in it (see
## ResidentWorld.is_earned). The debug focus cycle uses this so a world can
## be switched back to; the party will use it once it can be left behind.
func set_area_pinned(area_id: StringName, pinned: bool) -> void:
	var resident: ResidentWorld = _residents.get(area_id)
	if is_instance_valid(resident):
		resident.pinned = pinned


func is_area_pinned(area_id: StringName) -> bool:
	var resident: ResidentWorld = _residents.get(area_id)
	return is_instance_valid(resident) and resident.pinned


## Whether an area is currently loaded — the question load_area() asks
## itself before deciding to build anything.
func is_area_resident(area_id: StringName) -> bool:
	var resident: ResidentWorld = _residents.get(area_id)
	return is_instance_valid(resident) and is_instance_valid(resident.world)



## Withdraws every currently-fielded demon through the same path a
## voluntary Dismiss uses (see DismissEffect) — syncing current_hp/
## current_fp back onto its OwnedDemon roster entry first, so a demon
## standing in the world at the moment it unloads doesn't leave
## DemonRoster thinking it's still out. A summoned demon is never a
## PartyManager member (add_member() refuses anything with summoned_by
## set), so capture()/clear_members() above never see it at all — this is
## the separate cleanup that actually has to happen for it.
## Only this group's demons. Before groups there was one party and so
## one answer; now dismissing every fielded demon in the game because
## one group stepped onto the overworld would reach into worlds the
## player is not even in.
func _dismiss_fielded_demons(group: PartyGroup = null) -> void:
	for unit in UnitQuery.all_units(get_tree()):
		if group and not group.has_unit(unit.summoned_by if unit.summoned_by else unit):
			continue
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
