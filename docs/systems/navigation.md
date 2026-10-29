# Navigation

**Files:**
- `gdextension/src/navigation_grid.h` (347) and `navigation_grid.cpp` (1500): the C++ `NavigationGrid` Engine singleton, registered at register_types.cpp:25-27.
- `systems/navigation_system/`:
  - `route_planner.gd` (79)
  - `formation_planner.gd` (58)
  - `path_avoidance.gd` (50)
  - `path_corner_rounding.gd` (51)

**Autoloads owned:** none. `NavigationGrid` is an Engine singleton from the GDExtension, not a project autoload (register_types.cpp:25-27).

## Purpose
NavigationGrid builds a chunked grid of walkable cells for each registered world. The grid is 0.25 m per cell, in chunks of 32 cells (`CHUNK_DIM`). It stamps unit and corpse occupancy into the grid and answers `find_path`. Path search is weighted A* (`HEURISTIC_WEIGHT` 1.3) inside a coarse corridor, with an unrestricted fallback, then smoothing (navigation_grid.h:156-179; navigation_grid.cpp:1150-1200).

The GDScript helpers turn a path into something a unit can walk. RoutePlanner cuts a path to the movement budget using a cost sampler (route_planner.gd:38-79). FormationPlanner spreads group moves across ring offsets (formation_planner.gd:31-58). PathAvoidance gathers nearby units as obstacles (path_avoidance.gd:34-50). PathCornerRounding smooths corners (path_corner_rounding.gd:18-51).

It does NOT move units (unit_movement.gd), own terrain costs (SurfaceManager supplies the sampler, `surfaces.md`), or run on the overworld (the overworld uses direct avatar control, so it has no nav grid).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Registry of worlds: active world plus `parked_worlds` | navigation_grid.cpp:62-117 (register/unregister/world_id_of) | no (rebuilt from geometry) |
| Baked walkable cells per world, plus the `baked` latch | navigation_grid.cpp:141-253 (activate_world, ensure_baked) | no |
| Occupancy snapshot (units and blocking corpses) | navigation_grid.cpp:793-890 | no |
| Constants: cell size, `CHUNK_DIM`, `HEURISTIC_WEIGHT`, clearance, `FLIGHT_MIN_ALTITUDE` / `FLIGHT_CEILING` | navigation_grid.h:156-179; bound as properties at navigation_grid.cpp:39-41 | code |
| Route constants `STEP_LENGTH` 0.5 | route_planner.gd:38-79 | code |

## Derived / cached state
- **Occupancy** copies unit positions into the grid. It is refreshed only by explicit `update_occupancy` calls:
  - encounter.gd:358, 402, 468, 582, 622
  - ground_click_target.gd:332
  - party_manager.gd:886

  Between those calls, the grid and the real unit positions can disagree.
- **The baked grid** is a cache of scene geometry. `invalidate()` resets only the **active** world's latch (navigation_grid.cpp:255-257). It is called by world_manager.gd:363, 523.
- **The active world** is implicit state. `activate_for(node, world_ref)` switches to the world of the node it is given (navigation_grid.cpp:226-245). Any call without a resolvable node keeps whichever world was active last.

## Public surface
- **Calls in** (NavigationGrid bindings at navigation_grid.cpp:25-41)
  - `find_path(unit, from, to)` (1150-1200). Called by unit_movement.gd:192 inside `plan_route` (174-202), plus AI and targeting.
  - `update_occupancy(movers, world_ref)` (793-890). Callers are listed in the derived-state section above.
  - `is_valid_cell` (1030-1096), `nearest_valid_point` (1101-1123), `is_clear_of_units` (984-1027).
  - `register_world` / `unregister_world` (62-105). Called by world_context.gd:59 and 99.
  - `invalidate` (255-257) and `ensure_baked` (247-253).
  - `RoutePlanner.plan(path, budget, cost_sampler)` (route_planner.gd:38-79). Called by unit_movement.gd:202, movement_indicator.gd:290 and 353, fly_to_close_gap_behavior.gd:68, and ladder.gd:171.
  - `FormationPlanner.command_group_move` (formation_planner.gd:31-46). Used by party and selection commands.
  - `PathAvoidance.gather_obstacles` (path_avoidance.gd:34-50). Used by GroundPointTargeting.
- **Signals out:** none.
- **Signals in:** none. Everything is pull-based.

## Depends on
- The "units" group and the "blocking_corpses" group, both read during occupancy stamping (navigation_grid.cpp:793-890). Units leave "units" on death and corpses join "blocking_corpses" (unit_death.gd:53-117).
- The active root or current scene, used by the project scan (navigation_grid.cpp:259+).
- `WorldContext` register/unregister (world_context.gd:59, 99).
- `UnitQuery.living_units_near` for avoidance, scoped to the world (path_avoidance.gd:43-44).
- `PartyManager.leader` for the formation anchor (formation_planner.gd:31-46).
- `SurfaceManager.movement_cost_multiplier_at` as the sampler RoutePlanner usually receives (unit_movement.gd:202).

## Assumptions and invariants
- A world switch happens only inside `activate_for` / `activate_world`. Every query must pass a node whose world can be resolved.
- `find_path` excludes the moving unit from its own occupancy (is_clear_of_units, 1023). `update_occupancy` skips movers (793-890).
- A cell is valid only if it has support beneath it (1056-1061) and clearance on each layer (1076-1093).
- STALE, "one fight at a time": each world holds one occupancy snapshot. Two encounters in the same world share it, and each overwrites the other's movers at its own turn boundaries (793-890; encounter.gd:358, 468).
- STALE, "one active world": `invalidate()` touches only the active world (255-257).
- RoutePlanner samples the cost at the previous point and clamps to the budget (route_planner.gd:63, 67-72).

## Lifecycle
- **World load:** `WorldContext` registers its world (world_context.gd:59). The grid is baked lazily on first `ensure_baked` or query (navigation_grid.cpp:247-253).
- **World travel:** the old world is parked, not freed. WorldManager calls `invalidate` (world_manager.gd:363, 523).
- **World unload:** `unregister_world` (world_context.gd:99; navigation_grid.cpp:84-105).
- **Combat turns:** occupancy is refreshed at each turn start and end, on death, and on delay (encounter.gd:358, 402, 468, 582, 622).
- **Exploration:** occupancy is refreshed only on move commands (ground_click_target.gd:332; party_manager.gd:886).
- **Save / load / new game:** no state is saved. The grid is rebuilt from geometry.
- **Dialogue / cutscene:** not involved.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | `update_occupancy([])` with no `world_ref` stamps whichever world is currently active. Encounter's death handler does this when there is no current unit. | encounter.gd:582; navigation_grid.cpp:793-890, 226-245 | NEW |
| 2 | Concurrent encounters in one world share and overwrite a single occupancy snapshot. | navigation_grid.cpp:793-890 | NEW |
| 3 | Occupancy is stale between refresh points, for example after knockback or a mid-turn move by another unit, until the next turn boundary. | callers listed in "Derived / cached state" | NEW |
| 4 | `invalidate()` resets only the active world's bake latch. Parked worlds keep a stale bake. | navigation_grid.cpp:255-257 | NEW |
| 5 | Slopes and ramps are impassable, because risers fail the support and clearance checks. A red suite for this exists but is uncommitted (known issue). | navigation_grid.cpp:1056-1061, 1076-1093 | CONFIRMED |
| 6 | The route_planner.gd header still refers to `navigation_grid.gd` and navmesh. Both were replaced by the C++ grid. | route_planner.gd:3-4, 14-17 | NEW |
| 7 | `encounter.resume()` never refreshes occupancy, so the first turn after a load uses a snapshot from before the load (see `combat.md` #3). | encounter.gd:172-188 | CONFIRMED |

Checked and ruled out: the suspicion that `FLIGHT_MIN_ALTITUDE` / `FLIGHT_CEILING` are unbound from GDScript is false. They are bound as properties (navigation_grid.cpp:39-41) and used at unit_movement.gd:188-189 and 531-532.

## Tests
- tests/world/test_nav_grid_worlds.gd (multi-world registry)
- test_member_reachability.gd
- test_arrival_placement.gd
- test_jackson_square_paths.gd. This one is OSM-blockout overworld work, so it is not evidence for combat navigation.
- ai_test_case.gd harness.

**Gaps:**
- No test covers occupancy with two encounters in one world (issue 2) or `update_occupancy([])` world selection (issue 1).
- No test covers parked-world invalidation (issue 4).
- No unit tests exist for RoutePlanner budget clamping or FormationPlanner.
