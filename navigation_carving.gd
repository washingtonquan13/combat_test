class_name NavigationCarving
extends RefCounted
## Keeps the baked navmesh's carved-obstacle holes in sync with which
## units are actually free to move right now, in a turn-based game where
## movement only ever happens for a small, known set of units at a time
## (the current combat actor; a batch of selected units on a free-roam
## right-click) — never continuously, never every frame. Godot's own docs
## call static obstacle carving "ill-suited for usages where the position
## is changed every frame" but that's exactly NOT what this is: a full
## navmesh bake once per turn (or once per free-roam move order) is the
## cadence static carving is actually meant for.
##
## Every unit carries its own NavigationObstacle3D (Unit.nav_obstacle, a
## real saved child node — see unit.tscn — configured by UnitMovement,
## not created in code) that stays enabled at all times EXCEPT for
## whichever units are in `movers` — a unit can't have its own standing
## position carved into a hole, or NavigationServer3D.map_get_path has no
## valid walkable point to even start from.
##
## Does NOT call NavigationRegion3D.bake_navigation_mesh() — that method
## hardcodes ITSELF as the root node for the whole geometry/obstacle
## discovery walk (confirmed by reading Godot 4.4's own source:
## NavigationRegion3D::bake_navigation_mesh() calls
## parse_source_geometry_data(navigation_mesh, data, **this**), and with
## this project's SOURCE_GEOMETRY_ROOT_NODE_CHILDREN mode that walk only
## recurses into the region's own children). Every unit — and therefore
## every unit's NavigationObstacle3D — is a SIBLING of the region in this
## scene, not a descendant, so that walk never reaches them; carving
## silently discovered nothing, no matter how correctly the obstacles
## themselves were configured. Fixed by doing the same two-step bake
## manually (NavigationServer3D.parse_source_geometry_data +
## bake_from_source_geometry_data, same as bake_navigation_mesh() does
## internally) with the region's PARENT as the discovery root instead —
## that covers both the region's own walkable geometry AND every unit's
## obstacle, wherever it sits in the tree.

## Coalescing entry point for triggers that don't need the bake to be
## done before code LATER IN THE SAME CALL STACK runs (a death; an
## ability finishing) — as opposed to turn-start/free-roam move orders,
## which plan a path immediately afterward and must keep calling
## rebake_for_movers directly. Without this, an AoE that kills several
## units in one synchronous loop triggered one full bake PER DEATH, back
## to back — the actual source of the reported mass-death stutter.
## Multiple requests in the same frame merge into a single deferred bake
## covering every requested mover at once.
static var _pending_movers: Dictionary = {}  # Unit -> true, dedup set
static var _pending_tree: SceneTree
static var _flush_queued: bool = false

static func request_rebake(tree: SceneTree, movers: Array) -> void:
	for m in movers:
		if is_instance_valid(m):
			_pending_movers[m] = true
	_pending_tree = tree
	if _flush_queued:
		return
	_flush_queued = true
	# Waits for the NEXT frame's process_frame signal, not call_deferred
	# (same-frame idle time) — a dying unit's own node is usually
	# queue_free()'d in the same synchronous burst that requests this
	# rebake, and queue_free() is ALSO a deferred operation. Both being
	# on the same same-frame deferred-call queue was never something to
	# rely on the ordering of; waiting a full frame guarantees every
	# queue_free() from the events that triggered this request has
	# already been fully processed (node and its NavigationObstacle3D
	# child actually gone) before the scene tree gets walked for baking.
	tree.process_frame.connect(_flush_pending_rebake, CONNECT_ONE_SHOT)


static func _flush_pending_rebake() -> void:
	_flush_queued = false
	var movers: Array = _pending_movers.keys().filter(is_instance_valid)
	_pending_movers.clear()
	var tree: SceneTree = _pending_tree
	_pending_tree = null
	if tree:
		rebake_for_movers(tree, movers)


static func rebake_for_movers(tree: SceneTree, movers: Array) -> void:
	var region: NavigationRegion3D = tree.get_first_node_in_group("nav_region") as NavigationRegion3D
	if not region:
		return

	var mover_clearance: float = 0.0
	for m in movers:
		if m is Unit:
			mover_clearance = max(mover_clearance, m.radius + m.avoidance_margin)

	for node in tree.get_nodes_in_group("units"):
		var unit := node as Unit
		if not unit:
			continue
		var is_mover: bool = unit in movers
		unit.set_carving_enabled(not is_mover)
		if not is_mover:
			unit.set_carving_radius(mover_clearance)

	var source_geometry_data := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(region.navigation_mesh, source_geometry_data, region.get_parent())
	NavigationServer3D.bake_from_source_geometry_data(region.navigation_mesh, source_geometry_data)

	# bake_from_source_geometry_data mutates the NavigationMesh resource
	# in place — it does NOT push the result to the live navigation map
	# on its own. NavigationRegion3D.bake_navigation_mesh() achieves that
	# by re-assigning navigation_mesh at the end (see its _bake_finished);
	# re-running that same setter here is what actually makes
	# NavigationServer3D.map_get_path() see the new, carved result.
	region.set_navigation_mesh(region.navigation_mesh)
