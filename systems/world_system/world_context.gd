class_name WorldContext
extends Node
## Everything whose lifetime is one loaded world's lifetime, in one place
## that dies with it.
##
## Before this, three world-scoped things were cleaned up by three
## unrelated mechanisms and nothing said they were the same kind of thing:
## the navigation grid was invalidated by hand in WorldManager, surfaces
## were cleared by a combat-ended signal, and encounters survived only
## because GameMode.can_transition() happens to block area changes while
## one is running. The middle one was an outright leak —
## SurfaceManager.active_surfaces was never touched on teardown, so an
## ActiveSurface cast outside combat kept pointing at a visual_node and
## Area3D that the freed world took with it.
##
## SCOPED BY World3D, not by an id of its own. Node3D.get_world_3d()
## already answers "which world is this in," a SubViewport with
## own_world_3d gets a distinct one, and a key derived that way cannot
## drift out of sync with reality the way a hand-maintained id could. See
## UnitQuery's own header for the same reasoning applied to unit scans.
##
## WHAT DOESN'T BELONG HERE, and why. SelectionManager.selected_units,
## UIStack, GameMode's mode stack, CombatManager.focused_encounter and
## DialogueManager's live conversation are all PLAYER-scoped, not
## world-scoped — there is one player, so there is one of each no matter
## how many worlds exist. Putting them here would be a category error that
## only shows up later, as duplicated UI state fighting over one screen.
## DetectionManager holds no world state at all (awareness lives on the
## units themselves) and needs nothing.

## Fights running in this world. Moved off CombatManager, which now reads
## them through here.
var encounters: Array[Encounter] = []

## Grease, and anything else Surface-backed. Moved off SurfaceManager for
## the leak described above.
var surfaces: Array[ActiveSurface] = []

## This context's identity. Captured from the world root once it's in the
## tree; every world-scoped query compares against it.
var world_3d: World3D = null


## The node this world's geometry is scanned from — held because a World3D
## cannot be walked back to a node, so the navigation grid has to be TOLD
## where its world starts.
var world_root: Node3D = null


func _init(root: Node3D = null) -> void:
	if root and root.is_inside_tree():
		world_root = root
		world_3d = root.get_world_3d()
		# Announces this world to the navigation extension, which keeps one
		# grid per registered world. Until something registers, the grid
		# behaves exactly as its single-world self did (scanning the current
		# scene) — which is what keeps the editor and any pre-registration
		# call path working.
		NavigationGrid.register_world(root)


## The navigation grid serving this world.
##
## Still the engine singleton, but it is no longer one grid: it now keeps
## one per REGISTERED WORLD (see register_world above, and
## NavigationGrid::activate_world in the extension), swapping the right
## world's state in based on whichever node a call was handed. So this
## accessor is the object to talk to, and which world it answers about is
## decided by the arguments rather than by this handle.
func navigation_grid() -> Object:
	return NavigationGrid


## True if `node` lives in this context's world. The one predicate anything
## world-scoped should ask, rather than comparing World3D by hand.
func contains(node: Node) -> bool:
	if world_3d == null or node == null or not node.is_inside_tree():
		return false
	if not node is Node3D:
		return false
	return (node as Node3D).get_world_3d() == world_3d


## Called by WorldManager as the world comes down, before the world node
## itself is freed. Order matters: encounters end first so anything
## listening for combat_ended still sees a coherent world, then surfaces go
## without waiting on a combat signal that may never arrive.
func dispose() -> void:
	for encounter in encounters.duplicate():
		if is_instance_valid(encounter) and encounter.is_running:
			encounter.finish(&"")
	encounters.clear()

	# Hands this world's grid back before the geometry it points into is
	# freed. all_shapes/shapes_by_chunk hold raw CollisionShape3D pointers
	# into the world, and a grid outliving them is the exact native
	# segfault the extension's invalidate() was written to paper over.
	if world_root:
		NavigationGrid.unregister_world(world_root)
	world_root = null

	# Cleared, not expired. _expire() reaches for WorldManager.spawn_parent()
	# to detach visuals, and by this point that is either the outgoing world
	# (about to be freed anyway) or already gone. The nodes themselves are
	# children of the world and die with it; what has to end here is this
	# array's references to them.
	surfaces.clear()
