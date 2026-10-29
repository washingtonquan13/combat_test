# Surfaces

**Files:** `systems/surface_system/`:
- `surface_manager.gd` (199)
- `surface.gd` (91, the Resource definition)
- `active_surface.gd` (29, a RefCounted instance)
- `grease.gdshader` (54)
- `grease.tscn` (6)

**Autoloads owned:** `SurfaceManager` (project.godot:24)

## Purpose
Spawns ground-area effects, for example grease. Each one gets a detection Area3D and visuals. While a surface lasts it applies the surface's status effect to units that enter it or start a turn inside it. It also supplies the movement-cost multiplier for route planning, and expires surfaces by round count or when combat ends (surface_manager.gd:57-199). It does NOT define what the status effect does (status system), compute routes (`navigation.md`, route_planner.gd:38-79), or decide when a surface is cast (`spawn_surface_effect.gd:31`).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Live surfaces for each world | `WorldContext.surfaces` world_context.gd:37, read via the `active_surfaces` getter surface_manager.gd:40-43 | no (no save_system reference) |
| Surfaces when no world is loaded | `_detached` list, surface_manager.gd:40-43 | no |
| Per instance: surface def, position, radius, `rounds_remaining`, visual_node, area | active_surface.gd (whole file, 29 lines) | no |
| Definition: `duration_rounds`, `detection_height`, `status_effect`, `movement_cost_multiplier`, visuals and FX | surface.gd:27, 34, 43, 56, 66-84 | authored .tres |

## Derived / cached state
- `active_surfaces` always resolves to the **focused** context's array (surface_manager.gd:40-43). Every read, including spawn, cost, round aging and turn checks, is therefore focused-world-scoped. The caster's world and the mover's world are ignored.
- Each surface has an Area3D (built at 108-122) that duplicates its position and radius as physics. `_on_body_entered` (134-139) and the distance check in `_on_turn_started` (168-176) are two separate tests of "inside".

## Public surface
- **Calls in**
  - `spawn(surface, position, radius)` (57-83) is called by spawn_surface_effect.gd:31.
  - `movement_cost_multiplier_at(pos)` (151-156) is used as a RoutePlanner cost_sampler by:
    - unit_movement.gd:202
    - movement_indicator.gd:290, 353
    - fly_to_close_gap_behavior.gd:68
    - ladder.gd:171
- **Signals out:** none.
- **Signals in** (connected at 48-51)
  - `CombatManager.round_started` triggers `_on_round_started` (159-165), which decrements and expires surfaces.
  - `CombatManager.turn_started` triggers `_on_turn_started` (168-176), which applies the status to a unit standing inside.
  - `CombatManager.combat_ended` triggers `_on_combat_ended` (182-184), which expires every surface.
  - Each surface Area3D's `body_entered` triggers `_on_body_entered` (134-139).

## Depends on
- `WorldManager.spawn_parent()` parents the visual and area into the focused world (surface_manager.gd:57-61; world_manager.gd:962-963).
- `WorldManager` focused context provides the list storage (surface_manager.gd:40-43).
- CombatManager relayed signals (48-51); see `combat.md`, issues 4-6.
- Unit status application through the surface's `status_effect` (surface.gd:43; surface_manager.gd:134-139, 168-176).

## Assumptions and invariants
- Surfaces age only in rounds. Outside combat they never tick down; only `combat_ended` or world disposal removes them (159-165, 182-184; world_context.gd:88-107).
- STALE, "one focused world": every surface is assumed to belong to the focused world (40-43, 57-61, 151-156). Multiple resident worlds and encounters (WorldContext, encounters_by_area) broke this assumption.
- STALE, "one fight at a time": `combat_ended` is treated as "combat is over" (182-184), but it fires for each encounter (combat_manager.gd:404).
- `_expire` frees the visual node and Area3D and removes the entry from the list (187-199). Nothing else holds ActiveSurface references.

## Lifecycle
- **Spawn:** `spawn` (57-83):
  - appends an ActiveSurface to the focused list;
  - parents the visuals and an Area3D under `spawn_parent()`;
  - sets `rounds_remaining = duration_rounds`.
- **Combat rounds:** each focused `round_started` decrements every focused surface and expires it at 0 (159-165).
- **Turn start:** a relayed unit within the radius gets the status (168-176).
- **Combat end:** any encounter ending expires all focused surfaces, including ones cast before or outside that fight (182-184).
- **World travel / unload:** `WorldContext.dispose` first finishes encounters, which fires `combat_ended` and clears the **focused** world's surfaces. It then clears its own `surfaces` array (world_context.gd:88-107).
- **New game / save / load:** not persisted. A save made mid-fight reloads with no surfaces.
- **Dialogue / cutscene:** no gating.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | `round_started` arrives only from `focused_encounter`. Surfaces in an NPC-only fight (focused_encounter null) or in an unfocused world never age. | combat_manager.gd:142-143, 378-381; surface_manager.gd:40-43, 159-165 | CONFIRMED |
| 2 | `turn_started` is relayed from every encounter. `_on_turn_started` tests a unit from **any** world against focused-world surfaces using raw coordinates, so it can give false positives across worlds. | combat_manager.gd:362-365; surface_manager.gd:168-176 | CONFIRMED |
| 3 | When any encounter in any world ends, every focused-world surface expires, including surfaces from a still-running fight and surfaces cast outside combat. | combat_manager.gd:404; surface_manager.gd:182-184 | CONFIRMED |
| 4 | `spawn` files the surface into the focused world whatever the caster's world is. A caster in an unfocused world puts the surface in the wrong world. | surface_manager.gd:57-61; world_manager.gd:962-963 | NEW |
| 5 | `movement_cost_multiplier_at` samples focused-world surfaces for every mover's route, including AI in other worlds. | surface_manager.gd:151-156; unit_movement.gd:202 | NEW |
| 6 | Surfaces are not saved. A mid-combat save (now allowed, save_manager.gd:292-303) drops them. | no surface key in save_manager.gd; active_surface.gd | NEW |
| 7 | A surface cast outside combat never expires on its own, because aging happens only on rounds. | surface_manager.gd:159-165, 182-184 | NEW |

## Tests
- tests/world/test_world_scoping.gd:190-222 checks surface world scoping.
- test_the_harness_stands_up_a_world.gd:85-87 runs identity checks only.

**Gaps:**
- No test covers round aging, `combat_ended` expiry with two fights, or cross-world `turn_started` application.
- No test checks the cost multiplier inside RoutePlanner.
- No test covers save and reload.
