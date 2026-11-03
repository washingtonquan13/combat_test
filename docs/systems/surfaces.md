# Surfaces (areas)

**Files:** `systems/surface_system/`:
- `surface_manager.gd` (285)
- `surface.gd` (112, the Resource definition: the area TYPE)
- `active_surface.gd` (32, a RefCounted instance)
- `grease.gdshader` (54), `grease.tscn` (6)
- `fog_puff.gdshader`, `fog_cloud.tscn` (a GPUParticles3D puff cloud), `fog_cloud.gd` (its dissipate)

**Autoloads owned:** `SurfaceManager` (project.godot:24)

## Purpose
BG3's "areas": a flat surface (Grease) or a 3D cloud (Fog Cloud). Each one gets a detection Area3D and visuals. While it lasts it applies its status effect to units that enter it or start a turn inside it, and with `status_only_inside` takes the status off again when they leave. A cloud with `blocks_sight` blocks line of sight through it. A surface also supplies the movement-cost multiplier for route planning. It expires by round count, in or out of combat. It does NOT define what the status does (status system), compute routes (`navigation.md`), or decide when it is cast (`spawn_surface_effect.gd`).

## Shapes
- `Surface.Shape.DISC`: a `CylinderShape3D` that is `detection_height` tall and stands on the point. "Inside" is the 3D distance from the center minus `unit.radius`.
- `Surface.Shape.SPHERE`: a `SphereShape3D` centered on the point, which may be midair (cast with AerialAreaTargeting; Ctrl-drag sets the height). "Inside" uses the nearest point of the unit's feet→eye segment, so a cloud at head height covers the unit (`_contains`, surface_manager.gd:169). The visual scales uniformly.

## Fog Cloud (data/abilities/fog_cloud.tres)
- The rule is BG3's, with GURPS numbers.
  - A sphere 4 m in radius, up to 18 m away, lasting 10 rounds. It needs no to-hit roll.
  - It blocks sight: no ranged targeting into, out of or across it. `blocks_sight` (surface_manager.gd:181) runs a segment-vs-sphere test, called from `LineOfSight.has_clear_shot_to_point` (line_of_sight.gd:63) once the wall ray is clear. Detection, AoE aiming and the indicators all go through LineOfSight, so fog blocks them too.
  - Units inside are **Blinded** (data/statuses/blinded.tres: −10 to their attacks, no resistance, not curable), and only while inside.
- Visual: soft billboard particles, BG3-style. 36 slowly turning puffs (`fog_puff.gdshader`: procedural noise, top-lit, faded where they meet geometry via the depth texture) drift inside a unit sphere in local coordinates, so the uniform radius scale sizes the whole cloud. No ground ring; it reads the same on the ground or in midair. On expiry `_expire` calls the visual's `dissipate()` if it has one (else frees it): over 3 s the cloud spreads �1.35, lifts, and the shader's per-instance `dissipate` erodes each puff from its thin edges inward, then the node frees itself. Sight clears at expiry, not at the end of the fade.
- Given to the tiefling wizard.

## State it owns (source of truth)
| State | Where | Persisted? |
|---|---|---|
| Live surfaces for each world | `WorldContext.surfaces`, via `_list_for(context)` | no |
| Surfaces when no world is loaded | `_detached_surfaces` | no |
| Per instance: surface def, position, radius, `rounds_remaining`, visual_node, area, **context** | active_surface.gd | no |
| Definition: shape, duration, status, `status_only_inside`, `blocks_sight`, cost, visuals and FX | surface.gd | authored .tres |

## World scoping
Every surface belongs to a world.
- `spawn` files it into the caster's `WorldContext` and parents it under that world's root. With no world loaded, it uses the scene root and then the caster's own parent.
- Turn start, the cost sampler and sight blocking all read the world of the unit concerned, never the focused world.
- The `active_surfaces` getter (the focused world) is kept only for the world-scoping suite.

## Public surface
- **Calls in**
  - `spawn(surface, position, radius, caster)` is called by spawn_surface_effect.gd.
  - `cost_sampler(mover)` returns `movement_cost_multiplier_at` bound to the mover's world. It is used as the RoutePlanner cost_sampler by:
    - unit_movement.gd:202
    - movement_indicator.gd:290, 353
    - fly_to_close_gap_behavior.gd:68
    - ladder.gd:171
  - `blocks_sight(viewer, from, to)` is called by LineOfSight.
- **Signals in**
  - `CombatManager.round_started_in(encounter, n)` (combat_manager.gd:58, relayed from every encounter) triggers `_on_round_started_in`. This ages the encounter's world, but only when the encounter is the first fight running there: one clock per world.
  - A Timer fires every `ROUND_SECONDS` (6 s, BG3's turn) and triggers `_on_quiet_round`, which ages each world that has no fight running.
  - `CombatManager.turn_started` triggers `_on_turn_started`, which re-applies the status to a unit inside a surface in its own world.
  - Each Area3D's `body_entered` applies the status, and `body_exited` triggers `_release`.

## Lifecycle
- **Spawn:** the surface goes into the caster's world list with `rounds_remaining = duration_rounds`. Visuals and the Area3D are parented under that world.
- **Rounds:**
  - In combat, that world's oldest running fight ages it.
  - Out of combat, it ages once every 6 s. Expiry is at 0.
  - Combat ending does **not** clear surfaces; they finish their time.
- **Leaving / expiry:** an inside-only status comes off, unless another surface in the same world with the same status still contains the unit (`_release`).
- **World unload:** `WorldContext.dispose` clears its own `surfaces` array.
- **Save / load:** surfaces are not saved (issue 6).

## Known issues
| # | Issue | Status |
|---|---|---|
| 1-5, 7 | Focused-only aging, cross-world turn checks, expiry on any `combat_ended`, spawning into the focused world, focused-only cost sampling, no aging out of combat | FIXED (area/fog pass) |
| 6 | Surfaces are not saved. A mid-combat save drops them. | OPEN |
| 8 | A Blinded unit's attacks get −10, but attacks *against* units in fog are only blocked when ranged (by sight). A melee attack into fog gets no GURPS blind-defense rule. | OPEN, by design for now |

## Tests
- tests/combat/test_fog_cloud.gd (6 checks):
  - sight is blocked through a cloud but not by one overhead;
  - Blinded is applied inside and comes off on leaving;
  - out of combat, the cloud expires after its rounds.
  - Sabotage-checked: removing the LoS call or the release turns it red.
- tests/world/test_world_scoping.gd:190-222 checks surface world scoping.

**Gaps:** no test covers two fights in one world sharing a clock, or saving.
