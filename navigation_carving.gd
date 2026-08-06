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

## navigation_layers bitmask values passed to NavigationServer3D.
## map_get_path() by UnitMovement.move_to()/movement_indicator.gd to
## pick which region's polygons a query considers. GROUND_LAYER matches
## the ground NavigationRegion3D's default (unset navigation_layers is
## 1) — left implicit there rather than set explicitly in main.tscn, so
## this constant exists mainly to give that default a name at the call
## sites instead of a bare "1" whose meaning isn't obvious out of context.
const GROUND_LAYER := 1
const AIR_LAYER := 2

## Single flat global flight ceiling for the prototype — see
## ensure_air_region_baked(). A deliberate simplification (see this
## project's flight-design discussion): real per-location ceiling
## geometry or altitude bands are a later upgrade if a map ever actually
## needs them, not built preemptively.
const FLIGHT_CEILING_HEIGHT := 12.0
## Generous flat bound covering any reasonable battle map — this is a
## single rectangle, not per-level geometry, so oversizing it costs
## nothing.
const FLIGHT_AREA_HALF_EXTENT := 100.0

static var _air_region: NavigationRegion3D


## Creates and bakes the air navigation layer once — idempotent (a
## second call is a no-op), so every call site (rebake_for_movers()
## every turn, GrantFlightEffect at cast time, move_to() as a last-
## resort fallback) can just call this unconditionally rather than
## coordinating who's responsible for doing it once. In practice
## rebake_for_movers() is what actually creates it, on combat's very
## first turn, whether or not anyone ends up flying — see that
## function's comment for why creating it that early matters. Deliberately NOT a
## real NavigationServer3D.parse_source_geometry_data()/
## bake_from_source_geometry_data() bake like rebake_for_movers() below:
## there's no obstacle geometry to scan for yet (no ceiling obstacles,
## no per-unit carving — see this file's header for why flying units
## don't carve each other into this layer at all), so the navmesh is
## just one big hand-authored flat rectangle instead. Its baked Y is
## irrelevant to actual flight altitude — UnitMovement.move_to()
## overrides the Y of whatever path this returns to the unit's own
## chosen height; only the XZ shape (a single open rectangle, currently
## no holes) matters here. Switch this to a real geometry-scanned bake
## the day a map actually needs static air obstacles (a ceiling, a
## no-fly zone) — deferred, not forgotten.
static func ensure_air_region_baked(tree: SceneTree) -> void:
	if is_instance_valid(_air_region):
		return

	var region := NavigationRegion3D.new()
	region.name = "AirNavigationRegion3D"
	region.add_to_group("air_nav_region")
	region.navigation_layers = AIR_LAYER

	var nav_mesh := NavigationMesh.new()
	var h: float = FLIGHT_AREA_HALF_EXTENT
	var y: float = FLIGHT_CEILING_HEIGHT
	# Winding matters — Recast only treats a polygon as walkable if its
	# face normal points +Y. This order (confirmed by testing, not
	# assumed) is what actually produces that; the "obvious" [0,1,2,3]
	# order here faces -Y and silently bakes to zero usable polygons.
	nav_mesh.vertices = PackedVector3Array([
		Vector3(-h, y, -h), Vector3(h, y, -h), Vector3(h, y, h), Vector3(-h, y, h),
	])
	nav_mesh.add_polygon(PackedInt32Array([0, 3, 2, 1]))
	region.navigation_mesh = nav_mesh

	tree.current_scene.add_child(region)
	_air_region = region

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
	# Piggybacks the air region's one-time creation onto ground rebaking
	# (called every single turn already, from combat's very first turn)
	# rather than waiting for the first actual flight move to trigger it
	# lazily — see ensure_air_region_baked()'s own header for why: a
	# freshly created NavigationRegion3D needs the NavigationServer a
	# real physics frame or two to register before map_get_path can see
	# it, and a synchronous move_to() call can't await that. Creating it
	# here instead means it's had many turns to settle by the time
	# anyone could plausibly have cast a flight ability AND clicked a
	# destination — two separate inputs that can't happen in the same
	# frame combat starts in.
	ensure_air_region_baked(tree)

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
		# A flying unit isn't standing on the ground — nothing physically
		# occupies its ground-level footprint, so it shouldn't carve a
		# hole into the GROUND navmesh at all (a ground unit should be
		# free to walk underneath it). It still doesn't carve the AIR
		# navmesh either — see ensure_air_region_baked()'s header for why
		# flying units don't carve each other at all, in either layer.
		var carves_ground: bool = not is_mover and not unit.is_flying()
		unit.set_carving_enabled(carves_ground)
		if carves_ground:
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
