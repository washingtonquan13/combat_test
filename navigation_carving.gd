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
