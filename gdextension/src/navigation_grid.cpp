#include "navigation_grid.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>

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

void NavigationGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("ensure_baked", "tree"), &NavigationGrid::ensure_baked);
	ClassDB::bind_method(D_METHOD("invalidate"), &NavigationGrid::invalidate);
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

	Node *root = tree->get_current_scene();
	if (root) {
		collect_static_shapes(root, all_shapes);
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
	rasterize_chunk(chunk_coord, chunk);
	chunk.rasterized = true;
	return chunk;
}

void NavigationGrid::rasterize_chunk(const Vector3i &chunk_coord, NavChunk &chunk) {
	auto it = shapes_by_chunk.find(chunk_coord_index(chunk_coord));
	if (it == shapes_by_chunk.end()) {
		return; // no geometry touches this chunk — stays all-air
	}

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	for (CollisionShape3D *cs : it->second) {
		Ref<Shape3D> shape = cs->get_shape();
		Transform3D global_transform = cs->get_global_transform();
		AABB aabb = shape_global_aabb(cs);
		BoxShape3D *box = Object::cast_to<BoxShape3D>(shape.ptr());
		bool is_box = box != nullptr;
		Vector3 half_size = is_box ? box->get_size() * 0.5f : Vector3();
		Transform3D inverse = global_transform.affine_inverse();

		for (int x = 0; x < cx1; x++) {
			for (int y = 0; y < cy1; y++) {
				for (int z = 0; z < cz1; z++) {
					Vector3i cell = base + Vector3i(x, y, z);
					Vector3 world_point = cell_center(cell);
					bool inside;
					if (is_box) {
						Vector3 local = inverse.xform(world_point);
						inside = std::abs(local.x) <= half_size.x && std::abs(local.y) <= half_size.y && std::abs(local.z) <= half_size.z;
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
	// no_support only ever reads straight down (x, y-1, z), so only the
	// vertical neighbor needs rasterizing ahead of this pass.
	Vector3i below_chunk = chunk_coord - Vector3i(0, 1, 0);
	if (chunk_in_bounds(below_chunk)) {
		ensure_chunk_rasterized(below_chunk);
	}

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	chunk.no_support.assign((size_t)CHUNK_DIM * CHUNK_DIM * CHUNK_DIM, 0);
	chunk.has_ground_passable = false;
	chunk.has_flyable = false;

	for (int x = 0; x < cx1; x++) {
		for (int y = 0; y < cy1; y++) {
			for (int z = 0; z < cz1; z++) {
				Vector3i cell = base + Vector3i(x, y, z);
				int li = local_index(Vector3i(x, y, z));
				bool supported = cell.y > 0 && is_solid(cell - Vector3i(0, 1, 0));
				chunk.no_support[li] = supported ? 0 : 1;

				bool cell_solid = chunk.solid[li] != 0;
				if (!cell_solid) {
					if (supported) {
						chunk.has_ground_passable = true;
					}
					float world_y = bounds_origin.y + ((float)cell.y + 0.5f) * CELL_SIZE;
					if (world_y >= FLIGHT_MIN_ALTITUDE && world_y <= FLIGHT_CEILING_HEIGHT) {
						chunk.has_flyable = true;
					}
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
	for (int dx = -1; dx <= 1; dx++) {
		for (int dz = -1; dz <= 1; dz++) {
			Vector3i nc = chunk_coord + Vector3i(dx, 0, dz);
			if (chunk_in_bounds(nc)) {
				NavChunk &nchunk = ensure_chunk_rasterized(nc);
				neighbor_solid[dx + 1][dz + 1] = nchunk.solid.data();
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

	chunk.dist.assign((size_t)CHUNK_DIM * CHUNK_DIM * CHUNK_DIM, (uint16_t)(MAX_CLEARANCE_CELLS * DIST_SCALE));

	struct QEntry {
		float d;
		int x, z;
	};
	struct QCmp {
		bool operator()(const QEntry &a, const QEntry &b) const { return a.d > b.d; }
	};
	static const int OX[8] = { 1, -1, 0, 0, 1, 1, -1, -1 };
	static const int OZ[8] = { 0, 0, 1, -1, 1, -1, 1, -1 };
	static const float OD[8] = { 1.f, 1.f, 1.f, 1.f, 1.41421356f, 1.41421356f, 1.41421356f, 1.41421356f };

	// Scratch buffers sized once to the (CHUNK_DIM + 2*reach) window and
	// reused across every Y layer via a generation stamp instead of a
	// hashmap — this is the same flat-array-over-unordered_map trade this
	// codebase already validated for the main A* search (see the header's
	// own comment on why that reversed between the GDScript and C++
	// ports). Measured necessary here too: an unordered_map<int64_t,float>
	// version of this per-chunk Dijkstra cost 50-80ms on a first touch —
	// dominated by hashmap churn from seeding/relaxing every solid cell in
	// a large flat slab (e.g. deep inside a thick floor), not by the
	// search itself.
	int reach = MAX_CLEARANCE_CELLS;
	int W = CHUNK_DIM + 2 * reach;
	std::vector<float> best(( size_t)W * W);
	std::vector<int> best_gen((size_t)W * W, 0);
	int gen = 0;
	auto idx2 = [&](int x, int z) -> int { return (x + reach) * W + (z + reach); };

	for (int y = 0; y < cy1; y++) {
		int world_y = base.y + y;
		gen++;

		std::priority_queue<QEntry, std::vector<QEntry>, QCmp> pq;
		bool any_air = false;

		for (int x = -reach; x < CHUNK_DIM + reach; x++) {
			for (int z = -reach; z < CHUNK_DIM + reach; z++) {
				Vector3i wc(base.x + x, world_y, base.z + z);
				if (!in_bounds(wc)) {
					continue;
				}
				bool local = x >= 0 && x < cx1 && z >= 0 && z < cz1;
				if (solid_fast(x, y, z)) {
					int li2 = idx2(x, z);
					best[li2] = 0.0f;
					best_gen[li2] = gen;
					pq.push({ 0.0f, x, z });
					// Written directly (not just left to the propagation
					// pass below) so a solid cell is ALWAYS correctly 0,
					// even in the any_air==false fast-out right after this
					// loop -- is_valid_cell has no separate is_solid guard
					// before consulting this field (a solid cell reaching
					// dist==0 is what makes it "always blocked" at all),
					// and a grounded search always tries the straight-down
					// neighbor, so a cell one layer into a thick floor slab
					// is genuinely reachable on every expansion, not a
					// theoretical case.
					if (local) {
						chunk.dist[local_index(Vector3i(x, y, z))] = 0;
					}
				} else if (local) {
					any_air = true;
				}
			}
		}

		// No open cell inside this chunk at this Y (e.g. deep inside a
		// thick floor slab, far from any edge) -- every local cell here is
		// solid and already got dist=0 written directly above, so there's
		// nothing left for the propagation pass to contribute within this
		// chunk. A neighboring chunk that DOES have air at this Y picks up
		// these same solid cells as sources independently, from its own
		// is_solid() reads reaching across the boundary -- each chunk's
		// dist field is computed self-containedly, so skipping propagation
		// here doesn't leave a neighbor under-informed.
		if (!any_air) {
			continue;
		}

		while (!pq.empty()) {
			QEntry top = pq.top();
			pq.pop();
			int li2 = idx2(top.x, top.z);
			if (best_gen[li2] != gen || top.d > best[li2]) {
				continue; // stale entry
			}

			if (top.x >= 0 && top.x < cx1 && top.z >= 0 && top.z < cz1) {
				int li = local_index(Vector3i(top.x, y, top.z));
				uint16_t clamped = (uint16_t)std::min((float)(MAX_CLEARANCE_CELLS * DIST_SCALE), top.d * DIST_SCALE);
				if (clamped < chunk.dist[li]) {
					chunk.dist[li] = clamped;
				}
			}
			if (top.d >= (float)MAX_CLEARANCE_CELLS) {
				continue;
			}

			for (int i = 0; i < 8; i++) {
				int nx = top.x + OX[i], nz = top.z + OZ[i];
				if (nx < -reach || nx >= CHUNK_DIM + reach || nz < -reach || nz >= CHUNK_DIM + reach) {
					continue;
				}
				Vector3i nwc(base.x + nx, world_y, base.z + nz);
				if (!in_bounds(nwc)) {
					continue;
				}
				float nd = top.d + OD[i];
				if (nd > (float)MAX_CLEARANCE_CELLS) {
					continue;
				}
				int nli2 = idx2(nx, nz);
				if (best_gen[nli2] != gen || nd < best[nli2]) {
					best[nli2] = nd;
					best_gen[nli2] = gen;
					pq.push({ nd, nx, nz });
				}
			}
		}
	}
}

// --- Dynamic occupancy -------------------------------------------------------

Object *NavigationGrid::occupant_at(const Vector3i &cell) const {
	if (!in_bounds(cell)) {
		return nullptr;
	}
	int idx = chunk_coord_index(cell_to_chunk_coord(cell));
	const std::unique_ptr<NavChunk> &slot = chunks[idx];
	if (!slot) {
		return nullptr;
	}
	auto it = slot->occupied.find(local_index(cell_to_local(cell)));
	return it != slot->occupied.end() ? it->second : nullptr;
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
	slot->occupied[local_index(cell_to_local(cell))] = obj;
	slot->has_occupancy = true;
}

void NavigationGrid::update_occupancy(SceneTree *tree, Array movers) {
	ensure_baked(tree);
	for (auto &slot : chunks) {
		if (slot) {
			slot->occupied.clear();
			slot->has_occupancy = false;
		}
	}
	any_occupied = false;

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
		// Proactively bake the chunk a live unit currently occupies so the
		// area around active play stays query-ready, not just wherever a
		// find_path/nearest_valid_point call has happened to land already.
		if (in_bounds(base_cell)) {
			ensure_chunk_dist(cell_to_chunk_coord(base_cell));
		}
		// A flying occupant needs a full 3D volume, not the horizontal-only
		// disc grounded units share a common Y reference for — see
		// sphere_offsets' own comment for why the horizontal disc alone
		// silently let two hovering units pass through each other.
		bool node_flying = node->has_method("is_flying") && call_bool(node, "is_flying");
		const std::vector<Vector3i> &occ_offsets = node_flying ? sphere_offsets(clearance) : disc_offsets(clearance);
		for (const Vector3i &offset : occ_offsets) {
			Vector3i cell = base_cell + offset;
			if (in_bounds(cell)) {
				set_occupant(cell, obj);
				any_occupied = true;
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
		// A corpse isn't force-landed on death (see UnitDeath.handle_death) --
		// one that died mid-air stays exactly where it was, so it needs
		// the same flying-aware volume as a live flying unit.
		bool node_flying = node->has_method("is_flying") && call_bool(node, "is_flying");
		const std::vector<Vector3i> &occ_offsets = node_flying ? sphere_offsets(clearance) : disc_offsets(clearance);
		for (const Vector3i &offset : occ_offsets) {
			Vector3i cell = base_cell + offset;
			if (in_bounds(cell)) {
				set_occupant(cell, obj);
				any_occupied = true;
			}
		}
	}

	refresh_chunk_occupancy_nearby();
}

// Precomputes, for every chunk, whether ANY chunk in its own 3x3x3
// neighborhood has_occupancy. This exact 27-chunk scan used to happen
// inline inside is_clear_of_units, freshly, on every single candidate
// cell a pathfinding query touched — up to once per neighbor per A*
// expansion. Occupancy itself only changes here, at a turn-boundary
// update_occupancy call, so the scan is a loop invariant with respect to
// any pathfinding query run between updates: computing it once here
// and reading an O(1) flag from is_clear_of_units is the same "hoist the
// invariant out of the hot path" trade already used for the flat A*
// scratch arrays and the per-chunk distance field elsewhere in this file.
void NavigationGrid::refresh_chunk_occupancy_nearby() {
	std::fill(chunk_occupancy_nearby.begin(), chunk_occupancy_nearby.end(), (uint8_t)0);
	if (!any_occupied) {
		return;
	}
	for (int idx = 0; idx < (int)chunks.size(); idx++) {
		Vector3i cc = chunk_coord_from_index(idx);
		bool nearby = false;
		for (int dx = -1; dx <= 1 && !nearby; dx++) {
			for (int dy = -1; dy <= 1 && !nearby; dy++) {
				for (int dz = -1; dz <= 1 && !nearby; dz++) {
					Vector3i nc = cc + Vector3i(dx, dy, dz);
					if (!chunk_in_bounds(nc)) {
						continue;
					}
					const std::unique_ptr<NavChunk> &slot = chunks[chunk_coord_index(nc)];
					if (slot && slot->has_occupancy) {
						nearby = true;
					}
				}
			}
		}
		chunk_occupancy_nearby[idx] = nearby ? (uint8_t)1 : (uint8_t)0;
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
// marking cells a FLYING unit/corpse occupies in update_occupancy. A
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
	// chunk-neighborhood check, precomputed once per update_occupancy call
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
		Object *occ = occupant_at(c);
		if (occ != nullptr && occ != self_unit) {
			return false;
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
		if (world_y < FLIGHT_MIN_ALTITUDE || world_y > FLIGHT_CEILING_HEIGHT) {
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

	if (!flying) {
		NavChunk &support_chunk = ensure_chunk_support(chunk_coord);
		if (support_chunk.no_support[li] != 0) {
			return false;
		}
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

Dictionary NavigationGrid::nearest_valid_point(SceneTree *tree, Vector3 point, float clearance, bool flying, Object *exclude_unit, int max_radius_cells) {
	ensure_baked(tree);
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

PackedVector3Array NavigationGrid::find_path(SceneTree *tree, Vector3 start, Vector3 destination, Object *unit, bool flying) {
	ensure_baked(tree);

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
		Vector3 point = a.lerp(b, t);
		if (!is_valid_cell_cached(world_to_cell(point), offsets, clearance, height, flying, unit, smooth_sid)) {
			return false;
		}
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
