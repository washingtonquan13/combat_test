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
#include <cstring>
#include <algorithm>
#include <godot_cpp/core/error_macros.hpp>

namespace godot {

// One CHUNK_DIM^3 cube of the grid. Lazily rasterized (solid geometry
// only), then baked in two independent tiers on top of that:
//   - support tier: no_support[] (needs solid straight down).
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

// A CHUNK_DIM^3 cell field kept as 64 bricks of 8^3 cells, where a brick
// holding one value stores only that value. Air, rock and a flat floor's
// one clearance are most of any chunk: the nav-structure probe measured
// 82-99.9% of bricks uniform, field by field, and a dense array paid
// 32,768 entries a chunk for them.
//
// Writing goes through a dense buffer: begin_write() opens one holding a
// value, the baker writes and re-reads it through the returned pointer
// exactly as it did the old dense array, and end_write() packs it and frees
// it. Readers use get(), or dense() for a bake that sweeps a whole
// neighbouring chunk. There is no operator[]: every access says which of
// the two it is, so a write cannot land on packed bricks unnoticed.
//
// Building with nav_verify=yes (scons) checks every pack against the
// buffer it came from.
template <typename T>
class BrickField {
public:
	static constexpr int DIM = 32; // CHUNK_DIM
	static constexpr int CELLS = DIM * DIM * DIM;
	static constexpr int SLOTS = 64; // (DIM / 8)^3
	static constexpr int BRICK_CELLS = 512;
	static constexpr uint8_t UNIFORM = 0xFF;

	BrickField() {
		std::fill(index, index + SLOTS, UNIFORM);
		std::fill(uniform, uniform + SLOTS, T(0));
	}
	BrickField(const BrickField &) = delete;
	BrickField &operator=(const BrickField &) = delete;

	// local_index (x + y*32 + z*1024) -> brick slot (bx + by*4 + bz*16)
	// and the cell's place in that brick (lx + ly*8 + lz*64).
	static inline int slot_of(int li) { return ((li >> 3) & 3) | ((li >> 6) & 12) | ((li >> 9) & 48); }
	static inline int local_of(int li) { return (li & 7) | ((li >> 2) & 56) | ((li >> 4) & 448); }

	inline T get(int li) const {
		const int s = slot_of(li);
		const uint8_t k = index[s];
		return k == UNIFORM ? uniform[s] : pool[(size_t)k * BRICK_CELLS + local_of(li)];
	}

	// Whether the field holds data: written once, and not reset since.
	bool present() const { return has_data; }
	bool brick_uniform(int slot) const { return index[slot] == UNIFORM; }
	// Every cell holds `value`, read off the slots without expanding.
	bool all_of(T value) const {
		if (dense_count != 0) {
			return false;
		}
		for (int s = 0; s < SLOTS; s++) {
			if (uniform[s] != value) {
				return false;
			}
		}
		return true;
	}
	int dense_bricks() const { return dense_count; }

	T *begin_write(T value) {
		release();
		work.assign(CELLS, value);
		return work.data();
	}
	// The open buffer, for a writer that is handed the field rather than
	// the pointer begin_write returned.
	T *work_data() {
		CRASH_COND_MSG(work.empty(), "BrickField: written outside begin_write/end_write");
		return work.data();
	}
	void end_write() {
		CRASH_COND_MSG(work.empty(), "BrickField: end_write without begin_write");
		bool flat[SLOTS];
		int dense = 0;
		for (int s = 0; s < SLOTS; s++) {
			const int base = brick_base(s);
			const T first = work[base];
			// A brick row is 8 cells, sizeof(T) 64-bit words: compare whole
			// words against a row of `first`, one branch per brick plane.
			uint64_t ref[sizeof(T)];
			{
				T row_of_first[8];
				std::fill(row_of_first, row_of_first + 8, first);
				std::memcpy(ref, row_of_first, sizeof(ref));
			}
			bool same = true;
			for (int lz = 0; lz < 8 && same; lz++) {
				uint64_t diff = 0;
				for (int ly = 0; ly < 8; ly++) {
					const T *row = work.data() + base + ly * DIM + lz * DIM * DIM;
					for (size_t w = 0; w < sizeof(T); w++) {
						uint64_t v;
						std::memcpy(&v, row + w * (8 / sizeof(T)), sizeof(v));
						diff |= v ^ ref[w];
					}
				}
				same = diff == 0;
			}
			flat[s] = same;
			uniform[s] = same ? first : T(0);
			dense += same ? 0 : 1;
		}
		dense_count = dense;
		pool.reset(dense > 0 ? new T[(size_t)dense * BRICK_CELLS] : nullptr);
		uint8_t next = 0;
		for (int s = 0; s < SLOTS; s++) {
			if (flat[s]) {
				index[s] = UNIFORM;
				continue;
			}
			index[s] = next;
			T *dst = pool.get() + (size_t)next * BRICK_CELLS;
			const int base = brick_base(s);
			for (int lz = 0; lz < 8; lz++) {
				for (int ly = 0; ly < 8; ly++) {
					std::memcpy(dst + ly * 8 + lz * 64, work.data() + base + ly * DIM + lz * DIM * DIM, 8 * sizeof(T));
				}
			}
			next++;
		}
		has_data = true;
#ifdef NAV_BRICK_VERIFY
		for (int li = 0; li < CELLS; li++) {
			CRASH_COND_MSG(get(li) != work[li], "BrickField: a packed cell reads back different");
		}
#endif
		std::vector<T>().swap(work);
	}

	// Every cell one value, with nothing allocated.
	void fill(T value) {
		release();
		std::fill(uniform, uniform + SLOTS, value);
		has_data = true;
	}

	// The whole field as a dense array (local_index order), for a bake
	// that sweeps it: expanded into `scratch`, or, for a chunk of all air
	// or all rock, a shared constant array with no copy at all.
	const T *dense(std::vector<T> &scratch) const {
		if (dense_count == 0 && (uniform[0] == T(0) || uniform[0] == T(1))) {
			bool same = true;
			for (int s = 1; s < SLOTS && same; s++) {
				same = uniform[s] == uniform[0];
			}
			if (same) {
				return constant(uniform[0]);
			}
		}
		scratch.resize(CELLS);
		for (int s = 0; s < SLOTS; s++) {
			const int base = brick_base(s);
			const uint8_t k = index[s];
			const T *src = k == UNIFORM ? nullptr : pool.get() + (size_t)k * BRICK_CELLS;
			for (int lz = 0; lz < 8; lz++) {
				for (int ly = 0; ly < 8; ly++) {
					T *row = scratch.data() + base + ly * DIM + lz * DIM * DIM;
					if (src) {
						std::memcpy(row, src + ly * 8 + lz * 64, 8 * sizeof(T));
					} else {
						std::fill(row, row + 8, uniform[s]);
					}
				}
			}
		}
		return scratch.data();
	}

	// What the field holds: the dense bricks and the open buffer. The
	// slots themselves are counted in sizeof(NavChunk).
	int64_t bytes() const {
		return (int64_t)dense_count * BRICK_CELLS * sizeof(T) + (int64_t)work.capacity() * sizeof(T);
	}

private:
	static inline int brick_base(int s) { return (s & 3) * 8 + ((s >> 2) & 3) * 8 * DIM + (s >> 4) * 8 * DIM * DIM; }
	static const T *constant(T value) {
		static const std::vector<T> zeros(CELLS, T(0));
		static const std::vector<T> ones(CELLS, T(1));
		return value == T(0) ? zeros.data() : ones.data();
	}
	void release() {
		pool.reset();
		dense_count = 0;
		std::fill(index, index + SLOTS, UNIFORM);
		std::fill(uniform, uniform + SLOTS, T(0));
		has_data = false;
	}

	uint8_t index[SLOTS]; // a dense brick's place in pool, or UNIFORM
	T uniform[SLOTS]; // a uniform brick's one value
	std::unique_ptr<T[]> pool; // dense_count bricks of BRICK_CELLS, slot order
	int dense_count = 0;
	bool has_data = false;
	std::vector<T> work; // open between begin_write and end_write only
};

// One chunk's connected regions for one movement mode (walking or flying).
// A cell is open when SOME unit of that mode could stand in it: not solid,
// supported (walking) or high enough (flying), under the flight ceiling
// (flying). That is is_valid_cell with clearance, height and occupancy
// taken away, so it holds for every cell any search could accept, and two
// cells in different regions can never be joined by a search. Open cells
// touching across any of the 26 neighbours share a region, the same
// neighbours a_star steps through. See NavigationGrid::regions_may_connect.
//
// Wide bodies get their own labelling (NavChunk::wide): a cell is open for
// a clearance class only if that class also fits at it, so a gap too narrow
// for a dragon splits regions the way a wall does.

// A region in a neighbouring chunk that a region here touches, and the box
// of this chunk's own cells (local coords) along that touch.
struct RegionLink {
	uint32_t chunk;
	uint16_t label;
	uint8_t lo[3];
	uint8_t hi[3];
};

// One region's part in the current query's route estimate
// (NavigationGrid::build_region_guide): the cost from `entry` on to the
// goal, where entry is the point the route leaves this region's side at.
struct RegionGuide {
	int gen = 0;
	bool settled = false;
	float g = 0.0f;
	Vector3i entry;
};

struct NavRegions {
	bool labelled = false;
	bool linked = false;
	uint16_t count = 0;
	BrickField<uint16_t> label; // CHUNK_DIM^3, 0 = closed, else 1..count
	// A region's links are links[link_first[region - 1]] up to
	// links[link_first[region]]; count + 1 entries once linked.
	std::vector<uint32_t> link_first;
	std::vector<RegionLink> links;
	std::vector<RegionGuide> guide; // sized on first use, one per region
};

// Clearance classes above class 0, which every body narrower than the first
// threshold shares (see NavigationGrid::CLEARANCE_CLASS_M).
constexpr int WIDE_CLASSES = 5;

// One occupant as is_clear_of_units tests it: a vertical column from its
// feet cell up `layers` cells, `clearance` (radius + margin) around.
struct OccupantVolume {
	Object *obj = nullptr; // compared, never dereferenced
	Vector3i cell;
	float clearance = 0.0f;
	int layers = 0;
};

// What each cell of a chunk is to a crawler of one size, worked out the first
// time a search asks and kept until the geometry around it changes. Working
// it out means testing a body-sized ball of cells, hundreds of them for a cell
// in open air, and a search asks about thousands. 8^3 bricks, allocated on
// first touch: a crawler only ever visits the surfaces.
struct CrawlCells {
	enum Kind : uint8_t {
		UNKNOWN = 0,
		NONE, // the body doesn't fit, or has nothing to hold on to
		HOLDING, // on a wall or ceiling
		FLOORED, // something to stand on straight below
	};
	std::unique_ptr<uint8_t[]> bricks[64];
};

// seal_interiors' labels of one chunk with shapes, from its raw raster:
// kept so a pass relabels only the chunks whose raster was laid again.
struct SealLabels {
	bool valid = false;
	int count = 0; // 6-connected open components within the chunk
	std::vector<uint16_t> row_start; // CHUNK_DIM^2 + 1, row = y * CHUNK_DIM + z
	std::vector<uint8_t> x0, x1; // open runs along x, inclusive
	std::vector<uint16_t> comp; // per run: its component
	// Components touching -x, +x, -y, +y, -z, +z (sorted, unique).
	std::vector<uint16_t> face[6];
	// Components meeting the +x, +y, +z neighbour's, when it has shapes too.
	std::vector<std::pair<uint16_t, uint16_t>> link[3];
	// Components the last pass sealed (sorted). Also kept, as {0}, for a
	// chunk with no shapes that is sealed whole.
	std::vector<uint16_t> sealed;
};

struct NavChunk {
	BrickField<uint8_t> solid; // CHUNK_DIM^3, 1 = solid geometry
	// CHUNK_DIM^3, parallel to solid: 1 = solid lying just under a walkable
	// ramp's face (a tilted box no steeper than MAX_WALKABLE_SLOPE_DEGREES;
	// see ramp_of). Such a cell is still solid, but it is ground under a
	// unit's feet, not a wall in its way, so bake_chunk_dist does not
	// measure clearance from it.
	BrickField<uint8_t> ground;
	BrickField<uint8_t> no_support; // CHUNK_DIM^3, 1 = nothing solid directly below
	// CHUNK_DIM^3, 1 = solid within FLIGHT_MIN_ALTITUDE straight below: too
	// low for a flier, which must stay that far above whatever is under it.
	BrickField<uint8_t> flight_low;
	// CHUNK_DIM^3, 1 = nothing solid within FLIGHT_MAX_ALTITUDE straight
	// below: too high for a flier, whose ceiling rides on the ground under
	// it the same way its floor does.
	BrickField<uint8_t> flight_high;
	BrickField<uint16_t> dist; // CHUNK_DIM^3, fixed-point cells (see DIST_SCALE) to nearest solid, same Y layer
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
	NavRegions regions[2]; // [0] walking, [1] flying
	// [flying][class - 1], allocated by the main thread for the classes
	// something in this world has asked about: a map with no dragon on it
	// pays nothing for them.
	std::unique_ptr<NavRegions> wide[2][WIDE_CLASSES];

	NavRegions &regions_of(bool flying, int cls) {
		if (cls == 0) {
			return regions[flying ? 1 : 0];
		}
		std::unique_ptr<NavRegions> &slot = wide[flying ? 1 : 0][cls - 1];
		if (!slot) {
			slot = std::make_unique<NavRegions>();
		}
		return *slot;
	}
	SealLabels seal;
	// By NavigationGrid::crawl_class. Empty on a map no crawler has walked.
	std::vector<std::unique_ptr<CrawlCells>> crawl;
};

// Fine-A* scratch in 8^3 bricks: a chunk's page holds one slot per brick,
// and a brick is allocated the first time a search reaches it and kept for
// later searches. A search's corridor crosses most of its chunks' cells
// nowhere (a fifth of them on the quarry), so whole-chunk pages paid for
// sky and rock no search entered.
//
// A brick is stamped with the last search that used it (see
// NavigationGrid::astar_search_id), and the first touch of a brick in a
// search clears its 512 state bytes, so a cell carries no stamp of its own
// and no page is ever cleared whole. state packs, low bits first:
// - came_dir (5 bits): the index into neighbor_offsets (26 of them) of the
//   step that reached the cell, not the parent's index: the parent is
//   cell - offset, which works the same in this brick or the next;
// - CHECKED: is_valid_cell has answered for the cell this search, and VALID
//   is that answer. A cell is reached from up to 26 expanded neighbours
//   before it closes, and each used to re-ask: for a tall wide body that is
//   a column of distance field reads and an occupancy disc scan every time;
// - CLOSED: expanded this search.
// g is this search's cost once the cell is CHECKED (set to "unreached"
// then), or for the start cell, which is never checked.
struct AStarBrick {
	static constexpr int CELLS = 8 * 8 * 8;
	static constexpr uint8_t DIR_MASK = 0x1f;
	static constexpr uint8_t CHECKED = 0x20;
	static constexpr uint8_t VALID = 0x40;
	static constexpr uint8_t CLOSED = 0x80;
	int gen = 0;
	uint8_t state[CELLS];
	float g[CELLS];
};

struct AStarPage {
	static constexpr int SIDE = 4; // CHUNK_DIM / 8
	static constexpr int BRICKS = SIDE * SIDE * SIDE;
	std::unique_ptr<AStarBrick> bricks[BRICKS];
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
	// A route over floors, walls and ceilings for a unit that can cling to
	// them (see is_crawl_cell).
	PackedVector3Array find_crawl_path(SceneTree *tree, Vector3 start, Vector3 destination, Object *unit, Array ignore = Array());
	// Which way the surface under a crawler faces; ZERO with none in reach.
	Vector3 crawl_normal(SceneTree *tree, Vector3 origin, Object *unit);
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
	// Measurement only (the nav-structure probe): how the active world's
	// cells would pack as uniform 8^3 bricks, field by field, and how much
	// of the search scratch any search since `since_search` wrote to.
	Dictionary debug_structure_stats(int since_search = -1) const;
	// Cells a_star has expanded since the grid was made, across every
	// search and world, and the id of the latest search, so a caller can
	// difference both around one query.
	int64_t debug_expansions() const { return debug_expansion_count; }
	int debug_search_id() const { return astar_search_id; }
	// Measurement only: milliseconds spent so far in each stage of making
	// and searching the grid (scan, seal, rasterize, support, dist,
	// regions, links, search), each counted exclusive of the stages it
	// calls, since the grid was made.
	Dictionary debug_bake_profile() const;
	// Bakes every chunk of world_ref's world through region links, walking
	// and flying, across cores, so no query pays a bake; returns the chunk
	// count. Called once at area load (WorldContext); a no-op for a world
	// already baked.
	int prebake(Node *world_ref);
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
	static constexpr float HEURISTIC_WEIGHT = 1.6f;

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
	// matter. Each brick records which search last touched it; a stale
	// one means "not part of the current search," and is cleared on its
	// first touch instead of clearing everything between queries.
	//
	// Paged by chunk index and bricked within the page (see AStarBrick),
	// a brick allocated only when a search first reaches it. It used to be
	// flat arrays over the whole world volume, 21 bytes for every cell of
	// the bounds whether any search ever went there or not, and a copy per
	// parked world: a big map's sky and rock cost more than everything
	// else the grid holds put together. Then whole-chunk pages of 18 bytes
	// a cell, half the quarry's memory after a few dozen searches.
	std::vector<std::unique_ptr<AStarPage>> astar_pages;
	int astar_search_id = 0;
	int64_t debug_expansion_count = 0;
	// The brick holding an in-bounds cell, allocated on first touch and
	// cleared on the first touch of search `sid`, and the cell's index
	// within it. a_star keeps the last brick it used, since most
	// neighbours share their parent's.
	AStarBrick &astar_brick(const Vector3i &cell, int sid, int &local);
	AStarBrick &astar_brick_in(int chunk_index, const Vector3i &local_cell, int sid);

	// is_valid_cell, answered once per cell per query. is_valid_cell is pure
	// for one find_path (grid and occupancy don't change mid-call), and the
	// search, the goal flood and smooth_path all ask it about the same body,
	// so all three share the search's CHECKED | VALID bytes: the line tests
	// walk cells the search already paid for.
	bool valid_this_search(AStarBrick &brick, int local, const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit);
	bool is_valid_cell_cached(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit);

	// a_star's open list, kept between searches so one costs no allocation:
	// f quantised into OPEN_BUCKET_M buckets, each a chain of open_nodes,
	// newest first. A push is two writes where a heap's is a sift through
	// log n entries; order is approximate only within one bucket, a quarter
	// of the 0.25 m cell.
	struct OpenNode {
		Vector3i cell;
		int next;
	};
	static constexpr float OPEN_BUCKET_M = 0.0625f;
	static constexpr int OPEN_BUCKET_LIMIT = 1 << 18;
	std::vector<int> open_heads; // bucket -> newest node in it, -1 = empty
	std::vector<OpenNode> open_nodes;

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

	// Set for the length of a crawl query only: is_valid_cell swaps its cell
	// rule on this, the way is_clear_of_units reads query_ignore.
	struct CrawlOffset {
		Vector3i offset;
		int d2;
	};
	static constexpr float CRAWL_SHELL_CELLS = 1.5f;
	static constexpr float CRAWL_OFF_FLOOR_COST = 1.5f;
	static constexpr float CRAWL_CONTACT_CELLS = 1.5f;
	bool crawl_query = false;
	float crawl_radius = 0.0f;
	// Which of NavChunk::crawl this size reads: an index into crawl_radii.
	int crawl_class = 0;
	std::vector<float> crawl_radii;
	int crawl_radius_cells = 0;
	float crawl_core2 = 0.0f;
	int crawl_floor_first = 0;
	int crawl_floor_last = 0;
	std::vector<CrawlOffset> crawl_ball;
	void begin_crawl_query(float radius);
	bool crawl_solid(const Vector3i &cell);
	CrawlCells::Kind classify_crawl_cell(const Vector3i &cell);
	CrawlCells::Kind crawl_kind(const Vector3i &cell);
	bool is_crawl_cell(const Vector3i &cell);
	bool crawl_has_floor(const Vector3i &cell);
	bool crawl_surface(const Vector3 &point, Vector3 &normal, Vector3 &nearest);
	Vector3 crawl_project(const Vector3 &point);

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
	std::vector<int> seal_interiors();
	bool every_chunk_baked() const;
	void bake_missing_tiers();
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
		if (chunk.solid.get(li) != 0) {
			return false;
		}
		if (flying) {
			return chunk.flight_low.get(li) == 0 && chunk.flight_high.get(li) == 0;
		}
		return chunk.no_support.get(li) == 0;
	}

	struct NearestResult {
		bool found;
		Vector3i cell;
	};
	NearestResult nearest_crawl_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, Object *unit, int max_radius);
	NearestResult find_nearest_free_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit, int max_radius);
	NearestResult find_escape_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit, int max_radius);

	void ensure_neighbor_offsets();
	static float heuristic(const Vector3i &a, const Vector3i &b);
	static float coarse_heuristic(const Vector3i &a, const Vector3i &b);

	// --- Connectivity regions ----------------------------------------
	// Whether a search from start_cell could ever reach goal_cell: false
	// only when it provably can't (their regions are not connected), so
	// find_path answers "no path" without exhausting a search for it. A
	// search from both ends at once over the region graph, so a goal
	// sealed off from the start (a pocket inside hollow terrain, a ledge
	// with no way up) fails in the time it takes to walk ITS side, not
	// the whole level. Labels are built with the rest of a chunk's tiers
	// and go with the chunks when the world is rescanned.
	static constexpr int MAX_REGION_EXPANSIONS = 20000;
	bool regions_may_connect(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying, int cls);
	NavRegions &ensure_chunk_regions(const Vector3i &chunk_coord, bool flying, int cls = 0);
	NavRegions &ensure_chunk_region_links(const Vector3i &chunk_coord, bool flying, int cls = 0);
	// (chunk index << 16) | label, or 0 for a closed cell.
	uint64_t region_key(const Vector3i &cell, bool flying, int cls);

	// A body's clearance class is the largest threshold (metres) it reaches.
	// A class's regions admit every cell its bodies can stand on and may
	// admit more, so they can rule a route out but never rule one in.
	static constexpr float CLEARANCE_CLASS_M[WIDE_CLASSES + 1] = { 0.0f, 1.0f, 1.5f, 2.0f, 3.0f, 4.0f };
	static int clearance_class(float clearance);
	// Has the class baked with the rest of a world baked whole, on the first
	// query that needs it. In a world baked lazily it follows chunk by chunk.
	void ensure_class_ready(bool flying, int cls);

	// The route estimate a_star steers by: an A* over the region graph from
	// the goal toward the start, leaving each region it reaches a cost-to-goal
	// and the point that cost is measured from. It stops once every region
	// that could be on a route about as short as the best one is settled.
	static constexpr float GUIDE_SLACK_RATIO = 1.1f;
	static constexpr float GUIDE_SLACK_M = 4.0f;
	void build_region_guide(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying, int cls);
	int guide_gen = 0;
	// Regions the guide never reached are at least this far by way of the
	// start (their cost to the goal plus their distance to the start).
	float guide_bound = 0.0f;

	// The goal's own side of a search, flooded alongside it. Regions
	// (above) ignore occupancy and only approximate clearance, so a goal
	// they pass can still
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
		int seen_count = 0;
		// cell_index, open addressed, -1 = empty. The budget bounds it, so
		// it lives on the stack and a query allocates nothing for it.
		static constexpr int SEEN_SLOTS = 2048;
		int64_t seen[SEEN_SLOTS];
		// False if the cell was already seen.
		bool mark_seen(int64_t index) {
			uint32_t slot = ((uint32_t)index * 2654435761u) >> 21;
			while (seen[slot] != -1) {
				if (seen[slot] == index) {
					return false;
				}
				slot = (slot + 1) & (SEEN_SLOTS - 1);
			}
			seen[slot] = index;
			seen_count++;
			return true;
		}
	};
	static_assert(GOAL_FLOOD_BUDGET + 26 < GoalFlood::SEEN_SLOTS / 2, "the flood's table must stay sparse");
	void goal_flood_begin(GoalFlood &flood, const Vector3i &start_cell, const Vector3i &goal_cell);
	void goal_flood_step(GoalFlood &flood, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit);

	PackedVector3Array a_star(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit, int cls, GoalFlood *flood = nullptr);
	PackedVector3Array reconstruct_path(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell);
	PackedVector3Array smooth_path(const PackedVector3Array &path, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit);
	bool line_clear(const Vector3 &a, const Vector3 &b, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit);

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
