# Navigation

**Files:**
- `gdextension/src/navigation_grid.h` (1041) and `navigation_grid.cpp` (4474): the C++ `NavigationGrid` Engine singleton, registered at register_types.cpp:25-27.
- `systems/navigation_system/`:
  - `route_planner.gd` (79)
  - `formation_planner.gd` (100)
  - `path_avoidance.gd` (50)
  - `path_corner_rounding.gd` (76)

**Autoloads owned:** none. `NavigationGrid` is an Engine singleton from the GDExtension, not a project autoload (register_types.cpp:25-27).

## Purpose
NavigationGrid builds a chunked grid of walkable cells for each registered world. The grid is 0.25 m per cell, in chunks of 32 cells (`CHUNK_DIM`). It stamps unit and corpse occupancy into the grid and answers `find_path`. Path search is weighted A* (`HEURISTIC_WEIGHT` 1.3) inside a coarse corridor, with an unrestricted fallback, then smoothing (navigation_grid.h:156-179; navigation_grid.cpp:1150-1200).

The GDScript helpers turn a path into something a unit can walk. RoutePlanner cuts a path to the movement budget using a cost sampler (route_planner.gd:38-79). FormationPlanner spreads group moves across ring offsets (formation_planner.gd:31-58). PathAvoidance gathers nearby units as obstacles (path_avoidance.gd:34-50). PathCornerRounding smooths corners (path_corner_rounding.gd:18-51).

Which nodes and shapes the grid reads, and what counts as inside geometry, is the authoring contract in [navigation_authoring.md](navigation_authoring.md).

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
- **Occupancy** copies unit positions into the grid. Since 62f265d4 it is also compared live on every query (navigation_grid.cpp:2921-2997), so a stale stamp no longer decides a path; `update_occupancy` is still called at:
  - encounter.gd:358, 402, 468, 582, 622
  - ground_click_target.gd:332
  - party_manager.gd:886

  Between those calls the stamped list can lag, but queries re-check live positions (DOC DRIFT, fixed in doc by review 11-15).
- **The baked grid** is a cache of scene geometry. `invalidate()` resets only the **active** world's latch (navigation_grid.cpp:255-257). It is called by world_manager.gd:363, 523.
- **The active world** is implicit state. `activate_for(node, world_ref)` switches to the world of the node it is given (navigation_grid.cpp:226-245). Any call without a resolvable node keeps whichever world was active last.

## Public surface
- **Calls in** (NavigationGrid bindings at navigation_grid.cpp:25-41)
  - `find_path(unit, from, to)` (1150-1200). Called by unit_movement.gd:192 inside `plan_route` (174-202), plus AI and targeting.
  - `update_occupancy(movers, world_ref)` (793-890). Callers are listed in the derived-state section above.
  - `is_valid_cell` (1030-1096), `nearest_valid_point` (1101-1123), `is_clear_of_units` (984-1027).
  - `register_world` / `unregister_world` (62-105). Called by world_context.gd:59 and 99.
  - `invalidate` (255-257) and `ensure_baked` (247-253).
  - `RoutePlanner.plan(path, budget, cost_sampler)` (route_planner.gd:38-79). Called by `ladder.gd:352`, unit_movement.gd:400-405 (`_plan_waypoints`) and fly_to_close_gap_behavior.gd:79; the indicator now calls `Unit.preview_route` (movement_indicator.gd:160). (Callers corrected by review 11-15.)
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
- STALE, "one fight at a time" (occupancy is live per query since 62f265d4, review 11-15): each world holds one occupancy snapshot. Two encounters in the same world share it, and each overwrites the other's movers at its own turn boundaries (793-890; encounter.gd:358, 468).
- STALE, "one active world": `invalidate()` touches only the active world (255-257).
- **The grid owns where a body stands** (11-15, the fix for "I get stuck on terrain a lot"; owner: `UnitMovement._walk_step` / `_keep_to_ground` / `_ground_height`). A grounded unit, walking or idle, is placed: XZ along the route at move_speed, Y from `ground_height_at` under it, made exact by a physics ray only within that one cell. It never calls move_and_slide, so the CharacterBody3D's own idea of walkability (floor angle, a capsule sliding off a lip or a face the grid routed over) is no longer a second judge. Higher over its ground than a walk follows (2 × move_speed per second), it falls under gravity; a crawler that let go pays its drop on landing there. Fliers still move by move_and_slide. Root cause found by the stuck probe (`tools/_probe/stuck_probe`, gitignored): 7 of 60 random routes in the quarry ended short, all at steep faces or lips; after both fixes 0 of 56.
- **The ground band stops at a slope's foot** (11-15, `mark_tri_ground`): the band of ground under a walkable triangle runs on past an open edge only at the slope's top, within reach, never past its foot. Past the foot it used to mark the cells on a cliff face below as ground, so they had no wall beside them and were routed down where nothing can stand. Limit: box ramps (`ramp_of`) still extend both ways.
- RoutePlanner samples the cost at the previous point and clamps to the budget (route_planner.gd:63, 67-72).

- Review 2026-11-15, design notes (why it is so): route choice is written twice, `plan_route` for the real move and AI and `preview_route` with its own per-frame cache for the indicator, because the preview must be cheap per mouse frame (78fe18ee made `plan_route` "the one route query" but left the copy; MOVE-4). Ladders (a4df3008), wall crawling (ee4efa10) and the three executors in `_step` were built beside the grid to ship fast, so the grid does not know ladders exist and crawl is a mode flag read by `is_valid_cell` (MOVE-5, 6, 7). Arc sweeps use physics because jump validity needs sub-cell accuracy (9bbbf202; MOVE-11). A thrown prop is solid where it was and absent where it lands until it lands: an accepted limit, commented at movable_prop.gd:150-168 (MOVE-15). The stuck timer is a deliberate last-resort net (comment at unit_movement.gd:689; MOVE-19). Ladder rung spacing comes from the climb clip because a4df3008 ties the top-out clip to rung count (MOVE-20). Shove uses a placeholder for ST until the stat is wired (f186df85; MOVE-22). CeilingDrop listens to the global combat signals because CombatManager is one global fight (7831a523; MOVE-24). The bake notices only what it is told: callers must call `invalidate_region` (documented limit, navigation_grid.cpp:1019; MOVE-25).
- Not yet documented here (review 2026-11-15): ladders (`world/ladder.gd`), crawling, ArcFlight, movable props, walk-in buildings, ceiling drop, the relative flight floor/ceiling (65b80d1a), the multi-world registry, the region graph, sealed interiors (2176584c; see navigation_authoring.md) and chunks and bricks (7d4cdfc4). The mechanic-by-mechanic fork table is in the review report (move.md, answer A).

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
| 3 | Occupancy is stale between refresh points, for example after knockback or a mid-turn move by another unit, until the next turn boundary. | callers listed in "Derived / cached state" | FIXED (62f265d4), confirmed by review 11-15 |
| 4 | `invalidate()` resets only the active world's bake latch. Parked worlds keep a stale bake. | navigation_grid.cpp:255-257 | HALF FIXED: props re-bake only their own chunks in their own world (a92b2050, `invalidate_region`), confirmed by review 11-15; the general `invalidate()` still acts on the active world (navigation_grid.cpp:788-790), see MOVE-12 |
| 5 | Slopes and ramps are impassable, because risers fail the support and clearance checks. A red suite for this exists but is uncommitted (known issue). | navigation_grid.cpp:1056-1061, 1076-1093 | FIXED (69f46003, ramps up to 45.5 degrees walk), confirmed by review 11-15 |
| 6 | The route_planner.gd header still refers to `navigation_grid.gd` and navmesh. Both were replaced by the C++ grid. | route_planner.gd:3-4, 14-17 | NEW; review 11-15: still open |
| 7 | `encounter.resume()` never refreshes occupancy, so the first turn after a load uses a snapshot from before the load (see `combat.md` #3). | encounter.gd:172-188 | CONFIRMED |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| MOVE-1 | A carried unit keeps its old move and resumes it afterwards (a shoved walker walks back along the old path; a shoved climber is lerped back onto the ladder; a flier takes off and the ground path resumes at altitude). | unit_movement.gd:615-617, 598-600; arc_flight.gd:77-88; grant_flight_effect.gd:74-81 | "Carried" was added as a pause flag on the walker, not as a movement state with an exit. | One movement state (IDLE / ROUTE / CLIMB / CRAWL / CARRIED) in UnitMovement; entering CARRIED goes through one function that ends the current route (releases the ladder, zeroes `_moving`) before taking the tween. | R3 | M | BUG |
| MOVE-2 | `carry_tween` overwrites the previous carrier without ending it, so two tweens write the position and the first one's end step (fall damage, end_busy) runs mid-flight. | unit_movement.gd:598-600 | The carrier is a variable, not a state with an exit. | Taking a carrier while one is live refuses, or completes the old one's end step first; lives in the one-entry function from MOVE-1. | R5, R3 | S | BUG |
| MOVE-3 | `force_stop` resets only half the movement state (`_planned_cost`, `_route_crawls`, `_hold_height`, `_carrier` survive); a force-stopped crawler mis-forks the next floor route. | unit_movement.gd:583-592 vs 873-912, 566-574 | State was added field by field and each end-of-move function was patched only for the mechanic being added. | One `_clear_route_state()` called by all three end-of-move functions. | R3 | S | BUG |
| MOVE-4 | Route choice is written twice: `plan_route` (real move, AI) and `preview_route` (indicator, "Can't move there") fork crawl, ladder and direct in a different order. | unit_movement.gd:305-314 vs 426-457; ai_scorer.gd:140-149 | The preview needed to be cheap per mouse frame, so it got a cache and a copy of the decision. | `preview_route` = cached `plan_route(dest, INF, ignore)`; key = (cell, occupancy_version, ignore, crawl state, flying). | R4 | M | INTENTIONAL; document why: the preview must be cheap per mouse frame, split left behind by 78fe18ee ("plan_route is the one route query") |
| MOVE-5 | Ladders are stitched on beside the grid, one per journey; the grid does not know they exist and chains are not searched. | world/ladder.gd:4-31, 232-256, 297-338, 345-354; unit_movement.gd:308-313, 482-517, 847-865 | Ladders were built as a world prop with a script rather than an edge in the nav graph. | An off-grid link in NavigationGrid (two cells, a cost, an owner id, a busy predicate); `find_path` returns waypoints tagged with link ids and UnitMovement plays the link's traversal. | R7 | L | INTENTIONAL; document why: ladders (a4df3008) and wall crawl (ee4efa10) built beside the grid to ship fast; limit stated in the file header |
| MOVE-6 | Crawling is a second pathfinder behind a hidden mode flag (`crawl_query`) read by `is_valid_cell`; any early return before the manual reset leaves the singleton in crawl mode and the next walker validates wall cells. | navigation_grid.cpp:3583-3631, 3156-3165, 4259-4261, 4363, 3634-3646; navigation_grid.h:805-831; unit_movement.gd:306-307, 318-323, 806-819 | The cell rule is a function of (cell, mover) but the mover is passed as scattered arguments plus a global flag, so a third mover kind had nowhere to go. | A small `Mover` struct (kind, radius, height, ignore) passed through `is_valid_cell`, `a_star`, the region check and `nearest_valid_point`; a scope guard for the flag is the 10-minute interim fix. | R7 | L (S for the guard) | INTENTIONAL; document why: ladders (a4df3008) and wall crawl (ee4efa10) built beside the grid to ship fast; the unguarded flag is a latent defect |
| MOVE-7 | Three executors inside `_step` (walk by physics, climb and crawl by direct placement), each with its own arrival tolerance, stuck handling and gravity. | unit_movement.gd:680-730, 101, 660-666, 632-636 | Each traversal was added as a branch in the walker's frame function. | Per-segment executors chosen by the route's segment tag, each a small object with `step(delta) -> done`; also gives MOVE-1 its state machine. | R7 | L | INTENTIONAL; document why: ladders (a4df3008) and wall crawl (ee4efa10) built beside the grid to ship fast |
| MOVE-9 | Four ways to find where something lands (knockback grid snap, ground-point targeting grid plus second scan, `land()` raw physics ray with no occupancy check, ceiling drop own ray and ring search). | unit_movement.gd:974-982; ceiling_drop.gd:65-96; knockback_effect.gd:87-95; ground_point_targeting.gd:81-106 | Each carried move copied the nearest working example instead of asking the grid. | `NavigationGrid.landing_point(world, from, radius, height, ignore)` (ground under the point, then nearest valid cell) used by all four. | R4 | M | BUG (the `land()` ray lands a flier inside a unit below; the other finders are inconsistent) |
| MOVE-11 | Arc validity is physics sweeps, path validity is cells; three "is this air clear" checks (ArcFlight, PropDrag, ladder) disagree with the grid about sealed interiors. | arc_flight.gd:116-145; prop_drag.gd:140-152; ladder.gd:463-489 | The grid exposes "can stand / hover" only; nobody added "is this volume empty". | `NavigationGrid.volume_clear(world, a, b, radius, height)` over the existing distance field, used by all three. | R4 | M | INTENTIONAL; document why: arc sweeps chosen with the jump rework (9bbbf202); the ladder check is a quick fix |
| MOVE-12 | The grid's active world is hidden state: `invalidate()` and calls without a world ref act on whichever world was queried last (a move in encounter world B can un-bake area A instead of B). | navigation_grid.h:668-693; navigation_grid.cpp:674-776, 788-790, 837; world_manager.gd:363, 523; ai_scorer.gd:143 | Multi-world was retrofitted by swapping one world's state through the old single-world members. | Every public call takes the world (or a node in it); no fallback; `invalidate()` without a world becomes `invalidate_all()` or goes. The internal swap can stay. | R1 | M | BUG (the swap is intentional; a92b2050 fixed props only) |
| MOVE-13 | Global groups filtered per world in some places only: the grid and ladders filter, ArcFlight, CeilingDrop and WalkInBuilding do not. | navigation_grid.cpp:663-672; ladder.gd:265-284; arc_flight.gd:127-129; ceiling_drop.gd:76-96; walk_in_building.gd:15-24 | Groups are scene-tree global; each reader had to remember to filter. | One `UnitQuery.in_world_of(node)`; no direct `get_nodes_in_group("units")` in movement code. | R1 | S | BUG |
| MOVE-14 | Ladder route cache is one static entry holding node refs; after an area is freed and reloaded the key can match and return a route to a freed ladder. | world/ladder.gd:204-205, 244-250 | A per-frame memo was made static so the preview and the real plan would share it. | Key on world id and ladder count, store instance ids and re-validate with `is_instance_valid`, or drop it once ladders are grid links. | R5 | S | BUG |
| MOVE-15 | A thrown prop is solid where it was and absent where it lands until it lands; a unit ordered to the target cell can end up inside the crate (recovered by `find_escape_cell`). | movable_prop.gd:150-168, 120-123 | The bake is the only reservation mechanism and it runs after the fact. | Reserve the landing box at throw time and release the old box at the same moment. | R3 | S | INTENTIONAL; document why: accepted limit, described in the comment at movable_prop.gd:150-168 (74a3ea40) |
| MOVE-16 | Prop arcs keep their own six constants for height and time instead of `ArcFlight.duration`. | movable_prop.gd:39-48, 191-199; arc_flight.gd:67-70 | Props landed (74a3ea40) before jump and shove timing was unified (279bbb98) and were not in that pass. | `ArcFlight.duration(distance)` and one height rule with a per-caller scale. | R4 | S | DECISION NEEDED: should props share the jump and shove arc timing, or is the separate feel deliberate? |
| MOVE-17 | A second live overlap scan (`PathAvoidance.gather_obstacles`) the grid no longer needs; it can disagree with `nearest_valid_point` (different margin). | path_avoidance.gd:19-49; ground_point_targeting.gd:85-106 | The reason (stale occupancy) was removed by 62f265d4 and the workaround stayed. | Delete `PathAvoidance`; GroundPointTargeting trusts the grid. | R4 | S | LEFTOVER |
| MOVE-18 | Temporary stall logging is still in. | unit_movement.gd:141-143, 733-768 (`_log_stuck`) | Added to chase a stall (076a05c5) and marked TEMPORARY. | Remove, or keep behind the nav debug overlay. | - | S | LEFTOVER |
| MOVE-19 | The stuck timer is a net for causes that should not exist (plan and physics disagree: capsule vs cell margin, a prop landing, another unit arriving). | unit_movement.gd:696-730 | Plan-then-execute with no re-plan on occupancy change. | Re-plan when `occupancy_version` changes and the next waypoint's cell is no longer valid; keep the timer as an assert-style log. | R4 | M | INTENTIONAL; document why: deliberate last-resort safety net (comment at unit_movement.gd:689). One cause removed 11-15: a dead unit's leftovers used to be a solid Remains prop the grid didn't know; a Corpse now has no solid collider (unit.md, Corpse). 11-15: a ground walk no longer uses move_and_slide (see "The grid owns where a body stands"), so plan and physics can't disagree for it and it has no stuck timer; the timer is a flier's only |
| MOVE-20 | Ladder constants stand in for missing queries (ARRIVAL, a 9999 budget, `rung_spacing()` loading an animation file on every call). | ladder.gd:202, 352, 120-123; unit_movement.gd:101 | No budget-free cost query on RoutePlanner; rung spacing owned by the clip rather than the ladder. | `RoutePlanner.cost(waypoints, sampler)`; rung spacing as an export on Ladder, cached once. | - | S | INTENTIONAL; document why: climb geometry is tied to the top-out clip (a4df3008) |
| MOVE-21 | CrawlPose casts up to 8 rays, adding each hit unit to the exclude list. | crawl_pose.gd:78-88 | Units sit on the same layer as the surfaces being probed. | A surface-only collision mask. | - | S | DECISION NEEDED: add a surface-only collision layer, or keep the exclude-list workaround? |
| MOVE-22 | Shove distance uses a placeholder for ST. | knockback_effect.gd:5-8, 33-37 | The real stat source was not wired (f186df85). | Read ST the way `ArcFlight.strength_distance` does (arc_flight.gd:25-30). | - | S | INTENTIONAL; document why: marked placeholder until ST is wired (f186df85) |
| MOVE-23 | The movement indicator reads input (`select_additive`) and keeps a private corner fillet, against the rule that indicators only draw. | movement_indicator.gd:148; path_corner_rounding.gd:5-9 | The indicator predates the router-owns-aim rule and was half converted. | The router passes the additive flag in the aim; the indicator calls PathCornerRounding. | R4 | S | LEFTOVER |
| MOVE-24 | CeilingDrop listens to the global combat signals; every ceiling-hung unit in every world hears every fight start. | ceiling_drop.gd:29-43 | CombatManager is a single global fight. | The unit's own "joined combat" signal. | R1 | S | INTENTIONAL; document why: one global fight (7831a523); depends on R1 |
| MOVE-25 | The bake notices only what it is told: a resized shape or a freed StaticBody3D keeps the old cells until the next full bake; the gate, props and surface barriers each call `invalidate_region` by hand. | navigation_grid.cpp:1019-1020, 1183-1204; goblin_quarry.gd:344; surface_manager.gd:1304 | No hook from geometry change to the grid. | A small `NavObstacle` node that calls `invalidate_region` on enter, exit and transform change, so callers cannot forget. | R5 | M | INTENTIONAL; document why: documented limit (comment at navigation_grid.cpp:1019) |

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
