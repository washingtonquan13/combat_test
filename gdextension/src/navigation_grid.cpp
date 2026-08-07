#include "navigation_grid.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <queue>
#include <unordered_set>
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

void NavigationGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("ensure_baked", "tree"), &NavigationGrid::ensure_baked);
	ClassDB::bind_method(D_METHOD("update_occupancy", "tree", "movers"), &NavigationGrid::update_occupancy);
	ClassDB::bind_method(D_METHOD("nearest_valid_point", "tree", "point", "clearance", "flying", "exclude_unit", "max_radius_cells"), &NavigationGrid::nearest_valid_point, DEFVAL(Variant()), DEFVAL(12));
	ClassDB::bind_method(D_METHOD("find_path", "tree", "start", "destination", "unit", "flying"), &NavigationGrid::find_path);
	ClassDB::bind_method(D_METHOD("world_to_cell", "pos"), &NavigationGrid::world_to_cell);

	ClassDB::bind_method(D_METHOD("get_cell_size"), &NavigationGrid::get_cell_size);
	ClassDB::bind_method(D_METHOD("get_flight_min_altitude"), &NavigationGrid::get_flight_min_altitude);
	ClassDB::bind_method(D_METHOD("get_flight_ceiling_height"), &NavigationGrid::get_flight_ceiling_height);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "CELL_SIZE"), "", "get_cell_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "FLIGHT_MIN_ALTITUDE"), "", "get_flight_min_altitude");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "FLIGHT_CEILING_HEIGHT"), "", "get_flight_ceiling_height");
}

float NavigationGrid::get_cell_size() const { return CELL_SIZE; }
float NavigationGrid::get_flight_min_altitude() const { return FLIGHT_MIN_ALTITUDE; }
float NavigationGrid::get_flight_ceiling_height() const { return FLIGHT_CEILING_HEIGHT; }

// --- Setup / bake ---------------------------------------------------------

void NavigationGrid::ensure_baked(SceneTree *tree) {
	if (baked) {
		return;
	}
	bake_static(tree);
	baked = true;
}

void NavigationGrid::bake_static(SceneTree *tree) {
	std::vector<CollisionShape3D *> shapes;
	Node *root = tree->get_current_scene();
	if (root) {
		collect_static_shapes(root, shapes);
	}

	Vector3 world_min, world_max;
	bool have_bounds = false;
	for (CollisionShape3D *cs : shapes) {
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
	solid.assign((size_t)grid_size.x * (size_t)grid_size.y * (size_t)grid_size.z, 0);

	for (CollisionShape3D *cs : shapes) {
		rasterize_shape(cs);
	}

	bake_no_support();
}

void NavigationGrid::bake_no_support() {
	no_support.assign(solid.size(), 0);
	for (int z = 0; z < grid_size.z; z++) {
		for (int y = 0; y < grid_size.y; y++) {
			for (int x = 0; x < grid_size.x; x++) {
				bool supported = y > 0 && solid[cell_index(Vector3i(x, y - 1, z))] != 0;
				if (!supported) {
					no_support[cell_index(Vector3i(x, y, z))] = 1;
				}
			}
		}
	}
}

void NavigationGrid::collect_static_shapes(Node *node, std::vector<CollisionShape3D *> &out) {
	StaticBody3D *sb = Object::cast_to<StaticBody3D>(node);
	if (sb) {
		int count = sb->get_child_count();
		for (int i = 0; i < count; i++) {
			CollisionShape3D *cs = Object::cast_to<CollisionShape3D>(sb->get_child(i));
			if (cs && cs->get_shape().is_valid()) {
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
	} else {
		Ref<ArrayMesh> mesh = shape->get_debug_mesh();
		local_aabb = mesh->get_aabb();
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

void NavigationGrid::rasterize_shape(CollisionShape3D *cs) {
	Ref<Shape3D> shape = cs->get_shape();
	Transform3D global_transform = cs->get_global_transform();
	AABB aabb = shape_global_aabb(cs);

	Vector3i min_cell = world_to_cell(aabb.position);
	Vector3i max_cell = world_to_cell(aabb.position + aabb.size);
	BoxShape3D *box = Object::cast_to<BoxShape3D>(shape.ptr());
	bool is_box = box != nullptr;
	Vector3 half_size = is_box ? box->get_size() * 0.5f : Vector3();
	Transform3D inverse = global_transform.affine_inverse();

	int x0 = std::max(min_cell.x, 0), x1 = std::min(max_cell.x + 1, grid_size.x);
	int y0 = std::max(min_cell.y, 0), y1 = std::min(max_cell.y + 1, grid_size.y);
	int z0 = std::max(min_cell.z, 0), z1 = std::min(max_cell.z + 1, grid_size.z);

	for (int x = x0; x < x1; x++) {
		for (int y = y0; y < y1; y++) {
			for (int z = z0; z < z1; z++) {
				Vector3i cell(x, y, z);
				Vector3 world_point = cell_center(cell);
				bool inside;
				if (is_box) {
					Vector3 local = inverse.xform(world_point);
					inside = std::abs(local.x) <= half_size.x && std::abs(local.y) <= half_size.y && std::abs(local.z) <= half_size.z;
				} else {
					inside = aabb.has_point(world_point);
				}
				if (inside) {
					solid[cell_index(cell)] = 1;
				}
			}
		}
	}
}

// --- Cell <-> world --------------------------------------------------------

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

bool NavigationGrid::is_solid(const Vector3i &cell) const {
	if (!in_bounds(cell)) {
		return true;
	}
	return solid[cell_index(cell)] != 0;
}

// --- Dynamic occupancy ------------------------------------------------------

void NavigationGrid::update_occupancy(SceneTree *tree, Array movers) {
	ensure_baked(tree);
	occupied.clear();

	TypedArray<Node> units = tree->get_nodes_in_group("units");
	for (int i = 0; i < units.size(); i++) {
		Object *obj = units[i];
		Node *node = Object::cast_to<Node>(obj);
		if (!node || !node->has_method("is_alive") || !call_bool(node, "is_alive")) {
			continue;
		}

		bool is_mover = false;
		for (int m = 0; m < movers.size(); m++) {
			if ((Object *)movers[m] == obj) {
				is_mover = true;
				break;
			}
		}
		if (is_mover) {
			continue;
		}

		Node3D *n3d = Object::cast_to<Node3D>(node);
		if (!n3d) {
			continue;
		}
		float clearance = get_float_prop(node, "radius") + get_float_prop(node, "avoidance_margin");
		Vector3i base_cell = world_to_cell(n3d->get_global_position());
		for (const Vector3i &offset : disc_offsets(clearance)) {
			Vector3i cell = base_cell + offset;
			if (in_bounds(cell)) {
				occupied[cell_index(cell)] = obj;
			}
		}
	}

	TypedArray<Node> corpses = tree->get_nodes_in_group("blocking_corpses");
	for (int i = 0; i < corpses.size(); i++) {
		Object *obj = corpses[i];
		Node *node = Object::cast_to<Node>(obj);
		if (!node) {
			continue;
		}
		Node3D *n3d = Object::cast_to<Node3D>(node);
		if (!n3d) {
			continue;
		}
		float clearance = get_float_prop(node, "radius") + get_float_prop(node, "avoidance_margin");
		Vector3i base_cell = world_to_cell(n3d->get_global_position());
		for (const Vector3i &offset : disc_offsets(clearance)) {
			Vector3i cell = base_cell + offset;
			if (in_bounds(cell)) {
				occupied[cell_index(cell)] = obj;
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

const std::vector<uint8_t> &NavigationGrid::get_inflated_solid(float clearance, const std::vector<Vector3i> &offsets) {
	int key = clearance_key(clearance);
	auto it = inflated_solid_cache.find(key);
	if (it != inflated_solid_cache.end()) {
		return it->second;
	}

	std::vector<uint8_t> inflated(solid.size(), 0);
	for (int z = 0; z < grid_size.z; z++) {
		for (int y = 0; y < grid_size.y; y++) {
			for (int x = 0; x < grid_size.x; x++) {
				Vector3i cell(x, y, z);
				if (solid[cell_index(cell)] == 0) {
					continue;
				}
				for (const Vector3i &offset : offsets) {
					Vector3i blocked_center = cell - offset;
					if (in_bounds(blocked_center)) {
						inflated[cell_index(blocked_center)] = 1;
					}
				}
			}
		}
	}

	auto emplaced = inflated_solid_cache.emplace(key, std::move(inflated));
	return emplaced.first->second;
}

bool NavigationGrid::is_clear_of_units(const Vector3i &cell, const std::vector<Vector3i> &offsets, Object *self_unit) const {
	if (occupied.empty()) {
		return true;
	}
	for (const Vector3i &offset : offsets) {
		Vector3i c = cell + offset;
		if (!in_bounds(c)) {
			continue;
		}
		auto it = occupied.find(cell_index(c));
		if (it != occupied.end() && it->second != self_unit) {
			return false;
		}
	}
	return true;
}

bool NavigationGrid::is_valid_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *self_unit) {
	if (cell.x < 0 || cell.y < 0 || cell.z < 0 || cell.x >= grid_size.x || cell.y >= grid_size.y || cell.z >= grid_size.z) {
		return false;
	}
	int idx = cell_index(cell);
	if (flying) {
		float world_y = bounds_origin.y + ((float)cell.y + 0.5f) * CELL_SIZE;
		if (world_y < FLIGHT_MIN_ALTITUDE || world_y > FLIGHT_CEILING_HEIGHT) {
			return false;
		}
	} else if (no_support[idx] != 0) {
		return false;
	}
	if (get_inflated_solid(clearance, offsets)[idx] != 0) {
		return false;
	}
	return is_clear_of_units(cell, offsets, self_unit);
}

// --- Nearest-valid-point utility --------------------------------------------

Dictionary NavigationGrid::nearest_valid_point(SceneTree *tree, Vector3 point, float clearance, bool flying, Object *exclude_unit, int max_radius_cells) {
	ensure_baked(tree);
	const std::vector<Vector3i> &offsets = disc_offsets(clearance);
	NearestResult snap = find_nearest_free_cell(world_to_cell(point), offsets, clearance, flying, exclude_unit, max_radius_cells);
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

NavigationGrid::NearestResult NavigationGrid::find_nearest_free_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *self_unit, int max_radius) {
	if (is_valid_cell(cell, offsets, clearance, flying, self_unit)) {
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
					if (is_valid_cell(candidate, offsets, clearance, flying, self_unit)) {
						return { true, candidate };
					}
				}
			}
		}
	}
	return { false, cell };
}

// --- Pathfinding -------------------------------------------------------------

PackedVector3Array NavigationGrid::find_path(SceneTree *tree, Vector3 start, Vector3 destination, Object *unit, bool flying) {
	ensure_baked(tree);

	float clearance = get_float_prop(unit, "radius") + get_float_prop(unit, "avoidance_margin");
	const std::vector<Vector3i> &offsets = disc_offsets(clearance);
	ensure_neighbor_offsets();

	Vector3i start_cell = world_to_cell(start);
	if (!in_bounds(start_cell)) {
		return PackedVector3Array();
	}

	NearestResult goal_snap = find_nearest_free_cell(world_to_cell(destination), offsets, clearance, flying, unit, 12);
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

	PackedVector3Array raw = a_star(start, start_cell, goal_cell, offsets, clearance, flying, unit);
	if (raw.size() < 2) {
		return raw;
	}
	return smooth_path(raw, offsets, clearance, flying, unit);
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
			}
		}
	}
}

float NavigationGrid::heuristic(const Vector3i &a, const Vector3i &b) {
	Vector3i d = a - b;
	return Vector3((float)d.x, (float)d.y, (float)d.z).length() * CELL_SIZE;
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

PackedVector3Array NavigationGrid::a_star(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *unit) {
	std::unordered_map<int, int> came_from;
	std::unordered_map<int, float> g_score;
	std::unordered_set<int> closed;
	std::priority_queue<OpenEntry, std::vector<OpenEntry>, OpenEntryCompare> open_heap;

	int start_idx = cell_index(start_cell);
	g_score[start_idx] = 0.0f;
	open_heap.push({ heuristic(start_cell, goal_cell), start_cell });

	int expansions = 0;

	while (!open_heap.empty()) {
		OpenEntry top = open_heap.top();
		open_heap.pop();
		Vector3i current = top.cell;
		int current_idx = cell_index(current);
		if (closed.count(current_idx)) {
			continue;
		}
		closed.insert(current_idx);

		if (current == goal_cell) {
			return reconstruct_path(came_from, start, start_cell, goal_cell);
		}

		expansions++;
		if (expansions > MAX_EXPANSIONS) {
			break;
		}

		float current_g = g_score[current_idx];

		for (const Vector3i &offset : neighbor_offsets) {
			Vector3i neighbor = current + offset;
			if (!in_bounds(neighbor)) {
				continue;
			}
			int neighbor_idx = cell_index(neighbor);
			if (closed.count(neighbor_idx)) {
				continue;
			}
			if (!is_valid_cell(neighbor, offsets, clearance, flying, unit)) {
				continue;
			}
			float step_cost = Vector3((float)offset.x, (float)offset.y, (float)offset.z).length() * CELL_SIZE;
			float tentative = current_g + step_cost;
			auto gs_it = g_score.find(neighbor_idx);
			float neighbor_g = (gs_it != g_score.end()) ? gs_it->second : 1e30f;
			if (tentative < neighbor_g) {
				g_score[neighbor_idx] = tentative;
				came_from[neighbor_idx] = current_idx;
				open_heap.push({ tentative + heuristic(neighbor, goal_cell), neighbor });
			}
		}
	}

	return PackedVector3Array();
}

PackedVector3Array NavigationGrid::reconstruct_path(const std::unordered_map<int, int> &came_from, const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell) {
	int start_idx = cell_index(start_cell);
	std::vector<int> cell_indices;
	cell_indices.push_back(cell_index(goal_cell));
	int cur = cell_indices[0];
	while (cur != start_idx) {
		cur = came_from.at(cur);
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

PackedVector3Array NavigationGrid::smooth_path(const PackedVector3Array &path, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *unit) {
	if (path.size() <= 2) {
		return path;
	}
	PackedVector3Array result;
	result.push_back(path[0]);
	int anchor = 0;
	int probe = 2;
	while (probe < path.size()) {
		if (line_clear(path[anchor], path[probe], offsets, clearance, flying, unit)) {
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

bool NavigationGrid::line_clear(const Vector3 &a, const Vector3 &b, const std::vector<Vector3i> &offsets, float clearance, bool flying, Object *unit) {
	float length = a.distance_to(b);
	int steps = std::max(1, (int)std::ceil(length / CELL_SIZE));
	for (int i = 1; i < steps; i++) {
		float t = (float)i / (float)steps;
		Vector3 point = a.lerp(b, t);
		if (!is_valid_cell(world_to_cell(point), offsets, clearance, flying, unit)) {
			return false;
		}
	}
	return true;
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
