#ifndef NAVIGATION_GRID_H
#define NAVIGATION_GRID_H
// C++ port of navigation_grid.gd — see that file's own header (still
// present in git history) for the full design rationale: one shared 3D
// grid for ground+flight, static geometry baked once, dynamic occupancy
// rebuilt per turn. This class is registered as an Engine singleton named
// "NavigationGrid" (see register_types.cpp) so every existing GDScript
// call site (unit_movement.gd, movement_indicator.gd, combat_manager.gd,
// knockback_effect.gd, ground_point_targeting.gd, unit.gd) keeps calling
// NavigationGrid.find_path(...)/update_occupancy(...)/etc. completely
// unchanged — only the implementation moved from GDScript to native code.
//
// Internal data structures deliberately do NOT mirror the GDScript
// version's Dictionary<Vector3i, X> choices — those were tuned around
// GDScript-interpreter-specific overhead (see navigation_grid.gd's own
// A* comment: a flat-array rewrite measured SLOWER in GDScript because of
// redundant per-call overhead unique to the interpreter). That tradeoff
// doesn't apply to compiled C++, where flat, integer-indexed arrays and
// std::unordered_map keyed by a plain int cell index are straightforwardly
// faster than hashing a 3-int struct — so that's what's used here instead.

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
#include <cstdint>

namespace godot {

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

	Vector3 bounds_origin;
	Vector3i grid_size;
	std::vector<uint8_t> solid;
	std::vector<uint8_t> no_support;
	bool baked = false;

	// cell index -> occupying unit/corpse Object*, matching the GDScript
	// version's Dictionary<Vector3i, Unit> semantics exactly (a raw,
	// non-owning reference — occupancy is rebuilt every turn boundary, so
	// a stale pointer from a freed unit is never read across a boundary
	// where that could matter, same as the GDScript version's own
	// Variant-held Node reference).
	std::unordered_map<int, Object *> occupied;

	std::vector<Vector3i> neighbor_offsets;

	std::unordered_map<int, std::vector<Vector3i>> disc_offsets_cache;
	std::unordered_map<int, std::vector<uint8_t>> inflated_solid_cache;

	void bake_static(SceneTree *tree);
	void bake_no_support();
	void collect_static_shapes(Node *node, std::vector<CollisionShape3D *> &out);
	AABB shape_global_aabb(CollisionShape3D *cs);
	AABB transform_aabb(const Transform3D &t, const AABB &aabb);
	void rasterize_shape(CollisionShape3D *cs);

	Vector3 cell_center(const Vector3i &cell) const;
	int cell_index(const Vector3i &cell) const;
	Vector3i cell_from_index(int idx) const;
	bool in_bounds(const Vector3i &cell) const;
	bool is_solid(const Vector3i &cell) const;

	static int clearance_key(float clearance);
	const std::vector<Vector3i> &disc_offsets(float clearance);
	const std::vector<uint8_t> &get_inflated_solid(float clearance, const std::vector<Vector3i> &offsets);
	bool is_clear_of_units(const Vector3i &cell, const std::vector<Vector3i> &offsets, Object *self_unit) const;
	bool is_valid_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *self_unit);

	struct NearestResult {
		bool found;
		Vector3i cell;
	};
	NearestResult find_nearest_free_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *self_unit, int max_radius);

	void ensure_neighbor_offsets();
	static float heuristic(const Vector3i &a, const Vector3i &b);
	PackedVector3Array a_star(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *unit);
	PackedVector3Array reconstruct_path(const std::unordered_map<int, int> &came_from, const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell);
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
