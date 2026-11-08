#ifndef NAVIGATION_GRID_H
#define NAVIGATION_GRID_H
// C++ port of navigation_grid.gd — see that file's own header (still
// present in git history) for the original design rationale: one shared 3D
// grid for ground+flight, static geometry baked once, dynamic occupancy
// kept current by the grid itself (see ensure_occupancy_current). This class is registered as an Engine singleton named
// "NavigationGrid" (see register_types.cpp) so every existing GDScript
// call site (unit_movement.gd, movement_indicator.gd, combat_manager.gd,
// knockback_effect.gd, ground_point_targeting.gd, unit.gd) keeps calling
// NavigationGrid.find_path(...)/nearest_valid_point(...)/etc. largely
// unchanged — only the implementation moved from GDScript to native code.
//
// CHUNKED STORAGE (this revision): the world is no longer one dense flat
// array. It's split into CHUNK_DIM^3-cell chunks, lazily rasterized and
// baked on demand as queries actually touch them — sized for a single
// bounded, always-resident map (no eviction), matching a Solasta/BG3-style
// "one big continuous level at a time" scope rather than an unbounded
// streamed world. See each chunk-lifecycle method's own comment for the
// two-tier bake split (cheap support/coarse-flags tier vs. the more
// expensive per-cell clearance distance-field tier) and why it exists.
//
// Everything ABOVE the chunk-accessor layer (is_valid_cell, a_star,
// smooth_path, nearest_valid_point, reconstruct_path) is deliberately
// left structurally identical to the pre-chunking version — only
// is_solid/cell_no_support/cell_clearance_world/occupant_at changed what
// they read from underneath. That's intentional: those algorithms were
// already correctness-tested, and the smallest-risk way to add chunking
// was to keep them oblivious to it.

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <memory>
#include <cstdint>

namespace godot {

// One CHUNK_DIM^3 cube of the grid. Lazily rasterized (solid geometry
// only), then baked in two independent tiers on top of that:
//   - support tier: no_support[] (needs solid straight down) plus two
//     coarse flags (has_ground_passable / has_flyable) used ONLY by the
//     cheap chunk-level coarse search, deliberately ignoring clearance and
//     occupancy so it stays cheap — see NavigationGrid::coarse_corridor.
//   - dist tier: per-cell horizontal distance-to-nearest-solid, replacing
//     the old per-clearance inflated_solid_cache with one shared field
//     (see NavigationGrid::bake_chunk_dist for why one field suffices).
// Occupancy lives here too but is independent of bake state entirely — a
// chunk can hold occupancy before it's ever geometrically touched.
// A walkable ramp found while rasterizing (ramp_of in the .cpp): the box's
// space, which local axis is its face's normal, and how far the band of
// ground under that face reaches, down and past the box's ends.
struct RampInfo {
	Transform3D inverse;
	Vector3 half_size;
	Vector3 axis_scale;
	Vector3 extend;
	int up_axis = -1;
	float up_sign = 1.0f;
	float skin_depth = 0.0f;
};

// A mesh collision shape (ConcavePolygonShape3D, ConvexPolygonShape3D,
// HeightMapShape3D) as world-space triangles, built once per scan
// (build_tri_shape in the .cpp) and rasterized from its triangles rather
// than its bounding box.
struct TriShape {
	std::vector<Vector3> verts; // 3 per triangle, world space
	std::vector<Vector3> normals; // 1 per triangle, unit, pointing out of the solid
	// 1 per triangle: 1 = walkable (see tri_walkable) and at least one of
	// its edges borders no other walkable triangle, so the ground band
	// under it runs on past that edge (where the slope meets a platform).
	std::vector<uint8_t> open_edge;
	// 3 per triangle, edge k running from vertex k to k + 1: 1 = the edge
	// borders no other walkable triangle.
	std::vector<uint8_t> outer_edge;
	AABB aabb;
	bool any_walkable = false;
	// chunk column (cx * chunk_grid_size.z + cz) -> triangles whose
	// footprint, or ground band, reaches into it.
	std::unordered_map<int, std::vector<int>> by_column;
};

// One chunk's connected regions for one movement mode (walking or flying).
// A cell is open when SOME unit of that mode could stand in it: not solid,
// supported (walking) or high enough (flying), under the flight ceiling
// (flying). That is is_valid_cell with clearance, height and occupancy
// taken away, so it holds for every cell any search could accept, and two
// cells in different regions can never be joined by a search. Open cells
// touching across any of the 26 neighbours share a region, the same
// neighbours a_star steps through. See NavigationGrid::regions_may_connect.
struct NavRegions {
	bool labelled = false;
	bool linked = false;
	uint16_t count = 0;
	std::vector<uint16_t> label; // CHUNK_DIM^3, 0 = closed, else 1..count
	// [region - 1] -> region keys (see region_key) in neighbouring chunks
	// that one of its cells touches.
	std::vector<std::vector<uint64_t>> links;
};

// One occupant as is_clear_of_units tests it: a vertical column from its
// feet cell up `layers` cells, `clearance` (radius + margin) around.
struct OccupantVolume {
	Object *obj = nullptr; // compared, never dereferenced
	Vector3i cell;
	float clearance = 0.0f;
	int layers = 0;
};

struct NavChunk {
	std::vector<uint8_t> solid; // CHUNK_DIM^3, 1 = solid geometry
	// CHUNK_DIM^3, parallel to solid: 1 = solid lying just under a walkable
	// ramp's face (a tilted box no steeper than MAX_WALKABLE_SLOPE_DEGREES;
	// see ramp_of). Such a cell is still solid, but it is ground under a
	// unit's feet, not a wall in its way, so bake_chunk_dist does not
	// measure clearance from it.
	std::vector<uint8_t> ground;
	std::vector<uint8_t> no_support; // CHUNK_DIM^3, 1 = nothing solid directly below
	// CHUNK_DIM^3, 1 = solid within FLIGHT_MIN_ALTITUDE straight below: too
	// low for a flier, which must stay that far above whatever is under it.
	std::vector<uint8_t> flight_low;
	// CHUNK_DIM^3, 1 = nothing solid within FLIGHT_MAX_ALTITUDE straight
	// below: too high for a flier, whose ceiling rides on the ground under
	// it the same way its floor does.
	std::vector<uint8_t> flight_high;
	std::vector<uint16_t> dist; // CHUNK_DIM^3, fixed-point cells (see DIST_SCALE) to nearest solid, same Y layer
	// Every occupant whose column reaches into this chunk, as the volume it
	// is rather than the cells it covers. Stamping a body cell by cell cost
	// its disc times its height on every rebuild (an SM 6 dragon: ~21,000
	// cells whenever anyone crossed a cell), and testing a body against
	// stamps cost the querying disc times its sampled layers per candidate
	// cell (~6,300 lookups for the dragon). A volume test is a few compares.
	std::vector<OccupantVolume> occupants;
	bool has_occupancy = false; // true iff `occupants` is non-empty -- lets is_clear_of_units rule out a whole neighborhood cheaply

	bool rasterized = false;
	// solid[] holds a seal_interiors fill on top of the raw geometry.
	bool sealed = false;
	bool support_baked = false;
	bool dist_baked = false;
	bool has_ground_passable = false;
	bool has_flyable = false;
	NavRegions regions[2]; // [0] walking, [1] flying
};

// Fine-A* scratch for one chunk's cells, allocated the first time a search
// touches the chunk and kept for later searches. Every field is stamped
// with the search that wrote it (see NavigationGrid::astar_search_id), so a
// page is never cleared: a stale stamp reads as "untouched this search".
// came_dir is the index into neighbor_offsets of the step that reached the
// cell, not the parent's index: the parent is cell - offset, which works
// the same whether it sits in this chunk or the next, in one byte.
struct AStarPage {
	static constexpr int CELLS = 32 * 32 * 32; // CHUNK_DIM^3
	float g_score[CELLS];
	int g_gen[CELLS];
	int closed_gen[CELLS];
	uint8_t came_dir[CELLS];
	// is_valid_cell's answer this search (valid_gen == sid). A cell is
	// reached from up to 26 expanded neighbours before it closes, and each
	// used to re-ask: for a tall wide body that is a column of distance
	// field reads and an occupancy disc scan every time.
	int valid_gen[CELLS];
	uint8_t valid_result[CELLS];
};

// smooth_path's memo of is_valid_cell, paged the same way as AStarPage.
struct SmoothPage {
	static constexpr int CELLS = 32 * 32 * 32; // CHUNK_DIM^3
	int valid_gen[CELLS];
	uint8_t valid_result[CELLS];
};

// One world's worth of grid state, parked here while some OTHER world is
// the active one. See NavigationGrid::activate_world.
//
// Deliberately mirrors the identically-named members on NavigationGrid
// rather than replacing them. The class keeps operating on its own members
// exactly as it always has — every algorithm below (a_star, smooth_path,
// the whole chunk lifecycle) is untouched by multi-world support, which is
// the entire point: code that doesn't change can't regress. Only the
// public entry points swap the right world's state in first.
// One occupant as occupancy last stamped it: everything that decides
// which cells it covers. A list of these is the occupancy signature; a
// query rebuilds occupancy only when the live list differs from it.
struct OccupantKey {
	uint64_t id = 0; // instance id, not the pointer: a freed node's address can be reused
	Vector3i cell;
	int clearance_key = 0;
	int layers = 0; // body column height in cells, feet layer up; see occupant_layers
	bool operator==(const OccupantKey &o) const {
		return id == o.id && cell == o.cell && clearance_key == o.clearance_key && layers == o.layers;
	}
	bool operator!=(const OccupantKey &o) const { return !(*this == o); }
};

struct ParkedWorld {
	Vector3 bounds_origin;
	Vector3i grid_size;
	Vector3i chunk_grid_size;
	bool baked = false;
	bool any_occupied = false;
	std::vector<std::unique_ptr<NavChunk>> chunks;
	float geometry_min_y = 0.0f;
	std::vector<std::unique_ptr<AStarPage>> astar_pages;
	int astar_search_id = 0;
	std::vector<std::unique_ptr<SmoothPage>> smooth_pages;
	int smooth_search_id = 0;
	std::vector<CollisionShape3D *> all_shapes;
	std::unordered_map<int, std::vector<CollisionShape3D *>> shapes_by_chunk;
	std::unordered_map<CollisionShape3D *, std::shared_ptr<TriShape>> tri_shapes;
	std::vector<uint8_t> chunk_occupancy_nearby;
	std::vector<int> occupied_chunks;
	std::vector<OccupantKey> occupancy_signature;
	bool occupancy_stamped = false;
	uint64_t occupancy_version = 0;
	// The node this world's geometry is scanned from. A World3D can't be
	// walked back to a node, so the root has to be remembered when the
	// world registers itself.
	Node *root = nullptr;
};

class NavigationGrid : public Object {
	GDCLASS(NavigationGrid, Object)

public:
	NavigationGrid();
	~NavigationGrid();

	// --- Multi-world -------------------------------------------------
	// A world announces itself (WorldContext does this on construction)
	// and is forgotten when it goes. Until any world registers, this
	// behaves exactly as the single-grid version did, scanning the
	// current scene — which is what keeps the editor, tools and every
	// existing call path working unchanged.
	void register_world(Node *root);
	void unregister_world(Node *root);

	void ensure_baked(SceneTree *tree);
	// Drops every cached reference to the currently-loaded world's geometry
	// (all_shapes/shapes_by_chunk hold raw CollisionShape3D* into it) and
	// resets the baked latch, so the NEXT ensure_baked() call performs a
	// real re-scan instead of trusting stale state. Must be called by
	// WorldManager.load_world() before the outgoing world is freed —
	// without this, this singleton (it outlives every world, see this
	// class's own header) keeps dereferencing pointers into freed memory
	// the first time a query lazily touches a not-yet-rasterized chunk,
	// which is a real crash this project shipped (native segfault, no
	// preceding GDScript error — see WorldManager's own note on this).
	void invalidate();
	// The cheap form of invalidate() for one body that moved, appeared or
	// went away: `region` must cover everywhere its geometry was AND now is
	// (a moved prop's old and new AABB merged). Only chunks whose baked
	// tiers could read that region are reset; the rest of the world stays
	// baked. `world_root` names which world (any node in it works, the
	// root WorldContext registered is what callers hand over), so a parked
	// world is updated in place rather than whichever one is active. Falls
	// back to a full rescan when the change moves the world's bounds.
	void invalidate_region(Node *world_root, AABB region);
	// `ignore`: occupants this one query walks through as well as its own
	// unit — a group move's other movers, who are about to leave their
	// cells. Per query, never stored: occupancy itself always holds every
	// live unit and blocking corpse in the world.
	Dictionary nearest_valid_point(SceneTree *tree, Vector3 point, float clearance, bool flying, Object *exclude_unit, int max_radius_cells, Object *world_ref = nullptr, Array ignore = Array());
	PackedVector3Array find_path(SceneTree *tree, Vector3 start, Vector3 destination, Object *unit, bool flying, Array ignore = Array());
	// Bumps whenever the world's occupancy actually changes (anyone moves
	// a cell, dies, arrives, leaves), and whenever its geometry is
	// invalidated. For callers caching a route: equal versions mean
	// find_path would answer the same.
	int64_t occupancy_version(SceneTree *tree, Object *world_ref);
	Vector3i world_to_cell(Vector3 pos) const;
	// What GDScript gets as world_to_cell: a cell number is only meaningful
	// in the world whose lattice produced it, so the caller has to say
	// which world, and that world is activated first like every other query.
	Vector3i world_to_cell_in(Vector3 pos, Object *world_ref);

	float get_cell_size() const;
	float get_flight_min_altitude() const;
	float get_flight_max_altitude() const;
	float ground_height_at(SceneTree *tree, Vector3 pos, Object *world_ref = nullptr);
	float flight_floor_at(SceneTree *tree, Vector3 pos, Object *world_ref = nullptr);
	float flight_ceiling_at(SceneTree *tree, Vector3 pos, Object *world_ref = nullptr);
	float flight_lowest_altitude(SceneTree *tree, Object *world_ref = nullptr);
	// Bytes held by the active world's chunks and search scratch: what a
	// map's size actually costs, for measuring.
	int64_t debug_memory_bytes() const;
	float flight_highest_altitude(SceneTree *tree, Object *world_ref = nullptr);

protected:
	static void _bind_methods();

private:
	static constexpr float CELL_SIZE = 0.25f;
	// Width of the body a start escape walks with (find_escape_cell): one
	// cell, enough that it can't pass through a wall, thin enough that a
	// wide body wedged against one can still sidle out.
	static constexpr float ESCAPE_CLEARANCE = 0.25f;
	// Height a flier keeps above the ground under it - relative, not a world
	// Y, so a pit or a raised floor gets the same 1 m as y=0 ground.
	static constexpr float FLIGHT_MIN_ALTITUDE = 1.0f;
	// Highest a flier rises above the ground under it - relative too, so a
	// flier over a rooftop at y=15 has the same 12 m band as one over y=0.
	static constexpr float FLIGHT_MAX_ALTITUDE = 12.0f;
	// Body height assumed when a query names no unit: Unit.height's default,
	// so a unit-less nearest_valid_point never snaps under an overhang that
	// find_path (which always reads a real unit's height) would then reject.
	static constexpr float DEFAULT_BODY_HEIGHT = 2.0f;
	static constexpr float BOUNDS_MARGIN = 2.0f;
	static constexpr int MAX_EXPANSIONS = 30000;
	// Steepest floor a grounded unit walks up: CharacterBody3D's default
	// floor_max_angle, which units keep. A tilted box no steeper than this
	// is ground; anything steeper, or any vertical face, is a wall.
	static constexpr float MAX_WALKABLE_SLOPE_DEGREES = 45.5f;

	static constexpr int CHUNK_DIM = 32; // 8m/side at 0.25m cells
	// 5m horizontal reach cap for the distance field: past it every open
	// cell reads "clear all the way out". Wide enough for an SM 6 dragon
	// (clearance 4.25) to be kept its whole distance from walls; the cost
	// is the bake window, (CHUNK_DIM + 2 * cap)^2 per layer, ~1.3x at 16.
	// Must stay below CHUNK_DIM (bake_chunk_dist reads direct neighbours).
	static constexpr int MAX_CLEARANCE_CELLS = 20;
	static constexpr int DIST_SCALE = 8; // fixed-point precision for NavChunk::dist (1/8 cell ~= 0.03m)
	static constexpr int CORRIDOR_RADIUS_CHUNKS = 1; // fine search slack around the coarse route
	// Weighted A* (Pohl 1970): trades a bounded amount of path optimality
	// for far fewer expansions. Grid pathfinding with an unweighted
	// admissible heuristic suffers badly from tie-breaking symmetry — many
	// differently-shaped detours around an obstacle cost EXACTLY the same
	// true distance, so A* expands all of them before confirming which one
	// "wins," even though the final answer is the same either way. Measured
	// on a 51m path detouring around one obstacle: 9846 -> 419 expansions
	// (23x) with an IDENTICAL final path length (52.04m both ways) — this
	// game's turn-based tactical movement doesn't need provably-shortest
	// paths, just good-looking ones, so this trade is a clear win. Revisit
	// the weight (not the technique) if a future map ever produces a
	// visibly suboptimal path — smooth_path's post-hoc string-pulling also
	// cleans up most of any minor raggedness this could introduce.
	static constexpr float HEURISTIC_WEIGHT = 1.3f;

	// --- Multi-world registry ----------------------------------------
	// Every world EXCEPT the active one, parked. The active world's state
	// lives in the plain members below, which is what lets every
	// algorithm stay oblivious to any of this.
	std::unordered_map<uint64_t, ParkedWorld> parked_worlds;
	// World3D object id of whichever world's state is currently loaded
	// into those members. 0 means "none / the legacy current-scene grid."
	uint64_t active_world_id = 0;
	// Where the ACTIVE world's geometry is scanned from — see
	// ensure_project_scanned. Parked alongside the rest in ParkedWorld.
	Node *active_root = nullptr;

	// Parks the active world's state and loads world_id's in its place.
	// O(1) despite moving a dozen containers — every one is a vector or
	// map, so std::swap is a pointer exchange, not a copy. Cheap enough to
	// call at the top of every public entry point, which is exactly what
	// makes the swap trick viable at all.
	void activate_world(uint64_t world_id);
	// The World3D id a node belongs to, or 0 if it isn't a Node3D in a
	// tree. The one place node -> world resolution happens.
	static uint64_t world_id_of(Object *obj);
	bool in_active_world(Node3D *node);
	// Resolves which world a call means from whatever it was handed, in
	// priority order, and activates it. Falls back to the single
	// registered world, then to the legacy no-world grid.
	void activate_for(Object *primary, Object *fallback = nullptr);

	// Cell (0,0,0)'s corner. A multiple of CHUNK_DIM * CELL_SIZE on every
	// axis (see ensure_project_scanned), so cell and chunk boundaries sit at
	// the same world positions whatever geometry the level holds.
	Vector3 bounds_origin;
	Vector3i grid_size;
	Vector3i chunk_grid_size;
	// Lowest point of the scanned geometry (bounds_origin.y lies below it by
	// the margin plus the snap, so it is not derivable from the origin).
	float geometry_min_y = 0.0f;
	bool baked = false; // project geometry scanned + chunk table sized (NOT "every chunk rasterized")
	bool any_occupied = false;

	std::vector<std::unique_ptr<NavChunk>> chunks;

	// Persistent fine-A* scratch, reused across every query via a
	// generation stamp instead of a fresh unordered_map/unordered_set per
	// call — the same flat-array-over-hash trade already used for the
	// per-chunk distance field, applied here once profiling showed
	// g_score/came_from/closed hashing was the dominant per-expansion cost
	// once the corridor restriction made searches long enough for that to
	// matter. g_gen/closed_gen record which search last touched a cell; a
	// stale generation means "not part of the current search," standing in
	// for what would otherwise need a full clear between queries.
	//
	// Paged by chunk index, a page allocated only when a search first
	// reaches that chunk. It used to be flat arrays over the whole world
	// volume, 21 bytes for every cell of the bounds whether any search ever
	// went there or not, and a copy per parked world: a big map's sky and
	// rock cost more than everything else the grid holds put together.
	std::vector<std::unique_ptr<AStarPage>> astar_pages;
	int astar_search_id = 0;
	// The page holding an in-bounds cell, allocated on first touch, and the
	// cell's index within it. a_star keeps the last page it used, since
	// most neighbours share their parent's chunk.
	AStarPage &astar_page(const Vector3i &cell, int &local);
	SmoothPage &smooth_page(const Vector3i &cell, int &local);

	// Same flat-array-plus-generation-stamp trade as the fine-A* scratch
	// above, applied to smooth_path's is_valid_cell calls instead.
	// smooth_path's string-pulling re-derives line_clear(anchor, probe)
	// from scratch for every probe extension, which resamples most of the
	// SAME cells near the anchor over and over as probe grows (found by
	// profiling to dominate total find_path time on long paths — ~80% of
	// it on a 60m detour). is_valid_cell is pure for the duration of one
	// query (grid/occupancy state doesn't change mid-call), so caching its
	// result per cell here is exact, not an approximation — it changes
	// nothing about WHICH points get sampled or the early-exit behavior,
	// only skips recomputing an answer already known this call.
	std::vector<std::unique_ptr<SmoothPage>> smooth_pages; // paged as astar_pages
	int smooth_search_id = 0;
	bool is_valid_cell_cached(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit, int smooth_sid);

	// Static geometry, bucketed once by every chunk its AABB overlaps, so
	// rasterizing one chunk only tests the shapes that could touch it
	// instead of every shape in the level.
	std::vector<CollisionShape3D *> all_shapes;
	std::unordered_map<int, std::vector<CollisionShape3D *>> shapes_by_chunk;
	std::unordered_map<CollisionShape3D *, std::shared_ptr<TriShape>> tri_shapes;
	// CollisionShape3D instance ids already warned about as filled by their
	// bounding box, so a rescan (every area load, every prop drop) does not
	// repeat the warning. Shared across worlds: ids are never reused.
	std::unordered_set<uint64_t> warned_shapes;

	std::vector<Vector3i> neighbor_offsets; // 26-connectivity, fine A*
	std::vector<float> neighbor_step_cost; // parallel to neighbor_offsets — precomputed world-unit length of each offset, so a_star's hot loop doesn't call length() (sqrt) 26x per expansion for a fixed, known-in-advance set of vectors
	std::unordered_map<int, std::vector<Vector3i>> disc_offsets_cache; // horizontal (x,z) offsets by clearance — one layer of an occupancy column

	// Per-chunk cache: true iff ANY chunk in this chunk's own 3x3x3
	// neighborhood has_occupancy — see refresh_chunk_occupancy_nearby.
	// Rebuilt whenever occupancy is, then read as a plain O(1) lookup by
	// every is_clear_of_units call in between — replaces what used to be
	// a fresh 27-chunk scan on EVERY candidate cell during pathfinding.
	std::vector<uint8_t> chunk_occupancy_nearby;
	void refresh_chunk_occupancy_nearby();
	// Chunks holding any occupancy, so a rebuild clears and re-marks only
	// those instead of walking every chunk in the world.
	std::vector<int> occupied_chunks;

	// --- Self-maintaining occupancy ----------------------------------
	// Occupancy used to be a snapshot callers had to remember to retake
	// (update_occupancy), which also baked "who is moving" into the
	// snapshot. Every place that forgot, or retook it at the wrong time,
	// was a route through a unit. Now every query first compares the live
	// occupants against the signature occupancy was last built from and
	// rebuilds only on a difference — so it is exactly as current as the
	// scene at the moment of asking, with no frame or tick dependence.
	std::vector<OccupantKey> occupancy_signature;
	bool occupancy_stamped = false;
	uint64_t occupancy_version_value = 0;
	// Shared across worlds so a version never repeats after a world swap.
	uint64_t occupancy_version_counter = 0;
	void ensure_occupancy_current(SceneTree *tree);
	void collect_occupants(SceneTree *tree, std::vector<OccupantKey> &keys, std::vector<Object *> &objects);
	void reset_occupancy();
	// The current query's ignore list (see find_path). Set at the top of
	// each public query, read by is_clear_of_units.
	std::vector<Object *> query_ignore;
	void set_query_ignore(const Array &ignore);

	void ensure_project_scanned(SceneTree *tree);
	// invalidate_region's work on the active world: refreshes the shape
	// list, rebuckets and un-bakes the chunks around region.
	void invalidate_active_region(SceneTree *tree, const AABB &region);
	// The grid's origin and size for the shapes in all_shapes, as a scan
	// sizes it. Shared so invalidate_region can tell whether a change moved
	// the bounds (and so needs a full rescan).
	void scan_bounds(Vector3 &origin, Vector3i &size, float &min_y);
	// The chunks a shape is bucketed into (see shapes_by_chunk), or false
	// when it lies outside the grid.
	bool shape_chunk_range(CollisionShape3D *cs, Vector3i &min_chunk, Vector3i &max_chunk);
	void collect_static_shapes(Node *node, std::vector<CollisionShape3D *> &out);
	AABB shape_global_aabb(CollisionShape3D *cs);
	AABB transform_aabb(const Transform3D &t, const AABB &aabb);
	bool build_tri_shape(CollisionShape3D *cs, TriShape &out);
	void index_tri_columns(TriShape &tri);
	void rasterize_tri_shape(const TriShape &tri, const Vector3i &chunk_coord, NavChunk &chunk, std::vector<std::pair<const TriShape *, int>> &walkable);
	void mark_tri_ground(const TriShape &tri, int id, const Vector3i &chunk_coord, NavChunk &chunk);

	Vector3 cell_center(const Vector3i &cell) const;
	int64_t cell_index(const Vector3i &cell) const; // global bijection over grid_size; 64-bit, a large map's cell count passes 2^31
	Vector3i cell_from_index(int64_t idx) const;
	bool in_bounds(const Vector3i &cell) const;

	Vector3i cell_to_chunk_coord(const Vector3i &cell) const;
	Vector3i cell_to_local(const Vector3i &cell) const;
	int chunk_coord_index(const Vector3i &chunk_coord) const;
	Vector3i chunk_coord_from_index(int idx) const;
	bool chunk_in_bounds(const Vector3i &chunk_coord) const;
	static int local_index(const Vector3i &local);

	NavChunk &ensure_chunk_rasterized(const Vector3i &chunk_coord);
	NavChunk &ensure_chunk_support(const Vector3i &chunk_coord);
	NavChunk &ensure_chunk_dist(const Vector3i &chunk_coord);
	// `fill`: cells to make solid before the ramp bands are marked, so the
	// bands see them (see seal_interiors).
	void rasterize_chunk(const Vector3i &chunk_coord, NavChunk &chunk, const std::vector<uint8_t> *fill = nullptr);
	// Open means connected to the outside. Every open cell that cannot reach
	// the world's boundary through open cells is inside geometry (the hollow
	// of an open mesh, a pocket sealed in rock, a room with no way in) and is
	// made solid here, once per scan, before any tier reads solid[]. So
	// support, flight_low, dist, regions and the floor queries all agree that
	// it is not air.
	void seal_interiors();
	void bake_chunk_support(const Vector3i &chunk_coord, NavChunk &chunk);
	void bake_chunk_dist(const Vector3i &chunk_coord, NavChunk &chunk);

	bool is_solid(const Vector3i &cell);
	// Cells a flier may occupy within FLIGHT_MIN/MAX_ALTITUDE of the solid
	// below it, counted as bake_chunk_support counts them.
	static int flight_low_cells();
	static int flight_high_cells();
	// Top of the first solid at or below pos (pos inside solid climbs out
	// first); the world's floor when the column is empty all the way down.
	float ground_top_below(Vector3 pos);

	static int clearance_key(float clearance);
	const std::vector<Vector3i> &disc_offsets(float clearance);

	// Lists the volume in every chunk its column reaches; false when none
	// of it is in bounds.
	bool stamp_occupant(const OccupantVolume &volume);

	// Every occupant, walking or flying, fills a vertical column: its
	// clearance disc on every layer from its feet up its body height,
	// never shorter than MIN_OCCUPANT_LAYERS.
	static constexpr int MIN_OCCUPANT_LAYERS = 4; // 1 m
	static constexpr float DEFAULT_OCCUPANT_HEIGHT = 2.0f; // Unit.height's default, for an occupant reporting none
	static int occupant_layers(float height);
	static int body_layers(float height);

	bool is_clear_of_units(const Vector3i &cell, int chunk_idx, float clearance, float height, Object *self_unit) const;
	bool is_valid_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit);
	// The part of is_valid_cell that holds for every clearance and height,
	// for an in-bounds cell of a support-baked chunk: not solid; walking
	// needs support directly below; flying needs to be neither under
	// FLIGHT_MIN_ALTITUDE nor over FLIGHT_MAX_ALTITUDE above the ground.
	// is_valid_cell and ensure_chunk_regions both call this one rule, so a
	// region can never be stricter than A* - a cell A* accepts is always
	// open, and regions_may_connect never rules out a path that exists.
	static inline bool is_open_cell(const NavChunk &chunk, int li, bool flying) {
		if (chunk.solid[li] != 0) {
			return false;
		}
		if (flying) {
			return chunk.flight_low[li] == 0 && chunk.flight_high[li] == 0;
		}
		return chunk.no_support[li] == 0;
	}

	struct NearestResult {
		bool found;
		Vector3i cell;
	};
	NearestResult find_nearest_free_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit, int max_radius);
	NearestResult find_escape_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit, int max_radius);

	void ensure_neighbor_offsets();
	static float heuristic(const Vector3i &a, const Vector3i &b);
	static float coarse_heuristic(const Vector3i &a, const Vector3i &b);

	// Cheap chunk-level A* (using only the support-tier coarse flags) that
	// returns a chunk_coord_index -> allowed flat mask covering
	// CORRIDOR_RADIUS_CHUNKS around an approximate route from start to
	// goal, or an empty vector if none was found. A flat mask rather than
	// a hash set for the same reason as astar_pages above — chunk counts
	// are small, so this is cheap to allocate fresh per query. Deliberately
	// optimistic/approximate — see find_path for why that's safe (a failed
	// corridor-restricted fine search falls back to an unrestricted one
	// whenever the corridor could be why it failed, so this can only affect
	// speed).
	std::vector<uint8_t> coarse_corridor(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying);

	// --- Connectivity regions ----------------------------------------
	// Whether a search from start_cell could ever reach goal_cell: false
	// only when it provably can't (their regions are not connected), so
	// find_path answers "no path" without exhausting a search for it. A
	// search from both ends at once over the region graph, so a goal
	// sealed off from the start (a pocket inside hollow terrain, a ledge
	// with no way up) fails in the time it takes to walk ITS side, not
	// the whole level. Labels need only the support tier and are built
	// per chunk as the search reaches it; they go with the chunks when
	// the world is rescanned.
	static constexpr int MAX_REGION_EXPANSIONS = 20000;
	bool regions_may_connect(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying);
	NavRegions &ensure_chunk_regions(const Vector3i &chunk_coord, bool flying);
	NavRegions &ensure_chunk_region_links(const Vector3i &chunk_coord, bool flying);
	// (chunk index << 16) | label, or 0 for a closed cell.
	uint64_t region_key(const Vector3i &cell, bool flying);

	// The goal's own side of a search, flooded alongside it. Regions
	// (above) ignore clearance and occupancy, so a goal they pass can still
	// be sealed off for THIS unit: ringed by units, or behind a gap too
	// narrow for its body. A search from the start finds that out only by
	// exhausting everything it can reach, which on an open map is the
	// MAX_EXPANSIONS cap. The goal's sealed pocket is usually tiny, so a
	// breadth-first flood over the very cells the search would accept,
	// stepped once per GOAL_FLOOD_EVERY search expansions, empties it and
	// proves the goal unreachable after a few hundred expansions instead.
	// A flood that grows past GOAL_FLOOD_BUDGET cells gives up: the goal's
	// side is big, so the search decides as before. The budget is what an
	// OPEN goal pays on every route (26 validity checks per flooded cell),
	// so it is sized for the pockets this exists for, a goal ringed by
	// units or tucked behind one gap (about 32 m2 of floor), not whole
	// rooms: 4096 cost a quarry route 8 ms (16 -> 24 ms). Search and flood share
	// one adjacency (is_valid_cell over the 26 neighbours, symmetric), so
	// "sealed" is exact, never a guess.
	static constexpr int GOAL_FLOOD_EVERY = 4;
	static constexpr int GOAL_FLOOD_BUDGET = 512;
	struct GoalFlood {
		enum State { RUNNING, SEALED, OPEN };
		State state = RUNNING;
		Vector3i start_cell;
		std::vector<Vector3i> queue; // BFS order; head is the next to expand
		size_t head = 0;
		std::unordered_set<int64_t> seen; // cell_index
	};
	void goal_flood_begin(GoalFlood &flood, const Vector3i &start_cell, const Vector3i &goal_cell);
	void goal_flood_step(GoalFlood &flood, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit);

	PackedVector3Array a_star(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit, const std::vector<uint8_t> *allowed_chunks_mask, GoalFlood *flood = nullptr, bool *mask_cut = nullptr);
	PackedVector3Array reconstruct_path(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell);
	PackedVector3Array smooth_path(const PackedVector3Array &path, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit);
	bool line_clear(const Vector3 &a, const Vector3 &b, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit, int smooth_sid);

	// Reads a float property off a duck-typed GDScript "Unit" instance
	// (radius, avoidance_margin, height, flight_target_altitude) —
	// everything in the "units"/"blocking_corpses" groups is a Unit-scripted node by
	// this codebase's own hard invariant (only Unit._ready() ever calls
	// add_to_group("units")), so this trusts that rather than re-deriving
	// a type check GDScript's own "as Unit" cast already gave up on
	// duck-typing for elsewhere in this port.
	static float get_float_prop(Object *obj, const StringName &name);
	static bool call_bool(Object *obj, const StringName &method);
};

} // namespace godot

#endif // NAVIGATION_GRID_H
