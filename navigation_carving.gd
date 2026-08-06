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

## The air region lives on its OWN NavigationMap, not the World3D
## default map ground uses — confirmed necessary by testing, not a
## design preference: two regions with overlapping XZ footprints on the
## SAME map, even a completely flat pair with no shared obstacle at all,
## reliably triggers a NavigationServer "attempted to merge a navigation
## mesh polygon edge with another already-merged edge" error during that
## map's periodic sync pass. navigation_layers (AIR_LAYER/GROUND_LAYER
## above) was meant to be how ground/air stayed distinguished on one
## shared map; that assumption turned out not to hold once the air layer
## got real geometry-scanned obstacles instead of an empty rectangle —
## kept anyway since it's still harmless/correct on the air map's own
## terms, just no longer the thing doing the actual separation.
static var _air_map: RID


## Lazily creates (once) and returns the dedicated air NavigationMap RID
## — see the const comment above for why this exists instead of reusing
## the default map. map_set_active is required: a server-created map
## isn't live until explicitly activated, unlike the World3D default map
## which Godot activates for you.
static func get_air_map() -> RID:
	if not _air_map.is_valid():
		_air_map = NavigationServer3D.map_create()
		NavigationServer3D.map_set_active(_air_map, true)
	return _air_map

## Ceiling for the flight envelope — the hard upper clamp on
## Unit.adjust_flight_altitude(), not a physical obstacle (there's no
## geometry up there; a unit just can't scroll/hold past it). Real
## ceiling obstacles, where they exist, come from actual level geometry
## now that rebake_air_region_at_altitude() scans it — see that
## function's header for why this changed from the original
## flat-rectangle prototype.
const FLIGHT_CEILING_HEIGHT := 12.0
## Generous flat bound for the air layer's synthetic floor plate,
## covering any reasonable battle map — a single large rectangle, not
## per-level geometry, so oversizing it costs nothing.
const FLIGHT_AREA_HALF_EXTENT := 100.0
## Floor for Unit.adjust_flight_altitude()'s clamp — a flat safety
## minimum, not real per-location ground height (that would need a
## downward raycast/navmesh query per adjustment, not just a constant).
## Landing (Unit.land()) is what actually finds real ground precisely;
## this just stops scrolling from dragging a unit's TARGET altitude
## below/through the floor before they ever land.
const FLIGHT_MIN_ALTITUDE := 1.0
## Skips re-baking the air layer for a target altitude within this many
## meters of the last bake — avoids a full geometry-scan bake for
## floating-point noise or negligible drift, while still re-baking for
## any real altitude change.
const AIR_REBAKE_EPSILON := 0.1

static var _air_region: NavigationRegion3D
static var _air_floor_body: StaticBody3D
## Sentinel far outside the real flight envelope so the very first call
## always bakes rather than being skipped by the epsilon check above.
static var _air_baked_altitude: float = -INF


## Rewrites a flight path's Y values to interpolate from start_altitude
## to target_altitude, based on how far along the path's XZ length each
## waypoint sits — used by both UnitMovement.move_to() and
## movement_indicator.gd's preview so the two can't diverge (same
## reasoning as both already sharing RoutePlanner.plan). waypoints come
## back from map_get_path sitting on the air layer's own baked height
## (FLIGHT_CEILING_HEIGHT) — not a real altitude, only their XZ shape is
## meaningful; this is what turns that into an actual flight path that
## climbs/descends from wherever the unit currently is to
## target_altitude over the course of the move (so ascending/descending
## spends real movement budget via RoutePlanner's ordinary 3D-distance
## cost, rather than needing a separate cost rule for it).
static func remap_flight_altitude(waypoints: PackedVector3Array, start_altitude: float, target_altitude: float) -> PackedVector3Array:
	var xz_lengths: PackedFloat32Array = PackedFloat32Array([0.0])
	var total_length: float = 0.0
	for i in range(1, waypoints.size()):
		var a := Vector2(waypoints[i - 1].x, waypoints[i - 1].z)
		var b := Vector2(waypoints[i].x, waypoints[i].z)
		total_length += a.distance_to(b)
		xz_lengths.append(total_length)

	var result: PackedVector3Array = waypoints.duplicate()
	for i in result.size():
		var t: float = xz_lengths[i] / total_length if total_length > 0.0 else 1.0
		result[i].y = lerp(start_altitude, target_altitude, t)
	return result


## Bakes (or re-bakes) the air navigation layer's walkable surface at
## `altitude`, from REAL level geometry — replaces an earlier version of
## this function that hand-authored an empty flat rectangle with no
## obstacle awareness at all (confirmed missing via direct testing: a
## flying unit was flying straight through walls the ground layer
## already routes around). Reuses the exact same real-geometry bake
## pipeline rebake_for_movers() below already uses for the ground layer
## (parse_source_geometry_data + bake_from_source_geometry_data, region's
## PARENT as the discovery root) — just with a synthetic, invisible
## "floor" plate (_air_floor_body) repositioned to `altitude` instead of
## ground level. Recast's own obstacle exclusion (already proven correct
## for the ground layer, and directly verified for this specific
## use — baking a floor next to a tall wall produced a real detour
## around its exact footprint, while a short wall below that height was
## correctly ignored) then naturally carves out any real static geometry
## — walls, platforms, boxes — that occupies that specific height,
## leaving the rest open. Continuous in the real sense: any altitude,
## not a handful of pre-baked bands, since the bake target is whatever
## height is actually relevant right now, not a fixed layer.
##
## Idempotent against small altitude drift (see AIR_REBAKE_EPSILON) so
## every call site can call this liberally rather than tracking whether
## a rebake is actually owed.
##
## Real cost, unlike the old one-time rectangle: this is a genuine
## geometry-scan bake, same class of cost as the ground layer's own
## per-turn rebake, done every time a flying unit's relevant altitude
## changes meaningfully — not free, but proportionate to what it buys.
## And per the "freshly baked region needs a real physics frame before
## it's queryable" lesson (see feedback memory), this has to be
## triggered PROACTIVELY, ahead of when a query will actually happen —
## see call sites in rebake_for_movers() (every turn start, for whoever
## flying is currently acting) and movement_indicator.gd's altitude-key-
## release handling, not lazily inside move_to() alone (though it's
## still called there too, as a last-resort safety net).
static func rebake_air_region_at_altitude(tree: SceneTree, altitude: float) -> void:
	if is_instance_valid(_air_region) and absf(altitude - _air_baked_altitude) < AIR_REBAKE_EPSILON:
		return

	if not is_instance_valid(_air_region):
		_create_air_region(tree)

	_air_floor_body.position.y = altitude - 0.1
	_air_baked_altitude = altitude

	# A fresh NavigationMesh each bake, not the same resource re-baked in
	# place — this floor plate physically moves every time (unlike the
	# ground layer's own source geometry, which never moves between
	# bakes), and bake_from_source_geometry_data mutating stale polygon
	# data from a DIFFERENT source position in place is a real,
	# reproducible source of corruption (confirmed by testing). Safe to
	# reposition/re-bake the same persistent REGION node in place now
	# that it's on its own dedicated map (see AIR_MAP/get_air_map()) —
	# the map-sharing conflict that previously forced full region
	# destroy-and-recreate every rebake doesn't apply once ground and
	# air are never reconciled against each other on the same map.
	_air_region.navigation_mesh = NavigationMesh.new()

	var ground_region: NavigationRegion3D = tree.get_first_node_in_group("nav_region") as NavigationRegion3D
	var parent: Node = ground_region.get_parent() if ground_region else tree.current_scene
	var source_geometry_data := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(_air_region.navigation_mesh, source_geometry_data, parent)
	NavigationServer3D.bake_from_source_geometry_data(_air_region.navigation_mesh, source_geometry_data)
	_air_region.set_navigation_mesh(_air_region.navigation_mesh)


## One-time construction of the air region and its synthetic floor plate
## — a real StaticBody3D (MeshInstance3D + CollisionShape3D, same
## belt-and-suspenders reasoning as everywhere else in this project that
## doesn't know which geometry source mode is configured) so it actually
## participates in parse_source_geometry_data's scan alongside real
## level geometry. Invisible (mesh_instance.visible = false) — this is a
## bake-source plate, not something a player should ever see floating at
## a unit's flight altitude.
##
## Parented under the SAME root the ground region uses (so later scans
## pick up real static level geometry alongside this plate — units don't
## leak into that scan regardless, since they're CharacterBody3D, not
## StaticBody3D, same as how the ground bake already never picks them
## up), then EXPLICITLY reassigned onto the dedicated air map — Godot
## auto-attaches a newly-added NavigationRegion3D to the World3D default
## map, which is exactly the map ground already uses; region_set_map
## overrides that immediately, before this region ever gets baked, so it
## never actually coexists with the ground region on the same map even
## momentarily.
static func _create_air_region(tree: SceneTree) -> void:
	var region := NavigationRegion3D.new()
	region.name = "AirNavigationRegion3D"
	region.add_to_group("air_nav_region")
	region.navigation_layers = AIR_LAYER
	region.navigation_mesh = NavigationMesh.new()

	var floor_body := StaticBody3D.new()
	floor_body.name = "AirFloorPlate"
	region.add_child(floor_body)

	var h: float = FLIGHT_AREA_HALF_EXTENT
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(h * 2.0, 0.2, h * 2.0)
	mesh_instance.mesh = box_mesh
	mesh_instance.visible = false
	floor_body.add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(h * 2.0, 0.2, h * 2.0)
	collision.shape = box_shape
	floor_body.add_child(collision)

	var ground_region: NavigationRegion3D = tree.get_first_node_in_group("nav_region") as NavigationRegion3D
	var parent: Node = ground_region.get_parent() if ground_region else tree.current_scene
	parent.add_child(region)
	NavigationServer3D.region_set_map(region.get_region_rid(), get_air_map())

	_air_region = region
	_air_floor_body = floor_body

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
	# Piggybacks an air-layer rebake onto ground rebaking (called every
	# single turn already, from combat's very first turn) for any mover
	# that's currently flying, rather than waiting for that unit's own
	# move_to() call to trigger it lazily — see
	# rebake_air_region_at_altitude()'s own header for why: a freshly
	# baked region needs the NavigationServer a real physics frame or two
	# to register before map_get_path can see it, and a synchronous
	# move_to() call can't await that. Baking here instead means it's had
	# many frames to settle by the time this mover could plausibly have
	# clicked a destination — two separate inputs that can't happen in
	# the same frame their turn starts in. Harmless/no-op for a mover
	# that isn't flying, or whose altitude hasn't meaningfully changed
	# since the last bake (see AIR_REBAKE_EPSILON).
	for m in movers:
		if m is Unit and m.is_flying():
			rebake_air_region_at_altitude(tree, m.flight_target_altitude)

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
		# navmesh either — mutual flyer-to-flyer avoidance is a separate,
		# not-yet-built follow-up (see this project's flight-design
		# notes), not something rebake_air_region_at_altitude()'s
		# real-geometry bake currently accounts for.
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
