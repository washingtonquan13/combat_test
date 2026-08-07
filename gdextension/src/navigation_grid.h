#ifndef NAVIGATION_GRID_H
#define NAVIGATION_GRID_H
// C++ port of navigation_grid.gd — see that file's own header (still
// present in git history) for the original design rationale: one shared 3D
// grid for ground+flight, static geometry baked once, dynamic occupancy
// rebuilt per turn. This class is registered as an Engine singleton named
// "NavigationGrid" (see register_types.cpp) so every existing GDScript
// call site (unit_movement.gd, movement_indicator.gd, combat_manager.gd,
// knockback_effect.gd, ground_point_targeting.gd, unit.gd) keeps calling
// NavigationGrid.find_path(...)/update_occupancy(...)/etc. completely
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
struct NavChunk {
	std::vector<uint8_t> solid; // CHUNK_DIM^3, 1 = solid geometry
	std::vector<uint8_t> no_support; // CHUNK_DIM^3, 1 = nothing solid directly below
	std::vector<uint16_t> dist; // CHUNK_DIM^3, fixed-point cells (see DIST_SCALE) to nearest solid, same Y layer
	std::unordered_map<int, Object *> occupied; // chunk-local index -> occupant
	bool has_occupancy = false; // true iff `occupied` is non-empty -- lets is_clear_of_units rule out a whole neighborhood cheaply

	bool rasterized = false;
	bool support_baked = false;
	bool dist_baked = false;
	bool has_ground_passable = false;
	bool has_flyable = false;
};

class NavigationGrid : public Object {
	GDCLASS(NavigationGrid, Object)

public:
	NavigationGrid();
	~NavigationGrid();

	void ensure_baked(SceneTree *tree);
	void update_occupancy(SceneTree *tree, Array movers);
	Dictionary nearest_valid_point(SceneTree *tree, Vector3 point, float clearance, bool flying, Object *exclude_unit, int max_radius_cells);
	PackedVector3Array find_path(SceneTree *tree, Vector3 start, Vector3 destination, Object *unit, bool flying);
	Vector3i world_to_cell(Vector3 pos) const;

	float get_cell_size() const;
	float get_flight_min_altitude() const;
	float get_flight_ceiling_height() const;

protected:
	static void _bind_methods();

private:
	static constexpr float CELL_SIZE = 0.25f;
	static constexpr float FLIGHT_MIN_ALTITUDE = 1.0f;
	static constexpr float FLIGHT_CEILING_HEIGHT = 12.0f;
	static constexpr float BOUNDS_MARGIN = 2.0f;
	static constexpr int MAX_EXPANSIONS = 30000;

	static constexpr int CHUNK_DIM = 32; // 8m/side at 0.25m cells
	static constexpr int MAX_CLEARANCE_CELLS = 16; // 4m horizontal reach cap for the distance field
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

	Vector3 bounds_origin;
	Vector3i grid_size;
	Vector3i chunk_grid_size;
	bool baked = false; // project geometry scanned + chunk table sized (NOT "every chunk rasterized")
	bool any_occupied = false;

	std::vector<std::unique_ptr<NavChunk>> chunks;

	// Persistent fine-A* scratch, sized once to the total (bounded) world
	// cell count when the project is scanned and reused across every
	// query via a generation stamp instead of a fresh
	// unordered_map/unordered_set per call — the same flat-array-over-hash
	// trade already used for the per-chunk distance field, applied here
	// once profiling showed g_score/came_from/closed hashing (not chunk
	// lookups, which are plain vector indexing) was the dominant per-
	// expansion cost once the corridor restriction made searches long
	// enough for that to matter. astar_g_gen/astar_closed_gen record which
	// search last touched a cell; a stale generation means "not part of
	// the current search," standing in for what would otherwise need a
	// full clear between queries.
	std::vector<float> astar_g_score;
	std::vector<int> astar_g_gen;
	std::vector<int> astar_came_from;
	std::vector<int> astar_closed_gen;
	int astar_search_id = 0;

	// Static geometry, bucketed once by every chunk its AABB overlaps, so
	// rasterizing one chunk only tests the shapes that could touch it
	// instead of every shape in the level.
	std::vector<CollisionShape3D *> all_shapes;
	std::unordered_map<int, std::vector<CollisionShape3D *>> shapes_by_chunk;

	std::vector<Vector3i> neighbor_offsets; // 26-connectivity, fine A*
	std::unordered_map<int, std::vector<Vector3i>> disc_offsets_cache; // horizontal (x,z) offsets by clearance — grounded occupancy discs
	std::unordered_map<int, std::vector<Vector3i>> sphere_offsets_cache; // full 3D offsets by clearance — flying occupancy (see sphere_offsets)

	void ensure_project_scanned(SceneTree *tree);
	void collect_static_shapes(Node *node, std::vector<CollisionShape3D *> &out);
	AABB shape_global_aabb(CollisionShape3D *cs);
	AABB transform_aabb(const Transform3D &t, const AABB &aabb);

	Vector3 cell_center(const Vector3i &cell) const;
	int cell_index(const Vector3i &cell) const; // global bijection over grid_size — A* bookkeeping keys only
	Vector3i cell_from_index(int idx) const;
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
	void rasterize_chunk(const Vector3i &chunk_coord, NavChunk &chunk);
	void bake_chunk_support(const Vector3i &chunk_coord, NavChunk &chunk);
	void bake_chunk_dist(const Vector3i &chunk_coord, NavChunk &chunk);

	bool is_solid(const Vector3i &cell);
	bool cell_no_support(const Vector3i &cell);
	float cell_clearance_world(const Vector3i &cell);

	static int clearance_key(float clearance);
	const std::vector<Vector3i> &disc_offsets(float clearance);
	const std::vector<Vector3i> &sphere_offsets(float clearance);

	Object *occupant_at(const Vector3i &cell) const;
	void set_occupant(const Vector3i &cell, Object *obj);

	bool is_clear_of_units(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, Object *self_unit) const;
	bool is_valid_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *self_unit);

	struct NearestResult {
		bool found;
		Vector3i cell;
	};
	NearestResult find_nearest_free_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *self_unit, int max_radius);

	void ensure_neighbor_offsets();
	static float heuristic(const Vector3i &a, const Vector3i &b);
	static float coarse_heuristic(const Vector3i &a, const Vector3i &b);

	// Cheap chunk-level A* (using only the support-tier coarse flags) that
	// returns a chunk_coord_index -> allowed flat mask covering
	// CORRIDOR_RADIUS_CHUNKS around an approximate route from start to
	// goal, or an empty vector if none was found. A flat mask rather than
	// a hash set for the same reason as astar_g_score above — chunk counts
	// are small, so this is cheap to allocate fresh per query. Deliberately
	// optimistic/approximate — see find_path for why that's safe (a failed
	// corridor-restricted fine search always falls back to an unrestricted
	// one, so this can only affect speed).
	std::vector<uint8_t> coarse_corridor(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying);

	PackedVector3Array a_star(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *unit, const std::vector<uint8_t> *allowed_chunks_mask);
	PackedVector3Array reconstruct_path(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell);
	PackedVector3Array smooth_path(const PackedVector3Array &path, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *unit);
	bool line_clear(const Vector3 &a, const Vector3 &b, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *unit);

	// Reads a float property off a duck-typed GDScript "Unit" instance
	// (radius, avoidance_margin, flight_target_altitude) — everything in
	// the "units"/"blocking_corpses" groups is a Unit-scripted node by
	// this codebase's own hard invariant (only Unit._ready() ever calls
	// add_to_group("units")), so this trusts that rather than re-deriving
	// a type check GDScript's own "as Unit" cast already gave up on
	// duck-typing for elsewhere in this port.
	static float get_float_prop(Object *obj, const StringName &name);
	static bool call_bool(Object *obj, const StringName &method);
};

} // namespace godot

#endif // NAVIGATION_GRID_H
