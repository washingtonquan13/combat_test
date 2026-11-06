#include "navigation_grid.h"

#include <godot_cpp/classes/animatable_body3d.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/capsule_shape3d.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/convex_polygon_shape3d.hpp>
#include <godot_cpp/classes/cylinder_shape3d.hpp>
#include <godot_cpp/classes/height_map_shape3d.hpp>
#include <godot_cpp/classes/sphere_shape3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <queue>
#include <utility>

using namespace godot;

namespace {
Vector3 vmin(const Vector3 &a, const Vector3 &b) {
	return Vector3(std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z));
}
Vector3 vmax(const Vector3 &a, const Vector3 &b) {
	return Vector3(std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z));
}
} // namespace

NavigationGrid::NavigationGrid() {}
NavigationGrid::~NavigationGrid() {}

static bool ramp_of(CollisionShape3D *cs, float max_degrees, float cell_size, int reach_cells, RampInfo &slope);

void NavigationGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("ensure_baked", "tree"), &NavigationGrid::ensure_baked);
	ClassDB::bind_method(D_METHOD("invalidate"), &NavigationGrid::invalidate);
	ClassDB::bind_method(D_METHOD("register_world", "root"), &NavigationGrid::register_world);
	ClassDB::bind_method(D_METHOD("unregister_world", "root"), &NavigationGrid::unregister_world);
	ClassDB::bind_method(D_METHOD("nearest_valid_point", "tree", "point", "clearance", "flying", "exclude_unit", "max_radius_cells", "world_ref", "ignore"), &NavigationGrid::nearest_valid_point, DEFVAL(Variant()), DEFVAL(12), DEFVAL(Variant()), DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("find_path", "tree", "start", "destination", "unit", "flying", "ignore"), &NavigationGrid::find_path, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("occupancy_version", "tree", "world_ref"), &NavigationGrid::occupancy_version, DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("world_to_cell", "pos"), &NavigationGrid::world_to_cell);

	ClassDB::bind_method(D_METHOD("get_cell_size"), &NavigationGrid::get_cell_size);
	ClassDB::bind_method(D_METHOD("get_flight_min_altitude"), &NavigationGrid::get_flight_min_altitude);
	ClassDB::bind_method(D_METHOD("get_flight_ceiling_height"), &NavigationGrid::get_flight_ceiling_height);
	ClassDB::bind_method(D_METHOD("flight_floor_at", "tree", "pos", "world_ref"), &NavigationGrid::flight_floor_at, DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("flight_lowest_altitude", "tree", "world_ref"), &NavigationGrid::flight_lowest_altitude, DEFVAL(Variant()));

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "CELL_SIZE"), "", "get_cell_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "FLIGHT_MIN_ALTITUDE"), "", "get_flight_min_altitude");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "FLIGHT_CEILING_HEIGHT"), "", "get_flight_ceiling_height");
}

float NavigationGrid::get_cell_size() const { return CELL_SIZE; }
float NavigationGrid::get_flight_min_altitude() const { return FLIGHT_MIN_ALTITUDE; }
float NavigationGrid::get_flight_ceiling_height() const { return FLIGHT_CEILING_HEIGHT; }

// The lowest feet height a flier may take at pos's XZ: FLIGHT_MIN_ALTITUDE
// above the first solid at or below pos (pos inside solid climbs out of it
// first). Callers clamp an altitude up to this, so a pit floor at y=-6
// allows -5 while ground at y=0 still allows 1.
float NavigationGrid::flight_floor_at(SceneTree *tree, Vector3 pos, Object *world_ref) {
	activate_for(world_ref);
	ensure_baked(tree);
	Vector3i cell = world_to_cell(pos);
	cell.x = std::clamp(cell.x, 0, grid_size.x - 1);
	cell.z = std::clamp(cell.z, 0, grid_size.z - 1);
	cell.y = std::clamp(cell.y, 0, grid_size.y - 1);
	while (cell.y < grid_size.y - 1 && is_solid(cell)) {
		cell.y++;
	}
	while (cell.y > 0 && !is_solid(cell - Vector3i(0, 1, 0))) {
		cell.y--;
	}
	return bounds_origin.y + (float)cell.y * CELL_SIZE + FLIGHT_MIN_ALTITUDE;
}

// The lowest altitude a flier may take anywhere in this world: the bottom
// of its geometry plus FLIGHT_MIN_ALTITUDE. The altitude plane, which has
// no single XZ, clamps to this; the move query then lifts to the floor at
// its own destination (flight_floor_at).
float NavigationGrid::flight_lowest_altitude(SceneTree *tree, Object *world_ref) {
	activate_for(world_ref);
	ensure_baked(tree);
	return bounds_origin.y + BOUNDS_MARGIN + FLIGHT_MIN_ALTITUDE;
}

// --- Multi-world registry --------------------------------------------
//
// The active world's state lives in this object's own members; every other
// registered world's is parked in `parked_worlds`. Switching worlds swaps
// the two. That is deliberately the whole mechanism: not one line of the
// pathfinding below knows worlds exist, so making the grid per-world could
// not regress a_star, smooth_path, or the chunk lifecycle — the code that
// would have had to change is the code that didn't.
//
// Cheap despite appearances. Every parked member is a vector or an
// unordered_map, so std::swap on each is a pointer exchange rather than a
// copy; activate_world is O(1) and safe to call at the top of every public
// entry point.

void NavigationGrid::register_world(Node *root) {
	if (!root) {
		return;
	}
	uint64_t id = world_id_of(root);
	if (id == 0) {
		return;
	}
	// Fresh state for a world we haven't seen, and remember the root —
	// a World3D cannot be walked back to a node, so the only chance to
	// capture where this world's geometry is scanned from is now.
	if (id != active_world_id && parked_worlds.find(id) == parked_worlds.end()) {
		ParkedWorld fresh;
		fresh.root = root;
		parked_worlds.emplace(id, std::move(fresh));
	} else if (id == active_world_id) {
		active_root = root;
	} else {
		parked_worlds[id].root = root;
	}
}

void NavigationGrid::unregister_world(Node *root) {
	uint64_t id = world_id_of(root);
	if (id == 0) {
		return;
	}
	if (id == active_world_id) {
		// Drop the active world's state outright rather than parking it.
		// all_shapes/shapes_by_chunk hold raw CollisionShape3D* into
		// geometry that is about to be freed; keeping them is precisely
		// the dangling-pointer crash invalidate() existed to paper over.
		all_shapes.clear();
		shapes_by_chunk.clear();
		tri_shapes.clear();
		chunks.clear();
		chunk_occupancy_nearby.clear();
		reset_occupancy();
		baked = false;
		any_occupied = false;
		active_world_id = 0;
		active_root = nullptr;
		return;
	}
	parked_worlds.erase(id);
}

uint64_t NavigationGrid::world_id_of(Object *obj) {
	Node3D *node = Object::cast_to<Node3D>(obj);
	if (!node || !node->is_inside_tree()) {
		return 0;
	}
	Ref<World3D> world = node->get_world_3d();
	if (world.is_null()) {
		return 0;
	}
	return world->get_instance_id();
}

// True when a node belongs to the world currently loaded.
//
// Occupancy scans the WHOLE tree, because "units" and "blocking_corpses"
// are single global groups with no world in them. Without this filter a
// unit standing in one world stamps its cells into another world's grid —
// the same origin-overlap problem the geometry scan has, and worse for
// being invisible: no crash, just a route that swerves around something
// that isn't there.
//
// With no world registered (active_world_id == 0) this accepts
// everything, which is exactly the single-world behaviour that shipped.
bool NavigationGrid::in_active_world(Node3D *node) {
	if (active_world_id == 0) {
		return true;
	}
	if (!node || !node->is_inside_tree()) {
		return false;
	}
	Ref<World3D> world = node->get_world_3d();
	return world.is_valid() && world->get_instance_id() == active_world_id;
}

void NavigationGrid::activate_world(uint64_t world_id) {
	if (world_id == active_world_id) {
		return;
	}

	// Park what's loaded, unless it's the legacy no-world grid (id 0),
	// which nothing will ever ask for again once real worlds register.
	if (active_world_id != 0) {
		ParkedWorld &out = parked_worlds[active_world_id];
		out.bounds_origin = bounds_origin;
		out.grid_size = grid_size;
		out.chunk_grid_size = chunk_grid_size;
		out.baked = baked;
		out.any_occupied = any_occupied;
		out.astar_search_id = astar_search_id;
		out.smooth_search_id = smooth_search_id;
		out.root = active_root;
		out.occupancy_stamped = occupancy_stamped;
		out.occupancy_version = occupancy_version_value;
		std::swap(out.occupied_chunks, occupied_chunks);
		std::swap(out.occupancy_signature, occupancy_signature);
		std::swap(out.chunks, chunks);
		std::swap(out.astar_g_score, astar_g_score);
		std::swap(out.astar_g_gen, astar_g_gen);
		std::swap(out.astar_came_from, astar_came_from);
		std::swap(out.astar_closed_gen, astar_closed_gen);
		std::swap(out.smooth_valid_gen, smooth_valid_gen);
		std::swap(out.smooth_valid_result, smooth_valid_result);
		std::swap(out.all_shapes, all_shapes);
		std::swap(out.shapes_by_chunk, shapes_by_chunk);
		std::swap(out.tri_shapes, tri_shapes);
		std::swap(out.chunk_occupancy_nearby, chunk_occupancy_nearby);
	} else {
		// Leaving the legacy grid behind for good — clear rather than
		// park, so its shape pointers can't outlive their scene.
		chunks.clear();
		all_shapes.clear();
		shapes_by_chunk.clear();
		tri_shapes.clear();
		chunk_occupancy_nearby.clear();
		reset_occupancy();
	}

	active_world_id = world_id;

	auto it = parked_worlds.find(world_id);
	if (it == parked_worlds.end()) {
		// Unknown world: start empty and unbaked. The next ensure_baked
		// scans it for real.
		bounds_origin = Vector3();
		grid_size = Vector3i();
		chunk_grid_size = Vector3i();
		baked = false;
		any_occupied = false;
		astar_search_id = 0;
		smooth_search_id = 0;
		active_root = nullptr;
		chunks.clear();
		astar_g_score.clear();
		astar_g_gen.clear();
		astar_came_from.clear();
		astar_closed_gen.clear();
		smooth_valid_gen.clear();
		smooth_valid_result.clear();
		all_shapes.clear();
		shapes_by_chunk.clear();
		tri_shapes.clear();
		chunk_occupancy_nearby.clear();
		reset_occupancy();
		return;
	}

	ParkedWorld &in = it->second;
	bounds_origin = in.bounds_origin;
	grid_size = in.grid_size;
	chunk_grid_size = in.chunk_grid_size;
	baked = in.baked;
	any_occupied = in.any_occupied;
	astar_search_id = in.astar_search_id;
	smooth_search_id = in.smooth_search_id;
	active_root = in.root;
	occupancy_stamped = in.occupancy_stamped;
	occupancy_version_value = in.occupancy_version;
	std::swap(in.occupied_chunks, occupied_chunks);
	std::swap(in.occupancy_signature, occupancy_signature);
	std::swap(in.chunks, chunks);
	std::swap(in.astar_g_score, astar_g_score);
	std::swap(in.astar_g_gen, astar_g_gen);
	std::swap(in.astar_came_from, astar_came_from);
	std::swap(in.astar_closed_gen, astar_closed_gen);
	std::swap(in.smooth_valid_gen, smooth_valid_gen);
	std::swap(in.smooth_valid_result, smooth_valid_result);
	std::swap(in.all_shapes, all_shapes);
	std::swap(in.shapes_by_chunk, shapes_by_chunk);
	std::swap(in.tri_shapes, tri_shapes);
	std::swap(in.chunk_occupancy_nearby, chunk_occupancy_nearby);
	parked_worlds.erase(it);
}

void NavigationGrid::activate_for(Object *primary, Object *fallback) {
	uint64_t id = world_id_of(primary);
	if (id == 0) {
		id = world_id_of(fallback);
	}
	if (id == 0 && parked_worlds.size() == 1 && active_world_id == 0) {
		// Exactly one world registered and nothing loaded yet — the
		// single-world case, which is every call the game makes today.
		id = parked_worlds.begin()->first;
	}
	if (id == 0) {
		// Nothing identifiable: stay on whatever is loaded. Keeps the
		// editor, tools and any pre-registration call working exactly as
		// they did before worlds existed.
		return;
	}
	activate_world(id);
}

// --- Setup / project scan (cheap — NOT a full bake anymore) ----------------

void NavigationGrid::ensure_baked(SceneTree *tree) {
	if (baked) {
		return;
	}
	ensure_project_scanned(tree);
	baked = true;
}

void NavigationGrid::invalidate() {
	baked = false;
}

void NavigationGrid::ensure_project_scanned(SceneTree *tree) {
	// Cleared here, not just left to accumulate — this function reruns
	// after invalidate(), and both containers are append-only below, so
	// without this a re-scan would keep every dangling pointer from the
	// world that was just freed alongside the new world's real ones.
	all_shapes.clear();
	shapes_by_chunk.clear();
	tri_shapes.clear();

	// The registered world's own root, falling back to the current scene
	// for the pre-registration/editor case. Scanning get_current_scene()
	// unconditionally is what would bake every resident world's geometry
	// into one grid — and since every area here is authored around the
	// origin, that geometry would interleave into nonsense.
	Node *root = active_root ? active_root : tree->get_current_scene();
	if (root) {
		collect_static_shapes(root, all_shapes);
	}
	// Mesh shapes (concave, convex, height map) as their triangles.
	for (CollisionShape3D *cs : all_shapes) {
		auto tri = std::make_shared<TriShape>();
		if (build_tri_shape(cs, *tri)) {
			tri_shapes[cs] = tri;
			continue;
		}
		// Anything else is filled as its bounding box: say so, once, rather
		// than leave an author wondering why a slab of air is solid.
		Shape3D *shape = cs->get_shape().ptr();
		bool primitive = Object::cast_to<BoxShape3D>(shape) || Object::cast_to<SphereShape3D>(shape) || Object::cast_to<CylinderShape3D>(shape) || Object::cast_to<CapsuleShape3D>(shape);
		if (!primitive && warned_shapes.insert(cs->get_instance_id()).second) {
			UtilityFunctions::push_warning("NavigationGrid: ", cs->get_path(), " has a ", shape->get_class(),
					", which the grid fills as its whole bounding box (see docs/systems/navigation_authoring.md).");
		}
	}

	Vector3 world_min, world_max;
	bool have_bounds = false;
	for (CollisionShape3D *cs : all_shapes) {
		AABB aabb = shape_global_aabb(cs);
		if (!have_bounds) {
			world_min = aabb.position;
			world_max = aabb.position + aabb.size;
			have_bounds = true;
		} else {
			world_min = vmin(world_min, aabb.position);
			world_max = vmax(world_max, aabb.position + aabb.size);
		}
	}

	if (!have_bounds) {
		// No static geometry at all — degenerate, but a minimal placeholder
		// volume keeps every query well-defined ("no path") instead of a
		// zero-sized allocation elsewhere.
		world_min = Vector3(-1.0f, -1.0f, -1.0f);
		world_max = Vector3(1.0f, 1.0f, 1.0f);
	}

	world_min -= Vector3(BOUNDS_MARGIN, BOUNDS_MARGIN, BOUNDS_MARGIN);
	world_max += Vector3(BOUNDS_MARGIN, BOUNDS_MARGIN, BOUNDS_MARGIN);
	world_max.y = std::max(world_max.y, FLIGHT_CEILING_HEIGHT + BOUNDS_MARGIN);

	bounds_origin = world_min;
	Vector3 extent = world_max - world_min;
	grid_size = Vector3i(
			(int)std::ceil(extent.x / CELL_SIZE),
			(int)std::ceil(extent.y / CELL_SIZE),
			(int)std::ceil(extent.z / CELL_SIZE));
	chunk_grid_size = Vector3i(
			(grid_size.x + CHUNK_DIM - 1) / CHUNK_DIM,
			(grid_size.y + CHUNK_DIM - 1) / CHUNK_DIM,
			(grid_size.z + CHUNK_DIM - 1) / CHUNK_DIM);

	chunks.clear();
	chunks.resize((size_t)chunk_grid_size.x * (size_t)chunk_grid_size.y * (size_t)chunk_grid_size.z);
	chunk_occupancy_nearby.assign(chunks.size(), 0);
	// Fresh, empty chunks: whatever occupancy was stamped went with the
	// old ones, so the next query must restamp even if nobody moved.
	reset_occupancy();
	any_occupied = false;

	size_t total_cells = (size_t)grid_size.x * (size_t)grid_size.y * (size_t)grid_size.z;
	astar_g_score.assign(total_cells, 0.0f);
	astar_g_gen.assign(total_cells, 0);
	astar_came_from.assign(total_cells, -1);
	astar_closed_gen.assign(total_cells, 0);
	astar_search_id = 0;

	smooth_valid_gen.assign(total_cells, 0);
	smooth_valid_result.assign(total_cells, 0);
	smooth_search_id = 0;

	// Bucket every shape by each chunk its AABB overlaps, so a lazy
	// rasterize of one chunk only tests the shapes that could matter.
	for (CollisionShape3D *cs : all_shapes) {
		AABB aabb = shape_global_aabb(cs);
		// A ramp marks ground past its own box (ramp_of), in chunks it
		// may not otherwise touch.
		// So does a mesh with walkable slopes (mark_tri_ground).
		RampInfo ramp;
		auto tri = tri_shapes.find(cs);
		if (tri != tri_shapes.end()) {
			index_tri_columns(*tri->second);
		}
		if (ramp_of(cs, MAX_WALKABLE_SLOPE_DEGREES, CELL_SIZE, MAX_CLEARANCE_CELLS, ramp) || (tri != tri_shapes.end() && tri->second->any_walkable)) {
			aabb = aabb.grow(MAX_CLEARANCE_CELLS * CELL_SIZE);
		}
		Vector3i min_cell = world_to_cell(aabb.position);
		Vector3i max_cell = world_to_cell(aabb.position + aabb.size);
		min_cell = Vector3i(std::max(min_cell.x, 0), std::max(min_cell.y, 0), std::max(min_cell.z, 0));
		max_cell = Vector3i(std::min(max_cell.x, grid_size.x - 1), std::min(max_cell.y, grid_size.y - 1), std::min(max_cell.z, grid_size.z - 1));
		if (max_cell.x < min_cell.x || max_cell.y < min_cell.y || max_cell.z < min_cell.z) {
			continue;
		}
		Vector3i min_chunk = cell_to_chunk_coord(min_cell);
		Vector3i max_chunk = cell_to_chunk_coord(max_cell);
		for (int cx = min_chunk.x; cx <= max_chunk.x; cx++) {
			for (int cy = min_chunk.y; cy <= max_chunk.y; cy++) {
				for (int cz = min_chunk.z; cz <= max_chunk.z; cz++) {
					Vector3i cc(cx, cy, cz);
					if (chunk_in_bounds(cc)) {
						shapes_by_chunk[chunk_coord_index(cc)].push_back(cs);
					}
				}
			}
		}
	}

	seal_interiors();
}

void NavigationGrid::collect_static_shapes(Node *node, std::vector<CollisionShape3D *> &out) {
	// Only what the physics world itself collides with is geometry: a body
	// on no collision layer is touched by nothing, and a disabled shape is
	// not there at all. The project names no world-geometry layer (units,
	// props and level share layer 1), so the layer test is "any layer".
	// An AnimatableBody3D is a StaticBody3D that moves, and the bake is a
	// snapshot, so it is not geometry either.
	StaticBody3D *sb = Object::cast_to<StaticBody3D>(node);
	if (sb && sb->get_collision_layer() != 0 && !Object::cast_to<AnimatableBody3D>(node)) {
		int count = sb->get_child_count();
		for (int i = 0; i < count; i++) {
			CollisionShape3D *cs = Object::cast_to<CollisionShape3D>(sb->get_child(i));
			if (cs && !cs->is_disabled() && cs->get_shape().is_valid()) {
				out.push_back(cs);
			}
		}
	}
	int count = node->get_child_count();
	for (int i = 0; i < count; i++) {
		collect_static_shapes(node->get_child(i), out);
	}
}

AABB NavigationGrid::shape_global_aabb(CollisionShape3D *cs) {
	Ref<Shape3D> shape = cs->get_shape();
	AABB local_aabb;
	BoxShape3D *box = Object::cast_to<BoxShape3D>(shape.ptr());
	if (box) {
		Vector3 size = box->get_size();
		local_aabb = AABB(size * -0.5f, size);
	} else if (SphereShape3D *sphere = Object::cast_to<SphereShape3D>(shape.ptr())) {
		float r = sphere->get_radius();
		local_aabb = AABB(Vector3(-r, -r, -r), Vector3(r, r, r) * 2.0f);
	} else if (CylinderShape3D *cylinder = Object::cast_to<CylinderShape3D>(shape.ptr())) {
		float r = cylinder->get_radius(), h = cylinder->get_height() * 0.5f;
		local_aabb = AABB(Vector3(-r, -h, -r), Vector3(r, h, r) * 2.0f);
	} else if (CapsuleShape3D *capsule = Object::cast_to<CapsuleShape3D>(shape.ptr())) {
		float r = capsule->get_radius(), h = std::max(capsule->get_height() * 0.5f, r);
		local_aabb = AABB(Vector3(-r, -h, -r), Vector3(r, h, r) * 2.0f);
	} else {
		auto tri = tri_shapes.find(cs);
		if (tri != tri_shapes.end()) {
			return tri->second->aabb; // already world space
		}
		Ref<ArrayMesh> mesh = shape->get_debug_mesh();
		if (mesh.is_valid()) {
			local_aabb = mesh->get_aabb();
		}
	}
	return transform_aabb(cs->get_global_transform(), local_aabb);
}

AABB NavigationGrid::transform_aabb(const Transform3D &t, const AABB &aabb) {
	AABB result(t.xform(aabb.position), Vector3());
	for (int i = 0; i < 8; i++) {
		Vector3 corner = aabb.position + Vector3(
														 (i & 1) ? aabb.size.x : 0.0f,
														 (i & 2) ? aabb.size.y : 0.0f,
														 (i & 4) ? aabb.size.z : 0.0f);
		result = result.expand(t.xform(corner));
	}
	return result;
}

// --- Mesh shapes as triangles ------------------------------------------------

namespace {
// A triangle a unit walks on: facing up, no steeper than the body climbs,
// and tilted at all (a flat top is an ordinary floor or step, as for boxes).
bool tri_walkable(const Vector3 &n, float max_degrees, float &tan_tilt) {
	if (n.y < std::cos(max_degrees * (float)Math_PI / 180.0f) || n.y >= std::cos(1.0f * (float)Math_PI / 180.0f)) {
		return false;
	}
	tan_tilt = std::sqrt(std::max(0.0f, 1.0f - n.y * n.y)) / n.y;
	return true;
}

// Akenine-Moller triangle / axis-aligned box overlap.
bool tri_box_overlap(const Vector3 &centre, const Vector3 &half, const Vector3 &a, const Vector3 &b, const Vector3 &c) {
	Vector3 v[3] = { a - centre, b - centre, c - centre };
	Vector3 e[3] = { v[1] - v[0], v[2] - v[1], v[0] - v[2] };
	for (int i = 0; i < 3; i++) {
		for (int k = 0; k < 3; k++) {
			Vector3 unit_axis((float)(k == 0), (float)(k == 1), (float)(k == 2));
			Vector3 axis = unit_axis.cross(e[i]);
			float p0 = axis.dot(v[0]), p1 = axis.dot(v[1]), p2 = axis.dot(v[2]);
			float r = half.x * std::abs(axis.x) + half.y * std::abs(axis.y) + half.z * std::abs(axis.z);
			if (std::min({ p0, p1, p2 }) > r || std::max({ p0, p1, p2 }) < -r) {
				return false;
			}
		}
	}
	for (int k = 0; k < 3; k++) {
		float lo = std::min({ v[0][k], v[1][k], v[2][k] });
		float hi = std::max({ v[0][k], v[1][k], v[2][k] });
		if (lo > half[k] || hi < -half[k]) {
			return false;
		}
	}
	Vector3 n = e[0].cross(e[1]);
	float r = half.x * std::abs(n.x) + half.y * std::abs(n.y) + half.z * std::abs(n.z);
	return std::abs(n.dot(v[0])) <= r;
}

inline float cross2(float ax, float az, float bx, float bz) {
	return ax * bz - az * bx;
}

// Height of the triangle's plane over (x, z).
inline float plane_height(const Vector3 &a, const Vector3 &n, float x, float z) {
	return a.y - (n.x * (x - a.x) + n.z * (z - a.z)) / n.y;
}

uint64_t vertex_key(const Vector3 &p) {
	auto q = [](float f) -> uint64_t {
		int64_t i = (int64_t)std::llround(f / 0.01f) + (1 << 20);
		return (uint64_t)std::max<int64_t>(0, std::min<int64_t>(i, (1 << 21) - 1));
	};
	return (q(p.x) << 42) | (q(p.y) << 21) | q(p.z);
}

// A convex hull's faces from its points, with outward normals. Brute
// force over point triples: fine for the few dozen points a convex
// collision shape has.
bool hull_triangles(const std::vector<Vector3> &in, std::vector<Vector3> &verts, std::vector<Vector3> &normals) {
	std::vector<Vector3> pts;
	for (const Vector3 &p : in) {
		bool dup = false;
		for (const Vector3 &q : pts) {
			if (p.distance_squared_to(q) < 1e-8f) {
				dup = true;
				break;
			}
		}
		if (!dup) {
			pts.push_back(p);
		}
	}
	int n = (int)pts.size();
	if (n < 4 || n > 160) {
		return false;
	}
	Vector3 lo = pts[0], hi = pts[0];
	for (const Vector3 &p : pts) {
		lo = Vector3(std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z));
		hi = Vector3(std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z));
	}
	float eps = 1e-4f * std::max(1.0f, (hi - lo).length());
	std::vector<std::pair<Vector3, float>> planes;
	for (int i = 0; i < n; i++) {
		for (int j = i + 1; j < n; j++) {
			for (int k = j + 1; k < n; k++) {
				Vector3 nn = (pts[j] - pts[i]).cross(pts[k] - pts[i]);
				float len = nn.length();
				if (len < 1e-9f) {
					continue;
				}
				nn /= len;
				float d = nn.dot(pts[i]);
				bool any_above = false, any_below = false;
				for (const Vector3 &p : pts) {
					float s = nn.dot(p) - d;
					any_above |= s > eps;
					any_below |= s < -eps;
				}
				if (any_above && any_below) {
					continue;
				}
				if (any_above) {
					nn = -nn;
					d = -d;
				}
				bool seen = false;
				for (const auto &pl : planes) {
					if (pl.first.dot(nn) > 1.0f - 1e-5f && std::abs(pl.second - d) < eps) {
						seen = true;
						break;
					}
				}
				if (!seen) {
					planes.push_back({ nn, d });
				}
			}
		}
	}
	for (const auto &pl : planes) {
		std::vector<Vector3> face;
		for (const Vector3 &p : pts) {
			if (std::abs(pl.first.dot(p) - pl.second) <= eps) {
				face.push_back(p);
			}
		}
		if (face.size() < 3) {
			continue;
		}
		// The face's outline (monotone chain in the plane), so points
		// inside it or along its edges never join the fan.
		Vector3 u = std::abs(pl.first.x) < 0.9f ? Vector3(1, 0, 0).cross(pl.first).normalized() : Vector3(0, 1, 0).cross(pl.first).normalized();
		Vector3 w = pl.first.cross(u);
		auto pu = [&](const Vector3 &p) { return p.dot(u); };
		auto pw = [&](const Vector3 &p) { return p.dot(w); };
		std::sort(face.begin(), face.end(), [&](const Vector3 &p, const Vector3 &q) {
			return pu(p) != pu(q) ? pu(p) < pu(q) : pw(p) < pw(q);
		});
		auto turn = [&](const Vector3 &o, const Vector3 &p, const Vector3 &q) {
			return cross2(pu(p) - pu(o), pw(p) - pw(o), pu(q) - pu(o), pw(q) - pw(o));
		};
		std::vector<Vector3> ring(face.size() * 2);
		size_t m = 0;
		for (size_t i = 0; i < face.size(); i++) {
			while (m >= 2 && turn(ring[m - 2], ring[m - 1], face[i]) <= eps * eps) {
				m--;
			}
			ring[m++] = face[i];
		}
		for (size_t i = face.size() - 1, lower = m + 1; i-- > 0;) {
			while (m >= lower && turn(ring[m - 2], ring[m - 1], face[i]) <= eps * eps) {
				m--;
			}
			ring[m++] = face[i];
		}
		ring.resize(m > 0 ? m - 1 : 0);
		for (size_t i = 1; i + 1 < ring.size(); i++) {
			// Wound so (c - a) x (b - a) is the outward normal.
			Vector3 a = ring[0], b = ring[i], c = ring[i + 1];
			if ((c - a).cross(b - a).dot(pl.first) < 0.0f) {
				std::swap(b, c);
			}
			verts.push_back(a);
			verts.push_back(b);
			verts.push_back(c);
			normals.push_back(pl.first);
		}
	}
	return !normals.empty();
}
} // namespace

bool NavigationGrid::build_tri_shape(CollisionShape3D *cs, TriShape &out) {
	Ref<Shape3D> shape = cs->get_shape();
	Transform3D t = cs->get_global_transform();
	// A mirroring transform turns the winding inside out.
	float handedness = t.basis.determinant() < 0.0f ? -1.0f : 1.0f;
	auto add = [&](const Vector3 &la, const Vector3 &lb, const Vector3 &lc) {
		Vector3 a = t.xform(la), b = t.xform(lb), c = t.xform(lc);
		// Godot's front face is clockwise: its normal is (c - a) x (b - a).
		Vector3 n = (c - a).cross(b - a) * handedness;
		float len = n.length();
		if (!(len > 1e-12f)) {
			return;
		}
		out.verts.push_back(a);
		out.verts.push_back(b);
		out.verts.push_back(c);
		out.normals.push_back(n / len);
	};
	bool closed_kind = false;
	if (ConcavePolygonShape3D *concave = Object::cast_to<ConcavePolygonShape3D>(shape.ptr())) {
		PackedVector3Array faces = concave->get_faces();
		for (int64_t i = 0; i + 2 < faces.size(); i += 3) {
			add(faces[i], faces[i + 1], faces[i + 2]);
		}
		closed_kind = true;
	} else if (ConvexPolygonShape3D *convex = Object::cast_to<ConvexPolygonShape3D>(shape.ptr())) {
		PackedVector3Array points = convex->get_points();
		std::vector<Vector3> world;
		for (int64_t i = 0; i < points.size(); i++) {
			world.push_back(t.xform(points[i]));
		}
		if (!hull_triangles(world, out.verts, out.normals)) {
			return false;
		}
	} else if (HeightMapShape3D *height_map = Object::cast_to<HeightMapShape3D>(shape.ptr())) {
		int w = height_map->get_map_width();
		int d = height_map->get_map_depth();
		PackedFloat32Array data = height_map->get_map_data();
		if (w < 2 || d < 2 || data.size() < (int64_t)w * d) {
			return false;
		}
		auto at = [&](int x, int z) {
			return Vector3(x - (w - 1) * 0.5f, data[(int64_t)z * w + x], z - (d - 1) * 0.5f);
		};
		for (int z = 0; z + 1 < d; z++) {
			for (int x = 0; x + 1 < w; x++) {
				Vector3 v00 = at(x, z), v10 = at(x + 1, z), v01 = at(x, z + 1), v11 = at(x + 1, z + 1);
				if (std::isnan(v00.y) || std::isnan(v10.y) || std::isnan(v01.y) || std::isnan(v11.y)) {
					continue; // a hole
				}
				size_t before = out.normals.size();
				add(v00, v10, v11);
				add(v00, v11, v01);
				// A height field faces up whatever order its corners came in.
				for (size_t i = before; i < out.normals.size(); i++) {
					if (out.normals[i].y < 0.0f) {
						out.normals[i] = -out.normals[i];
					}
				}
			}
		}
	} else {
		return false;
	}
	size_t count = out.normals.size();
	if (count == 0) {
		return false;
	}

	std::unordered_map<uint64_t, int> vertex_ids;
	auto vid = [&](const Vector3 &p) {
		auto it = vertex_ids.emplace(vertex_key(p), (int)vertex_ids.size());
		return (uint64_t)it.first->second;
	};
	std::vector<uint64_t> edges(count * 3);
	std::unordered_map<uint64_t, int> edge_uses;
	for (size_t i = 0; i < count; i++) {
		uint64_t ids[3] = { vid(out.verts[i * 3]), vid(out.verts[i * 3 + 1]), vid(out.verts[i * 3 + 2]) };
		for (int k = 0; k < 3; k++) {
			uint64_t p = ids[k], q = ids[(k + 1) % 3];
			edges[i * 3 + k] = (std::min(p, q) << 32) | std::max(p, q);
			edge_uses[edges[i * 3 + k]]++;
		}
	}
	// A closed mesh wound inside out (negative volume) is flipped, so its
	// normals point out of the solid either way.
	if (closed_kind) {
		bool closed = true;
		for (const auto &e : edge_uses) {
			closed &= e.second == 2;
		}
		float volume = 0.0f;
		for (size_t i = 0; i < count; i++) {
			const Vector3 &a = out.verts[i * 3], &b = out.verts[i * 3 + 1], &c = out.verts[i * 3 + 2];
			volume += ((a + b + c) / 3.0f).dot(out.normals[i]) * (b - a).cross(c - a).length();
		}
		if (closed && volume < 0.0f) {
			for (Vector3 &n : out.normals) {
				n = -n;
			}
		}
	}

	std::vector<uint8_t> walkable(count, 0);
	std::unordered_map<uint64_t, int> walkable_uses;
	for (size_t i = 0; i < count; i++) {
		float tan_tilt;
		if (tri_walkable(out.normals[i], MAX_WALKABLE_SLOPE_DEGREES, tan_tilt)) {
			walkable[i] = 1;
			out.any_walkable = true;
			for (int k = 0; k < 3; k++) {
				walkable_uses[edges[i * 3 + k]]++;
			}
		}
	}
	out.open_edge.assign(count, 0);
	out.outer_edge.assign(count * 3, 0);
	for (size_t i = 0; i < count; i++) {
		if (walkable[i]) {
			for (int k = 0; k < 3; k++) {
				if (walkable_uses[edges[i * 3 + k]] < 2) {
					out.open_edge[i] = 1;
					out.outer_edge[i * 3 + k] = 1;
				}
			}
		}
	}

	out.aabb = AABB(out.verts[0], Vector3());
	for (const Vector3 &v : out.verts) {
		out.aabb = out.aabb.expand(v);
	}
	return true;
}

void NavigationGrid::index_tri_columns(TriShape &tri) {
	float reach = MAX_CLEARANCE_CELLS * CELL_SIZE;
	size_t count = tri.normals.size();
	for (size_t i = 0; i < count; i++) {
		const Vector3 &a = tri.verts[i * 3], &b = tri.verts[i * 3 + 1], &c = tri.verts[i * 3 + 2];
		float x0 = std::min({ a.x, b.x, c.x }), x1 = std::max({ a.x, b.x, c.x });
		float z0 = std::min({ a.z, b.z, c.z }), z1 = std::max({ a.z, b.z, c.z });
		if (tri.open_edge[i]) {
			x0 -= reach;
			x1 += reach;
			z0 -= reach;
			z1 += reach;
		}
		Vector3i lo = world_to_cell(Vector3(x0, 0.0f, z0));
		Vector3i hi = world_to_cell(Vector3(x1, 0.0f, z1));
		lo.x = std::max(0, lo.x);
		lo.z = std::max(0, lo.z);
		hi.x = std::min(grid_size.x - 1, hi.x);
		hi.z = std::min(grid_size.z - 1, hi.z);
		if (hi.x < lo.x || hi.z < lo.z) {
			continue;
		}
		for (int cx = lo.x / CHUNK_DIM; cx <= hi.x / CHUNK_DIM; cx++) {
			for (int cz = lo.z / CHUNK_DIM; cz <= hi.z / CHUNK_DIM; cz++) {
				tri.by_column[cx * chunk_grid_size.z + cz].push_back((int)i);
			}
		}
	}
}

// Solid from a mesh's triangles, sampled at cell centres the way boxes
// are: each column of cells up through the chunk crosses the mesh's
// faces, and runs from a face looking down (into the solid) to the next
// looking up (out of it) are solid. An up-facing face with nothing under
// it (terrain, an open floor) is solid down to the shape's bottom, and a
// run thinner than a cell keeps one cell. Steep faces also mark every
// cell they pass through, so a thin open wall still blocks.
void NavigationGrid::rasterize_tri_shape(const TriShape &tri, const Vector3i &chunk_coord, NavChunk &chunk, std::vector<std::pair<const TriShape *, int>> &walkable) {
	auto col = tri.by_column.find(chunk_coord.x * chunk_grid_size.z + chunk_coord.z);
	if (col == tri.by_column.end()) {
		return;
	}
	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);
	// Off the cell centres by a hair, so a column never runs exactly down
	// an edge two triangles share and counts both or neither.
	const float JX = 1.37e-4f, JZ = 2.91e-4f;
	auto first_centre = [&](float v, float origin) { return (int)std::ceil((v - origin) / CELL_SIZE - 0.5f); };
	auto last_centre = [&](float v, float origin) { return (int)std::floor((v - origin) / CELL_SIZE - 0.5f); };
	auto clampi = [](int v, int lo, int hi) { return std::max(lo, std::min(v, hi)); };

	struct Hit {
		int column;
		float h;
		bool enters;
	};
	std::vector<Hit> hits;
	Vector3 half = Vector3(CELL_SIZE, CELL_SIZE, CELL_SIZE) * 0.49f;
	for (int id : col->second) {
		const Vector3 &a = tri.verts[id * 3], &b = tri.verts[id * 3 + 1], &c = tri.verts[id * 3 + 2];
		const Vector3 &n = tri.normals[id];
		float tan_tilt;
		if (tri_walkable(n, MAX_WALKABLE_SLOPE_DEGREES, tan_tilt)) {
			walkable.push_back({ &tri, id });
		}
		if (std::abs(n.y) > 1e-4f) {
			int x0 = std::max(base.x, first_centre(std::min({ a.x, b.x, c.x }), bounds_origin.x));
			int x1 = std::min(base.x + cx1 - 1, last_centre(std::max({ a.x, b.x, c.x }), bounds_origin.x));
			int z0 = std::max(base.z, first_centre(std::min({ a.z, b.z, c.z }), bounds_origin.z));
			int z1 = std::min(base.z + cz1 - 1, last_centre(std::max({ a.z, b.z, c.z }), bounds_origin.z));
			for (int x = x0; x <= x1; x++) {
				float px = bounds_origin.x + (x + 0.5f) * CELL_SIZE + JX;
				for (int z = z0; z <= z1; z++) {
					float pz = bounds_origin.z + (z + 0.5f) * CELL_SIZE + JZ;
					float d1 = cross2(b.x - a.x, b.z - a.z, px - a.x, pz - a.z);
					float d2 = cross2(c.x - b.x, c.z - b.z, px - b.x, pz - b.z);
					float d3 = cross2(a.x - c.x, a.z - c.z, px - c.x, pz - c.z);
					bool inside = (d1 >= 0.0f && d2 >= 0.0f && d3 >= 0.0f) || (d1 <= 0.0f && d2 <= 0.0f && d3 <= 0.0f);
					if (inside) {
						hits.push_back({ (x - base.x) * CHUNK_DIM + (z - base.z), plane_height(a, n, px, pz), n.y < 0.0f });
					}
				}
			}
		}
		// Any face too steep to walk, not just near-vertical ones: steeper
		// than 45 degrees, neighbouring columns cross it more than a cell
		// apart, and the cells between would leave a crack the outside
		// leaks through into a hollow (see seal_interiors).
		if (std::abs(n.y) < std::cos(MAX_WALKABLE_SLOPE_DEGREES * (float)Math_PI / 180.0f)) {
			Vector3i lo = world_to_cell(Vector3(std::min({ a.x, b.x, c.x }), std::min({ a.y, b.y, c.y }), std::min({ a.z, b.z, c.z })));
			Vector3i hi = world_to_cell(Vector3(std::max({ a.x, b.x, c.x }), std::max({ a.y, b.y, c.y }), std::max({ a.z, b.z, c.z })));
			int fx0 = std::max(base.x, lo.x), fx1 = std::min(base.x + cx1 - 1, hi.x);
			int fy0 = std::max(base.y, lo.y), fy1 = std::min(base.y + cy1 - 1, hi.y);
			int fz0 = std::max(base.z, lo.z), fz1 = std::min(base.z + cz1 - 1, hi.z);
			for (int x = fx0; x <= fx1; x++) {
				for (int y = fy0; y <= fy1; y++) {
					for (int z = fz0; z <= fz1; z++) {
						Vector3i cell(x, y, z);
						if (tri_box_overlap(cell_center(cell), half, a, b, c)) {
							chunk.solid[local_index(cell - base)] = 1;
						}
					}
				}
			}
		}
	}

	std::sort(hits.begin(), hits.end(), [](const Hit &p, const Hit &q) {
		return p.column != q.column ? p.column < q.column : p.h < q.h;
	});
	auto fill = [&](int column, float lo, float hi) {
		int lx = column / CHUNK_DIM, lz = column % CHUNK_DIM;
		int y0 = first_centre(lo, bounds_origin.y), y1 = last_centre(hi, bounds_origin.y);
		if (y1 < y0) {
			y0 = y1 = (int)std::floor(((lo + hi) * 0.5f - bounds_origin.y) / CELL_SIZE);
		}
		y0 = clampi(y0, base.y, base.y + cy1);
		y1 = clampi(y1, base.y - 1, base.y + cy1 - 1);
		for (int y = y0; y <= y1; y++) {
			chunk.solid[local_index(Vector3i(lx, y - base.y, lz))] = 1;
		}
	};
	for (size_t i = 0; i < hits.size();) {
		size_t j = i;
		bool open = false;
		float start = 0.0f;
		bool below = false; // a run already closed lower in this column
		for (; j < hits.size() && hits[j].column == hits[i].column; j++) {
			const Hit &hit = hits[j];
			if (hit.enters) {
				if (!open) {
					open = true;
					start = hit.h;
				}
			} else {
				// An up-facing face with nothing opened under it: the first
				// is ground down to the shape's bottom; one over a run
				// already closed (a bridge deck over the terrain of the same
				// mesh) is only its own cell, leaving the gap open.
				fill(hit.column, open ? start : (below ? hit.h : tri.aabb.position.y), hit.h);
				open = false;
				below = true;
			}
		}
		if (open) {
			fill(hits[i].column, start, start);
		}
		i = j;
	}
}

// The walkable triangle's band of ground (see NavChunk::ground): solid
// lying just under its face, down by as much as the face rises over the
// widest clearance the grid measures, so the slope ahead of a unit's feet
// is not a wall to it. Where the triangle borders no other walkable one
// (open_edge), the band runs on along the slope past it, under the face's
// plane, onto whatever the slope meets there: the platform it climbs to.
// Across the slope it stops short of the triangle's own sides: an outer
// side running with the slope is the top of the ramp's side face, so the
// cell just inside it stays a wall and a unit on the floor beside the face
// keeps clear of it instead of stepping up onto it from the side.
void NavigationGrid::mark_tri_ground(const TriShape &tri, int id, const Vector3i &chunk_coord, NavChunk &chunk) {
	const Vector3 &a = tri.verts[id * 3], &b = tri.verts[id * 3 + 1], &c = tri.verts[id * 3 + 2];
	const Vector3 &n = tri.normals[id];
	float tan_tilt;
	if (!tri_walkable(n, MAX_WALKABLE_SLOPE_DEGREES, tan_tilt)) {
		return;
	}
	float reach = MAX_CLEARANCE_CELLS * CELL_SIZE;
	float sweep = tri.open_edge[id] ? reach : 0.0f;
	float skin = CELL_SIZE + reach * tan_tilt;
	float ux = -n.x, uz = -n.z;
	float ulen = std::sqrt(ux * ux + uz * uz);
	ux /= ulen;
	uz /= ulen;
	// Counter-clockwise in x/z, so inside is the left of every edge.
	Vector3 v[3] = { a, b, c };
	// edge_of[k]: which of the triangle's own edges v[k] -> v[k + 1] is.
	int edge_of[3] = { 0, 1, 2 };
	if (cross2(b.x - a.x, b.z - a.z, c.x - a.x, c.z - a.z) < 0.0f) {
		std::swap(v[1], v[2]);
		edge_of[0] = 2;
		edge_of[2] = 0;
	}
	// How far inside each edge the band stops: a cell for an outer edge
	// within 45 degrees of the slope's direction (a side), else nothing.
	float inset[3] = { 0.0f, 0.0f, 0.0f };
	if (ulen > 1e-4f) {
		for (int k = 0; k < 3; k++) {
			const Vector3 &p0 = v[k], &p1 = v[(k + 1) % 3];
			float ex = p1.x - p0.x, ez = p1.z - p0.z;
			float elen = std::sqrt(ex * ex + ez * ez);
			if (tri.outer_edge[id * 3 + edge_of[k]] && elen > 1e-6f && std::abs(cross2(ex, ez, ux, uz)) < 0.7071f * elen) {
				inset[k] = CELL_SIZE * elen;
			}
		}
	}

	float x0 = std::min({ a.x, b.x, c.x }) - sweep * std::abs(ux), x1 = std::max({ a.x, b.x, c.x }) + sweep * std::abs(ux);
	float z0 = std::min({ a.z, b.z, c.z }) - sweep * std::abs(uz), z1 = std::max({ a.z, b.z, c.z }) + sweep * std::abs(uz);
	float h_lo = 1e30f, h_hi = -1e30f;
	for (int k = 0; k < 4; k++) {
		float h = plane_height(a, n, (k & 1) ? x1 : x0, (k & 2) ? z1 : z0);
		h_lo = std::min(h_lo, h);
		h_hi = std::max(h_hi, h);
	}
	Vector3i base = chunk_coord * CHUNK_DIM;
	Vector3i lo = world_to_cell(Vector3(x0, h_lo - skin, z0));
	Vector3i hi = world_to_cell(Vector3(x1, h_hi + CELL_SIZE, z1));
	lo = Vector3i(std::max(lo.x, base.x), std::max(lo.y, base.y), std::max(lo.z, base.z));
	hi = Vector3i(std::min({ hi.x, base.x + CHUNK_DIM - 1, grid_size.x - 1 }), std::min({ hi.y, base.y + CHUNK_DIM - 1, grid_size.y - 1 }), std::min({ hi.z, base.z + CHUNK_DIM - 1, grid_size.z - 1 }));
	for (int x = lo.x; x <= hi.x; x++) {
		for (int z = lo.z; z <= hi.z; z++) {
			Vector3 p = cell_center(Vector3i(x, 0, z));
			// The stretch of s for which (p + s * u) lies in the triangle,
			// and the edges it enters and leaves by.
			float s_lo = -1e30f, s_hi = 1e30f;
			int lo_edge = -1, hi_edge = -1;
			for (int k = 0; k < 3 && s_lo <= s_hi; k++) {
				const Vector3 &p0 = v[k], &p1 = v[(k + 1) % 3];
				float ex = p1.x - p0.x, ez = p1.z - p0.z;
				float f0 = cross2(ex, ez, p.x - p0.x, p.z - p0.z) - inset[k];
				float f1 = cross2(ex, ez, ux, uz);
				if (std::abs(f1) < 1e-9f) {
					if (f0 < -1e-6f) {
						s_hi = s_lo - 1.0f;
					}
				} else if (f1 > 0.0f) {
					if (-f0 / f1 > s_lo) {
						s_lo = -f0 / f1;
						lo_edge = k;
					}
				} else if (-f0 / f1 < s_hi) {
					s_hi = -f0 / f1;
					hi_edge = k;
				}
			}
			if (s_lo > s_hi + 1e-6f) {
				continue;
			}
			// Off the triangle, the band runs on only past an outer edge
			// across the slope (a toe or a top, not a side), and only
			// within reach of it: never through a neighbouring triangle.
			auto crossable = [&](int k) { return k >= 0 && tri.outer_edge[id * 3 + edge_of[k]] && inset[k] == 0.0f; };
			if (s_lo > 1e-6f && !(s_lo <= sweep && crossable(lo_edge))) {
				continue;
			}
			if (s_hi < -1e-6f && !(-s_hi <= sweep && crossable(hi_edge))) {
				continue;
			}
			float h = plane_height(a, n, p.x, p.z);
			for (int y = lo.y; y <= hi.y; y++) {
				int li = local_index(Vector3i(x, y, z) - base);
				if (!chunk.solid[li]) {
					continue;
				}
				float depth = h - cell_center(Vector3i(x, y, z)).y;
				if (depth >= -CELL_SIZE * 0.5f && depth <= skin) {
					chunk.ground[li] = 1;
				}
			}
		}
	}
}

// --- Cell <-> world / chunk addressing --------------------------------------

Vector3i NavigationGrid::world_to_cell(Vector3 pos) const {
	Vector3 local = pos - bounds_origin;
	return Vector3i(
			(int)std::floor(local.x / CELL_SIZE),
			(int)std::floor(local.y / CELL_SIZE),
			(int)std::floor(local.z / CELL_SIZE));
}

Vector3 NavigationGrid::cell_center(const Vector3i &cell) const {
	return bounds_origin + Vector3((float)cell.x, (float)cell.y, (float)cell.z) * CELL_SIZE + Vector3(CELL_SIZE * 0.5f, CELL_SIZE * 0.5f, CELL_SIZE * 0.5f);
}

int NavigationGrid::cell_index(const Vector3i &cell) const {
	return cell.x + cell.y * grid_size.x + cell.z * grid_size.x * grid_size.y;
}

Vector3i NavigationGrid::cell_from_index(int idx) const {
	int x = idx % grid_size.x;
	int y = (idx / grid_size.x) % grid_size.y;
	int z = idx / (grid_size.x * grid_size.y);
	return Vector3i(x, y, z);
}

bool NavigationGrid::in_bounds(const Vector3i &cell) const {
	return cell.x >= 0 && cell.y >= 0 && cell.z >= 0 && cell.x < grid_size.x && cell.y < grid_size.y && cell.z < grid_size.z;
}

Vector3i NavigationGrid::cell_to_chunk_coord(const Vector3i &cell) const {
	return Vector3i(cell.x / CHUNK_DIM, cell.y / CHUNK_DIM, cell.z / CHUNK_DIM);
}

Vector3i NavigationGrid::cell_to_local(const Vector3i &cell) const {
	return Vector3i(cell.x % CHUNK_DIM, cell.y % CHUNK_DIM, cell.z % CHUNK_DIM);
}

int NavigationGrid::chunk_coord_index(const Vector3i &chunk_coord) const {
	return chunk_coord.x + chunk_coord.y * chunk_grid_size.x + chunk_coord.z * chunk_grid_size.x * chunk_grid_size.y;
}

Vector3i NavigationGrid::chunk_coord_from_index(int idx) const {
	int x = idx % chunk_grid_size.x;
	int y = (idx / chunk_grid_size.x) % chunk_grid_size.y;
	int z = idx / (chunk_grid_size.x * chunk_grid_size.y);
	return Vector3i(x, y, z);
}

bool NavigationGrid::chunk_in_bounds(const Vector3i &chunk_coord) const {
	return chunk_coord.x >= 0 && chunk_coord.y >= 0 && chunk_coord.z >= 0 && chunk_coord.x < chunk_grid_size.x && chunk_coord.y < chunk_grid_size.y && chunk_coord.z < chunk_grid_size.z;
}

int NavigationGrid::local_index(const Vector3i &local) {
	return local.x + local.y * CHUNK_DIM + local.z * CHUNK_DIM * CHUNK_DIM;
}

// --- Chunk lifecycle ---------------------------------------------------------

NavChunk &NavigationGrid::ensure_chunk_rasterized(const Vector3i &chunk_coord) {
	int idx = chunk_coord_index(chunk_coord);
	std::unique_ptr<NavChunk> &slot = chunks[idx];
	if (!slot) {
		slot = std::make_unique<NavChunk>();
	}
	NavChunk &chunk = *slot;
	if (chunk.rasterized) {
		return chunk;
	}
	chunk.solid.assign((size_t)CHUNK_DIM * CHUNK_DIM * CHUNK_DIM, 0);
	chunk.ground.assign((size_t)CHUNK_DIM * CHUNK_DIM * CHUNK_DIM, 0);
	rasterize_chunk(chunk_coord, chunk);
	chunk.rasterized = true;
	return chunk;
}

// A tilted box no steeper than a unit can walk is a ramp: its upper face is
// ground. Which face is "upper" is whichever local axis points most nearly
// up; a box tilted by less than a degree is flat and its top is an ordinary
// step, which the body cannot climb. Fills `slope` and returns true for a
// ramp.
static bool ramp_of(CollisionShape3D *cs, float max_degrees, float cell_size, int reach_cells, RampInfo &slope) {
	BoxShape3D *box = Object::cast_to<BoxShape3D>(cs->get_shape().ptr());
	if (!box) {
		return false;
	}
	Transform3D global_transform = cs->get_global_transform();
	float best = 0.0f;
	slope.up_axis = -1;
	for (int k = 0; k < 3; k++) {
		Vector3 axis = global_transform.basis.get_column(k);
		float len = axis.length();
		slope.axis_scale[k] = len;
		if (len <= 0.0f) {
			return false;
		}
		float d = axis.y / len;
		if (std::abs(d) > best) {
			best = std::abs(d);
			slope.up_axis = k;
			slope.up_sign = d < 0.0f ? -1.0f : 1.0f;
		}
	}
	if (best < std::cos(max_degrees * (float)Math_PI / 180.0f) || best >= std::cos(1.0f * (float)Math_PI / 180.0f)) {
		return false;
	}
	slope.inverse = global_transform.affine_inverse();
	slope.half_size = box->get_size() * 0.5f;
	float reach = reach_cells * cell_size;
	// A unit's feet sit on the face and the face rises ahead of them, so
	// within the widest clearance the grid measures, what lies beside the
	// feet layer is up to reach * sin(tilt) under the face: under the
	// walking surface, not in the body's way.
	slope.skin_depth = cell_size + reach * std::sqrt(std::max(0.0f, 1.0f - best * best));
	// The face runs on past the box's ends along the slope, by the same
	// reach: whatever meets the ramp there (the platform it climbs to, the
	// floor it starts from) is ground too where it lies under that face.
	// Across the slope the band stops at the box's sides.
	for (int k = 0; k < 3; k++) {
		slope.extend[k] = 0.0f;
		if (k != slope.up_axis && std::abs(global_transform.basis.get_column(k).y) / slope.axis_scale[k] > 0.0175f) {
			slope.extend[k] = reach / slope.axis_scale[k];
		}
	}
	return true;
}

void NavigationGrid::rasterize_chunk(const Vector3i &chunk_coord, NavChunk &chunk, const std::vector<uint8_t> *fill) {
	auto it = shapes_by_chunk.find(chunk_coord_index(chunk_coord));
	if (it == shapes_by_chunk.end()) {
		return; // no geometry touches this chunk — stays all-air
	}

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	std::vector<RampInfo> ramps;
	std::vector<std::pair<const TriShape *, int>> walkable_tris;
	for (CollisionShape3D *cs : it->second) {
		auto tri = tri_shapes.find(cs);
		if (tri != tri_shapes.end()) {
			rasterize_tri_shape(*tri->second, chunk_coord, chunk, walkable_tris);
			continue;
		}
		Ref<Shape3D> shape = cs->get_shape();
		Transform3D global_transform = cs->get_global_transform();
		AABB aabb = shape_global_aabb(cs);
		BoxShape3D *box = Object::cast_to<BoxShape3D>(shape.ptr());
		bool is_box = box != nullptr;
		Vector3 half_size = is_box ? box->get_size() * 0.5f : Vector3();
		// Round primitives are tested exactly too, in their own space.
		SphereShape3D *sphere = Object::cast_to<SphereShape3D>(shape.ptr());
		CylinderShape3D *cylinder = Object::cast_to<CylinderShape3D>(shape.ptr());
		CapsuleShape3D *capsule = Object::cast_to<CapsuleShape3D>(shape.ptr());
		Transform3D inverse = global_transform.affine_inverse();
		RampInfo ramp;
		if (ramp_of(cs, MAX_WALKABLE_SLOPE_DEGREES, CELL_SIZE, MAX_CLEARANCE_CELLS, ramp)) {
			ramps.push_back(ramp);
		}

		// Only the cells whose centres can lie in the shape's bounding box:
		// every shape is tested exactly inside it, and seal_interiors
		// rasterizes every chunk a shape touches, where a floor slab one
		// metre thick would otherwise cost the whole 8 m chunk.
		Vector3i lo = world_to_cell(aabb.position) - base;
		Vector3i hi = world_to_cell(aabb.position + aabb.size) - base;
		int x0 = std::max(0, lo.x), y0 = std::max(0, lo.y), z0 = std::max(0, lo.z);
		int x1 = std::min(cx1, hi.x + 1), y1 = std::min(cy1, hi.y + 1), z1 = std::min(cz1, hi.z + 1);
		for (int x = x0; x < x1; x++) {
			for (int y = y0; y < y1; y++) {
				for (int z = z0; z < z1; z++) {
					Vector3i cell = base + Vector3i(x, y, z);
					Vector3 world_point = cell_center(cell);
					bool inside;
					if (is_box) {
						Vector3 local = inverse.xform(world_point);
						inside = std::abs(local.x) <= half_size.x && std::abs(local.y) <= half_size.y && std::abs(local.z) <= half_size.z;
					} else if (sphere) {
						inside = inverse.xform(world_point).length() <= sphere->get_radius();
					} else if (cylinder) {
						Vector3 local = inverse.xform(world_point);
						float r = cylinder->get_radius();
						inside = std::abs(local.y) <= cylinder->get_height() * 0.5f && local.x * local.x + local.z * local.z <= r * r;
					} else if (capsule) {
						Vector3 local = inverse.xform(world_point);
						float r = capsule->get_radius();
						float core = std::max(0.0f, capsule->get_height() * 0.5f - r);
						local.y = std::max(0.0f, std::abs(local.y) - core);
						inside = local.length() <= r;
					} else {
						inside = aabb.has_point(world_point);
					}
					if (inside) {
						chunk.solid[local_index(Vector3i(x, y, z))] = 1;
					}
				}
			}
		}
	}

	if (fill) {
		for (size_t i = 0; i < chunk.solid.size(); i++) {
			chunk.solid[i] |= (*fill)[i];
		}
	}

	// Once everything is solid: each ramp's band under its face, whichever
	// shape the solid there belongs to. Solid standing ABOVE the face (a
	// crate on the ramp) stays a wall; half a cell of slack lets the
	// ramp's own top cells, whose centres can sit just over it, through.
	for (const auto &walk : walkable_tris) {
		mark_tri_ground(*walk.first, walk.second, chunk_coord, chunk);
	}
	for (const RampInfo &ramp : ramps) {
		for (int x = 0; x < cx1; x++) {
			for (int y = 0; y < cy1; y++) {
				for (int z = 0; z < cz1; z++) {
					int li = local_index(Vector3i(x, y, z));
					if (!chunk.solid[li]) {
						continue;
					}
					Vector3 local = ramp.inverse.xform(cell_center(base + Vector3i(x, y, z)));
					bool within = true;
					for (int k = 0; k < 3 && within; k++) {
						// Short of the box's sides by a cell (see mark_tri_ground).
						if (k != ramp.up_axis) {
							float side = ramp.extend[k] > 0.0f ? ramp.extend[k] : -CELL_SIZE / ramp.axis_scale[k];
							within = std::abs(local[k]) <= ramp.half_size[k] + side;
						}
					}
					if (!within) {
						continue;
					}
					float depth = (ramp.half_size[ramp.up_axis] - local[ramp.up_axis] * ramp.up_sign) * ramp.axis_scale[ramp.up_axis];
					if (depth >= -CELL_SIZE * 0.5f && depth <= ramp.skin_depth) {
						chunk.ground[li] = 1;
					}
				}
			}
		}
	}
}

namespace {
// Union-find over the open runs seal_interiors labels.
struct RunSets {
	std::vector<int> parent;
	int find(int a) {
		while (parent[a] != a) {
			parent[a] = parent[parent[a]];
			a = parent[a];
		}
		return a;
	}
	void unite(int a, int b) {
		a = find(a);
		b = find(b);
		if (a != b) {
			parent[std::max(a, b)] = std::min(a, b);
		}
	}
};
} // namespace

// The rasterizers mark the shells of shapes. What lies inside a shell is
// decided here, by one rule instead of per-mesh heuristics: an open cell is
// air only if it is connected to the outside. The grid's boundary layer is
// outside by construction (BOUNDS_MARGIN of air around all geometry), so a
// flood from it over open cells reaches every cell any unit could get to,
// and what it does not reach is inside geometry and becomes solid.
//
// Face neighbours only (6-connected), though a_star steps across all 26.
// A crack only a diagonal step gets through is narrower than any unit's
// clearance, so nothing a unit can reach is lost by closing it, and a
// rasterized shell sloping one cell per column is tight to a 6-connected
// flood but would leak at every step to a 26-connected one.
//
// Done at the scan, not lazily: whether a pocket is sealed depends on
// geometry anywhere in the world. So every chunk a shape touches is
// rasterized now (rasterize_chunk walks each shape's own bounding box, so
// that is a few ms per hundred chunks of boxes), and a chunk no shape
// touches costs one node and is never allocated unless it is sealed.
// Labelling is by runs of open cells along x, a few per row, rather than by
// cell, so a chunk's labels cost one pass over its solid[].
void NavigationGrid::seal_interiors() {
	uint64_t started = Time::get_singleton()->get_ticks_usec();
	const int D = CHUNK_DIM;
	struct ChunkRuns {
		bool shaped = false;
		int first = 0; // node of the chunk's first run, or of the whole chunk when no shape touches it
		Vector3i dims; // in-bounds extent
		std::vector<int> row_start; // D*D + 1, row = y * D + z
		std::vector<uint8_t> x0, x1; // inclusive
	};
	size_t n = chunks.size();
	std::vector<ChunkRuns> runs(n);
	int nodes = 1; // node 0 is the outside
	int shaped_chunks = 0;
	for (size_t i = 0; i < n; i++) {
		ChunkRuns &c = runs[i];
		Vector3i cc = chunk_coord_from_index((int)i);
		Vector3i base = cc * D;
		c.dims = Vector3i(std::min(D, grid_size.x - base.x), std::min(D, grid_size.y - base.y), std::min(D, grid_size.z - base.z));
		c.first = nodes;
		if (shapes_by_chunk.find((int)i) == shapes_by_chunk.end()) {
			nodes++;
			continue;
		}
		c.shaped = true;
		shaped_chunks++;
		const std::vector<uint8_t> &solid = ensure_chunk_rasterized(cc).solid;
		c.row_start.assign((size_t)D * D + 1, 0);
		for (int y = 0; y < D; y++) {
			for (int z = 0; z < D; z++) {
				c.row_start[y * D + z] = (int)c.x0.size();
				if (y >= c.dims.y || z >= c.dims.z) {
					continue;
				}
				const uint8_t *row = solid.data() + local_index(Vector3i(0, y, z));
				for (int x = 0; x < c.dims.x;) {
					if (row[x]) {
						x++;
						continue;
					}
					int s = x;
					while (x < c.dims.x && !row[x]) {
						x++;
					}
					c.x0.push_back((uint8_t)s);
					c.x1.push_back((uint8_t)(x - 1));
				}
			}
		}
		c.row_start[(size_t)D * D] = (int)c.x0.size();
		nodes += (int)c.x0.size();
	}

	RunSets sets;
	sets.parent.resize(nodes);
	for (int i = 0; i < nodes; i++) {
		sets.parent[i] = i;
	}
	// Every run of row ra in a sharing an x with a run of row rb in b. A
	// chunk no shape touches is one open node whatever the row.
	auto unite_rows = [&](const ChunkRuns &a, int ra, const ChunkRuns &b, int rb) {
		if (!a.shaped || !b.shaped) {
			const ChunkRuns &s = a.shaped ? a : b;
			int whole = a.shaped ? b.first : a.first;
			if (!s.shaped) {
				sets.unite(s.first, whole);
				return;
			}
			int rs = a.shaped ? ra : rb;
			for (int k = s.row_start[rs]; k < s.row_start[rs + 1]; k++) {
				sets.unite(s.first + k, whole);
			}
			return;
		}
		int i = a.row_start[ra], ie = a.row_start[ra + 1];
		int j = b.row_start[rb], je = b.row_start[rb + 1];
		while (i < ie && j < je) {
			if (a.x1[i] >= b.x0[j] && b.x1[j] >= a.x0[i]) {
				sets.unite(a.first + i, b.first + j);
			}
			if (a.x1[i] < b.x1[j]) {
				i++;
			} else {
				j++;
			}
		}
	};
	// The run of a row that covers x, if any.
	auto run_at = [&](const ChunkRuns &c, int row, int x) -> int {
		if (!c.shaped) {
			return c.first;
		}
		for (int k = c.row_start[row]; k < c.row_start[row + 1]; k++) {
			if (c.x0[k] <= x && x <= c.x1[k]) {
				return c.first + k;
			}
		}
		return -1;
	};
	auto unite_row_with = [&](const ChunkRuns &c, int row, int node) {
		if (!c.shaped) {
			sets.unite(c.first, node);
			return;
		}
		for (int k = c.row_start[row]; k < c.row_start[row + 1]; k++) {
			sets.unite(c.first + k, node);
		}
	};

	for (size_t i = 0; i < n; i++) {
		const ChunkRuns &c = runs[i];
		Vector3i cc = chunk_coord_from_index((int)i);
		const Vector3i &d = c.dims;
		// Within the chunk: each row with the rows below and behind it.
		if (c.shaped) {
			for (int y = 0; y < d.y; y++) {
				for (int z = 0; z < d.z; z++) {
					if (y > 0) {
						unite_rows(c, y * D + z, c, (y - 1) * D + z);
					}
					if (z > 0) {
						unite_rows(c, y * D + z, c, y * D + z - 1);
					}
				}
			}
		}
		// Across the faces it shares with its +x, +y, +z neighbours. A
		// neighbour exists only past a full chunk, so the shared face is at
		// D - 1 on this side and 0 on the other.
		Vector3i nx = cc + Vector3i(1, 0, 0), ny = cc + Vector3i(0, 1, 0), nz = cc + Vector3i(0, 0, 1);
		if (chunk_in_bounds(nx)) {
			const ChunkRuns &o = runs[chunk_coord_index(nx)];
			if (!c.shaped && !o.shaped) {
				sets.unite(c.first, o.first);
			} else {
				for (int y = 0; y < d.y; y++) {
					for (int z = 0; z < d.z; z++) {
						int a = run_at(c, y * D + z, D - 1), b = run_at(o, y * D + z, 0);
						if (a >= 0 && b >= 0) {
							sets.unite(a, b);
						}
					}
				}
			}
		}
		if (chunk_in_bounds(ny)) {
			const ChunkRuns &o = runs[chunk_coord_index(ny)];
			for (int z = 0; z < d.z; z++) {
				unite_rows(c, (D - 1) * D + z, o, z);
			}
		}
		if (chunk_in_bounds(nz)) {
			const ChunkRuns &o = runs[chunk_coord_index(nz)];
			for (int y = 0; y < d.y; y++) {
				unite_rows(c, y * D + D - 1, o, y * D);
			}
		}
		// The world's boundary faces are the outside.
		bool on_x0 = cc.x == 0, on_x1 = cc.x == chunk_grid_size.x - 1;
		bool on_y0 = cc.y == 0, on_y1 = cc.y == chunk_grid_size.y - 1;
		bool on_z0 = cc.z == 0, on_z1 = cc.z == chunk_grid_size.z - 1;
		if (!(on_x0 || on_x1 || on_y0 || on_y1 || on_z0 || on_z1)) {
			continue;
		}
		if (!c.shaped) {
			sets.unite(c.first, 0);
			continue;
		}
		for (int y = 0; y < d.y; y++) {
			for (int z = 0; z < d.z; z++) {
				int row = y * D + z;
				if ((on_y0 && y == 0) || (on_y1 && y == d.y - 1) || (on_z0 && z == 0) || (on_z1 && z == d.z - 1)) {
					unite_row_with(c, row, 0);
					continue;
				}
				if (on_x0) {
					int a = run_at(c, row, 0);
					if (a >= 0) {
						sets.unite(a, 0);
					}
				}
				if (on_x1) {
					int a = run_at(c, row, d.x - 1);
					if (a >= 0) {
						sets.unite(a, 0);
					}
				}
			}
		}
	}

	// Everything the outside did not reach becomes solid. A chunk with
	// shapes is rasterized again with the fill, so its ramp bands are
	// marked against the solid that will stay.
	int outside = sets.find(0);
	int64_t sealed_cells = 0;
	int sealed_chunks = 0;
	const size_t cells = (size_t)D * D * D;
	for (size_t i = 0; i < n; i++) {
		const ChunkRuns &c = runs[i];
		Vector3i cc = chunk_coord_from_index((int)i);
		if (!c.shaped) {
			if (sets.find(c.first) == outside) {
				continue;
			}
			std::unique_ptr<NavChunk> &slot = chunks[i];
			if (!slot) {
				slot = std::make_unique<NavChunk>();
			}
			slot->solid.assign(cells, 1);
			slot->ground.assign(cells, 0);
			slot->rasterized = true;
			sealed_cells += (int64_t)c.dims.x * c.dims.y * c.dims.z;
			sealed_chunks++;
			continue;
		}
		std::vector<uint8_t> fill;
		for (int y = 0; y < c.dims.y; y++) {
			for (int z = 0; z < c.dims.z; z++) {
				int row = y * D + z;
				for (int k = c.row_start[row]; k < c.row_start[row + 1]; k++) {
					if (sets.find(c.first + k) == outside) {
						continue;
					}
					if (fill.empty()) {
						fill.assign(cells, 0);
					}
					for (int x = c.x0[k]; x <= c.x1[k]; x++) {
						fill[local_index(Vector3i(x, y, z))] = 1;
					}
					sealed_cells += c.x1[k] - c.x0[k] + 1;
				}
			}
		}
		if (!fill.empty()) {
			NavChunk &chunk = *chunks[i];
			chunk.solid.assign(cells, 0);
			chunk.ground.assign(cells, 0);
			rasterize_chunk(cc, chunk, &fill);
			sealed_chunks++;
		}
	}
	UtilityFunctions::print_verbose("NavigationGrid: ", shaped_chunks, " of ", (int64_t)n, " chunks hold geometry; sealed ", sealed_cells,
			" interior cells in ", sealed_chunks, " chunks; ", (double)(Time::get_singleton()->get_ticks_usec() - started) / 1000.0, " ms");
}

bool NavigationGrid::is_solid(const Vector3i &cell) {
	if (!in_bounds(cell)) {
		return true;
	}
	NavChunk &chunk = ensure_chunk_rasterized(cell_to_chunk_coord(cell));
	return chunk.solid[local_index(cell_to_local(cell))] != 0;
}

NavChunk &NavigationGrid::ensure_chunk_support(const Vector3i &chunk_coord) {
	NavChunk &chunk = ensure_chunk_rasterized(chunk_coord);
	if (chunk.support_baked) {
		return chunk;
	}
	bake_chunk_support(chunk_coord, chunk);
	chunk.support_baked = true;
	return chunk;
}

void NavigationGrid::bake_chunk_support(const Vector3i &chunk_coord, NavChunk &chunk) {
	// Both tiers only ever read straight down, at most FLIGHT_LOW_CELLS
	// (< CHUNK_DIM) cells: this chunk's own solid[] or the one directly
	// below's. Read those two arrays directly - going through is_solid()
	// per cell (bounds check, chunk lookup) cost ~1 ms a chunk, and a
	// flier's coarse corridor bakes ~100 of them.
	// Off the world's bottom counts as solid, as is_solid() has it.
	Vector3i below_chunk = chunk_coord - Vector3i(0, 1, 0);
	const uint8_t *below_solid = nullptr;
	if (chunk_in_bounds(below_chunk)) {
		below_solid = ensure_chunk_rasterized(below_chunk).solid.data();
	}
	const uint8_t *own_solid = chunk.solid.data();
	auto solid_at = [&](int x, int y, int z) -> bool {
		if (y >= 0) {
			return own_solid[local_index(Vector3i(x, y, z))] != 0;
		}
		return below_solid == nullptr || below_solid[local_index(Vector3i(x, y + CHUNK_DIM, z))] != 0;
	};
	// Too low to fly: solid in any cell whose top lies under
	// FLIGHT_MIN_ALTITUDE below this cell's centre - the same cut the old
	// absolute rule made over y=0 ground.
	int flight_low_cells = 0;
	while (((float)(flight_low_cells + 1) - 0.5f) * CELL_SIZE < FLIGHT_MIN_ALTITUDE) {
		flight_low_cells++;
	}

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	chunk.no_support.assign((size_t)CHUNK_DIM * CHUNK_DIM * CHUNK_DIM, 0);
	chunk.flight_low.assign((size_t)CHUNK_DIM * CHUNK_DIM * CHUNK_DIM, 0);
	chunk.has_ground_passable = false;
	chunk.has_flyable = false;

	// One walk up each column, carrying how far below the nearest solid
	// cell is: supported = it is 1, too low = it is within flight_low_cells.
	for (int x = 0; x < cx1; x++) {
		for (int z = 0; z < cz1; z++) {
			int since_solid = flight_low_cells + 1; // "none in reach"
			for (int k = 1; k <= flight_low_cells; k++) {
				if (solid_at(x, -k, z)) {
					since_solid = k;
					break;
				}
			}
			for (int y = 0; y < cy1; y++) {
				int li = local_index(Vector3i(x, y, z));
				bool supported = base.y + y > 0 && since_solid == 1;
				chunk.no_support[li] = supported ? 0 : 1;
				if (own_solid[li] == 0) {
					if (supported) {
						chunk.has_ground_passable = true;
					}
					bool low = since_solid <= flight_low_cells;
					chunk.flight_low[li] = low ? 1 : 0;
					float world_y = bounds_origin.y + ((float)(base.y + y) + 0.5f) * CELL_SIZE;
					if (!low && world_y <= FLIGHT_CEILING_HEIGHT) {
						chunk.has_flyable = true;
					}
					since_solid = std::min(since_solid + 1, flight_low_cells + 1);
				} else {
					since_solid = 1;
				}
			}
		}
	}
}

NavChunk &NavigationGrid::ensure_chunk_dist(const Vector3i &chunk_coord) {
	NavChunk &chunk = ensure_chunk_rasterized(chunk_coord);
	if (chunk.dist_baked) {
		return chunk;
	}
	bake_chunk_dist(chunk_coord, chunk);
	chunk.dist_baked = true;
	return chunk;
}

// Per-Y-layer horizontal (x,z) multi-source Dijkstra to the nearest solid
// cell, using octile (8-connected) distance — a standard grid-pathfinding
// approximation of true Euclidean distance, close but not bit-identical to
// the old disc_offsets' exact-circle check at the extreme edge of a
// clearance radius. Mirrors that old check's semantics otherwise exactly:
// it never looked at Y (a unit's footprint is horizontal), and a solid
// cell's own distance is always 0, so it's always "blocked" for any
// clearance >= 0 — replicated below by seeding solid cells at distance 0
// and comparing with a strict '>' in cell_clearance_world's caller.
//
// This computes ONE shared field per chunk instead of the old one full
// grid-sized mask PER DISTINCT CLEARANCE VALUE — the fix for
// inflated_solid_cache growing without bound as unit radii vary.
void NavigationGrid::bake_chunk_dist(const Vector3i &chunk_coord, NavChunk &chunk) {
	// The horizontal reach can cross into any of the 8 side neighbors (and
	// MAX_CLEARANCE_CELLS < CHUNK_DIM guarantees direct neighbors are
	// always sufficient — never a neighbor-of-neighbor).
	// Pre-resolve all 9 relevant chunks' solid[] arrays ONCE per bake
	// instead of re-deriving a chunk pointer (chunk-coord divide + vector
	// lookup + unique_ptr deref) on every one of the ~130K individual cell
	// reads the seed scan below does — that per-cell indirection was a
	// second, independent cost from the hashmap-vs-flat-array one (see the
	// comment above), found by the same profiling pass.
	uint8_t *neighbor_solid[3][3] = {};
	uint8_t *neighbor_ground[3][3] = {};
	for (int dx = -1; dx <= 1; dx++) {
		for (int dz = -1; dz <= 1; dz++) {
			Vector3i nc = chunk_coord + Vector3i(dx, 0, dz);
			if (chunk_in_bounds(nc)) {
				NavChunk &nchunk = ensure_chunk_rasterized(nc);
				neighbor_solid[dx + 1][dz + 1] = nchunk.solid.data();
				neighbor_ground[dx + 1][dz + 1] = nchunk.ground.data();
			}
		}
	}

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	// Fast solid lookup for the seed scan: x,z are chunk-relative and may
	// reach one chunk-width into a neighbor (guaranteed by
	// MAX_CLEARANCE_CELLS < CHUNK_DIM); local_y is relative to THIS
	// chunk's own base and is valid for every horizontal neighbor too
	// (they share the same chunk row). Caller must already know the
	// corresponding world cell is in_bounds -- a null neighbor_solid slot
	// (chunk coordinate off the world edge) is the only "solid" case this
	// needs to handle, since an in-bounds world cell is always covered by
	// its owning neighbor's own rasterized range.
	auto solid_fast = [&](int x, int local_y, int z) -> bool {
		int cdx = (x < 0) ? -1 : (x >= CHUNK_DIM ? 1 : 0);
		int cdz = (z < 0) ? -1 : (z >= CHUNK_DIM ? 1 : 0);
		uint8_t *arr = neighbor_solid[cdx + 1][cdz + 1];
		if (!arr) {
			return true;
		}
		int lx = x - cdx * CHUNK_DIM;
		int lz = z - cdz * CHUNK_DIM;
		return arr[local_index(Vector3i(lx, local_y, lz))] != 0;
	};
	// A ramp's skin (NavChunk::ground == 1) is solid but not a wall: it is
	// what a unit walking the ramp stands on, the cell beside its feet one
	// step further up the slope. Clearance is measured from walls only.
	auto ramp_skin = [&](int x, int local_y, int z) -> bool {
		int cdx = (x < 0) ? -1 : (x >= CHUNK_DIM ? 1 : 0);
		int cdz = (z < 0) ? -1 : (z >= CHUNK_DIM ? 1 : 0);
		uint8_t *arr = neighbor_ground[cdx + 1][cdz + 1];
		if (!arr) {
			return false;
		}
		int lx = x - cdx * CHUNK_DIM;
		int lz = z - cdz * CHUNK_DIM;
		return arr[local_index(Vector3i(lx, local_y, lz))] == 1;
	};

	chunk.dist.assign((size_t)CHUNK_DIM * CHUNK_DIM * CHUNK_DIM, (uint16_t)(MAX_CLEARANCE_CELLS * DIST_SCALE));

	// Per Y layer, distance to the nearest wall cell over the 8-connected
	// grid (steps 1 and sqrt 2), out to MAX_CLEARANCE_CELLS. Computed as a
	// two-pass chamfer sweep over the (CHUNK_DIM + 2*reach)^2 window: the
	// forward pass carries every path made of +x / +z-leaning steps, the
	// backward pass the rest, and on a rectangle (the window clipped to the
	// world, with no holes) a shortest path can always be reordered into
	// one run of each - so two passes give exactly the graph distance.
	// This replaced a per-layer Dijkstra that pushed every wall cell in the
	// window through a priority queue: same field, ~2.4 ms -> a fraction
	// of that per chunk, and a flier's first path bakes dozens of chunks.
	const float D1 = 1.0f;
	const float D2 = 1.41421356f;
	const float FAR = 1.0e9f;
	const uint16_t MAX_DIST = (uint16_t)(MAX_CLEARANCE_CELLS * DIST_SCALE);
	int reach = MAX_CLEARANCE_CELLS;
	int W = CHUNK_DIM + 2 * reach;
	auto idx2 = [&](int x, int z) -> int { return (x + reach) * W + (z + reach); };
	// The window clipped to the world: cells outside it are neither walls
	// nor passed through, as in_bounds() had it.
	int xlo = std::max(-reach, -base.x), xhi = std::min(CHUNK_DIM + reach, grid_size.x - base.x);
	int zlo = std::max(-reach, -base.z), zhi = std::min(CHUNK_DIM + reach, grid_size.z - base.z);
	std::vector<float> d((size_t)W * W, FAR);
	const uint8_t *own_solid = neighbor_solid[1][1];

	for (int y = 0; y < cy1; y++) {
		// A solid cell is always 0 (is_valid_cell has no separate is_solid
		// guard; dist==0 is what blocks it), written even when the layer
		// has no air to propagate into.
		bool any_air = false;
		for (int x = 0; x < cx1; x++) {
			for (int z = 0; z < cz1; z++) {
				int li = local_index(Vector3i(x, y, z));
				if (own_solid[li] != 0) {
					chunk.dist[li] = 0;
				} else {
					any_air = true;
				}
			}
		}
		if (!any_air) {
			continue;
		}

		// A ramp's skin is solid but not a wall (see ramp_skin above).
		bool any_wall = false;
		for (int x = xlo; x < xhi; x++) {
			for (int z = zlo; z < zhi; z++) {
				bool wall = solid_fast(x, y, z) && !ramp_skin(x, y, z);
				d[idx2(x, z)] = wall ? 0.0f : FAR;
				any_wall = any_wall || wall;
			}
		}
		if (!any_wall) {
			continue; // no wall in reach: the open cells keep MAX_DIST
		}

		for (int x = xlo; x < xhi; x++) {
			for (int z = zlo; z < zhi; z++) {
				int i = idx2(x, z);
				float v = d[i];
				if (v == 0.0f) {
					continue;
				}
				if (x > xlo) {
					int u = i - W;
					v = std::min(v, d[u] + D1);
					if (z > zlo) {
						v = std::min(v, d[u - 1] + D2);
					}
					if (z < zhi - 1) {
						v = std::min(v, d[u + 1] + D2);
					}
				}
				if (z > zlo) {
					v = std::min(v, d[i - 1] + D1);
				}
				d[i] = v;
			}
		}
		for (int x = xhi - 1; x >= xlo; x--) {
			for (int z = zhi - 1; z >= zlo; z--) {
				int i = idx2(x, z);
				float v = d[i];
				if (v == 0.0f) {
					continue;
				}
				if (x < xhi - 1) {
					int u = i + W;
					v = std::min(v, d[u] + D1);
					if (z > zlo) {
						v = std::min(v, d[u - 1] + D2);
					}
					if (z < zhi - 1) {
						v = std::min(v, d[u + 1] + D2);
					}
				}
				if (z < zhi - 1) {
					v = std::min(v, d[i + 1] + D1);
				}
				d[i] = v;
			}
		}

		for (int x = 0; x < cx1; x++) {
			for (int z = 0; z < cz1; z++) {
				int li = local_index(Vector3i(x, y, z));
				uint16_t clamped = (uint16_t)std::min((float)MAX_DIST, d[idx2(x, z)] * DIST_SCALE);
				if (clamped < chunk.dist[li]) {
					chunk.dist[li] = clamped;
				}
			}
		}
	}
}

// --- Dynamic occupancy -------------------------------------------------------

const std::vector<Object *> *NavigationGrid::occupants_at(const Vector3i &cell) const {
	if (!in_bounds(cell)) {
		return nullptr;
	}
	int idx = chunk_coord_index(cell_to_chunk_coord(cell));
	const std::unique_ptr<NavChunk> &slot = chunks[idx];
	if (!slot) {
		return nullptr;
	}
	auto it = slot->occupied.find(local_index(cell_to_local(cell)));
	return it != slot->occupied.end() ? &it->second : nullptr;
}

void NavigationGrid::set_occupant(const Vector3i &cell, Object *obj) {
	if (!in_bounds(cell)) {
		return;
	}
	int idx = chunk_coord_index(cell_to_chunk_coord(cell));
	std::unique_ptr<NavChunk> &slot = chunks[idx];
	if (!slot) {
		slot = std::make_unique<NavChunk>(); // occupancy doesn't need geometry rasterized
	}
	std::vector<Object *> &here = slot->occupied[local_index(cell_to_local(cell))];
	if (std::find(here.begin(), here.end(), obj) == here.end()) {
		here.push_back(obj);
	}
	if (!slot->has_occupancy) {
		slot->has_occupancy = true;
		occupied_chunks.push_back(idx);
	}
}

void NavigationGrid::reset_occupancy() {
	occupancy_signature.clear();
	occupied_chunks.clear();
	occupancy_stamped = false;
}

void NavigationGrid::set_query_ignore(const Array &ignore) {
	query_ignore.clear();
	for (int i = 0; i < ignore.size(); i++) {
		Object *obj = ignore[i];
		if (obj) {
			query_ignore.push_back(obj);
		}
	}
}

// Everything that occupies cells in the ACTIVE world, in group order:
// living units, then blocking corpses. Both groups are global, so
// in_active_world keeps other worlds' occupants out.
void NavigationGrid::collect_occupants(SceneTree *tree, std::vector<OccupantKey> &keys, std::vector<Object *> &objects) {
	static const StringName groups[2] = { StringName("units"), StringName("blocking_corpses") };
	for (int pass = 0; pass < 2; pass++) {
		TypedArray<Node> nodes = tree->get_nodes_in_group(groups[pass]);
		for (int i = 0; i < nodes.size(); i++) {
			Object *obj = nodes[i];
			Node3D *n3d = Object::cast_to<Node3D>(obj);
			if (!n3d || !in_active_world(n3d)) {
				continue;
			}
			if (pass == 0 && (!n3d->has_method("is_alive") || !call_bool(n3d, "is_alive"))) {
				continue;
			}
			OccupantKey key;
			key.id = obj->get_instance_id();
			key.cell = world_to_cell(n3d->get_global_position());
			key.clearance_key = clearance_key(get_float_prop(n3d, "radius") + get_float_prop(n3d, "avoidance_margin"));
			// A flying occupant (or a corpse that died mid-air: corpses
			// aren't force-landed, see UnitDeath.handle_death) needs a full
			// 3D volume, not the horizontal disc grounded units share a Y
			// reference for; see sphere_offsets.
			key.flying = n3d->has_method("is_flying") && call_bool(n3d, "is_flying");
			keys.push_back(key);
			objects.push_back(obj);
		}
	}
}

// Rebuilds occupancy only when the live occupants differ from what it was
// last built from. Called at the top of every query, so a query always
// sees the scene as it is at that moment, whatever changed it: a walk, a
// shove, a teleport earlier this same tick, a death, a unit arriving from
// another world. Nothing outside has to remember to refresh it. Keys are
// cells, not positions, so walking inside one cell costs no rebuild.
//
// Every occupant is stamped, the querying unit included; who a query
// ignores (itself, and its group on a group move) is decided per query in
// is_clear_of_units, so one snapshot serves every caller.
void NavigationGrid::ensure_occupancy_current(SceneTree *tree) {
	std::vector<OccupantKey> keys;
	std::vector<Object *> objects;
	collect_occupants(tree, keys, objects);
	if (occupancy_stamped && keys == occupancy_signature) {
		return;
	}

	for (int idx : occupied_chunks) {
		std::unique_ptr<NavChunk> &slot = chunks[idx];
		if (slot) {
			slot->occupied.clear();
			slot->has_occupancy = false;
		}
	}
	occupied_chunks.clear();
	any_occupied = false;

	for (size_t i = 0; i < keys.size(); i++) {
		const OccupantKey &key = keys[i];
		// Proactively bake the chunk an occupant stands in so the area
		// around active play stays query-ready.
		if (in_bounds(key.cell)) {
			ensure_chunk_dist(cell_to_chunk_coord(key.cell));
		}
		float clearance = (float)key.clearance_key / 1000.0f;
		const std::vector<Vector3i> &occ_offsets = key.flying ? sphere_offsets(clearance) : disc_offsets(clearance);
		for (const Vector3i &offset : occ_offsets) {
			Vector3i cell = key.cell + offset;
			if (in_bounds(cell)) {
				set_occupant(cell, objects[i]);
				any_occupied = true;
			}
		}
	}

	refresh_chunk_occupancy_nearby();
	occupancy_signature = std::move(keys);
	occupancy_stamped = true;
	occupancy_version_value = ++occupancy_version_counter;
}

// Changes whenever the active world's occupancy is rebuilt, so a cached
// route (UnitMovement's preview) knows when someone has moved since.
int64_t NavigationGrid::occupancy_version(SceneTree *tree, Object *world_ref) {
	activate_for(world_ref);
	ensure_baked(tree);
	ensure_occupancy_current(tree);
	return (int64_t)occupancy_version_value;
}

// Precomputes, for every chunk, whether ANY chunk in its own 3x3x3
// neighborhood has_occupancy, so is_clear_of_units can rule a cell out
// with one lookup instead of a 27-chunk scan per candidate cell. Marks
// outward from the occupied chunks rather than scanning every chunk,
// since occupancy rebuilds whenever anyone crosses a cell.
void NavigationGrid::refresh_chunk_occupancy_nearby() {
	std::fill(chunk_occupancy_nearby.begin(), chunk_occupancy_nearby.end(), (uint8_t)0);
	for (int idx : occupied_chunks) {
		Vector3i cc = chunk_coord_from_index(idx);
		for (int dx = -1; dx <= 1; dx++) {
			for (int dy = -1; dy <= 1; dy++) {
				for (int dz = -1; dz <= 1; dz++) {
					Vector3i nc = cc + Vector3i(dx, dy, dz);
					if (chunk_in_bounds(nc)) {
						chunk_occupancy_nearby[chunk_coord_index(nc)] = 1;
					}
				}
			}
		}
	}
}

int NavigationGrid::clearance_key(float clearance) {
	return (int)std::round(clearance * 1000.0f);
}

const std::vector<Vector3i> &NavigationGrid::disc_offsets(float clearance) {
	int key = clearance_key(clearance);
	auto it = disc_offsets_cache.find(key);
	if (it != disc_offsets_cache.end()) {
		return it->second;
	}

	std::vector<Vector3i> result;
	int reach = (int)std::ceil(clearance / CELL_SIZE);
	for (int dx = -reach; dx <= reach; dx++) {
		for (int dz = -reach; dz <= reach; dz++) {
			float dist = std::sqrt((float)(dx * dx + dz * dz)) * CELL_SIZE;
			if (dist > clearance) {
				continue;
			}
			result.push_back(Vector3i(dx, 0, dz));
		}
	}
	auto emplaced = disc_offsets_cache.emplace(key, std::move(result));
	return emplaced.first->second;
}

// Full 3D occupancy volume for a flying occupant, used in place of
// disc_offsets (which is deliberately horizontal-only, dy always 0) when
// marking cells a FLYING unit/corpse occupies in ensure_occupancy_current. A
// grounded unit's Y is pinned to whatever surface it's standing on, so two
// grounded units near each other always land on the same Y cell and the
// horizontal disc alone catches their collision correctly. A flying unit
// has no such shared reference — its altitude is whatever the player last
// set it to (R/F historically, now the Ctrl-drag control) — so two
// hovering units can be right next to each other in world space while
// sitting in DIFFERENT Y cells, and the horizontal-only disc would never
// mark them as overlapping at all. That's the actual root cause behind
// "flying units fly through each other" — read-side collision checks
// (is_clear_of_units) don't need to change; they already test a
// horizontal disc around each candidate cell at that candidate's own Y,
// which correctly detects an overlap once the occupied SET properly
// represents the occupant's true 3D volume here on the write side.
const std::vector<Vector3i> &NavigationGrid::sphere_offsets(float clearance) {
	int key = clearance_key(clearance);
	auto it = sphere_offsets_cache.find(key);
	if (it != sphere_offsets_cache.end()) {
		return it->second;
	}

	std::vector<Vector3i> result;
	int reach = (int)std::ceil(clearance / CELL_SIZE);
	for (int dx = -reach; dx <= reach; dx++) {
		for (int dy = -reach; dy <= reach; dy++) {
			for (int dz = -reach; dz <= reach; dz++) {
				float dist = std::sqrt((float)(dx * dx + dy * dy + dz * dz)) * CELL_SIZE;
				if (dist > clearance) {
					continue;
				}
				result.push_back(Vector3i(dx, dy, dz));
			}
		}
	}
	auto emplaced = sphere_offsets_cache.emplace(key, std::move(result));
	return emplaced.first->second;
}

bool NavigationGrid::is_clear_of_units(const Vector3i &cell, int chunk_idx, const std::vector<Vector3i> &offsets, float clearance, Object *self_unit) const {
	if (!any_occupied) {
		return true;
	}

	// Fast path: any_occupied only means "someone is occupied SOMEWHERE on
	// the map" (matches the pre-chunking design's single global flag) — on
	// a real battlefield with several units, that's true almost all the
	// time even when nothing is anywhere near THIS cell, which used to
	// force every single neighbor check across the whole search to do a
	// full per-offset hashmap lookup regardless. chunk_occupancy_nearby
	// (see refresh_chunk_occupancy_nearby) is this same 3x3x3
	// chunk-neighborhood check, precomputed once per occupancy rebuild
	// instead of rescanned fresh on every candidate cell here — an O(1)
	// lookup rules out the common case cheaply. Only sound when the disc's
	// reach can't cross more than one chunk width, which holds for any
	// realistic unit clearance (this falls back to the exact per-offset
	// check otherwise, so an oversized clearance degrades to the old cost
	// rather than being wrong). The cached flag already accounts for all
	// three axes, not just the horizontal ones — a flying occupant's
	// occupancy is a real 3D sphere now (see sphere_offsets), so it can
	// land in a vertically-adjacent chunk too. chunk_idx is the caller's
	// already-computed chunk_coord_index(cell_to_chunk_coord(cell)) — this
	// is always called right after is_valid_cell derives the same chunk
	// coordinate for its own support/clearance checks, so recomputing it a
	// third time here would be pure waste.
	int reach_cells = (int)std::ceil(clearance / CELL_SIZE);
	if (reach_cells <= CHUNK_DIM) {
		if (!chunk_occupancy_nearby[chunk_idx]) {
			return true;
		}
	}

	for (const Vector3i &offset : offsets) {
		Vector3i c = cell + offset;
		if (!in_bounds(c)) {
			continue;
		}
		const std::vector<Object *> *here = occupants_at(c);
		if (!here) {
			continue;
		}
		for (Object *occ : *here) {
			if (occ != self_unit && std::find(query_ignore.begin(), query_ignore.end(), occ) == query_ignore.end()) {
				return false;
			}
		}
	}
	return true;
}

bool NavigationGrid::is_valid_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit) {
	if (cell.x < 0 || cell.y < 0 || cell.z < 0 || cell.x >= grid_size.x || cell.y >= grid_size.y || cell.z >= grid_size.z) {
		return false;
	}
	if (flying) {
		float world_y = bounds_origin.y + ((float)cell.y + 0.5f) * CELL_SIZE;
		if (world_y > FLIGHT_CEILING_HEIGHT) {
			return false;
		}
	}

	// Chunk coordinate/local index/chunk lookup computed ONCE and shared
	// across the support, clearance, and occupancy checks below — this
	// used to be independently re-derived by cell_no_support(),
	// cell_clearance_world(), and is_clear_of_units() each calling
	// cell_to_chunk_coord(cell) (and re-fetching the chunk) on their own,
	// even though all three are answering questions about the exact same
	// cell within the same call. Found by profiling alongside the
	// smooth_path memoization above; same "hoist the repeated work out of
	// the hot path" idea, just at cell-granularity instead of query- or
	// update-granularity.
	Vector3i chunk_coord = cell_to_chunk_coord(cell);
	Vector3i local = cell_to_local(cell);
	int li = local_index(local);
	int chunk_idx = chunk_coord_index(chunk_coord);

	NavChunk &support_chunk = ensure_chunk_support(chunk_coord);
	if (flying ? support_chunk.flight_low[li] != 0 : support_chunk.no_support[li] != 0) {
		return false;
	}

	// Body clearance checked across every Y-layer the unit's height spans,
	// starting at THIS cell — not just this one layer. bake_chunk_dist
	// already computes horizontal distance-to-nearest-solid independently
	// PER Y-LAYER (see its own comment), so no baking change is needed
	// here, only walking more of what's already there. Before this, a
	// unit could be routed somewhere its reference point fit but its body
	// didn't — a low archway for a grounded unit, or (what actually
	// surfaced this) a flying unit routed just under a platform: its
	// single reference cell was clear, but nothing checked the layers
	// above it where its body actually is. Applies uniformly to flying
	// and grounded — the reference cell is always treated as the body's
	// base, extending upward, matching how GrantFlightEffect/land() also
	// treat the reference Y as "where the unit's feet are," airborne or
	// not.
	int vertical_cells = std::max(1, (int)std::ceil(height / CELL_SIZE));
	for (int dy = 0; dy < vertical_cells; dy++) {
		Vector3i layer_chunk_coord = chunk_coord;
		int layer_li = li;
		if (dy > 0) {
			Vector3i layer_cell = cell + Vector3i(0, dy, 0);
			if (layer_cell.y >= grid_size.y) {
				return false;
			}
			layer_chunk_coord = cell_to_chunk_coord(layer_cell);
			layer_li = local_index(cell_to_local(layer_cell));
		}
		NavChunk &dist_chunk = ensure_chunk_dist(layer_chunk_coord);
		float clearance_world = (float)dist_chunk.dist[layer_li] / (float)DIST_SCALE * CELL_SIZE;
		if (clearance_world <= clearance) {
			return false;
		}
	}

	return is_clear_of_units(cell, chunk_idx, offsets, clearance, self_unit);
}

// --- Nearest-valid-point utility --------------------------------------------

Dictionary NavigationGrid::nearest_valid_point(SceneTree *tree, Vector3 point, float clearance, bool flying, Object *exclude_unit, int max_radius_cells, Object *world_ref, Array ignore) {
	// exclude_unit is optional here (see _bind_methods' DEFVAL), so
	// world_ref is the fallback for callers that pass neither.
	activate_for(exclude_unit, world_ref);
	ensure_baked(tree);
	ensure_occupancy_current(tree);
	set_query_ignore(ignore);
	const std::vector<Vector3i> &offsets = disc_offsets(clearance);
	// height comes off exclude_unit the same duck-typed way find_path()
	// reads it off its own unit parameter — exclude_unit is genuinely
	// optional here (DEFVAL(Variant()) in _bind_methods), unlike find_path's
	// unit, so this can't assume non-null the way get_float_prop's other
	// callers do.
	float height = exclude_unit ? get_float_prop(exclude_unit, "height") : 0.0f;
	NearestResult snap = find_nearest_free_cell(world_to_cell(point), offsets, clearance, height, flying, exclude_unit, max_radius_cells);
	Dictionary result;
	if (!snap.found) {
		result["found"] = false;
		result["point"] = point;
		return result;
	}
	result["found"] = true;
	result["point"] = cell_center(snap.cell);
	return result;
}

NavigationGrid::NearestResult NavigationGrid::find_nearest_free_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit, int max_radius) {
	if (is_valid_cell(cell, offsets, clearance, height, flying, self_unit)) {
		return { true, cell };
	}
	for (int radius = 1; radius <= max_radius; radius++) {
		for (int dx = -radius; dx <= radius; dx++) {
			for (int dy = -radius; dy <= radius; dy++) {
				for (int dz = -radius; dz <= radius; dz++) {
					int m = std::max(std::abs(dx), std::max(std::abs(dy), std::abs(dz)));
					if (m != radius) {
						continue;
					}
					Vector3i candidate = cell + Vector3i(dx, dy, dz);
					if (is_valid_cell(candidate, offsets, clearance, height, flying, self_unit)) {
						return { true, candidate };
					}
				}
			}
		}
	}
	return { false, cell };
}

// --- Pathfinding -------------------------------------------------------------

PackedVector3Array NavigationGrid::find_path(SceneTree *tree, Vector3 start, Vector3 destination, Object *unit, bool flying, Array ignore) {
	// unit is always supplied here, so the world is never ambiguous.
	activate_for(unit);
	ensure_baked(tree);
	ensure_occupancy_current(tree);
	set_query_ignore(ignore);

	float clearance = get_float_prop(unit, "radius") + get_float_prop(unit, "avoidance_margin");
	float height = get_float_prop(unit, "height");
	const std::vector<Vector3i> &offsets = disc_offsets(clearance);
	ensure_neighbor_offsets();

	Vector3i start_cell = world_to_cell(start);
	if (!in_bounds(start_cell)) {
		return PackedVector3Array();
	}

	NearestResult goal_snap = find_nearest_free_cell(world_to_cell(destination), offsets, clearance, height, flying, unit, 12);
	if (!goal_snap.found) {
		return PackedVector3Array();
	}
	Vector3i goal_cell = goal_snap.cell;

	if (start_cell == goal_cell) {
		PackedVector3Array result;
		result.push_back(start);
		result.push_back(cell_center(goal_cell));
		return result;
	}

	// A goal sealed off from the start is answered here, not by a search
	// that has to exhaust itself (MAX_EXPANSIONS, ~160 ms) to find out.
	if (!regions_may_connect(start_cell, goal_cell, flying)) {
		return PackedVector3Array();
	}

	// Coarse-guided fast path: restrict the fine search to a corridor of
	// chunks around an approximate chunk-level route. The coarse pass is
	// deliberately optimistic (ignores clearance/occupancy entirely), so
	// it can never make the fine search MISS a real path that exists — if
	// the restricted search fails, fall back to a full unrestricted one
	// below. This mirrors the project's standing rule that a speed
	// optimization must never silently change correctness (see the old
	// navmesh outage in HANDOFF.md): it can only affect how fast a path is
	// found, never whether one is found when it exists.
	std::vector<uint8_t> corridor = coarse_corridor(start_cell, goal_cell, flying);
	PackedVector3Array raw;
	if (!corridor.empty()) {
		raw = a_star(start, start_cell, goal_cell, offsets, clearance, height, flying, unit, &corridor);
	}
	if (raw.size() < 2) {
		raw = a_star(start, start_cell, goal_cell, offsets, clearance, height, flying, unit, nullptr);
	}
	if (raw.size() < 2) {
		return raw;
	}
	return smooth_path(raw, offsets, clearance, height, flying, unit);
}

void NavigationGrid::ensure_neighbor_offsets() {
	if (!neighbor_offsets.empty()) {
		return;
	}
	for (int dx = -1; dx <= 1; dx++) {
		for (int dy = -1; dy <= 1; dy++) {
			for (int dz = -1; dz <= 1; dz++) {
				if (dx == 0 && dy == 0 && dz == 0) {
					continue;
				}
				neighbor_offsets.push_back(Vector3i(dx, dy, dz));
				// The 26 offsets are a fixed, known-in-advance set — every
				// step cost is one of exactly 3 values (1, sqrt(2), sqrt(3))
				// times CELL_SIZE. Precomputing here means a_star's hot loop
				// reads a float instead of calling length() (a sqrt) on
				// every neighbor of every expansion.
				neighbor_step_cost.push_back(Vector3((float)dx, (float)dy, (float)dz).length() * CELL_SIZE);
			}
		}
	}
}

float NavigationGrid::heuristic(const Vector3i &a, const Vector3i &b) {
	Vector3i d = a - b;
	return Vector3((float)d.x, (float)d.y, (float)d.z).length() * CELL_SIZE;
}

float NavigationGrid::coarse_heuristic(const Vector3i &a, const Vector3i &b) {
	// Chunk-hop units (matches the coarse search's +1.0f per edge) — kept
	// separate from heuristic() above, which is scaled to world meters and
	// would badly under-inform a chunk-graph search if reused here.
	Vector3i d = a - b;
	return Vector3((float)d.x, (float)d.y, (float)d.z).length();
}

namespace {
struct OpenEntry {
	float priority;
	Vector3i cell;
};
struct OpenEntryCompare {
	bool operator()(const OpenEntry &a, const OpenEntry &b) const {
		return a.priority > b.priority;
	}
};
} // namespace

std::vector<uint8_t> NavigationGrid::coarse_corridor(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying) {
	std::vector<uint8_t> corridor; // stays empty (size 0) to signal "not found"

	Vector3i start_chunk = cell_to_chunk_coord(start_cell);
	Vector3i goal_chunk = cell_to_chunk_coord(goal_cell);
	if (!chunk_in_bounds(start_chunk) || !chunk_in_bounds(goal_chunk)) {
		return corridor;
	}

	auto traversable = [&](const Vector3i &cc) -> bool {
		NavChunk &c = ensure_chunk_support(cc);
		return flying ? c.has_flyable : c.has_ground_passable;
	};
	if (!traversable(start_chunk) || !traversable(goal_chunk)) {
		return corridor;
	}

	static const Vector3i FACE[6] = {
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	};

	int start_idx = chunk_coord_index(start_chunk);
	int goal_idx = chunk_coord_index(goal_chunk);

	std::unordered_map<int, int> came_from;
	std::unordered_map<int, float> g_score;
	std::unordered_set<int> closed;
	std::priority_queue<OpenEntry, std::vector<OpenEntry>, OpenEntryCompare> open_heap;

	g_score[start_idx] = 0.0f;
	open_heap.push({ coarse_heuristic(start_chunk, goal_chunk), start_chunk });

	bool found = false;
	while (!open_heap.empty()) {
		OpenEntry top = open_heap.top();
		open_heap.pop();
		int cur_idx = chunk_coord_index(top.cell);
		if (closed.count(cur_idx)) {
			continue;
		}
		closed.insert(cur_idx);
		if (cur_idx == goal_idx) {
			found = true;
			break;
		}

		float cur_g = g_score[cur_idx];
		for (const Vector3i &f : FACE) {
			Vector3i nc = top.cell + f;
			if (!chunk_in_bounds(nc)) {
				continue;
			}
			int nidx = chunk_coord_index(nc);
			if (closed.count(nidx)) {
				continue;
			}
			if (!traversable(nc)) {
				continue;
			}
			float ng = cur_g + 1.0f;
			auto gs_it = g_score.find(nidx);
			if (gs_it == g_score.end() || ng < gs_it->second) {
				g_score[nidx] = ng;
				came_from[nidx] = cur_idx;
				open_heap.push({ ng + coarse_heuristic(nc, goal_chunk), nc });
			}
		}
	}

	if (!found) {
		return corridor; // empty — caller falls back to an unrestricted fine search
	}

	std::vector<int> route;
	int cur = goal_idx;
	route.push_back(cur);
	while (cur != start_idx) {
		cur = came_from.at(cur);
		route.push_back(cur);
	}

	corridor.assign((size_t)chunk_grid_size.x * (size_t)chunk_grid_size.y * (size_t)chunk_grid_size.z, 0);
	for (int idx : route) {
		Vector3i cc = chunk_coord_from_index(idx);
		for (int dx = -CORRIDOR_RADIUS_CHUNKS; dx <= CORRIDOR_RADIUS_CHUNKS; dx++) {
			for (int dy = -CORRIDOR_RADIUS_CHUNKS; dy <= CORRIDOR_RADIUS_CHUNKS; dy++) {
				for (int dz = -CORRIDOR_RADIUS_CHUNKS; dz <= CORRIDOR_RADIUS_CHUNKS; dz++) {
					Vector3i nc = cc + Vector3i(dx, dy, dz);
					if (chunk_in_bounds(nc)) {
						corridor[chunk_coord_index(nc)] = 1;
					}
				}
			}
		}
	}
	return corridor;
}

// --- Connectivity regions ----------------------------------------------------

NavRegions &NavigationGrid::ensure_chunk_regions(const Vector3i &chunk_coord, bool flying) {
	NavChunk &chunk = ensure_chunk_support(chunk_coord);
	NavRegions &r = chunk.regions[flying ? 1 : 0];
	if (r.labelled) {
		return r;
	}
	r.labelled = true;
	const size_t n = (size_t)CHUNK_DIM * CHUNK_DIM * CHUNK_DIM;
	r.label.assign(n, 0);
	r.count = 0;

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	// Open = is_valid_cell's tests that hold for every clearance and height:
	// dist > clearance >= 0 is exactly "not solid" (bake_chunk_dist writes 0
	// for solid cells only), and the body's first layer is the cell itself.
	// Closed cells stay 0; open ones are marked UINT16_MAX until labelled.
	const uint16_t OPEN = 0xFFFF;
	bool any_open = false;
	for (int y = 0; y < cy1; y++) {
		float world_y = bounds_origin.y + ((float)(base.y + y) + 0.5f) * CELL_SIZE;
		if (flying && world_y > FLIGHT_CEILING_HEIGHT) {
			continue;
		}
		for (int z = 0; z < cz1; z++) {
			for (int x = 0; x < cx1; x++) {
				int li = local_index(Vector3i(x, y, z));
				if (chunk.solid[li] != 0) {
					continue;
				}
				if (flying ? chunk.flight_low[li] != 0 : chunk.no_support[li] != 0) {
					continue;
				}
				r.label[li] = OPEN;
				any_open = true;
			}
		}
	}
	if (!any_open) {
		return r;
	}

	std::vector<int> stack;
	for (int seed = 0; seed < (int)n; seed++) {
		if (r.label[seed] != OPEN) {
			continue;
		}
		uint16_t id = ++r.count;
		r.label[seed] = id;
		stack.push_back(seed);
		while (!stack.empty()) {
			int li = stack.back();
			stack.pop_back();
			int x = li % CHUNK_DIM;
			int y = (li / CHUNK_DIM) % CHUNK_DIM;
			int z = li / (CHUNK_DIM * CHUNK_DIM);
			for (int dz = -1; dz <= 1; dz++) {
				int nz = z + dz;
				if (nz < 0 || nz >= CHUNK_DIM) {
					continue;
				}
				for (int dy = -1; dy <= 1; dy++) {
					int ny = y + dy;
					if (ny < 0 || ny >= CHUNK_DIM) {
						continue;
					}
					for (int dx = -1; dx <= 1; dx++) {
						int nx = x + dx;
						if (nx < 0 || nx >= CHUNK_DIM) {
							continue;
						}
						int ni = local_index(Vector3i(nx, ny, nz));
						if (r.label[ni] == OPEN) {
							r.label[ni] = id;
							stack.push_back(ni);
						}
					}
				}
			}
		}
	}
	return r;
}

NavRegions &NavigationGrid::ensure_chunk_region_links(const Vector3i &chunk_coord, bool flying) {
	NavRegions &r = ensure_chunk_regions(chunk_coord, flying);
	if (r.linked) {
		return r;
	}
	r.linked = true;
	r.links.assign(r.count, std::vector<uint64_t>());
	if (r.count == 0) {
		return r;
	}

	// The 26 neighbouring chunks' labels, resolved once. chunks is sized
	// once per scan, so these references stay valid while more are built.
	const NavRegions *around[3][3][3] = {};
	uint64_t around_idx[3][3][3] = {};
	for (int dx = -1; dx <= 1; dx++) {
		for (int dy = -1; dy <= 1; dy++) {
			for (int dz = -1; dz <= 1; dz++) {
				Vector3i nc = chunk_coord + Vector3i(dx, dy, dz);
				if ((dx == 0 && dy == 0 && dz == 0) || !chunk_in_bounds(nc)) {
					continue;
				}
				around[dx + 1][dy + 1][dz + 1] = &ensure_chunk_regions(nc, flying);
				around_idx[dx + 1][dy + 1][dz + 1] = (uint64_t)chunk_coord_index(nc);
			}
		}
	}

	const int last = CHUNK_DIM - 1;
	for (int z = 0; z < CHUNK_DIM; z++) {
		for (int y = 0; y < CHUNK_DIM; y++) {
			for (int x = 0; x < CHUNK_DIM; x++) {
				if (x != 0 && x != last && y != 0 && y != last && z != 0 && z != last) {
					continue;
				}
				uint16_t own = r.label[local_index(Vector3i(x, y, z))];
				if (own == 0) {
					continue;
				}
				std::vector<uint64_t> &out = r.links[own - 1];
				for (int dz = -1; dz <= 1; dz++) {
					for (int dy = -1; dy <= 1; dy++) {
						for (int dx = -1; dx <= 1; dx++) {
							int nx = x + dx, ny = y + dy, nz = z + dz;
							int cdx = nx < 0 ? -1 : (nx > last ? 1 : 0);
							int cdy = ny < 0 ? -1 : (ny > last ? 1 : 0);
							int cdz = nz < 0 ? -1 : (nz > last ? 1 : 0);
							if (cdx == 0 && cdy == 0 && cdz == 0) {
								continue; // inside this chunk: same region already
							}
							const NavRegions *nb = around[cdx + 1][cdy + 1][cdz + 1];
							if (!nb) {
								continue;
							}
							uint16_t other = nb->label[local_index(Vector3i(nx - cdx * CHUNK_DIM, ny - cdy * CHUNK_DIM, nz - cdz * CHUNK_DIM))];
							if (other != 0) {
								out.push_back((around_idx[cdx + 1][cdy + 1][cdz + 1] << 16) | other);
							}
						}
					}
				}
			}
		}
	}
	for (std::vector<uint64_t> &out : r.links) {
		std::sort(out.begin(), out.end());
		out.erase(std::unique(out.begin(), out.end()), out.end());
	}
	return r;
}

uint64_t NavigationGrid::region_key(const Vector3i &cell, bool flying) {
	if (!in_bounds(cell)) {
		return 0;
	}
	Vector3i cc = cell_to_chunk_coord(cell);
	uint16_t label = ensure_chunk_regions(cc, flying).label[local_index(cell_to_local(cell))];
	if (label == 0) {
		return 0;
	}
	return ((uint64_t)chunk_coord_index(cc) << 16) | label;
}

bool NavigationGrid::regions_may_connect(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying) {
	uint64_t goal_key = region_key(goal_cell, flying);
	if (goal_key == 0) {
		return true; // the goal passed is_valid_cell, so this can't happen; let the search decide
	}
	// a_star expands the start cell whether or not it is valid, then steps
	// only into valid cells: its own region if open, else its neighbours'.
	std::vector<uint64_t> seeds;
	uint64_t own = region_key(start_cell, flying);
	if (own != 0) {
		seeds.push_back(own);
	} else {
		for (const Vector3i &offset : neighbor_offsets) {
			uint64_t k = region_key(start_cell + offset, flying);
			if (k != 0 && std::find(seeds.begin(), seeds.end(), k) == seeds.end()) {
				seeds.push_back(k);
			}
		}
	}
	if (seeds.empty()) {
		return false;
	}
	if (std::find(seeds.begin(), seeds.end(), goal_key) != seeds.end()) {
		return true;
	}

	// Greedy best-first from both ends, each heading for the other's chunk;
	// always grow the smaller frontier. A node is checked against the other
	// side when first seen, so a shared region is caught by whichever side
	// reaches it second. A side that runs out has walked its whole
	// component without touching the other: no path.
	struct Side {
		std::unordered_set<uint64_t> seen;
		std::priority_queue<std::pair<float, uint64_t>, std::vector<std::pair<float, uint64_t>>, std::greater<std::pair<float, uint64_t>>> open;
		Vector3i toward;
	};
	Side sides[2];
	sides[0].toward = cell_to_chunk_coord(goal_cell);
	sides[1].toward = cell_to_chunk_coord(start_cell);
	auto priority = [&](uint64_t key, const Vector3i &toward) -> float {
		return coarse_heuristic(chunk_coord_from_index((int)(key >> 16)), toward);
	};
	for (uint64_t k : seeds) {
		sides[0].seen.insert(k);
		sides[0].open.push({ priority(k, sides[0].toward), k });
	}
	sides[1].seen.insert(goal_key);
	sides[1].open.push({ priority(goal_key, sides[1].toward), goal_key });

	for (int expansions = 0; expansions < MAX_REGION_EXPANSIONS; expansions++) {
		if (sides[0].open.empty() || sides[1].open.empty()) {
			return false;
		}
		int s = sides[0].open.size() <= sides[1].open.size() ? 0 : 1;
		Side &me = sides[s];
		Side &other = sides[1 - s];
		uint64_t key = me.open.top().second;
		me.open.pop();
		Vector3i cc = chunk_coord_from_index((int)(key >> 16));
		const NavRegions &r = ensure_chunk_region_links(cc, flying);
		for (uint64_t next : r.links[(key & 0xFFFF) - 1]) {
			if (other.seen.count(next)) {
				return true;
			}
			if (me.seen.insert(next).second) {
				me.open.push({ priority(next, me.toward), next });
			}
		}
	}
	return true; // too big to settle cheaply: the search decides, capped as ever
}

PackedVector3Array NavigationGrid::a_star(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit, const std::vector<uint8_t> *allowed_chunks_mask) {
	std::priority_queue<OpenEntry, std::vector<OpenEntry>, OpenEntryCompare> open_heap;

	astar_search_id++;
	int sid = astar_search_id;

	int start_idx = cell_index(start_cell);
	astar_g_score[start_idx] = 0.0f;
	astar_g_gen[start_idx] = sid;
	open_heap.push({ heuristic(start_cell, goal_cell) * HEURISTIC_WEIGHT, start_cell });

	int expansions = 0;

	while (!open_heap.empty()) {
		OpenEntry top = open_heap.top();
		open_heap.pop();
		Vector3i current = top.cell;
		int current_idx = cell_index(current);
		if (astar_closed_gen[current_idx] == sid) {
			continue;
		}
		astar_closed_gen[current_idx] = sid;

		if (current == goal_cell) {
			return reconstruct_path(start, start_cell, goal_cell);
		}

		expansions++;
		if (expansions > MAX_EXPANSIONS) {
			break;
		}

		float current_g = astar_g_score[current_idx];

		for (size_t oi = 0; oi < neighbor_offsets.size(); oi++) {
			const Vector3i &offset = neighbor_offsets[oi];
			Vector3i neighbor = current + offset;
			if (!in_bounds(neighbor)) {
				continue;
			}
			if (allowed_chunks_mask && !(*allowed_chunks_mask)[chunk_coord_index(cell_to_chunk_coord(neighbor))]) {
				continue;
			}
			int neighbor_idx = cell_index(neighbor);
			if (astar_closed_gen[neighbor_idx] == sid) {
				continue;
			}
			if (!is_valid_cell(neighbor, offsets, clearance, height, flying, unit)) {
				continue;
			}
			float step_cost = neighbor_step_cost[oi];
			float tentative = current_g + step_cost;
			float neighbor_g = (astar_g_gen[neighbor_idx] == sid) ? astar_g_score[neighbor_idx] : 1e30f;
			if (tentative < neighbor_g) {
				astar_g_score[neighbor_idx] = tentative;
				astar_g_gen[neighbor_idx] = sid;
				astar_came_from[neighbor_idx] = current_idx;
				open_heap.push({ tentative + heuristic(neighbor, goal_cell) * HEURISTIC_WEIGHT, neighbor });
			}
		}
	}

	return PackedVector3Array();
}

PackedVector3Array NavigationGrid::reconstruct_path(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell) {
	int start_idx = cell_index(start_cell);
	std::vector<int> cell_indices;
	cell_indices.push_back(cell_index(goal_cell));
	int cur = cell_indices[0];
	while (cur != start_idx) {
		cur = astar_came_from[cur];
		cell_indices.push_back(cur);
	}
	std::reverse(cell_indices.begin(), cell_indices.end());

	PackedVector3Array result;
	result.push_back(start);
	for (size_t i = 1; i < cell_indices.size(); i++) {
		result.push_back(cell_center(cell_from_index(cell_indices[i])));
	}
	return result;
}

PackedVector3Array NavigationGrid::smooth_path(const PackedVector3Array &path, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit) {
	if (path.size() <= 2) {
		return path;
	}

	smooth_search_id++;
	int sid = smooth_search_id;

	PackedVector3Array result;
	result.push_back(path[0]);
	int anchor = 0;
	int probe = 2;
	while (probe < path.size()) {
		if (line_clear(path[anchor], path[probe], offsets, clearance, height, flying, unit, sid)) {
			probe++;
		} else {
			result.push_back(path[probe - 1]);
			anchor = probe - 1;
			probe++;
		}
	}
	result.push_back(path[path.size() - 1]);
	return result;
}

bool NavigationGrid::line_clear(const Vector3 &a, const Vector3 &b, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit, int smooth_sid) {
	float length = a.distance_to(b);
	int steps = std::max(1, (int)std::ceil(length / CELL_SIZE));
	for (int i = 1; i < steps; i++) {
		float t = (float)i / (float)steps;
		Vector3i cell = world_to_cell(a.lerp(b, t));
		if (is_valid_cell_cached(cell, offsets, clearance, height, flying, unit, smooth_sid)) {
			continue;
		}
		// A walker's standing cells climb a slope in whole-cell stairs, so
		// a straight line up a ramp passes through the layer above or below
		// them between treads. The ground under the line is still there, a
		// cell off, and the same one-cell rise A* steps between neighbours.
		// Where the ground bends away from the line further than that (the
		// knee where a ramp meets the floor), the corner stays a waypoint.
		if (!flying && (is_valid_cell_cached(cell + Vector3i(0, 1, 0), offsets, clearance, height, flying, unit, smooth_sid) || is_valid_cell_cached(cell - Vector3i(0, 1, 0), offsets, clearance, height, flying, unit, smooth_sid))) {
			continue;
		}
		return false;
	}
	return true;
}

// Memoized wrapper around is_valid_cell for use within a single
// smooth_path() call — see the header comment on smooth_valid_gen for
// why this is exact (not approximate) despite the cache. Mirrors
// is_valid_cell's own out-of-bounds handling (false) so callers can
// treat this as a drop-in replacement.
bool NavigationGrid::is_valid_cell_cached(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit, int smooth_sid) {
	if (!in_bounds(cell)) {
		return false;
	}
	int idx = cell_index(cell);
	if (smooth_valid_gen[idx] == smooth_sid) {
		return smooth_valid_result[idx] != 0;
	}
	bool result = is_valid_cell(cell, offsets, clearance, height, flying, self_unit);
	smooth_valid_gen[idx] = smooth_sid;
	smooth_valid_result[idx] = result ? (uint8_t)1 : (uint8_t)0;
	return result;
}

// --- Duck-typed GDScript "Unit" property/method access ---------------------

float NavigationGrid::get_float_prop(Object *obj, const StringName &name) {
	Variant v = obj->get(name);
	return (float)(double)v;
}

bool NavigationGrid::call_bool(Object *obj, const StringName &method) {
	Variant v = obj->call(method);
	return (bool)v;
}
