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
#include <atomic>
#include <chrono>
#include <cmath>
#include <queue>
#include <thread>
#include <utility>

using namespace godot;

namespace {
Vector3 vmin(const Vector3 &a, const Vector3 &b) {
	return Vector3(std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z));
}
Vector3 vmax(const Vector3 &a, const Vector3 &b) {
	return Vector3(std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z));
}

// Exclusive time per bake stage (debug_bake_profile). A stage entered
// inside another pauses the outer one's clock until it returns. Main
// thread only: a prebake worker turns its clock off (stage_clock_on), and
// the main thread times each parallel phase whole instead.
enum BakeStage { STAGE_SCAN, STAGE_SEAL, STAGE_RASTERIZE, STAGE_SUPPORT, STAGE_DIST, STAGE_REGIONS, STAGE_LINKS, STAGE_SEARCH, STAGE_COUNT };
const char *const BAKE_STAGE_NAMES[STAGE_COUNT] = { "scan", "seal", "rasterize", "support", "dist", "regions", "links", "search" };
int64_t bake_stage_ns[STAGE_COUNT] = {};
int bake_stage_current = -1;
std::chrono::steady_clock::time_point bake_stage_since;
thread_local bool stage_clock_on = true;

struct StageClock {
	bool on;
	int previous = -1;
	explicit StageClock(int stage) :
			on(stage_clock_on) {
		if (!on) {
			return;
		}
		const auto now = std::chrono::steady_clock::now();
		if (bake_stage_current >= 0) {
			bake_stage_ns[bake_stage_current] += std::chrono::duration_cast<std::chrono::nanoseconds>(now - bake_stage_since).count();
		}
		previous = bake_stage_current;
		bake_stage_current = stage;
		bake_stage_since = now;
	}
	~StageClock() {
		if (!on) {
			return;
		}
		const auto now = std::chrono::steady_clock::now();
		bake_stage_ns[bake_stage_current] += std::chrono::duration_cast<std::chrono::nanoseconds>(now - bake_stage_since).count();
		bake_stage_current = previous;
		bake_stage_since = now;
	}
};

// Dense views of packed cell fields for the bakes that sweep whole chunks
// (BrickField::dense), kept so a bake does not allocate. One set per
// thread, so prebake's workers each have their own.
struct BakeScratch {
	// support: [0] the chunk itself, [k] the chunk k below.
	std::vector<std::vector<uint8_t>> support;
	// dist: [(dx + 1) * 3 + dz + 1], the chunk and its 8 side neighbours.
	std::vector<uint8_t> dist_solid[9];
	std::vector<uint8_t> dist_ground[9];
};
BakeScratch &bake_scratch() {
	thread_local BakeScratch s;
	return s;
}

// work(i) for every i in [0, count), spread over the machine's cores (the
// calling thread is one of them). Workers keep no stage clock.
template <typename F>
void parallel_for(int count, F &&work) {
	const int hw = (int)std::thread::hardware_concurrency();
	const int helpers = std::max(0, std::min(std::min(hw, 16) - 1, count / 8));
	std::atomic<int> next{ 0 };
	auto loop = [&]() {
		for (int i = next.fetch_add(1); i < count; i = next.fetch_add(1)) {
			work(i);
		}
	};
	std::vector<std::thread> threads;
	threads.reserve((size_t)helpers);
	for (int t = 0; t < helpers; t++) {
		threads.emplace_back([&]() {
			stage_clock_on = false;
			loop();
		});
	}
	const bool was_on = stage_clock_on;
	stage_clock_on = false;
	loop();
	stage_clock_on = was_on;
	for (std::thread &t : threads) {
		t.join();
	}
}
} // namespace

Dictionary NavigationGrid::debug_bake_profile() const {
	Dictionary d;
	for (int i = 0; i < STAGE_COUNT; i++) {
		d[BAKE_STAGE_NAMES[i]] = (double)bake_stage_ns[i] / 1.0e6;
	}
	return d;
}

// Every tier of every chunk, now, so no query pays a bake: called at area
// load, behind the fade (WorldContext). A chunk already baked is skipped,
// so a world re-entered costs nothing.
int NavigationGrid::prebake(Node *world_ref) {
	if (!world_ref || !world_ref->is_inside_tree()) {
		return 0;
	}
	activate_for(world_ref);
	ensure_baked(world_ref->get_tree());
	for (int i = 0; i < (int)chunks.size(); i++) {
		ensure_chunk_rasterized(chunk_coord_from_index(i));
	}
	// The wide classes of the bodies standing here, walking and flying both:
	// a dragon's first path would otherwise bake them mid-fight.
	TypedArray<Node> units = world_ref->get_tree()->get_nodes_in_group("units");
	for (int u = 0; u < units.size(); u++) {
		Node3D *unit = Object::cast_to<Node3D>((Object *)units[u]);
		if (!unit || !in_active_world(unit)) {
			continue;
		}
		const int cls = clearance_class(get_float_prop(unit, "radius") + get_float_prop(unit, "avoidance_margin"));
		if (cls == 0) {
			continue;
		}
		for (const std::unique_ptr<NavChunk> &chunk : chunks) {
			chunk->regions_of(false, cls);
			chunk->regions_of(true, cls);
		}
	}
	bake_missing_tiers();
	return (int)chunks.size();
}

bool NavigationGrid::every_chunk_baked() const {
	for (const std::unique_ptr<NavChunk> &slot : chunks) {
		if (!slot || !slot->rasterized || !slot->support_baked || !slot->dist_baked || !slot->regions[0].linked || !slot->regions[1].linked) {
			return false;
		}
	}
	return true;
}

// Whatever tiers any chunk lacks. Rasterizing reads the scene and stays on
// this thread; each later tier reads only tiers before it and writes only
// its own chunk, so it runs across cores, one phase at a time. A phase must
// finish every chunk before the next begins: a worker that found a tier
// below it missing would bake it in a neighbour another worker is reading.
void NavigationGrid::bake_missing_tiers() {
	const int count = (int)chunks.size();
	for (int i = 0; i < count; i++) {
		ensure_chunk_rasterized(chunk_coord_from_index(i));
	}
	auto phase = [&](BakeStage stage, auto &&needs, auto &&work) {
		StageClock clock(stage);
		std::vector<int> todo;
		for (int i = 0; i < count; i++) {
			if (needs(*chunks[i])) {
				todo.push_back(i);
			}
		}
		parallel_for((int)todo.size(), [&](int s) { work(todo[s], *chunks[todo[s]]); });
	};
	phase(STAGE_SUPPORT, [](const NavChunk &c) { return !c.support_baked; }, [&](int i, NavChunk &c) {
		bake_chunk_support(chunk_coord_from_index(i), c);
		c.support_baked = true;
	});
	phase(STAGE_DIST, [](const NavChunk &c) { return !c.dist_baked; }, [&](int i, NavChunk &c) {
		bake_chunk_dist(chunk_coord_from_index(i), c);
		c.dist_baked = true;
	});
	// Both modes at class 0, and every wide class this world has used. Its
	// slots are made here, on this thread, so the workers only ever read
	// the slot pointers.
	struct Layer {
		bool flying;
		int cls;
	};
	std::vector<Layer> layers = { { false, 0 }, { true, 0 } };
	for (int f = 0; f < 2; f++) {
		for (int cls = 1; cls <= WIDE_CLASSES; cls++) {
			bool used = false;
			for (int i = 0; i < count && !used; i++) {
				used = chunks[i]->wide[f][cls - 1] != nullptr;
			}
			if (!used) {
				continue;
			}
			for (int i = 0; i < count; i++) {
				chunks[i]->regions_of(f == 1, cls);
			}
			layers.push_back({ f == 1, cls });
		}
	}
	phase(STAGE_REGIONS, [&](NavChunk &c) {
		for (const Layer &l : layers) {
			if (!c.regions_of(l.flying, l.cls).labelled) {
				return true;
			}
		}
		return false; }, [&](int i, NavChunk &) {
		for (const Layer &l : layers) {
			ensure_chunk_regions(chunk_coord_from_index(i), l.flying, l.cls);
		}
	});
	phase(STAGE_LINKS, [&](NavChunk &c) {
		for (const Layer &l : layers) {
			if (!c.regions_of(l.flying, l.cls).linked) {
				return true;
			}
		}
		return false; }, [&](int i, NavChunk &) {
		for (const Layer &l : layers) {
			ensure_chunk_region_links(chunk_coord_from_index(i), l.flying, l.cls);
		}
	});
}

int NavigationGrid::clearance_class(float clearance) {
	int cls = 0;
	for (int k = 1; k <= WIDE_CLASSES; k++) {
		if (clearance >= CLEARANCE_CLASS_M[k]) {
			cls = k;
		}
	}
	return cls;
}

void NavigationGrid::ensure_class_ready(bool flying, int cls) {
	if (cls == 0 || (!chunks.empty() && chunks[0] && chunks[0]->wide[flying ? 1 : 0][cls - 1]) || !every_chunk_baked()) {
		return;
	}
	for (const std::unique_ptr<NavChunk> &chunk : chunks) {
		chunk->regions_of(flying, cls);
	}
	bake_missing_tiers();
}

NavigationGrid::NavigationGrid() {}
NavigationGrid::~NavigationGrid() {}

static bool ramp_of(CollisionShape3D *cs, float max_degrees, float cell_size, int reach_cells, RampInfo &slope);

void NavigationGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("ensure_baked", "tree"), &NavigationGrid::ensure_baked);
	ClassDB::bind_method(D_METHOD("invalidate"), &NavigationGrid::invalidate);
	ClassDB::bind_method(D_METHOD("invalidate_region", "world_root", "region"), &NavigationGrid::invalidate_region);
	ClassDB::bind_method(D_METHOD("register_world", "root"), &NavigationGrid::register_world);
	ClassDB::bind_method(D_METHOD("unregister_world", "root"), &NavigationGrid::unregister_world);
	ClassDB::bind_method(D_METHOD("nearest_valid_point", "tree", "point", "clearance", "flying", "exclude_unit", "max_radius_cells", "world_ref", "ignore"), &NavigationGrid::nearest_valid_point, DEFVAL(Variant()), DEFVAL(12), DEFVAL(Variant()), DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("find_path", "tree", "start", "destination", "unit", "flying", "ignore"), &NavigationGrid::find_path, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("find_crawl_path", "tree", "start", "destination", "unit", "ignore"), &NavigationGrid::find_crawl_path, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("crawl_normal", "tree", "origin", "unit"), &NavigationGrid::crawl_normal);
	ClassDB::bind_method(D_METHOD("occupancy_version", "tree", "world_ref"), &NavigationGrid::occupancy_version, DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("world_to_cell", "pos", "world_ref"), &NavigationGrid::world_to_cell_in);

	ClassDB::bind_method(D_METHOD("get_cell_size"), &NavigationGrid::get_cell_size);
	ClassDB::bind_method(D_METHOD("get_flight_min_altitude"), &NavigationGrid::get_flight_min_altitude);
	ClassDB::bind_method(D_METHOD("get_flight_max_altitude"), &NavigationGrid::get_flight_max_altitude);
	ClassDB::bind_method(D_METHOD("ground_height_at", "tree", "pos", "world_ref"), &NavigationGrid::ground_height_at, DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("flight_floor_at", "tree", "pos", "world_ref"), &NavigationGrid::flight_floor_at, DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("flight_ceiling_at", "tree", "pos", "world_ref"), &NavigationGrid::flight_ceiling_at, DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("flight_lowest_altitude", "tree", "world_ref"), &NavigationGrid::flight_lowest_altitude, DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("debug_memory_bytes"), &NavigationGrid::debug_memory_bytes);
	ClassDB::bind_method(D_METHOD("debug_structure_stats", "since_search"), &NavigationGrid::debug_structure_stats, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("debug_expansions"), &NavigationGrid::debug_expansions);
	ClassDB::bind_method(D_METHOD("debug_bake_profile"), &NavigationGrid::debug_bake_profile);
	ClassDB::bind_method(D_METHOD("prebake", "world_ref"), &NavigationGrid::prebake);
	ClassDB::bind_method(D_METHOD("debug_search_id"), &NavigationGrid::debug_search_id);
	ClassDB::bind_method(D_METHOD("flight_highest_altitude", "tree", "world_ref"), &NavigationGrid::flight_highest_altitude, DEFVAL(Variant()));

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "CELL_SIZE"), "", "get_cell_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "FLIGHT_MIN_ALTITUDE"), "", "get_flight_min_altitude");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "FLIGHT_MAX_ALTITUDE"), "", "get_flight_max_altitude");
}

float NavigationGrid::get_cell_size() const { return CELL_SIZE; }
float NavigationGrid::get_flight_min_altitude() const { return FLIGHT_MIN_ALTITUDE; }
float NavigationGrid::get_flight_max_altitude() const { return FLIGHT_MAX_ALTITUDE; }

// The ground the flight band at pos's XZ is measured from. The world's
// floor counts as solid (is_solid has it so), so an empty column measures
// from the bottom of the bounds - the same ground bake_chunk_support sees.
float NavigationGrid::ground_top_below(Vector3 pos) {
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
	return bounds_origin.y + (float)cell.y * CELL_SIZE;
}

// The height of the ground under pos (pos inside solid climbs out first):
// where a grounded body dropped there would stand.
float NavigationGrid::ground_height_at(SceneTree *tree, Vector3 pos, Object *world_ref) {
	activate_for(world_ref);
	ensure_baked(tree);
	return ground_top_below(pos);
}

// The lowest feet height a flier may take at pos's XZ: FLIGHT_MIN_ALTITUDE
// above the first solid at or below pos (pos inside solid climbs out of it
// first). Callers clamp an altitude up to this, so a pit floor at y=-6
// allows -5 while ground at y=0 still allows 1.
float NavigationGrid::flight_floor_at(SceneTree *tree, Vector3 pos, Object *world_ref) {
	activate_for(world_ref);
	ensure_baked(tree);
	return ground_top_below(pos) + FLIGHT_MIN_ALTITUDE;
}

// The highest feet height a flier may take at pos's XZ, measured from the
// same ground as flight_floor_at, so a rooftop at y=15 allows 26.875 while
// ground at y=0 still allows 11.875. Returned as the centre of the topmost
// flyable cell rather than ground + FLIGHT_MAX_ALTITUDE: that exact height
// is the bottom edge of the first cell bake_chunk_support marks too high,
// so clamping to it would put the flier in a cell the grid rejects.
float NavigationGrid::flight_ceiling_at(SceneTree *tree, Vector3 pos, Object *world_ref) {
	activate_for(world_ref);
	ensure_baked(tree);
	return ground_top_below(pos) + ((float)flight_high_cells() - 0.5f) * CELL_SIZE;
}

// The lowest altitude a flier may take anywhere in this world: the bottom
// of its geometry plus FLIGHT_MIN_ALTITUDE. The altitude plane, which has
// no single XZ, clamps to this; the move query then lifts to the floor at
// its own destination (flight_floor_at).
float NavigationGrid::flight_lowest_altitude(SceneTree *tree, Object *world_ref) {
	activate_for(world_ref);
	ensure_baked(tree);
	return geometry_min_y + FLIGHT_MIN_ALTITUDE;
}

// Counts container payloads (capacity, not size: that is what is held),
// plus a rough per-entry cost for the hash maps. Shapes and the parked
// worlds are left out: this is the cost of the one world being walked.
int64_t NavigationGrid::debug_memory_bytes() const {
	int64_t bytes = (int64_t)chunks.capacity() * sizeof(std::unique_ptr<NavChunk>);
	for (const std::unique_ptr<NavChunk> &c : chunks) {
		if (!c) {
			continue;
		}
		bytes += sizeof(NavChunk);
		bytes += c->solid.bytes() + c->ground.bytes() + c->no_support.bytes() + c->flight_low.bytes() + c->flight_high.bytes();
		bytes += c->dist.bytes();
		for (const std::unique_ptr<CrawlCells> &cells : c->crawl) {
			if (cells) {
				bytes += sizeof(CrawlCells);
				for (const std::unique_ptr<uint8_t[]> &brick : cells->bricks) {
					bytes += brick ? BrickField<uint8_t>::BRICK_CELLS : 0;
				}
			}
		}
		bytes += (int64_t)c->occupants.capacity() * sizeof(OccupantVolume);
		auto add_regions = [&](const NavRegions &r) {
			bytes += r.label.bytes();
			bytes += (int64_t)r.link_first.capacity() * sizeof(uint32_t);
			bytes += (int64_t)r.links.capacity() * sizeof(RegionLink);
			bytes += (int64_t)r.guide.capacity() * sizeof(RegionGuide);
		};
		for (const NavRegions &r : c->regions) {
			add_regions(r);
		}
		for (const auto &by_mode : c->wide) {
			for (const std::unique_ptr<NavRegions> &r : by_mode) {
				if (r) {
					bytes += sizeof(NavRegions);
					add_regions(*r);
				}
			}
		}
	}
	bytes += (int64_t)astar_pages.capacity() * sizeof(std::unique_ptr<AStarPage>);
	for (const std::unique_ptr<AStarPage> &p : astar_pages) {
		if (p) {
			bytes += sizeof(AStarPage);
			for (const std::unique_ptr<AStarBrick> &b : p->bricks) {
				bytes += b ? sizeof(AStarBrick) : 0;
			}
		}
	}
	bytes += (int64_t)open_heads.capacity() * sizeof(int) + (int64_t)open_nodes.capacity() * sizeof(OpenNode);
	bytes += (int64_t)chunk_occupancy_nearby.capacity();
	// This thread's bake scratch; a prebake worker's dies with it.
	const BakeScratch &scratch = bake_scratch();
	for (const std::vector<uint8_t> &s : scratch.support) {
		bytes += (int64_t)s.capacity();
	}
	for (int i = 0; i < 9; i++) {
		bytes += (int64_t)scratch.dist_solid[i].capacity() + (int64_t)scratch.dist_ground[i].capacity();
	}
	return bytes;
}

namespace {
constexpr int BRICK = 8;
constexpr int BRICKS_PER_AXIS = 32 / BRICK; // CHUNK_DIM / BRICK
constexpr int BRICKS_PER_CHUNK = BRICKS_PER_AXIS * BRICKS_PER_AXIS * BRICKS_PER_AXIS;

inline int cell_of(int bx, int by, int bz, int x, int y, int z) {
	return (bx * BRICK + x) + (by * BRICK + y) * 32 + (bz * BRICK + z) * 32 * 32;
}

// Whether brick (bx, by, bz) of a CHUNK_DIM^3 field holds one value.
template <typename T>
bool brick_uniform(const BrickField<T> &field, int bx, int by, int bz) {
	return field.brick_uniform(bx + by * BRICKS_PER_AXIS + bz * BRICKS_PER_AXIS * BRICKS_PER_AXIS);
}

struct FieldTally {
	int64_t bricks = 0;
	int64_t uniform = 0;
	Dictionary to_dict() const {
		Dictionary d;
		d["bricks"] = bricks;
		d["uniform"] = uniform;
		return d;
	}
};
} // namespace

// Read-only. A field is only examined in chunks where it is meant to hold
// data (solid/ground once rasterized, the support fields once baked, dist
// once its own bake ran, region labels once labelled), so a lazily skipped
// field doesn't read as "uniform zero".
Dictionary NavigationGrid::debug_structure_stats(int since_search) const {
	static constexpr int CELLS = 32 * 32 * 32;
	int64_t allocated = 0, rasterized = 0, support_baked = 0, dist_baked = 0, sealed = 0;
	FieldTally solid, ground, no_support, flight_low, flight_high, dist, walk_label, fly_label, all_cell;
	int64_t bytes_u8 = 0, bytes_dist = 0, bytes_labels = 0;
	for (const std::unique_ptr<NavChunk> &cp : chunks) {
		if (!cp) {
			continue;
		}
		const NavChunk &c = *cp;
		allocated++;
		rasterized += c.rasterized;
		support_baked += c.support_baked;
		dist_baked += c.dist_baked;
		sealed += c.sealed;
		bytes_u8 += c.solid.bytes() + c.ground.bytes() + c.no_support.bytes() + c.flight_low.bytes() + c.flight_high.bytes();
		bytes_dist += c.dist.bytes();
		for (const NavRegions &r : c.regions) {
			bytes_labels += r.label.bytes();
		}
		for (const auto &by_mode : c.wide) {
			for (const std::unique_ptr<NavRegions> &r : by_mode) {
				if (r) {
					bytes_labels += r->label.bytes();
				}
			}
		}
		const bool has_solid = c.rasterized && c.solid.present();
		const bool has_ground = c.rasterized && c.ground.present();
		const bool has_support = c.support_baked && c.no_support.present();
		const bool has_low = c.support_baked && c.flight_low.present();
		const bool has_high = c.support_baked && c.flight_high.present();
		const bool has_dist = c.dist_baked && c.dist.present();
		const bool has_walk = c.regions[0].labelled && c.regions[0].label.present();
		const bool has_fly = c.regions[1].labelled && c.regions[1].label.present();
		for (int bz = 0; bz < BRICKS_PER_AXIS; bz++) {
			for (int by = 0; by < BRICKS_PER_AXIS; by++) {
				for (int bx = 0; bx < BRICKS_PER_AXIS; bx++) {
					bool all = true;
					bool any = false;
					auto tally = [&](bool present, FieldTally &f, bool uniform) {
						if (!present) {
							return;
						}
						any = true;
						f.bricks++;
						f.uniform += uniform;
						all = all && uniform;
					};
					tally(has_solid, solid, has_solid && brick_uniform(c.solid, bx, by, bz));
					tally(has_ground, ground, has_ground && brick_uniform(c.ground, bx, by, bz));
					tally(has_support, no_support, has_support && brick_uniform(c.no_support, bx, by, bz));
					tally(has_low, flight_low, has_low && brick_uniform(c.flight_low, bx, by, bz));
					tally(has_high, flight_high, has_high && brick_uniform(c.flight_high, bx, by, bz));
					tally(has_dist, dist, has_dist && brick_uniform(c.dist, bx, by, bz));
					tally(has_walk, walk_label, has_walk && brick_uniform(c.regions[0].label, bx, by, bz));
					tally(has_fly, fly_label, has_fly && brick_uniform(c.regions[1].label, bx, by, bz));
					if (any) {
						all_cell.bricks++;
						all_cell.uniform += all;
					}
				}
			}
		}
	}

	int64_t astar_count = 0, astar_ever = 0, astar_since = 0, astar_cells_since = 0;
	for (const std::unique_ptr<AStarPage> &pp : astar_pages) {
		if (!pp) {
			continue;
		}
		astar_count++;
		for (const std::unique_ptr<AStarBrick> &b : pp->bricks) {
			if (!b) {
				continue;
			}
			astar_ever++;
			if (b->gen > since_search) {
				astar_since++;
				for (int i = 0; i < AStarBrick::CELLS; i++) {
					astar_cells_since += b->state[i] != 0;
				}
			}
		}
	}

	Dictionary d;
	d["chunk_grid"] = chunk_grid_size;
	d["chunks_allocated"] = allocated;
	d["chunks_rasterized"] = rasterized;
	d["chunks_sealed"] = sealed;
	d["chunks_support_baked"] = support_baked;
	d["chunks_dist_baked"] = dist_baked;
	d["bytes_u8_fields"] = bytes_u8;
	d["bytes_dist"] = bytes_dist;
	d["bytes_region_labels"] = bytes_labels;
	Dictionary fields;
	fields["solid"] = solid.to_dict();
	fields["ground"] = ground.to_dict();
	fields["no_support"] = no_support.to_dict();
	fields["flight_low"] = flight_low.to_dict();
	fields["flight_high"] = flight_high.to_dict();
	fields["dist"] = dist.to_dict();
	fields["walk_label"] = walk_label.to_dict();
	fields["fly_label"] = fly_label.to_dict();
	fields["every_field"] = all_cell.to_dict();
	d["fields"] = fields;
	d["astar_pages"] = astar_count;
	d["astar_bytes"] = astar_count * (int64_t)sizeof(AStarPage) + astar_ever * (int64_t)sizeof(AStarBrick);
	d["astar_bricks_ever"] = astar_ever;
	d["astar_bricks_since"] = astar_since;
	d["astar_cells_since"] = astar_cells_since;
	d["bricks_per_page"] = BRICKS_PER_CHUNK;
	return d;
}

// The highest altitude a flier may take anywhere in this world: the top of
// its geometry plus FLIGHT_MAX_ALTITUDE, which is where ensure_baked put
// the bounds' top. For the altitude plane, like flight_lowest_altitude;
// the move query then clamps to the ceiling at its own destination.
float NavigationGrid::flight_highest_altitude(SceneTree *tree, Object *world_ref) {
	activate_for(world_ref);
	ensure_baked(tree);
	return bounds_origin.y + (float)grid_size.y * CELL_SIZE - BOUNDS_MARGIN;
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
		astar_pages.clear();
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
		out.root = active_root;
		out.occupancy_stamped = occupancy_stamped;
		out.occupancy_version = occupancy_version_value;
		std::swap(out.occupied_chunks, occupied_chunks);
		std::swap(out.occupancy_signature, occupancy_signature);
		std::swap(out.chunks, chunks);
		out.geometry_min_y = geometry_min_y;
		std::swap(out.astar_pages, astar_pages);
		std::swap(out.all_shapes, all_shapes);
		std::swap(out.shapes_by_chunk, shapes_by_chunk);
		std::swap(out.tri_shapes, tri_shapes);
		std::swap(out.chunk_occupancy_nearby, chunk_occupancy_nearby);
	} else {
		// Leaving the legacy grid behind for good — clear rather than
		// park, so its shape pointers can't outlive their scene.
		chunks.clear();
		astar_pages.clear();
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
		active_root = nullptr;
		chunks.clear();
		geometry_min_y = 0.0f;
		astar_pages.clear();
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
	active_root = in.root;
	occupancy_stamped = in.occupancy_stamped;
	occupancy_version_value = in.occupancy_version;
	std::swap(in.occupied_chunks, occupied_chunks);
	std::swap(in.occupancy_signature, occupancy_signature);
	std::swap(in.chunks, chunks);
	geometry_min_y = in.geometry_min_y;
	std::swap(in.astar_pages, astar_pages);
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

// Resolves the world, then lets invalidate_active_region do the work on it
// while it is the loaded one. A parked world is swapped in, updated and
// swapped back out (O(1) each way, see activate_world), so the world a call
// names is the world that changes, whichever happens to be active.
void NavigationGrid::invalidate_region(Node *world_root, AABB region) {
	uint64_t id = world_id_of(world_root);
	if (id == 0) {
		// Not a node in any world: the grid can't tell which one changed,
		// so the active one is rescanned whole, as invalidate() does.
		invalidate();
		return;
	}
	SceneTree *tree = world_root->get_tree();
	if (id != active_world_id && parked_worlds.find(id) == parked_worlds.end()) {
		// An unregistered world. With nothing registered the legacy grid,
		// scanned from the current scene, is the one holding its geometry;
		// otherwise no grid has scanned it, and its first query will.
		if (active_world_id == 0) {
			invalidate_active_region(tree, region);
		}
		return;
	}
	uint64_t previous = active_world_id;
	activate_world(id);
	invalidate_active_region(tree, region);
	if (previous != id && previous != 0) {
		activate_world(previous);
	}
}

void NavigationGrid::ensure_project_scanned(SceneTree *tree) {
	StageClock clock(STAGE_SCAN);
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

	scan_bounds(bounds_origin, grid_size, geometry_min_y);
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

	// One empty slot per chunk; a page is allocated the first time a
	// search reaches its chunk (see astar_brick).
	astar_pages.clear();
	astar_pages.resize(chunks.size());
	astar_search_id = 0;

	// Bucket every shape by each chunk its AABB overlaps, so a lazy
	// rasterize of one chunk only tests the shapes that could matter.
	for (CollisionShape3D *cs : all_shapes) {
		auto tri = tri_shapes.find(cs);
		if (tri != tri_shapes.end()) {
			index_tri_columns(*tri->second);
		}
		Vector3i min_chunk, max_chunk;
		if (!shape_chunk_range(cs, min_chunk, max_chunk)) {
			continue;
		}
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

void NavigationGrid::scan_bounds(Vector3 &origin, Vector3i &size, float &min_y) {
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

	min_y = world_min.y;
	world_min -= Vector3(BOUNDS_MARGIN, BOUNDS_MARGIN, BOUNDS_MARGIN);
	world_max += Vector3(BOUNDS_MARGIN, BOUNDS_MARGIN, BOUNDS_MARGIN);
	// Room for the flight band over the tallest geometry: the ceiling is
	// FLIGHT_MAX_ALTITUDE above the ground under a flier, so the highest
	// flyable cell sits that far over the top of the world.
	world_max.y += FLIGHT_MAX_ALTITUDE;

	// The lattice is anchored to the world, not to the geometry: the origin
	// snaps down to a whole chunk (8 m) on each axis, and the grid grows by
	// whatever that adds. Taken straight from the geometry's minimum, every
	// cell boundary moved whenever anything low was added or nudged, so the
	// same floor rasterized into a different layer from one edit to the
	// next and feet on it rounded into the floor or above it. A multiple of
	// CHUNK_DIM * CELL_SIZE is also a multiple of CELL_SIZE, so cell faces
	// land on round world values (y = 0 is a cell face) and chunk faces on
	// fixed 8 m planes, whatever the level holds.
	const float chunk_world = (float)CHUNK_DIM * CELL_SIZE;
	world_min = Vector3(
			std::floor(world_min.x / chunk_world) * chunk_world,
			std::floor(world_min.y / chunk_world) * chunk_world,
			std::floor(world_min.z / chunk_world) * chunk_world);

	origin = world_min;
	Vector3 extent = world_max - world_min;
	size = Vector3i(
			(int)std::ceil(extent.x / CELL_SIZE),
			(int)std::ceil(extent.y / CELL_SIZE),
			(int)std::ceil(extent.z / CELL_SIZE));
}

bool NavigationGrid::shape_chunk_range(CollisionShape3D *cs, Vector3i &min_chunk, Vector3i &max_chunk) {
	AABB aabb = shape_global_aabb(cs);
	// A ramp marks ground past its own box (ramp_of), in chunks it
	// may not otherwise touch.
	// So does a mesh with walkable slopes (mark_tri_ground).
	RampInfo ramp;
	auto tri = tri_shapes.find(cs);
	if (ramp_of(cs, MAX_WALKABLE_SLOPE_DEGREES, CELL_SIZE, MAX_CLEARANCE_CELLS, ramp) || (tri != tri_shapes.end() && tri->second->any_walkable)) {
		aabb = aabb.grow(MAX_CLEARANCE_CELLS * CELL_SIZE);
	}
	Vector3i min_cell = world_to_cell(aabb.position);
	Vector3i max_cell = world_to_cell(aabb.position + aabb.size);
	min_cell = Vector3i(std::max(min_cell.x, 0), std::max(min_cell.y, 0), std::max(min_cell.z, 0));
	max_cell = Vector3i(std::min(max_cell.x, grid_size.x - 1), std::min(max_cell.y, grid_size.y - 1), std::min(max_cell.z, grid_size.z - 1));
	if (max_cell.x < min_cell.x || max_cell.y < min_cell.y || max_cell.z < min_cell.z) {
		return false;
	}
	min_chunk = cell_to_chunk_coord(min_cell);
	max_chunk = cell_to_chunk_coord(max_cell);
	return true;
}

// The local half of invalidate_region. Every tier is lazy and keyed by a
// per-chunk flag, so un-baking a chunk is just clearing its flags: the next
// query that reaches it rebuilds it from the refreshed shape buckets. What
// has to be got right is WHICH chunks, since each tier reads more than its
// own chunk:
//   - solid/ground (rasterize): the chunks the region overlaps (T). The
//     region is first grown by the widest reach any shape marks beyond its
//     own box (a ramp's or walkable mesh's ground band, MAX_CLEARANCE_CELLS)
//     so a moved ramp's band is covered too.
//   - support/flight_low: T and the chunk ABOVE each, which reads T's top
//     cells as the ground under its bottom ones (bake_chunk_support).
//   - dist: T and its 8 horizontal neighbours, whose clearance windows
//     reach one chunk sideways into T (bake_chunk_dist).
//   - region labels: wherever support changed (they read solid, no_support
//     and flight_low), and region links: every chunk touching one of
//     those, since links name neighbours' labels.
// Occupancy is left alone: it lives in the chunks beside the geometry and
// never depended on it. The coarse corridor is computed per query from the
// support flags, so it follows on its own.
void NavigationGrid::invalidate_active_region(SceneTree *tree, const AABB &region) {
	if (!baked) {
		return; // the next query scans everything anyway
	}
	Node *root = active_root ? active_root : (tree ? tree->get_current_scene() : nullptr);
	if (!root) {
		baked = false;
		return;
	}

	AABB touched = region.abs().grow((MAX_CLEARANCE_CELLS + 1) * CELL_SIZE);

	// The shape list is re-walked whole: a moved body may have changed
	// buckets, a freed one must not leave a dangling pointer behind, and
	// walking the tree is cheap. Building a mesh's triangles is not, so a
	// mesh shape clear of the region (and so, by this call's contract,
	// unmoved) keeps the TriShape it already has, column index included —
	// the grid's size is unchanged or the rescan below replaces it anyway.
	std::vector<CollisionShape3D *> shapes;
	collect_static_shapes(root, shapes);
	std::unordered_map<CollisionShape3D *, std::shared_ptr<TriShape>> tris;
	std::vector<TriShape *> fresh;
	for (CollisionShape3D *cs : shapes) {
		auto old = tri_shapes.find(cs);
		if (old != tri_shapes.end() && !old->second->aabb.intersects(touched)) {
			tris[cs] = old->second;
			continue;
		}
		auto tri = std::make_shared<TriShape>();
		if (build_tri_shape(cs, *tri)) {
			tris[cs] = tri;
			fresh.push_back(tri.get());
		}
	}
	std::swap(all_shapes, shapes);
	std::swap(tri_shapes, tris);

	// Geometry that moved past the old bounds (or took the old extreme
	// with it) needs a grid of another size: everything is re-laid, so
	// nothing baked can be kept.
	Vector3 origin;
	Vector3i size;
	float min_y;
	scan_bounds(origin, size, min_y);
	if (origin != bounds_origin || size != grid_size) {
		baked = false;
		return;
	}
	// The lattice is snapped, so the lowest geometry can move within one
	// chunk without changing the grid; the flight floor follows it.
	geometry_min_y = min_y;
	for (TriShape *tri : fresh) {
		index_tri_columns(*tri);
	}

	// A route cached against the old geometry must not survive it. Full
	// invalidate gets this from the rescan restamping occupancy; here the
	// occupancy stays, so the version is bumped directly.
	occupancy_version_value = ++occupancy_version_counter;

	Vector3i lo_cell = world_to_cell(touched.position);
	Vector3i hi_cell = world_to_cell(touched.position + touched.size);
	lo_cell = Vector3i(std::max(lo_cell.x, 0), std::max(lo_cell.y, 0), std::max(lo_cell.z, 0));
	hi_cell = Vector3i(std::min(hi_cell.x, grid_size.x - 1), std::min(hi_cell.y, grid_size.y - 1), std::min(hi_cell.z, grid_size.z - 1));
	if (hi_cell.x < lo_cell.x || hi_cell.y < lo_cell.y || hi_cell.z < lo_cell.z) {
		return; // wholly outside the grid: no baked chunk can have read it
	}
	Vector3i lo = cell_to_chunk_coord(lo_cell);
	Vector3i hi = cell_to_chunk_coord(hi_cell);

	// Rebucket T alone. A bucket outside T can only have changed if a shape
	// in it moved, and every shape that moved lies in the region.
	for (int cx = lo.x; cx <= hi.x; cx++) {
		for (int cy = lo.y; cy <= hi.y; cy++) {
			for (int cz = lo.z; cz <= hi.z; cz++) {
				shapes_by_chunk.erase(chunk_coord_index(Vector3i(cx, cy, cz)));
			}
		}
	}
	for (CollisionShape3D *cs : all_shapes) {
		Vector3i smin, smax;
		if (!shape_chunk_range(cs, smin, smax)) {
			continue;
		}
		Vector3i a(std::max(smin.x, lo.x), std::max(smin.y, lo.y), std::max(smin.z, lo.z));
		Vector3i b(std::min(smax.x, hi.x), std::min(smax.y, hi.y), std::min(smax.z, hi.z));
		for (int cx = a.x; cx <= b.x; cx++) {
			for (int cy = a.y; cy <= b.y; cy++) {
				for (int cz = a.z; cz <= b.z; cz++) {
					shapes_by_chunk[chunk_coord_index(Vector3i(cx, cy, cz))].push_back(cs);
				}
			}
		}
	}

	// A world baked whole is kept whole (see the end of this function).
	const bool was_whole = every_chunk_baked();

	// Each tier reads more than its own chunk, so un-baking a box of
	// chunks [a, b] un-bakes what reads it too (see above). Support reads
	// up to flight_high_cells straight down, which reaches support_reach
	// chunks below, so that many chunks above the box lose their support.
	const int support_reach = (flight_high_cells() + CHUNK_DIM - 1) / CHUNK_DIM;
	auto within = [](int v, int a, int b) { return v >= a && v <= b; };
	auto unbake = [&](const Vector3i &a, const Vector3i &b, bool raster) {
		// Two chunks out in x and z: a wide class's labels read dist, which
		// reaches one chunk past the box, and its links read those labels.
		for (int cx = a.x - 2; cx <= b.x + 2; cx++) {
			for (int cy = a.y - 1; cy <= b.y + support_reach + 1; cy++) {
				for (int cz = a.z - 2; cz <= b.z + 2; cz++) {
					Vector3i cc(cx, cy, cz);
					if (!chunk_in_bounds(cc)) {
						continue;
					}
					std::unique_ptr<NavChunk> &slot = chunks[chunk_coord_index(cc)];
					if (!slot) {
						continue; // never touched: nothing baked to drop
					}
					NavChunk &chunk = *slot;
					bool in_xz = within(cx, a.x, b.x) && within(cz, a.z, b.z);
					bool in_support = in_xz && within(cy, a.y, b.y + support_reach);
					if (raster && in_xz && within(cy, a.y, b.y)) {
						chunk.rasterized = false;
					}
					if (in_support) {
						chunk.support_baked = false;
					}
					const bool near_xz = within(cx, a.x - 1, b.x + 1) && within(cz, a.z - 1, b.z + 1);
					const bool in_dist = near_xz && within(cy, a.y, b.y);
					if (in_dist) {
						chunk.dist_baked = false;
					}
					// A crawler's ball is under a chunk across, so it only
					// reads the chunks either side.
					if (near_xz && within(cy, a.y - 1, b.y + 1)) {
						chunk.crawl.clear();
					}
					for (NavRegions &r : chunk.regions) {
						if (in_support) {
							r.labelled = false;
						}
						if (near_xz) {
							r.linked = false; // the support box grown by one chunk
						}
					}
					for (auto &by_mode : chunk.wide) {
						for (std::unique_ptr<NavRegions> &r : by_mode) {
							if (r) {
								r->labelled = r->labelled && !in_support && !in_dist;
								r->linked = false;
							}
						}
					}
				}
			}
		}
	};
	unbake(lo, hi, true);

	// Sealed interiors are a global answer (seal_interiors): the move may
	// have opened a sealed room or closed an open one anywhere its flood
	// reached. The pass relabels only the chunks just un-rasterized, joins
	// the world over cached components, and returns the chunks whose fill
	// changed; those lose the tiers above the raster, which it has laid.
	for (int i : seal_interiors()) {
		Vector3i cc = chunk_coord_from_index(i);
		unbake(cc, cc, false);
	}

	// Paid here, across cores, and not by the next unit to ask for a path.
	if (was_whole) {
		bake_missing_tiers();
	}
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
	uint8_t *solid_w = chunk.solid.work_data();
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
							solid_w[local_index(cell - base)] = 1;
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
			solid_w[local_index(Vector3i(lx, y - base.y, lz))] = 1;
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
	const uint8_t *solid_w = chunk.solid.work_data();
	uint8_t *ground_w = chunk.ground.work_data();
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
				if (!solid_w[li]) {
					continue;
				}
				float depth = h - cell_center(Vector3i(x, y, z)).y;
				if (depth >= -CELL_SIZE * 0.5f && depth <= skin) {
					ground_w[li] = 1;
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

Vector3i NavigationGrid::world_to_cell_in(Vector3 pos, Object *world_ref) {
	activate_for(world_ref);
	return world_to_cell(pos);
}

Vector3 NavigationGrid::cell_center(const Vector3i &cell) const {
	return bounds_origin + Vector3((float)cell.x, (float)cell.y, (float)cell.z) * CELL_SIZE + Vector3(CELL_SIZE * 0.5f, CELL_SIZE * 0.5f, CELL_SIZE * 0.5f);
}

int64_t NavigationGrid::cell_index(const Vector3i &cell) const {
	return (int64_t)cell.x + (int64_t)cell.y * grid_size.x + (int64_t)cell.z * grid_size.x * grid_size.y;
}

Vector3i NavigationGrid::cell_from_index(int64_t idx) const {
	int64_t x = idx % grid_size.x;
	int64_t y = (idx / grid_size.x) % grid_size.y;
	int64_t z = idx / ((int64_t)grid_size.x * grid_size.y);
	return Vector3i((int)x, (int)y, (int)z);
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
	StageClock clock(STAGE_RASTERIZE);
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
		// No geometry touches this chunk: all air, nothing allocated.
		chunk.solid.fill(0);
		chunk.ground.fill(0);
		return;
	}
	uint8_t *solid_w = chunk.solid.begin_write(0);
	uint8_t *ground_w = chunk.ground.begin_write(0);

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
						solid_w[local_index(Vector3i(x, y, z))] = 1;
					}
				}
			}
		}
	}

	if (fill) {
		for (size_t i = 0; i < (size_t)BrickField<uint8_t>::CELLS; i++) {
			solid_w[i] |= (*fill)[i];
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
					if (!solid_w[li]) {
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
						ground_w[li] = 1;
					}
				}
			}
		}
	}
	chunk.solid.end_write();
	chunk.ground.end_write();
}

namespace {
// Union-find over integer nodes: a chunk's open runs while seal_interiors
// labels it, then every chunk's components for the world-wide join.
struct RunSets {
	std::vector<int> parent;
	void reset(int count) {
		parent.resize((size_t)count);
		for (int i = 0; i < count; i++) {
			parent[i] = i;
		}
	}
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

// Faces of a chunk, as SealLabels::face indexes them.
enum SealFace { FACE_X0, FACE_X1, FACE_Y0, FACE_Y1, FACE_Z0, FACE_Z1 };

void sort_unique(std::vector<uint16_t> &v) {
	std::sort(v.begin(), v.end());
	v.erase(std::unique(v.begin(), v.end()), v.end());
}
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
// touches is one open component and is never allocated unless it is
// sealed.
//
// Two levels, so a prop move pays for the chunks it touched and not the
// world. Each chunk with shapes is labelled on its own (SealLabels): its
// open runs along x, joined into 6-connected components, and which of
// those touch each face and each neighbour's components. That is kept,
// and redone only for a chunk whose raw raster was redone
// (invalidate_active_region clears `valid`). The world-wide join is then
// over components, not cells or runs: a few thousand nodes.
//
// Returns the chunks whose fill changed (solid[] laid again), so a caller
// with tiers already baked can un-bake them.
std::vector<int> NavigationGrid::seal_interiors() {
	StageClock clock(STAGE_SEAL);
	uint64_t started = Time::get_singleton()->get_ticks_usec();
	const int D = CHUNK_DIM;
	const int n = (int)chunks.size();
	auto dims_of = [&](const Vector3i &cc) {
		Vector3i base = cc * D;
		return Vector3i(std::min(D, grid_size.x - base.x), std::min(D, grid_size.y - base.y), std::min(D, grid_size.z - base.z));
	};
	std::vector<uint8_t> shaped((size_t)n, 0);
	for (int i = 0; i < n; i++) {
		shaped[i] = shapes_by_chunk.find(i) != shapes_by_chunk.end();
	}

	// Label every chunk with shapes whose labels are stale: rasterize on
	// this thread (it reads the scene), then label across cores (each
	// reads only its own solid[] and writes only its own labels).
	std::vector<int> stale;
	std::vector<uint8_t> relabelled((size_t)n, 0);
	for (int i = 0; i < n; i++) {
		if (!shaped[i]) {
			continue;
		}
		// Labels describe the raw raster; one just laid makes them stale.
		const bool fresh = !chunks[i] || !chunks[i]->rasterized;
		NavChunk &chunk = ensure_chunk_rasterized(chunk_coord_from_index(i));
		if (fresh) {
			chunk.seal.valid = false;
		}
		if (!chunk.seal.valid) {
			stale.push_back(i);
			relabelled[i] = 1;
		}
	}
	for (int i = 0; i < n; i++) {
		// A chunk that lost its shapes keeps no labels: it is one open node.
		if (!shaped[i] && chunks[i] && chunks[i]->seal.valid) {
			chunks[i]->seal = SealLabels();
			relabelled[i] = 1;
		}
	}
	parallel_for((int)stale.size(), [&](int s) {
		const int i = stale[s];
		NavChunk &chunk = *chunks[i];
		SealLabels &L = chunk.seal;
		const Vector3i d = dims_of(chunk_coord_from_index(i));
		thread_local std::vector<uint8_t> solid_view;
		const uint8_t *solid = chunk.solid.dense(solid_view);
		L.row_start.assign((size_t)D * D + 1, 0);
		L.x0.clear();
		L.x1.clear();
		for (int y = 0; y < D; y++) {
			for (int z = 0; z < D; z++) {
				L.row_start[y * D + z] = (uint16_t)L.x0.size();
				if (y >= d.y || z >= d.z) {
					continue;
				}
				const uint8_t *row = solid + local_index(Vector3i(0, y, z));
				for (int x = 0; x < d.x;) {
					if (row[x]) {
						x++;
						continue;
					}
					int start = x;
					while (x < d.x && !row[x]) {
						x++;
					}
					L.x0.push_back((uint8_t)start);
					L.x1.push_back((uint8_t)(x - 1));
				}
			}
		}
		L.row_start[(size_t)D * D] = (uint16_t)L.x0.size();
		const int runs = (int)L.x0.size();

		// Each row with the rows below and behind it.
		thread_local RunSets sets;
		sets.reset(runs);
		auto unite_rows = [&](int ra, int rb) {
			int a = L.row_start[ra], ae = L.row_start[ra + 1];
			int b = L.row_start[rb], be = L.row_start[rb + 1];
			while (a < ae && b < be) {
				if (L.x1[a] >= L.x0[b] && L.x1[b] >= L.x0[a]) {
					sets.unite(a, b);
				}
				if (L.x1[a] < L.x1[b]) {
					a++;
				} else {
					b++;
				}
			}
		};
		for (int y = 0; y < d.y; y++) {
			for (int z = 0; z < d.z; z++) {
				if (y > 0) {
					unite_rows(y * D + z, (y - 1) * D + z);
				}
				if (z > 0) {
					unite_rows(y * D + z, y * D + z - 1);
				}
			}
		}
		// Roots are the lowest run of each set (unite keeps the min), so
		// numbering in run order meets every root before its members.
		L.comp.assign((size_t)runs, 0);
		L.count = 0;
		for (int k = 0; k < runs; k++) {
			int root = sets.find(k);
			L.comp[k] = root == k ? (uint16_t)L.count++ : L.comp[root];
		}

		for (std::vector<uint16_t> &f : L.face) {
			f.clear();
		}
		for (int y = 0; y < d.y; y++) {
			for (int z = 0; z < d.z; z++) {
				const int row = y * D + z;
				for (int k = L.row_start[row]; k < L.row_start[row + 1]; k++) {
					const uint16_t c = L.comp[k];
					if (L.x0[k] == 0) {
						L.face[FACE_X0].push_back(c);
					}
					if (L.x1[k] == d.x - 1) {
						L.face[FACE_X1].push_back(c);
					}
					if (y == 0) {
						L.face[FACE_Y0].push_back(c);
					}
					if (y == d.y - 1) {
						L.face[FACE_Y1].push_back(c);
					}
					if (z == 0) {
						L.face[FACE_Z0].push_back(c);
					}
					if (z == d.z - 1) {
						L.face[FACE_Z1].push_back(c);
					}
				}
			}
		}
		for (std::vector<uint16_t> &f : L.face) {
			sort_unique(f);
		}
		L.valid = true;
	});

	// Which components meet across each face both of whose chunks have
	// shapes, kept on the chunk on the low side. Redone where either side
	// was relabelled. A neighbour exists only past a full chunk, so the
	// shared face is at D - 1 on this side and 0 on the other.
	std::vector<int> relink;
	for (int i = 0; i < n; i++) {
		if (!shaped[i]) {
			continue;
		}
		const Vector3i cc = chunk_coord_from_index(i);
		bool any = relabelled[i];
		for (int axis = 0; axis < 3 && !any; axis++) {
			Vector3i o = cc;
			o[axis] += 1;
			any = chunk_in_bounds(o) && relabelled[chunk_coord_index(o)];
		}
		if (any) {
			relink.push_back(i);
		}
	}
	parallel_for((int)relink.size(), [&](int s) {
		const int i = relink[s];
		const Vector3i cc = chunk_coord_from_index(i);
		const Vector3i d = dims_of(cc);
		SealLabels &L = chunks[i]->seal;
		for (int axis = 0; axis < 3; axis++) {
			std::vector<std::pair<uint16_t, uint16_t>> &link = L.link[axis];
			link.clear();
			Vector3i oc = cc;
			oc[axis] += 1;
			if (!chunk_in_bounds(oc) || !shaped[chunk_coord_index(oc)]) {
				continue;
			}
			const SealLabels &O = chunks[chunk_coord_index(oc)]->seal;
			auto merge = [&](int ra, int rb) {
				int a = L.row_start[ra], ae = L.row_start[ra + 1];
				int b = O.row_start[rb], be = O.row_start[rb + 1];
				while (a < ae && b < be) {
					if (L.x1[a] >= O.x0[b] && O.x1[b] >= L.x0[a]) {
						link.emplace_back(L.comp[a], O.comp[b]);
					}
					if (L.x1[a] < O.x1[b]) {
						a++;
					} else {
						b++;
					}
				}
			};
			if (axis == 0) {
				for (int y = 0; y < d.y; y++) {
					for (int z = 0; z < d.z; z++) {
						const int row = y * D + z;
						int a = L.row_start[row + 1] - 1, b = O.row_start[row];
						if (a >= L.row_start[row] && L.x1[a] == D - 1 && b < O.row_start[row + 1] && O.x0[b] == 0) {
							link.emplace_back(L.comp[a], O.comp[b]);
						}
					}
				}
			} else if (axis == 1) {
				for (int z = 0; z < d.z; z++) {
					merge((D - 1) * D + z, z);
				}
			} else {
				for (int y = 0; y < d.y; y++) {
					merge(y * D + D - 1, y * D);
				}
			}
			std::sort(link.begin(), link.end());
			link.erase(std::unique(link.begin(), link.end()), link.end());
		}
	});

	// The world-wide join. Node 0 is the outside; a chunk with shapes has
	// one node per component, a chunk without is one open node.
	std::vector<int> first((size_t)n);
	int nodes = 1;
	for (int i = 0; i < n; i++) {
		first[i] = nodes;
		nodes += shaped[i] ? chunks[i]->seal.count : 1;
	}
	RunSets sets;
	sets.reset(nodes);
	const SealFace low_face[3] = { FACE_X0, FACE_Y0, FACE_Z0 };
	const SealFace high_face[3] = { FACE_X1, FACE_Y1, FACE_Z1 };
	// Every component of chunk i on face f, joined to node.
	auto unite_face = [&](int i, int f, int node) {
		if (!shaped[i]) {
			sets.unite(first[i], node);
			return;
		}
		for (uint16_t c : chunks[i]->seal.face[f]) {
			sets.unite(first[i] + c, node);
		}
	};
	for (int i = 0; i < n; i++) {
		const Vector3i cc = chunk_coord_from_index(i);
		for (int axis = 0; axis < 3; axis++) {
			// The world's boundary faces are the outside.
			if (cc[axis] == 0) {
				unite_face(i, low_face[axis], 0);
			}
			if (cc[axis] == chunk_grid_size[axis] - 1) {
				unite_face(i, high_face[axis], 0);
				continue;
			}
			Vector3i oc = cc;
			oc[axis] += 1;
			const int o = chunk_coord_index(oc);
			if (shaped[i] && shaped[o]) {
				for (const std::pair<uint16_t, uint16_t> &e : chunks[i]->seal.link[axis]) {
					sets.unite(first[i] + e.first, first[o] + e.second);
				}
			} else if (shaped[i]) {
				unite_face(i, high_face[axis], first[o]);
			} else {
				unite_face(o, low_face[axis], first[i]);
			}
		}
	}

	// Everything the outside did not reach becomes solid. A chunk with
	// shapes is rasterized again with the fill, so its ramp bands are
	// marked against the solid that will stay. Only a chunk whose sealed
	// components changed, or whose raw raster was just laid, is touched.
	const int outside = sets.find(0);
	int64_t sealed_cells = 0;
	int sealed_chunks = 0;
	std::vector<int> changed;
	std::vector<uint16_t> now;
	std::vector<uint8_t> fill;
	for (int i = 0; i < n; i++) {
		const Vector3i cc = chunk_coord_from_index(i);
		now.clear();
		if (shaped[i]) {
			const SealLabels &L = chunks[i]->seal;
			for (int c = 0; c < L.count; c++) {
				if (sets.find(first[i] + c) != outside) {
					now.push_back((uint16_t)c);
				}
			}
		} else if (sets.find(first[i]) != outside) {
			now.push_back(0);
		}
		std::unique_ptr<NavChunk> &slot = chunks[i];
		if (!slot && now.empty()) {
			continue;
		}
		if (!slot) {
			slot = std::make_unique<NavChunk>();
		}
		NavChunk &chunk = *slot;
		if (!now.empty()) {
			sealed_chunks++;
		}
		// Its raw raster was just laid, or was dropped (an unshaped chunk
		// in the moved box): its fill must be laid again either way.
		const bool raw_fresh = relabelled[i] != 0 || !chunk.rasterized;
		if (!raw_fresh && now == chunk.seal.sealed && chunk.sealed == !now.empty()) {
			continue;
		}
		chunk.seal.sealed = now;
		changed.push_back(i);
		if (now.empty()) {
			if (chunk.sealed) {
				rasterize_chunk(cc, chunk); // back to the raw geometry
				chunk.rasterized = true;
			}
			chunk.sealed = false;
			continue;
		}
		if (!shaped[i]) {
			const Vector3i d = dims_of(cc);
			chunk.solid.fill(1);
			chunk.ground.fill(0);
			chunk.rasterized = true;
			chunk.sealed = true;
			sealed_cells += (int64_t)d.x * d.y * d.z;
			continue;
		}
		const SealLabels &L = chunk.seal;
		fill.assign((size_t)D * D * D, 0);
		for (int y = 0; y < D; y++) {
			for (int z = 0; z < D; z++) {
				const int row = y * D + z;
				for (int k = L.row_start[row]; k < L.row_start[row + 1]; k++) {
					if (!std::binary_search(now.begin(), now.end(), L.comp[k])) {
						continue;
					}
					for (int x = L.x0[k]; x <= L.x1[k]; x++) {
						fill[local_index(Vector3i(x, y, z))] = 1;
					}
					sealed_cells += L.x1[k] - L.x0[k] + 1;
				}
			}
		}
		rasterize_chunk(cc, chunk, &fill);
		chunk.rasterized = true;
		chunk.sealed = true;
	}
	UtilityFunctions::print_verbose("NavigationGrid: seal relabelled ", (int64_t)stale.size(), " of ", (int64_t)n, " chunks, ", nodes,
			" components; sealed ", sealed_chunks, " chunks, ", (int64_t)changed.size(), " changed (", sealed_cells, " cells laid); ",
			(double)(Time::get_singleton()->get_ticks_usec() - started) / 1000.0, " ms");
	return changed;
}

bool NavigationGrid::is_solid(const Vector3i &cell) {
	if (!in_bounds(cell)) {
		return true;
	}
	NavChunk &chunk = ensure_chunk_rasterized(cell_to_chunk_coord(cell));
	return chunk.solid.get(local_index(cell_to_local(cell))) != 0;
}

NavChunk &NavigationGrid::ensure_chunk_support(const Vector3i &chunk_coord) {
	NavChunk &chunk = ensure_chunk_rasterized(chunk_coord);
	if (chunk.support_baked) {
		return chunk;
	}
	StageClock clock(STAGE_SUPPORT);
	bake_chunk_support(chunk_coord, chunk);
	chunk.support_baked = true;
	return chunk;
}

void NavigationGrid::bake_chunk_support(const Vector3i &chunk_coord, NavChunk &chunk) {
	// Every tier only ever reads straight down, at most flight_high_cells
	// cells - more than one chunk, so a column can reach two chunks below.
	// Read those solid[] arrays directly - going through is_solid() per
	// cell (bounds check, chunk lookup) cost ~1 ms a chunk, and a flier's
	// coarse corridor bakes ~100 of them. A chunk below is rasterized only
	// once some column actually scans into it: over ground the scan stops
	// at the first solid, so a walker's bake still touches only the chunk
	// directly below.
	// Off the world's bottom counts as solid, as is_solid() has it.
	const int flight_low = flight_low_cells();
	const int flight_high = flight_high_cells();
	const int below_count = (flight_high + CHUNK_DIM - 1) / CHUNK_DIM;
	std::vector<const uint8_t *> below_solid((size_t)below_count, nullptr);
	std::vector<uint8_t> below_resolved((size_t)below_count, 0);
	std::vector<std::vector<uint8_t>> &support_scratch = bake_scratch().support;
	support_scratch.resize((size_t)below_count + 1);
	// The chunk `depth` below (1 = directly below), rasterized on first use;
	// null off the world's bottom.
	auto below = [&](int depth) -> const uint8_t * {
		if (!below_resolved[depth - 1]) {
			below_resolved[depth - 1] = 1;
			Vector3i below_chunk = chunk_coord - Vector3i(0, depth, 0);
			if (chunk_in_bounds(below_chunk)) {
				below_solid[depth - 1] = ensure_chunk_rasterized(below_chunk).solid.dense(support_scratch[depth]);
			}
		}
		return below_solid[depth - 1];
	};

	// Open sky: no solid in this chunk nor anywhere in reach below it. Every
	// cell is unsupported and too high to fly; the sweep would find that one
	// column at a time.
	{
		const Vector3i b = chunk_coord * CHUNK_DIM;
		const bool whole = b.x + CHUNK_DIM <= grid_size.x && b.y + CHUNK_DIM <= grid_size.y && b.z + CHUNK_DIM <= grid_size.z;
		bool sky = whole && chunk.solid.all_of(0);
		for (int depth = 1; sky && depth <= below_count; depth++) {
			Vector3i below_chunk = chunk_coord - Vector3i(0, depth, 0);
			sky = chunk_in_bounds(below_chunk) && ensure_chunk_rasterized(below_chunk).solid.all_of(0);
		}
		if (sky) {
			chunk.no_support.fill(1);
			chunk.flight_low.fill(0);
			chunk.flight_high.fill(1);
			return;
		}
	}
	const uint8_t *own_solid = chunk.solid.dense(support_scratch[0]);

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	uint8_t *no_support_w = chunk.no_support.begin_write(0);
	uint8_t *flight_low_w = chunk.flight_low.begin_write(0);
	uint8_t *flight_high_w = chunk.flight_high.begin_write(0);

	// One walk up each column, carrying how far below the nearest solid
	// cell is: supported = it is 1, too low = it is within flight_low,
	// too high = it is beyond flight_high.
	for (int x = 0; x < cx1; x++) {
		for (int z = 0; z < cz1; z++) {
			// The nearest solid straight down, k cells below the chunk's
			// floor, read chunk by chunk.
			int since_solid = flight_high + 1; // "none in reach"
			for (int depth = 1; depth <= below_count && since_solid > flight_high; depth++) {
				const int k0 = (depth - 1) * CHUNK_DIM + 1;
				const int k1 = std::min(depth * CHUNK_DIM, flight_high);
				const uint8_t *solid = below(depth);
				if (solid == nullptr) {
					since_solid = k0;
					break;
				}
				const uint8_t *col = solid + x + z * CHUNK_DIM * CHUNK_DIM;
				for (int k = k0; k <= k1; k++) {
					if (col[(depth * CHUNK_DIM - k) * CHUNK_DIM] != 0) {
						since_solid = k;
						break;
					}
				}
			}
			for (int y = 0; y < cy1; y++) {
				int li = local_index(Vector3i(x, y, z));
				bool supported = base.y + y > 0 && since_solid == 1;
				no_support_w[li] = supported ? 0 : 1;
				if (own_solid[li] == 0) {
					bool low = since_solid <= flight_low;
					bool high = since_solid > flight_high;
					flight_low_w[li] = low ? 1 : 0;
					flight_high_w[li] = high ? 1 : 0;
					since_solid = std::min(since_solid + 1, flight_high + 1);
				} else {
					since_solid = 1;
				}
			}
		}
	}
	chunk.no_support.end_write();
	chunk.flight_low.end_write();
	chunk.flight_high.end_write();
}

// Too low to fly: solid in any cell whose top lies under
// FLIGHT_MIN_ALTITUDE below this cell's centre - the same cut the old
// absolute rule made over y=0 ground.
int NavigationGrid::flight_low_cells() {
	int cells = 0;
	while (((float)(cells + 1) - 0.5f) * CELL_SIZE < FLIGHT_MIN_ALTITUDE) {
		cells++;
	}
	return cells;
}

// Too high to fly: no solid within this many cells straight down, so the
// cell's centre is more than FLIGHT_MAX_ALTITUDE over the ground's top -
// the cut the old absolute ceiling made over y=0 ground.
int NavigationGrid::flight_high_cells() {
	int cells = 0;
	while (((float)(cells + 1) - 0.5f) * CELL_SIZE <= FLIGHT_MAX_ALTITUDE) {
		cells++;
	}
	return cells;
}

NavChunk &NavigationGrid::ensure_chunk_dist(const Vector3i &chunk_coord) {
	NavChunk &chunk = ensure_chunk_rasterized(chunk_coord);
	if (chunk.dist_baked) {
		return chunk;
	}
	StageClock clock(STAGE_DIST);
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
	const uint16_t MAX_DIST = (uint16_t)(MAX_CLEARANCE_CELLS * DIST_SCALE);
	// Whole chunks first: all rock is 0 everywhere, and with no solid at
	// all in the 3x3 around it nothing is in reach, so every cell keeps
	// MAX_DIST. Most of a map is one or the other (sky, bedrock), and the
	// per-layer sweep below would scan a 72^2 window 32 times to find that.
	NavChunk *neighbor_chunk[3][3] = {};
	bool wall_near = false;
	for (int dx = -1; dx <= 1; dx++) {
		for (int dz = -1; dz <= 1; dz++) {
			Vector3i nc = chunk_coord + Vector3i(dx, 0, dz);
			if (chunk_in_bounds(nc)) {
				neighbor_chunk[dx + 1][dz + 1] = &ensure_chunk_rasterized(nc);
				wall_near = wall_near || !neighbor_chunk[dx + 1][dz + 1]->solid.all_of(0);
			}
		}
	}
	if (!wall_near) {
		chunk.dist.fill(MAX_DIST);
		return;
	}
	const Vector3i whole_base = chunk_coord * CHUNK_DIM;
	const bool whole = whole_base.x + CHUNK_DIM <= grid_size.x && whole_base.y + CHUNK_DIM <= grid_size.y && whole_base.z + CHUNK_DIM <= grid_size.z;
	if (whole && chunk.solid.all_of(1)) {
		chunk.dist.fill(0);
		return;
	}
	const uint8_t *neighbor_solid[3][3] = {};
	const uint8_t *neighbor_ground[3][3] = {};
	std::vector<uint8_t> *dist_solid_scratch = bake_scratch().dist_solid;
	std::vector<uint8_t> *dist_ground_scratch = bake_scratch().dist_ground;
	for (int dx = 0; dx < 3; dx++) {
		for (int dz = 0; dz < 3; dz++) {
			if (neighbor_chunk[dx][dz]) {
				neighbor_solid[dx][dz] = neighbor_chunk[dx][dz]->solid.dense(dist_solid_scratch[dx * 3 + dz]);
				neighbor_ground[dx][dz] = neighbor_chunk[dx][dz]->ground.dense(dist_ground_scratch[dx * 3 + dz]);
			}
		}
	}

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	// A ramp's skin (NavChunk::ground == 1) is solid but not a wall: it is
	// what a unit walking the ramp stands on, the cell beside its feet one
	// step further up the slope. Clearance is measured from walls only.
	// A chunk slot off the world edge (null) never falls inside the window,
	// which is clipped to the world; it reads as wall if it ever did.

	uint16_t *dist_w = chunk.dist.begin_write(MAX_DIST);

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
					dist_w[li] = 0;
				} else {
					any_air = true;
				}
			}
		}
		if (!any_air) {
			continue;
		}

		// A ramp's skin is solid but not a wall (see above).
		// The window row by row, each row in up to three runs (one per
		// neighbour chunk it crosses), so the chunk is picked per run, not
		// per cell.
		bool any_wall = false;
		for (int x = xlo; x < xhi; x++) {
			const int cdx = (x < 0) ? -1 : (x >= CHUNK_DIM ? 1 : 0);
			const int lx = x - cdx * CHUNK_DIM;
			float *row = d.data() + idx2(x, 0);
			for (int cdz = -1; cdz <= 1; cdz++) {
				const int z0 = std::max(zlo, cdz * CHUNK_DIM);
				const int z1 = std::min(zhi, cdz * CHUNK_DIM + CHUNK_DIM);
				if (z0 >= z1) {
					continue;
				}
				const uint8_t *sol = neighbor_solid[cdx + 1][cdz + 1];
				const uint8_t *gnd = neighbor_ground[cdx + 1][cdz + 1];
				if (!sol) {
					for (int z = z0; z < z1; z++) {
						row[z] = 0.0f;
					}
					any_wall = true;
					continue;
				}
				const int li0 = lx + y * CHUNK_DIM - cdz * CHUNK_DIM * CHUNK_DIM * CHUNK_DIM;
				for (int z = z0; z < z1; z++) {
					const int li = li0 + z * CHUNK_DIM * CHUNK_DIM;
					const bool wall = sol[li] != 0 && !(gnd && gnd[li] == 1);
					row[z] = wall ? 0.0f : FAR;
					any_wall = any_wall || wall;
				}
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
				if (clamped < dist_w[li]) {
					dist_w[li] = clamped;
				}
			}
		}
	}
	chunk.dist.end_write();
}

// --- Dynamic occupancy -------------------------------------------------------

bool NavigationGrid::stamp_occupant(const OccupantVolume &volume) {
	int reach = (int)std::ceil(volume.clearance / CELL_SIZE);
	Vector3i lo = volume.cell - Vector3i(reach, 0, reach);
	Vector3i hi = volume.cell + Vector3i(reach, volume.layers - 1, reach);
	lo = Vector3i(std::max(lo.x, 0), std::max(lo.y, 0), std::max(lo.z, 0));
	hi = Vector3i(std::min(hi.x, grid_size.x - 1), std::min(hi.y, grid_size.y - 1), std::min(hi.z, grid_size.z - 1));
	if (lo.x > hi.x || lo.y > hi.y || lo.z > hi.z) {
		return false;
	}
	Vector3i clo = cell_to_chunk_coord(lo);
	Vector3i chi = cell_to_chunk_coord(hi);
	for (int cx = clo.x; cx <= chi.x; cx++) {
		for (int cy = clo.y; cy <= chi.y; cy++) {
			for (int cz = clo.z; cz <= chi.z; cz++) {
				int idx = chunk_coord_index(Vector3i(cx, cy, cz));
				std::unique_ptr<NavChunk> &slot = chunks[idx];
				if (!slot) {
					slot = std::make_unique<NavChunk>(); // occupancy doesn't need geometry rasterized
				}
				slot->occupants.push_back(volume);
				if (!slot->has_occupancy) {
					slot->has_occupancy = true;
					occupied_chunks.push_back(idx);
				}
			}
		}
	}
	return true;
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
			// Walking or flying (or a corpse that died mid-air: corpses
			// aren't force-landed, see UnitDeath.handle_death), the volume
			// is the same column from the feet up; see occupant_layers.
			key.layers = occupant_layers(get_float_prop(n3d, "height"));
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
			slot->occupants.clear();
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
		OccupantVolume volume;
		volume.obj = objects[i];
		volume.cell = key.cell;
		volume.clearance = (float)key.clearance_key / 1000.0f;
		volume.layers = key.layers;
		if (stamp_occupant(volume)) {
			any_occupied = true;
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

// A column, not a disc at the feet layer or (for fliers) a sphere: a
// unit's body is that tall wherever it stands. A disc at the feet alone
// missed every overlap that wasn't feet-to-feet on one layer: two walkers
// a layer apart on a ramp, or a flier at chest height crossing a standing
// unit. A sphere around a flier's feet had the same blind spot above and
// below it. Columns on both sides (the occupant's here, the querying
// body's in is_clear_of_units) make every vertical overlap a collision.
int NavigationGrid::occupant_layers(float height) {
	if (height <= 0.0f) {
		height = DEFAULT_OCCUPANT_HEIGHT;
	}
	return std::max(MIN_OCCUPANT_LAYERS, body_layers(height));
}

// Layers a body of this height spans from its feet cell, as is_valid_cell
// counts them for clearance.
int NavigationGrid::body_layers(float height) {
	return std::max(1, (int)std::ceil(height / CELL_SIZE));
}

bool NavigationGrid::is_clear_of_units(const Vector3i &cell, int chunk_idx, float clearance, float height, Object *self_unit) const {
	if (!any_occupied) {
		return true;
	}

	// Fast path: any_occupied only means "someone is occupied SOMEWHERE on
	// the map" (matches the pre-chunking design's single global flag) — on
	// a real battlefield with several units, that's true almost all the
	// time even when nothing is anywhere near THIS cell, which used to
	// force every single neighbor check across the whole search to do a
	// full occupancy test regardless. chunk_occupancy_nearby
	// (see refresh_chunk_occupancy_nearby) is this same 3x3x3
	// chunk-neighborhood check, precomputed once per occupancy rebuild
	// instead of rescanned fresh on every candidate cell here — an O(1)
	// lookup rules out the common case cheaply. Only sound when the disc's
	// reach can't cross more than one chunk width, which holds for any
	// realistic unit clearance (this falls back to the full test below
	// otherwise, so an oversized clearance only costs more, never answers
	// wrong). The cached flag already accounts for all
	// three axes, not just the horizontal ones — occupancy is a column
	// (see occupant_layers), and so is the body tested below, so either can
	// reach into a vertically-adjacent chunk too. chunk_idx is the caller's
	// already-computed chunk_coord_index(cell_to_chunk_coord(cell)) — this
	// is always called right after is_valid_cell derives the same chunk
	// coordinate for its own support/clearance checks, so recomputing it a
	// third time here would be pure waste.
	int reach_cells = (int)std::ceil(clearance / CELL_SIZE);
	int layers = body_layers(height);
	if (reach_cells <= CHUNK_DIM && layers <= CHUNK_DIM) {
		if (!chunk_occupancy_nearby[chunk_idx]) {
			return true;
		}
	}

	// Two columns collide when their discs overlap (centres no further
	// apart than the two clearances) and their layer spans share a layer:
	// the continuous form of asking whether any cell of this body's disc
	// lies in the occupant's. Any occupant that can collide is listed in a chunk
	// this body's own column reaches, since the overlap lies in both.
	Vector3i lo = cell - Vector3i(reach_cells, 0, reach_cells);
	Vector3i hi = cell + Vector3i(reach_cells, layers - 1, reach_cells);
	lo = Vector3i(std::max(lo.x, 0), std::max(lo.y, 0), std::max(lo.z, 0));
	hi = Vector3i(std::min(hi.x, grid_size.x - 1), std::min(hi.y, grid_size.y - 1), std::min(hi.z, grid_size.z - 1));
	Vector3i clo = cell_to_chunk_coord(lo);
	Vector3i chi = cell_to_chunk_coord(hi);
	for (int cx = clo.x; cx <= chi.x; cx++) {
		for (int cy = clo.y; cy <= chi.y; cy++) {
			for (int cz = clo.z; cz <= chi.z; cz++) {
				const std::unique_ptr<NavChunk> &slot = chunks[chunk_coord_index(Vector3i(cx, cy, cz))];
				if (!slot || !slot->has_occupancy) {
					continue;
				}
				for (const OccupantVolume &occ : slot->occupants) {
					if (cell.y > occ.cell.y + occ.layers - 1 || occ.cell.y > cell.y + layers - 1) {
						continue;
					}
					int dx = occ.cell.x - cell.x;
					int dz = occ.cell.z - cell.z;
					float reach = clearance + occ.clearance;
					if ((float)(dx * dx + dz * dz) * CELL_SIZE * CELL_SIZE > reach * reach) {
						continue;
					}
					if (occ.obj != self_unit && std::find(query_ignore.begin(), query_ignore.end(), occ.obj) == query_ignore.end()) {
						return false;
					}
				}
			}
		}
	}
	return true;
}

bool NavigationGrid::is_valid_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit) {
	if (!in_bounds(cell)) {
		return false;
	}

	// A crawl query's cell is the middle of the body, and it has its own
	// rule (see is_crawl_cell). Other units are kept off the same way as
	// always, from the bottom of the body up.
	if (crawl_query) {
		if (!is_crawl_cell(cell)) {
			return false;
		}
		if (!any_occupied) {
			return true;
		}
		const Vector3i feet(cell.x, std::max(0, cell.y - crawl_radius_cells), cell.z);
		return is_clear_of_units(feet, chunk_coord_index(cell_to_chunk_coord(feet)), clearance, height, self_unit);
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

	// Baked chunks are the rule at query time (the area load bakes them all),
	// so the ensure_ calls hide behind a look at the flags.
	const std::unique_ptr<NavChunk> &slot = chunks[chunk_idx];
	NavChunk &support_chunk = (slot && slot->rasterized && slot->support_baked) ? *slot : ensure_chunk_support(chunk_coord);
	if (!is_open_cell(support_chunk, li, flying)) {
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
	// The distance field stops counting at MAX_CLEARANCE_CELLS, so a body
	// at least that wide (past 5 m) would find no cell "more than" clear
	// and could never move. Past the field's reach, ask only for the most
	// it can say: clear all the way out. Other units are still kept off at
	// the body's full clearance below.
	const float wall_clearance = std::min(clearance, MAX_CLEARANCE_CELLS * CELL_SIZE - 0.5f / DIST_SCALE * CELL_SIZE);
	Vector3i layer_chunk_coord = chunk_coord;
	int layer_chunk_idx = chunk_idx;
	int layer_li = li;
	NavChunk *dist_chunk = nullptr;
	for (int dy = 0; dy < vertical_cells; dy++, layer_li += CHUNK_DIM) {
		const int y = cell.y + dy;
		if (y >= grid_size.y) {
			return false;
		}
		// The column stays in one chunk until it crosses that chunk's top.
		if (dy > 0 && (y & (CHUNK_DIM - 1)) == 0) {
			layer_chunk_coord.y++;
			layer_chunk_idx += chunk_grid_size.x;
			layer_li -= CHUNK_DIM * CHUNK_DIM;
			dist_chunk = nullptr;
		}
		if (!dist_chunk) {
			const std::unique_ptr<NavChunk> &layer_slot = chunks[layer_chunk_idx];
			dist_chunk = (layer_slot && layer_slot->rasterized && layer_slot->dist_baked) ? layer_slot.get() : &ensure_chunk_dist(layer_chunk_coord);
		}
		float clearance_world = (float)dist_chunk->dist.get(layer_li) / (float)DIST_SCALE * CELL_SIZE;
		if (clearance_world <= wall_clearance) {
			return false;
		}
	}

	if (!any_occupied) {
		return true;
	}
	return is_clear_of_units(cell, chunk_idx, clearance, height, self_unit);
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
	float height = exclude_unit ? get_float_prop(exclude_unit, "height") : DEFAULT_BODY_HEIGHT;
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
				// Only the shell: inside it, dz jumps straight from -radius to radius.
				bool on_shell = std::abs(dx) == radius || std::abs(dy) == radius;
				int dz_step = on_shell ? 1 : 2 * radius;
				for (int dz = -radius; dz <= radius; dz += dz_step) {
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

// The nearest cell a body fits, reached by walking from where it stands.
// find_nearest_free_cell answers "where near here does it fit", which is
// right for a clicked goal but not for a start: the nearest fit can be on
// the far side of a wall, and the route's first leg would go through it.
// This walks the A* neighbour steps instead, over cells a thin body could
// stand in, so the step out is one the body can actually take.
NavigationGrid::NearestResult NavigationGrid::find_escape_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit, int max_radius) {
	ensure_neighbor_offsets();
	const std::vector<Vector3i> &thin = disc_offsets(ESCAPE_CLEARANCE);
	auto key = [](const Vector3i &c) -> int64_t {
		return ((int64_t)c.x << 42) ^ ((int64_t)c.y << 21) ^ (int64_t)c.z;
	};
	std::unordered_set<int64_t> seen;
	std::vector<Vector3i> frontier;
	frontier.push_back(cell);
	seen.insert(key(cell));
	// One layer per step, so the first fit found is the fewest steps away.
	while (!frontier.empty()) {
		std::vector<Vector3i> next;
		for (const Vector3i &current : frontier) {
			for (const Vector3i &offset : neighbor_offsets) {
				Vector3i n = current + offset;
				if (!in_bounds(n)) {
					continue;
				}
				Vector3i d = n - cell;
				if (std::abs(d.x) > max_radius || std::abs(d.y) > max_radius || std::abs(d.z) > max_radius) {
					continue;
				}
				if (!seen.insert(key(n)).second) {
					continue;
				}
				if (!is_valid_cell(n, thin, ESCAPE_CLEARANCE, height, flying, self_unit)) {
					continue;
				}
				if (is_valid_cell(n, offsets, clearance, height, flying, self_unit)) {
					return { true, n };
				}
				next.push_back(n);
			}
		}
		frontier.swap(next);
	}
	return { false, cell };
}

// --- Pathfinding -------------------------------------------------------------

PackedVector3Array NavigationGrid::find_path(SceneTree *tree, Vector3 start, Vector3 destination, Object *unit, bool flying, Array ignore) {
	StageClock clock(STAGE_SEARCH);
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

	// The search reaches past the body's own clearance, so a wide body sent
	// onto another unit still finds the nearest spot it fits beside it.
	int snap_radius = 12 + (int)Math::ceil(clearance / CELL_SIZE);
	NearestResult goal_snap = find_nearest_free_cell(world_to_cell(destination), offsets, clearance, height, flying, unit, snap_radius);
	if (!goal_snap.found) {
		return PackedVector3Array();
	}
	Vector3i goal_cell = goal_snap.cell;

	// A body can stand where its clearance says it does not fit: spawned
	// there, grown there, or pressed there by physics (its collider is
	// narrower than its clearance disc). A* only steps onto valid cells, so
	// from such a start every neighbour is refused and no route exists to
	// anywhere. The search starts instead from the nearest cell the body
	// does fit, walked to rather than looked up (find_escape_cell), and the
	// route's first leg is the step out to it.
	Vector3i search_start_cell = start_cell;
	bool start_snapped = false;
	if (!is_valid_cell(start_cell, offsets, clearance, height, flying, unit)) {
		NearestResult start_snap = find_escape_cell(start_cell, offsets, clearance, height, flying, unit, snap_radius);
		if (!start_snap.found) {
			return PackedVector3Array();
		}
		search_start_cell = start_snap.cell;
		start_snapped = true;
	}

	if (search_start_cell == goal_cell) {
		PackedVector3Array result;
		result.push_back(start);
		result.push_back(cell_center(goal_cell));
		return result;
	}

	// A goal sealed off from the start is answered here, not by a search
	// that has to exhaust itself (MAX_EXPANSIONS, ~160 ms) to find out.
	const int cls = clearance_class(clearance);
	ensure_class_ready(flying, cls);
	if (!regions_may_connect(search_start_cell, goal_cell, flying, cls)) {
		return PackedVector3Array();
	}

	// One search, steered by a route estimate over the region graph. The
	// estimate changes which cells are looked at first and never which are
	// allowed, so a route that exists is still found.
	//
	// Regions ignore occupancy and only approximate a body's clearance, so
	// a goal they pass can still be sealed off for this unit (ringed by
	// units, behind a gap a little too narrow for it). The goal flood (see
	// GoalFlood) answers that from the goal's side while the search runs.
	build_region_guide(search_start_cell, goal_cell, flying, cls);
	GoalFlood flood;
	goal_flood_begin(flood, search_start_cell, goal_cell);
	PackedVector3Array raw = a_star(start, search_start_cell, goal_cell, offsets, clearance, height, flying, unit, cls, &flood);
	if (raw.size() < 2) {
		return raw;
	}
	if (start_snapped) {
		raw.insert(1, cell_center(search_start_cell));
	}
	return smooth_path(raw, offsets, clearance, height, flying, unit);
}

// --- Wall crawling -----------------------------------------------------------
//
// A crawler's body is a ball, and the cells it may be centred on are a shell:
// no solid closer than the ball's radius, and some solid just past it. Floors,
// walls and ceilings are the same rule, the ball always fits, and inner and
// outer corners round off without anyone describing them.

void NavigationGrid::begin_crawl_query(float radius) {
	crawl_query = true;
	if (radius == crawl_radius && !crawl_ball.empty()) {
		return;
	}
	crawl_radius = radius;
	crawl_class = (int)(std::find(crawl_radii.begin(), crawl_radii.end(), radius) - crawl_radii.begin());
	if (crawl_class == (int)crawl_radii.size()) {
		crawl_radii.push_back(radius);
	}
	const float radius_cells = radius / CELL_SIZE;
	crawl_radius_cells = (int)std::round(radius_cells);
	// Half a cell because a solid cell's centre is half a cell behind its face.
	const float core = radius_cells + 0.5f;
	const float outer = core + CRAWL_SHELL_CELLS;
	crawl_core2 = core * core;
	crawl_ball.clear();
	const int reach = (int)std::ceil(outer);
	for (int dx = -reach; dx <= reach; dx++) {
		for (int dy = -reach; dy <= reach; dy++) {
			for (int dz = -reach; dz <= reach; dz++) {
				const int d2 = dx * dx + dy * dy + dz * dz;
				if ((float)d2 <= outer * outer) {
					crawl_ball.push_back({ Vector3i(dx, dy, dz), d2 });
				}
			}
		}
	}
	std::sort(crawl_ball.begin(), crawl_ball.end(), [](const CrawlOffset &a, const CrawlOffset &b) { return a.d2 < b.d2; });
	// Directly below: from the first layer the core allows to the shell's end.
	crawl_floor_first = (int)std::floor(core) + 1;
	crawl_floor_last = (int)std::floor(outer);
}

// The map's sides and top are open air, not a surface to climb; only off the
// bottom counts as solid, as it does for everyone.
bool NavigationGrid::crawl_solid(const Vector3i &cell) {
	if (cell.x < 0 || cell.z < 0 || cell.x >= grid_size.x || cell.y >= grid_size.y || cell.z >= grid_size.z) {
		return false;
	}
	return is_solid(cell);
}

// The ball is sorted by distance, so the nearest solid is the first one met
// and it alone decides: inside the core the body doesn't fit, past it the
// body is against a surface. Nothing met means nothing to hold on to.
CrawlCells::Kind NavigationGrid::classify_crawl_cell(const Vector3i &cell) {
	for (const CrawlOffset &entry : crawl_ball) {
		if (!crawl_solid(cell + entry.offset)) {
			continue;
		}
		if ((float)entry.d2 <= crawl_core2) {
			return CrawlCells::NONE;
		}
		for (int down = crawl_floor_first; down <= crawl_floor_last; down++) {
			if (crawl_solid(cell - Vector3i(0, down, 0))) {
				return CrawlCells::FLOORED;
			}
		}
		return CrawlCells::HOLDING;
	}
	return CrawlCells::NONE;
}

CrawlCells::Kind NavigationGrid::crawl_kind(const Vector3i &cell) {
	NavChunk &chunk = ensure_chunk_rasterized(cell_to_chunk_coord(cell));
	if ((int)chunk.crawl.size() <= crawl_class) {
		chunk.crawl.resize(crawl_class + 1);
	}
	std::unique_ptr<CrawlCells> &cells = chunk.crawl[crawl_class];
	if (!cells) {
		cells = std::make_unique<CrawlCells>();
	}
	const int li = local_index(cell_to_local(cell));
	std::unique_ptr<uint8_t[]> &brick = cells->bricks[BrickField<uint8_t>::slot_of(li)];
	if (!brick) {
		brick.reset(new uint8_t[BrickField<uint8_t>::BRICK_CELLS]());
	}
	uint8_t &kind = brick[BrickField<uint8_t>::local_of(li)];
	if (kind == CrawlCells::UNKNOWN) {
		kind = classify_crawl_cell(cell);
	}
	return (CrawlCells::Kind)kind;
}

bool NavigationGrid::is_crawl_cell(const Vector3i &cell) {
	return crawl_kind(cell) != CrawlCells::NONE;
}

bool NavigationGrid::crawl_has_floor(const Vector3i &cell) {
	return crawl_kind(cell) == CrawlCells::FLOORED;
}

// Away from whatever solid the ball holds: the offsets of a flat surface's
// cells cancel sideways, so a floor or wall is exact, and a corner, where two
// surfaces share the ball, comes out between them and turns smoothly.
bool NavigationGrid::crawl_surface(const Vector3 &point, Vector3 &normal, Vector3 &nearest) {
	const Vector3i cell = world_to_cell(point);
	Vector3i sum;
	bool found = false;
	float contact2 = 0.0f;
	for (const CrawlOffset &entry : crawl_ball) {
		if (found && (float)entry.d2 > contact2) {
			break;
		}
		if (!crawl_solid(cell + entry.offset)) {
			continue;
		}
		if (!found) {
			nearest = cell_center(cell + entry.offset);
			found = true;
			// Only what the body is touching: a wall a metre off doesn't
			// lean a spider walking the floor beside it.
			const float contact = std::sqrt((float)entry.d2) + CRAWL_CONTACT_CELLS;
			contact2 = contact * contact;
		}
		sum += entry.offset;
	}
	if (!found || sum == Vector3i()) {
		return false;
	}
	normal = -Vector3((float)sum.x, (float)sum.y, (float)sum.z).normalized();
	return true;
}

// The cells only say which layer of the shell a point is in; the body rides
// exactly one radius off the surface.
Vector3 NavigationGrid::crawl_project(const Vector3 &point) {
	Vector3 normal;
	Vector3 nearest;
	if (!crawl_surface(point, normal, nearest)) {
		return point;
	}
	const float gap = (point - nearest).dot(normal) - CELL_SIZE * 0.5f;
	return point + normal * (crawl_radius - gap);
}

// A click lands on the surface, a few cells inside the shell's reach, so the
// ball (sorted by distance) finds the truly nearest cell. The cube search
// returns the first hit from one corner of each ring, which on a wall is a
// metre down and to the side of where the player clicked.
NavigationGrid::NearestResult NavigationGrid::nearest_crawl_cell(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, Object *unit, int max_radius) {
	for (const CrawlOffset &entry : crawl_ball) {
		const Vector3i candidate = cell + entry.offset;
		if (is_valid_cell(candidate, offsets, clearance, height, true, unit)) {
			return { true, candidate };
		}
	}
	return find_nearest_free_cell(cell, offsets, clearance, height, true, unit, max_radius);
}

// Start and result are the unit's origin, as every other route is, so the
// preview, the budget and the walking code need no second kind of point. The
// body's centre is always one radius straight above that origin.
PackedVector3Array NavigationGrid::find_crawl_path(SceneTree *tree, Vector3 start, Vector3 destination, Object *unit, Array ignore) {
	StageClock clock(STAGE_SEARCH);
	activate_for(unit);
	ensure_baked(tree);
	ensure_occupancy_current(tree);
	set_query_ignore(ignore);

	const float clearance = get_float_prop(unit, "radius") + get_float_prop(unit, "avoidance_margin");
	const float height = get_float_prop(unit, "height");
	const float radius = height * 0.5f;
	const std::vector<Vector3i> &offsets = disc_offsets(clearance);
	ensure_neighbor_offsets();
	begin_crawl_query(radius);
	struct EndQuery {
		bool &flag;
		~EndQuery() { flag = false; }
	} end_query{ crawl_query };

	const Vector3 centre_lift(0.0f, radius, 0.0f);
	const Vector3 centre = start + centre_lift;
	const Vector3i start_cell = world_to_cell(centre);
	if (!in_bounds(start_cell)) {
		return PackedVector3Array();
	}
	const int snap_radius = 12 + (int)Math::ceil(clearance / CELL_SIZE);
	const NearestResult goal = nearest_crawl_cell(world_to_cell(destination), offsets, clearance, height, unit, snap_radius);
	const NearestResult from = nearest_crawl_cell(start_cell, offsets, clearance, height, unit, snap_radius);
	if (!goal.found || !from.found) {
		return PackedVector3Array();
	}

	PackedVector3Array path;
	if (from.cell == goal.cell) {
		path.push_back(centre);
		path.push_back(cell_center(goal.cell));
	} else {
		GoalFlood flood;
		goal_flood_begin(flood, from.cell, goal.cell);
		PackedVector3Array raw = a_star(centre, from.cell, goal.cell, offsets, clearance, height, true, unit, 0, &flood);
		if (raw.size() < 2) {
			return PackedVector3Array();
		}
		path = smooth_path(raw, offsets, clearance, height, true, unit);
	}
	for (int i = 0; i < path.size(); i++) {
		path.set(i, (i == 0 ? path[i] : crawl_project(path[i])) - centre_lift);
	}
	return path;
}

// ZERO when the ball holds no surface at all: the unit has nothing to cling to.
Vector3 NavigationGrid::crawl_normal(SceneTree *tree, Vector3 origin, Object *unit) {
	activate_for(unit);
	ensure_baked(tree);
	const float radius = get_float_prop(unit, "height") * 0.5f;
	begin_crawl_query(radius);
	crawl_query = false;
	Vector3 normal;
	Vector3 nearest;
	if (!crawl_surface(origin + Vector3(0.0f, radius, 0.0f), normal, nearest)) {
		return Vector3();
	}
	return normal;
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

// --- Connectivity regions ----------------------------------------------------

NavRegions &NavigationGrid::ensure_chunk_regions(const Vector3i &chunk_coord, bool flying, int cls) {
	NavChunk &chunk = ensure_chunk_support(chunk_coord);
	NavRegions &r = chunk.regions_of(flying, cls);
	if (r.labelled) {
		return r;
	}
	if (cls > 0) {
		ensure_chunk_dist(chunk_coord);
	}
	StageClock clock(STAGE_REGIONS);
	r.labelled = true;
	r.guide.clear();
	uint16_t *label_w = r.label.begin_write(0);
	r.count = 0;

	Vector3i base = chunk_coord * CHUNK_DIM;
	int cx1 = std::min(CHUNK_DIM, grid_size.x - base.x);
	int cy1 = std::min(CHUNK_DIM, grid_size.y - base.y);
	int cz1 = std::min(CHUNK_DIM, grid_size.z - base.z);

	// Open = is_open_cell, the very call is_valid_cell makes: the part of
	// its rule that holds for every clearance and height. Sharing the rule
	// instead of restating it is what keeps regions from ever being
	// stricter than A*. Closed cells stay 0. A wide class also wants its
	// threshold's room at the cell, which is_valid_cell demands of every
	// cell of the body, the feet included: still never stricter.
	//
	// Labelled by runs, not cells: each x-row's open cells split into runs,
	// and a run joins (union-find) every run it touches in the 8 rows
	// around it - touching takes overlap with one cell of slack either
	// side, which is 26-connectivity. A chunk of air is 1,024 runs, not
	// 32,768 cells times 26 neighbours. Runs come in local_index order, so
	// numbering components by their first run gives the very labels a
	// cell-by-cell flood seeded in that order did.
	thread_local std::vector<uint8_t> s_solid, s_a, s_b;
	const uint8_t *solid = chunk.solid.dense(s_solid);
	const uint8_t *fa = flying ? chunk.flight_low.dense(s_a) : chunk.no_support.dense(s_a);
	const uint8_t *fb = flying ? chunk.flight_high.dense(s_b) : nullptr;
	thread_local std::vector<uint16_t> s_dist;
	const uint16_t *dist = cls > 0 ? chunk.dist.dense(s_dist) : nullptr;
	const uint16_t min_dist = (uint16_t)(CLEARANCE_CLASS_M[cls] / CELL_SIZE * DIST_SCALE);

	struct Run {
		int16_t x0, x1;
		int parent;
	};
	thread_local std::vector<Run> runs;
	thread_local std::vector<int> row_first; // [row] -> first run, row = y + z * CHUNK_DIM; [ROWS] = end
	const int ROWS = CHUNK_DIM * CHUNK_DIM;
	runs.clear();
	row_first.assign(ROWS + 1, 0);
	for (int z = 0; z < CHUNK_DIM; z++) {
		for (int y = 0; y < CHUNK_DIM; y++) {
			const int row = y + z * CHUNK_DIM;
			row_first[row] = (int)runs.size();
			if (y >= cy1 || z >= cz1) {
				continue;
			}
			const int li0 = row * CHUNK_DIM;
			int x = 0;
			while (x < cx1) {
				auto open = [&](int xi) {
					const int li = li0 + xi;
					return solid[li] == 0 && fa[li] == 0 && (!fb || fb[li] == 0) && (!dist || dist[li] >= min_dist);
				};
				if (!open(x)) {
					x++;
					continue;
				}
				int x0 = x;
				while (x < cx1 && open(x)) {
					x++;
				}
				runs.push_back({ (int16_t)x0, (int16_t)(x - 1), (int)runs.size() });
			}
		}
	}
	row_first[ROWS] = (int)runs.size();
	if (runs.empty()) {
		r.label.end_write();
		return r;
	}

	auto find = [&](int i) {
		while (runs[i].parent != i) {
			runs[i].parent = runs[runs[i].parent].parent;
			i = runs[i].parent;
		}
		return i;
	};
	auto unite = [&](int a, int b) {
		a = find(a);
		b = find(b);
		if (a != b) {
			// The lower run stays the root, so a root is its component's first run.
			if (a < b) {
				runs[b].parent = a;
			} else {
				runs[a].parent = b;
			}
		}
	};
	// Each row against the four rows of the 8 around it that come before
	// it in row order; the other four see it from their side.
	static const int BEFORE[4][2] = { { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }; // (dy, dz)
	for (int z = 0; z < cz1; z++) {
		for (int y = 0; y < cy1; y++) {
			const int row = y + z * CHUNK_DIM;
			const int a0 = row_first[row], a1 = row_first[row + 1];
			if (a0 == a1) {
				continue;
			}
			for (const int *d : BEFORE) {
				const int ny = y + d[0], nz = z + d[1];
				if (ny < 0 || ny >= cy1 || nz < 0) {
					continue;
				}
				const int nrow = ny + nz * CHUNK_DIM;
				int i = a0, j = row_first[nrow];
				const int j1 = row_first[nrow + 1];
				while (i < a1 && j < j1) {
					if (runs[j].x0 <= runs[i].x1 + 1 && runs[i].x0 <= runs[j].x1 + 1) {
						unite(i, j);
					}
					// Step past whichever run ends first.
					if (runs[i].x1 < runs[j].x1) {
						i++;
					} else {
						j++;
					}
				}
			}
		}
	}

	thread_local std::vector<uint16_t> id_of_root;
	id_of_root.assign(runs.size(), 0);
	for (int i = 0; i < (int)runs.size(); i++) {
		const int root = find(i);
		if (id_of_root[root] == 0) {
			id_of_root[root] = ++r.count;
		}
	}
	for (int row = 0; row < ROWS; row++) {
		for (int i = row_first[row]; i < row_first[row + 1]; i++) {
			const uint16_t id = id_of_root[find(i)];
			uint16_t *dst = label_w + row * CHUNK_DIM;
			std::fill(dst + runs[i].x0, dst + runs[i].x1 + 1, id);
		}
	}
	r.label.end_write();
	return r;
}

NavRegions &NavigationGrid::ensure_chunk_region_links(const Vector3i &chunk_coord, bool flying, int cls) {
	NavRegions &r = ensure_chunk_regions(chunk_coord, flying, cls);
	if (r.linked) {
		return r;
	}
	StageClock clock(STAGE_LINKS);
	r.linked = true;
	r.links.clear();
	r.link_first.assign((size_t)r.count + 1, 0);
	if (r.count == 0) {
		return r;
	}

	// The 26 neighbouring chunks' labels, resolved once. chunks is sized
	// once per scan, so these references stay valid while more are built.
	const NavRegions *around[3][3][3] = {};
	uint32_t around_idx[3][3][3] = {};
	for (int dx = -1; dx <= 1; dx++) {
		for (int dy = -1; dy <= 1; dy++) {
			for (int dz = -1; dz <= 1; dz++) {
				Vector3i nc = chunk_coord + Vector3i(dx, dy, dz);
				if ((dx == 0 && dy == 0 && dz == 0) || !chunk_in_bounds(nc)) {
					continue;
				}
				around[dx + 1][dy + 1][dz + 1] = &ensure_chunk_regions(nc, flying, cls);
				around_idx[dx + 1][dy + 1][dz + 1] = (uint32_t)chunk_coord_index(nc);
			}
		}
	}

	// Every (own region, neighbour region) pair across the chunk's skin, each
	// with the box of own cells along it. A neighbour chunk is across exactly
	// one side, so a pair is met on one side only: looking back over that
	// side's few pairs finds any repeat, and the flat sort needs no merging.
	struct Touch {
		uint16_t own;
		uint32_t chunk;
		uint16_t label;
		uint8_t lo[3];
		uint8_t hi[3];
	};
	thread_local std::vector<uint16_t> s_own;
	const uint16_t *own_label = r.label.dense(s_own);
	thread_local std::vector<Touch> touches;
	touches.clear();
	const int last = CHUNK_DIM - 1;
	for (int cdz = -1; cdz <= 1; cdz++) {
		for (int cdy = -1; cdy <= 1; cdy++) {
			for (int cdx = -1; cdx <= 1; cdx++) {
				const NavRegions *nb = around[cdx + 1][cdy + 1][cdz + 1];
				if (!nb || nb->count == 0) {
					continue;
				}
				const uint32_t nb_idx = around_idx[cdx + 1][cdy + 1][cdz + 1];
				// This chunk's cells on that side: the face, edge or corner
				// layer, and for each the neighbour cells across it.
				const int x0 = cdx < 0 ? 0 : (cdx > 0 ? last : 0), x1 = cdx == 0 ? last : x0;
				const int y0 = cdy < 0 ? 0 : (cdy > 0 ? last : 0), y1 = cdy == 0 ? last : y0;
				const int z0 = cdz < 0 ? 0 : (cdz > 0 ? last : 0), z1 = cdz == 0 ? last : z0;
				const size_t side_first = touches.size();
				size_t prev = (size_t)-1;
				for (int z = z0; z <= z1; z++) {
					for (int y = y0; y <= y1; y++) {
						for (int x = x0; x <= x1; x++) {
							const uint16_t own = own_label[x + y * CHUNK_DIM + z * CHUNK_DIM * CHUNK_DIM];
							if (own == 0) {
								continue;
							}
							// Neighbour cells across this side: on an axis the
							// side crosses, the one layer over; on the others,
							// this cell and the two beside it that stay inside
							// the neighbour chunk.
							const int ax0 = cdx != 0 ? (cdx < 0 ? last : 0) : std::max(0, x - 1);
							const int ax1 = cdx != 0 ? ax0 : std::min(last, x + 1);
							const int ay0 = cdy != 0 ? (cdy < 0 ? last : 0) : std::max(0, y - 1);
							const int ay1 = cdy != 0 ? ay0 : std::min(last, y + 1);
							const int az0 = cdz != 0 ? (cdz < 0 ? last : 0) : std::max(0, z - 1);
							const int az1 = cdz != 0 ? az0 : std::min(last, z + 1);
							for (int nz = az0; nz <= az1; nz++) {
								for (int ny = ay0; ny <= ay1; ny++) {
									for (int nx = ax0; nx <= ax1; nx++) {
										const uint16_t other = nb->label.get(nx + ny * CHUNK_DIM + nz * CHUNK_DIM * CHUNK_DIM);
										if (other == 0) {
											continue;
										}
										if (prev == (size_t)-1 || touches[prev].own != own || touches[prev].label != other) {
											prev = (size_t)-1;
											for (size_t t = side_first; t < touches.size(); t++) {
												if (touches[t].own == own && touches[t].label == other) {
													prev = t;
													break;
												}
											}
											if (prev == (size_t)-1) {
												prev = touches.size();
												touches.push_back({ own, nb_idx, other, { (uint8_t)x, (uint8_t)y, (uint8_t)z }, { (uint8_t)x, (uint8_t)y, (uint8_t)z } });
											}
										}
										Touch &t = touches[prev];
										t.lo[0] = std::min(t.lo[0], (uint8_t)x);
										t.lo[1] = std::min(t.lo[1], (uint8_t)y);
										t.lo[2] = std::min(t.lo[2], (uint8_t)z);
										t.hi[0] = std::max(t.hi[0], (uint8_t)x);
										t.hi[1] = std::max(t.hi[1], (uint8_t)y);
										t.hi[2] = std::max(t.hi[2], (uint8_t)z);
									}
								}
							}
						}
					}
				}
			}
		}
	}
	std::sort(touches.begin(), touches.end(), [](const Touch &a, const Touch &b) {
		if (a.own != b.own) {
			return a.own < b.own;
		}
		return a.chunk != b.chunk ? a.chunk < b.chunk : a.label < b.label;
	});
	r.links.reserve(touches.size());
	for (const Touch &t : touches) {
		r.link_first[t.own]++;
		r.links.push_back({ t.chunk, t.label, { t.lo[0], t.lo[1], t.lo[2] }, { t.hi[0], t.hi[1], t.hi[2] } });
	}
	for (int i = 1; i <= r.count; i++) {
		r.link_first[i] += r.link_first[i - 1];
	}
	return r;
}

uint64_t NavigationGrid::region_key(const Vector3i &cell, bool flying, int cls) {
	if (!in_bounds(cell)) {
		return 0;
	}
	Vector3i cc = cell_to_chunk_coord(cell);
	uint16_t label = ensure_chunk_regions(cc, flying, cls).label.get(local_index(cell_to_local(cell)));
	if (label == 0) {
		return 0;
	}
	return ((uint64_t)chunk_coord_index(cc) << 16) | label;
}

bool NavigationGrid::regions_may_connect(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying, int cls) {
	uint64_t goal_key = region_key(goal_cell, flying, cls);
	if (goal_key == 0) {
		return true; // the goal passed is_valid_cell, so this can't happen; let the search decide
	}
	// a_star expands the start cell whether or not it is valid, then steps
	// only into valid cells: its own region if open, else its neighbours'.
	std::vector<uint64_t> seeds;
	uint64_t own = region_key(start_cell, flying, cls);
	if (own != 0) {
		seeds.push_back(own);
	} else {
		for (const Vector3i &offset : neighbor_offsets) {
			uint64_t k = region_key(start_cell + offset, flying, cls);
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
		const NavRegions &r = ensure_chunk_region_links(cc, flying, cls);
		const int region = (int)(key & 0xFFFF) - 1;
		for (uint32_t li = r.link_first[region]; li < r.link_first[region + 1]; li++) {
			const uint64_t next = ((uint64_t)r.links[li].chunk << 16) | r.links[li].label;
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

// Where the straight line from `from` toward `toward` first enters the box
// [lo, hi], or the box's nearest point to where it stops. Aiming at the far
// end, not just the nearest point of the box, keeps a chain of these taut
// across open ground instead of staircasing along chunk faces.
static Vector3i portal_point(const Vector3i &from, const Vector3i &toward, const Vector3i &lo, const Vector3i &hi) {
	const float p[3] = { (float)from.x, (float)from.y, (float)from.z };
	const float d[3] = { (float)(toward.x - from.x), (float)(toward.y - from.y), (float)(toward.z - from.z) };
	float t = 0.0f;
	for (int a = 0; a < 3; a++) {
		if (d[a] != 0.0f) {
			const float t0 = ((float)lo[a] - p[a]) / d[a];
			const float t1 = ((float)hi[a] - p[a]) / d[a];
			t = std::max(t, std::min(t0, t1));
		}
	}
	t = std::min(t, 1.0f);
	Vector3i q;
	for (int a = 0; a < 3; a++) {
		const int v = (int)std::lround(p[a] + d[a] * t);
		q[a] = std::min(std::max(v, lo[a]), hi[a]);
	}
	return q;
}

void NavigationGrid::build_region_guide(const Vector3i &start_cell, const Vector3i &goal_cell, bool flying, int cls) {
	guide_gen++;
	guide_bound = 0.0f;
	const uint64_t goal_key = region_key(goal_cell, flying, cls);
	if (goal_key == 0) {
		return;
	}
	const uint64_t start_key = region_key(start_cell, flying, cls);

	auto guide_of = [&](NavRegions &r, int label) -> RegionGuide & {
		if (r.guide.size() != r.count) {
			r.guide.resize(r.count);
		}
		return r.guide[label - 1];
	};

	std::priority_queue<std::pair<float, uint64_t>, std::vector<std::pair<float, uint64_t>>, std::greater<std::pair<float, uint64_t>>> open;
	{
		NavRegions &r = ensure_chunk_region_links(cell_to_chunk_coord(goal_cell), flying, cls);
		RegionGuide &seed = guide_of(r, (int)(goal_key & 0xFFFF));
		seed.gen = guide_gen;
		seed.settled = false;
		seed.g = 0.0f;
		seed.entry = goal_cell;
	}
	open.push({ heuristic(goal_cell, start_cell), goal_key });

	float f_start = -1.0f;
	int settled = 0;
	while (!open.empty()) {
		const float f = open.top().first;
		const uint64_t key = open.top().second;
		if ((f_start >= 0.0f && f > f_start * GUIDE_SLACK_RATIO + GUIDE_SLACK_M) || settled >= MAX_REGION_EXPANSIONS) {
			guide_bound = f;
			return;
		}
		open.pop();
		const Vector3i cc = chunk_coord_from_index((int)(key >> 16));
		NavRegions &r = ensure_chunk_region_links(cc, flying, cls);
		const int region = (int)(key & 0xFFFF) - 1;
		RegionGuide &u = r.guide[region];
		if (u.settled) {
			continue;
		}
		u.settled = true;
		settled++;
		if (key == start_key && f_start < 0.0f) {
			f_start = f;
		}
		const float g_u = u.g;
		const Vector3i entry_u = u.entry;
		const Vector3i base = cc * CHUNK_DIM;
		for (uint32_t li = r.link_first[region]; li < r.link_first[region + 1]; li++) {
			const RegionLink &link = r.links[li];
			NavRegions &nr = chunks[link.chunk]->regions_of(flying, cls);
			RegionGuide &v = guide_of(nr, link.label);
			if (v.gen == guide_gen && v.settled) {
				continue;
			}
			const Vector3i lo = base + Vector3i(link.lo[0], link.lo[1], link.lo[2]);
			const Vector3i hi = base + Vector3i(link.hi[0], link.hi[1], link.hi[2]);
			const Vector3i p = portal_point(entry_u, start_cell, lo, hi);
			const float ng = g_u + heuristic(entry_u, p);
			if (v.gen != guide_gen || ng < v.g) {
				v.gen = guide_gen;
				v.settled = false;
				v.g = ng;
				v.entry = p;
				open.push({ ng + heuristic(p, start_cell), ((uint64_t)link.chunk << 16) | link.label });
			}
		}
	}
}

// A local cell's brick within its chunk's page, and its index in the brick.
static inline int brick_slot(const Vector3i &local_cell) {
	return (local_cell.x >> 3) + (local_cell.y >> 3) * 4 + (local_cell.z >> 3) * 16;
}

static inline int brick_local(const Vector3i &local_cell) {
	return (local_cell.x & 7) + (local_cell.y & 7) * 8 + (local_cell.z & 7) * 64;
}

AStarBrick &NavigationGrid::astar_brick_in(int chunk_index, const Vector3i &local_cell, int sid) {
	std::unique_ptr<AStarPage> &page = astar_pages[chunk_index];
	if (!page) {
		page = std::make_unique<AStarPage>();
	}
	std::unique_ptr<AStarBrick> &brick = page->bricks[brick_slot(local_cell)];
	if (!brick) {
		brick = std::make_unique<AStarBrick>();
	}
	if (brick->gen != sid) {
		// First touch this search: nothing in it is this search's yet.
		brick->gen = sid;
		std::fill_n(brick->state, AStarBrick::CELLS, (uint8_t)0);
	}
	return *brick;
}

AStarBrick &NavigationGrid::astar_brick(const Vector3i &cell, int sid, int &local) {
	Vector3i local_cell = cell_to_local(cell);
	local = brick_local(local_cell);
	return astar_brick_in(chunk_coord_index(cell_to_chunk_coord(cell)), local_cell, sid);
}

// The first ask of a cell is the only one that costs anything. g goes to
// "unreached" with it, which is what the search reads a CHECKED cell's g as.
inline bool NavigationGrid::valid_this_search(AStarBrick &brick, int local, const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit) {
	uint8_t &state = brick.state[local];
	if (!(state & AStarBrick::CHECKED)) {
		state |= AStarBrick::CHECKED | (is_valid_cell(cell, offsets, clearance, height, flying, self_unit) ? AStarBrick::VALID : (uint8_t)0);
		brick.g[local] = 1e30f;
	}
	return (state & AStarBrick::VALID) != 0;
}

bool NavigationGrid::is_valid_cell_cached(const Vector3i &cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *self_unit) {
	if (!in_bounds(cell)) {
		return false;
	}
	int local;
	AStarBrick &brick = astar_brick(cell, astar_search_id, local);
	return valid_this_search(brick, local, cell, offsets, clearance, height, flying, self_unit);
}

void NavigationGrid::goal_flood_begin(GoalFlood &flood, const Vector3i &start_cell, const Vector3i &goal_cell) {
	flood.state = GoalFlood::RUNNING;
	flood.start_cell = start_cell;
	flood.queue.clear();
	flood.head = 0;
	flood.seen_count = 0;
	std::fill_n(flood.seen, GoalFlood::SEEN_SLOTS, (int64_t)-1);
	flood.queue.push_back(goal_cell);
	flood.mark_seen(cell_index(goal_cell));
}

// One breadth-first expansion of the goal's side. Touching the start cell
// ends it OPEN: a_star expands the start whether or not it is valid, so
// that is exactly where the two sides meet.
void NavigationGrid::goal_flood_step(GoalFlood &flood, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit) {
	if (flood.state != GoalFlood::RUNNING) {
		return;
	}
	if (flood.head >= flood.queue.size()) {
		flood.state = GoalFlood::SEALED;
		return;
	}
	if (flood.seen_count > GOAL_FLOOD_BUDGET) {
		flood.state = GoalFlood::OPEN;
		return;
	}
	Vector3i current = flood.queue[flood.head++];
	for (const Vector3i &offset : neighbor_offsets) {
		Vector3i neighbor = current + offset;
		if (neighbor == flood.start_cell) {
			flood.state = GoalFlood::OPEN;
			return;
		}
		if (is_valid_cell_cached(neighbor, offsets, clearance, height, flying, unit) && flood.mark_seen(cell_index(neighbor))) {
			flood.queue.push_back(neighbor);
		}
	}
}

PackedVector3Array NavigationGrid::a_star(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit, int cls, GoalFlood *flood) {
	astar_search_id++;
	int sid = astar_search_id;

	int start_local;
	AStarBrick &start_brick = astar_brick(start_cell, sid, start_local);
	start_brick.g[start_local] = 0.0f;

	// Cost to the goal by way of the region the cell is in, from the guide;
	// most steps stay in the last cell's chunk, so its regions are kept.
	int cached_chunk = -1;
	NavRegions *cached_r = nullptr;
	auto estimate = [&](const Vector3i &cell, int chunk_idx, const Vector3i &local_cell) -> float {
		// Regions describe walkers and fliers; a crawler's cells aren't in them.
		if (crawl_query) {
			return heuristic(cell, goal_cell);
		}
		if (chunk_idx != cached_chunk) {
			cached_r = &ensure_chunk_regions(chunk_coord_from_index(chunk_idx), flying, cls);
			cached_chunk = chunk_idx;
		}
		const uint16_t label = cached_r->label.get(local_index(local_cell));
		if (label != 0 && !cached_r->guide.empty()) {
			const RegionGuide &g = cached_r->guide[label - 1];
			if (g.gen == guide_gen) {
				return heuristic(cell, g.entry) + g.g;
			}
		}
		return std::max(heuristic(cell, goal_cell), guide_bound - heuristic(cell, start_cell));
	};

	std::fill(open_heads.begin(), open_heads.end(), -1);
	open_nodes.clear();
	int open_cursor = OPEN_BUCKET_LIMIT;
	auto open_push = [&](float f, const Vector3i &cell) {
		const int bucket = (int)std::min(f / OPEN_BUCKET_M, (float)(OPEN_BUCKET_LIMIT - 1));
		if (bucket >= (int)open_heads.size()) {
			open_heads.resize(bucket + 1024, -1);
		}
		open_nodes.push_back({ cell, open_heads[bucket] });
		open_heads[bucket] = (int)open_nodes.size() - 1;
		open_cursor = std::min(open_cursor, bucket);
	};
	open_push(estimate(start_cell, chunk_coord_index(cell_to_chunk_coord(start_cell)), cell_to_local(start_cell)) * HEURISTIC_WEIGHT, start_cell);

	int expansions = 0;

	// The last brick a neighbour fell in: most of a cell's 26 neighbours
	// share its brick, so this skips the page table most steps. A brick
	// never moves once allocated (it is behind a unique_ptr) and is cleared
	// only on its first touch this search, so the pointer holds for the
	// whole search.
	int last_key = -1;
	AStarBrick *last_brick = nullptr;

	const int bricks_x = chunk_grid_size.x * AStarPage::SIDE;
	const int bricks_xy = bricks_x * chunk_grid_size.y * AStarPage::SIDE;
	const Vector3i last_cell = grid_size - Vector3i(1, 1, 1);
	const int neighbor_count = (int)neighbor_offsets.size();

	while (true) {
		const int open_end = (int)open_heads.size();
		while (open_cursor < open_end && open_heads[open_cursor] < 0) {
			open_cursor++;
		}
		if (open_cursor >= open_end) {
			break;
		}
		const OpenNode top = open_nodes[open_heads[open_cursor]];
		open_heads[open_cursor] = top.next;
		const Vector3i current = top.cell;
		int current_local;
		AStarBrick &current_brick = astar_brick(current, sid, current_local);
		if (current_brick.state[current_local] & AStarBrick::CLOSED) {
			continue;
		}
		current_brick.state[current_local] |= AStarBrick::CLOSED;

		if (current == goal_cell) {
			return reconstruct_path(start, start_cell, goal_cell);
		}

		expansions++;
		debug_expansion_count++;
		if (expansions > MAX_EXPANSIONS) {
			break;
		}
		if (flood && expansions % GOAL_FLOOD_EVERY == 0) {
			goal_flood_step(*flood, offsets, clearance, height, flying, unit);
			if (flood->state == GoalFlood::SEALED) {
				break;
			}
		}

		const float current_g = current_brick.g[current_local];
		const bool interior = current.x > 0 && current.y > 0 && current.z > 0 && current.x < last_cell.x && current.y < last_cell.y && current.z < last_cell.z;

		for (int oi = 0; oi < neighbor_count; oi++) {
			const Vector3i neighbor = current + neighbor_offsets[oi];
			if (!interior && !in_bounds(neighbor)) {
				continue;
			}
			// In bounds, so never negative: a shift is the division, and the
			// brick's own coordinates key it without finding its chunk.
			const int key = (neighbor.x >> 3) + (neighbor.y >> 3) * bricks_x + (neighbor.z >> 3) * bricks_xy;
			if (key != last_key) {
				last_brick = &astar_brick_in(chunk_coord_index(cell_to_chunk_coord(neighbor)), cell_to_local(neighbor), sid);
				last_key = key;
			}
			const int neighbor_local = (neighbor.x & 7) + (neighbor.y & 7) * 8 + (neighbor.z & 7) * 64;
			uint8_t &state = last_brick->state[neighbor_local];
			if (state & AStarBrick::CLOSED) {
				continue;
			}
			if (!valid_this_search(*last_brick, neighbor_local, neighbor, offsets, clearance, height, flying, unit)) {
				continue;
			}
			// A crawler takes the floor unless a wall is really a shortcut.
			const float step_cost = neighbor_step_cost[oi] * ((crawl_query && !crawl_has_floor(neighbor)) ? CRAWL_OFF_FLOOR_COST : 1.0f);
			const float tentative = current_g + step_cost;
			if (tentative < last_brick->g[neighbor_local]) {
				last_brick->g[neighbor_local] = tentative;
				state = (state & ~AStarBrick::DIR_MASK) | (uint8_t)oi;
				open_push(tentative + estimate(neighbor, chunk_coord_index(cell_to_chunk_coord(neighbor)), cell_to_local(neighbor)) * HEURISTIC_WEIGHT, neighbor);
			}
		}
	}

	return PackedVector3Array();
}

PackedVector3Array NavigationGrid::reconstruct_path(const Vector3 &start, const Vector3i &start_cell, const Vector3i &goal_cell) {
	// Walk back from the goal by each cell's arriving step. Every cell on
	// the chain but the start was reached this search, so its came_dir is
	// this search's, whichever chunk it sits in.
	std::vector<Vector3i> cells;
	cells.push_back(goal_cell);
	Vector3i cur = goal_cell;
	while (cur != start_cell) {
		int local;
		AStarBrick &brick = astar_brick(cur, astar_search_id, local);
		cur = cur - neighbor_offsets[brick.state[local] & AStarBrick::DIR_MASK];
		cells.push_back(cur);
	}
	std::reverse(cells.begin(), cells.end());

	PackedVector3Array result;
	result.push_back(start);
	for (size_t i = 1; i < cells.size(); i++) {
		result.push_back(cell_center(cells[i]));
	}
	return result;
}

PackedVector3Array NavigationGrid::smooth_path(const PackedVector3Array &path, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit) {
	if (path.size() <= 2) {
		return path;
	}

	// How far each anchor sees, by galloping out and bisecting back: a
	// straight run of n points costs log n line tests, where trying each
	// point in turn cost n of them, each as long as the run so far. The line
	// bisection lands on is clear and the next one isn't, so an anchor never
	// sees less far than the first failure would have left it.
	PackedVector3Array result;
	result.push_back(path[0]);
	const int last = path.size() - 1;
	int anchor = 0;
	while (anchor < last) {
		int clear = anchor + 1;
		int blocked = -1;
		for (int stride = 1; clear < last; stride *= 2) {
			const int probe = std::min(clear + stride, last);
			if (!line_clear(path[anchor], path[probe], offsets, clearance, height, flying, unit)) {
				blocked = probe;
				break;
			}
			clear = probe;
		}
		while (blocked - clear > 1) {
			const int probe = clear + (blocked - clear) / 2;
			if (line_clear(path[anchor], path[probe], offsets, clearance, height, flying, unit)) {
				clear = probe;
			} else {
				blocked = probe;
			}
		}
		if (clear < last) {
			result.push_back(path[clear]);
		}
		anchor = clear;
	}
	result.push_back(path[last]);
	return result;
}

bool NavigationGrid::line_clear(const Vector3 &a, const Vector3 &b, const std::vector<Vector3i> &offsets, float clearance, float height, bool flying, Object *unit) {
	float length = a.distance_to(b);
	int steps = std::max(1, (int)std::ceil(length / CELL_SIZE));
	for (int i = 1; i < steps; i++) {
		float t = (float)i / (float)steps;
		Vector3i cell = world_to_cell(a.lerp(b, t));
		if (is_valid_cell_cached(cell, offsets, clearance, height, flying, unit)) {
			continue;
		}
		// A walker's standing cells climb a slope in whole-cell stairs, so
		// a straight line up a ramp passes through the layer above or below
		// them between treads. The ground under the line is still there, a
		// cell off, and the same one-cell rise A* steps between neighbours.
		// Where the ground bends away from the line further than that (the
		// knee where a ramp meets the floor), the corner stays a waypoint.
		if (!flying && (is_valid_cell_cached(cell + Vector3i(0, 1, 0), offsets, clearance, height, flying, unit) || is_valid_cell_cached(cell - Vector3i(0, 1, 0), offsets, clearance, height, flying, unit))) {
			continue;
		}
		return false;
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
