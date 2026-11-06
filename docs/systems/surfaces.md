# Surfaces (areas)

**Files:** `systems/surface_system/`:
- `surface_manager.gd` (285)
- `surface.gd` (112, the Resource definition: the area TYPE)
- `active_surface.gd` (32, a RefCounted instance: a cloud)
- `surface_grid.gd`, `surface_cell.gd`, `surface_patch.gd` (the ground grid: 0.5 m cells, grouped into patches)
- `decal_surface.gd` (DecalSurface, shared by every ground film), `film_common.gdshaderinc` + `film_passes.gdshaderinc` (the film shaders' shared uniforms, noise and fragment)
- `grease.tscn`, `water.tscn`, `blood.tscn`, `acid.tscn` (`liquid_film.gdshader`), `ice.tscn` (`ice_film.gdshader`), `web.tscn` (`web_film.gdshader`), `fire.tscn` (`scorch_film.gdshader` + `fire_surface.gd` + `flame.gdshader` + `spark.gdshader` + `heat_haze.gdshader`, smoke reuses `fog_puff.gdshader`). Only Grease has an ability; the rest are visuals with no Surface resource yet.
- `fog_puff.gdshader`, `fog_cloud.tscn` (a GPUParticles3D puff cloud), `fog_cloud.gd` (colors and dissipate for every particle layer), `darkness.tscn` (the same cloud, inked, plus a tendril layer), `darkness_tendril.gdshader`

**Autoloads owned:** `SurfaceManager` (project.godot:24)

## Purpose
BG3's "areas": a ground surface (Grease) or a 3D cloud (Fog Cloud). A cloud floods the world's 3D cloud grid; a ground surface spills into its 2D surface grid. While it lasts it applies its status effect to units that enter it or start a turn inside it, and with `status_only_inside` takes the status off again when they leave. A cloud with `blocks_sight` blocks line of sight through it. A surface also supplies the movement-cost multiplier for route planning. It expires by round count, in or out of combat. It does NOT define what the status does (status system), compute routes (`navigation.md`), or decide when it is cast (`spawn_surface_effect.gd`).

## Shapes
- `Surface.Shape.DISC`: spilled over the ground's `SurfaceGrid` cells (see Surface grid below). "Inside" is any cell under the unit's footprint.
- `Surface.Shape.SPHERE`: CloudGrid cubes flooded out from the point, which may be midair (cast with AerialAreaTargeting; Ctrl-drag sets the height). See Cloud grid below. A unit is inside when any cube touches its feet-to-eye capsule, so a cloud at head height covers the unit (`_clouds_holding`).
- `Surface.Shape.WALL`: CloudGrid cubes along a ground line, `wall_height` tall (`spawn_wall(surface, from, to, caster)`). A cube is in when it lies within `WALL_HALF_THICKNESS` of the line across the ground and overlaps the height above the line's ground (`_within_wall`); `_wall_point` lifts each cube's ray target 0.1 m over that ground so the bottom row floods along a floor that passes through it.

## Fog Cloud (data/abilities/fog_cloud.tres)
- The rule is BG3's, with GURPS numbers.
  - A sphere 5 m in radius, up to 18 m away, lasting 10 rounds. It needs no to-hit roll.
  - It blocks sight: no ranged targeting into, out of or across it. `blocks_sight` (surface_manager.gd:181) walks the cubes along the segment (`CloudGrid.cells_along`), called from `LineOfSight.has_clear_shot_to_point` (line_of_sight.gd:63) once the wall ray is clear. Detection, AoE aiming and the indicators all go through LineOfSight, so fog blocks them too.
  - Units inside are **Blinded** (data/statuses/blinded.tres: −10 to their attacks, no resistance, not curable), and only while inside.
- Visual: soft billboard particles, BG3-style. 36 slowly turning puffs (`fog_puff.gdshader`: procedural noise, top-lit, faded where they meet geometry via the depth texture) are born at points scattered through the cast's cubes (`show_cubes`), so the cloud takes the grid's shape; the puff count scales with the cube count. No ground ring; it reads the same on the ground or in midair. When its last cube goes, the visual's `dissipate()` runs if it has one (else frees it): over 3.5 s, driven by one progress value so the motion and the thinning are a single movement, the cloud spreads �1.35, lifts, and the shader's per-instance `dissipate` erodes each puff from its thin edges inward (each puff starting a little later than the last) while the whole cloud fades, then the node frees itself. Sight clears at expiry, not at the end of the fade.
- Given to the tiefling wizard.

## Grease (data/abilities/grease.tres)
- Visual: `grease.tscn` is a DecalSurface (see Ground films below).
- The outline follows its cells, wandered by fbm noise sampled in world meters, so neighbouring casts line up and detail doesn't stretch; droplets sit just past the edge.
- New cells spread out from the cast point over 0.6 s; cells that run out recede over 1.5 s, thin film first, and the decal frees itself when it has none left. Roughness 0.12 via a flat ORM. `normal_fade` 0.6 fades it off steep faces (a decal projects straight down, so on a wall the texture smears into vertical streaks); floors and gentle slopes keep it.
- `cull_mask` leaves out `Unit.RENDER_LAYER` (2); `Unit.wear_render_layer()` puts unit bodies and held weapons on it, so units standing in grease aren't painted.
- Look demo: `tools/grease_look_demo.tscn` (recorded, not a test).

## Surface grid (surface_grid.gd, surface_cell.gd, surface_patch.gd)
- BG3-style. Each world has one `SurfaceGrid` (`WorldContext`, via `_grid_for`) of 0.5 m cells keyed by (x, z), several per key when floors stack. A cell holds its Surface, floor height and its own `rounds` left.
- `_spill` floods out from the cast point to the radius, stepping cell to cell with physics rays: a wall in the way stops it, and it climbs or drops up to `MAX_STEP` (0.45 m) onto floors facing up at least `FLOOR_NORMAL`. Rays, not the nav grid: exact heights, no C++ change, and it works on the overworld, which has no nav grid.
- Cells of the same Surface that touch are one `SurfacePatch` with one visual: a new cast merges every patch it touches into the largest. Absorbed visuals free themselves once the merged film has drawn (its `drawn` signal), so there's no gap.
- Another Surface cast over cells takes them (overwrite; reactions such as fire on grease are not built). The old patch's visual drops them via `set_cells` once the new film has spread over them.
- Ageing is per cell (`_age_grid`); `expire_cells` recedes the cells that ran out, `expire_all_ground(context)` runs a whole world out. `surface_at(point, context)` answers what lies on the floor there.
- Clouds (SPHERE) have their own 3D grid; see Cloud grid.
- Merge demo: `tools/surface_merge_demo.tscn` (recorded, not a test): overlapping casts, a step, water over grease, partial drying.

## Wall of Fire (data/abilities/wall_of_fire.tres)
- Two clicks: `LineTargeting.resolve_click` holds the first click on `AbilityManager.line_start` (if it is in range and sight) and returns null; the second returns a `LineTarget` whose end `end_for` pulls in to `max_length`. An illegal end keeps the start. `LineIndicator` draws the aim line, then the wall's outline with the same `end_for` and the wall surface's height.
- Air walls: holding Ctrl and dragging lifts each click into the air, like an aerial blast (`IndicatorBase._handle_aim_height_input`, shared with `AerialAreaIndicator`; `LineTargeting.resolve_target_point` applies `AbilityManager.aim_height_override`). The wall stands from that height, and `_leave_behind` lays no ground fire under cubes whose bottom doesn't meet the floor.
- It is a cloud, not ground: opaque (`blocks_sight`), and it sets walkers and fliers alike Searing (`data/statuses/searing.tres`, 1d6 a turn against Burning's 1d6-3).
- `lays_ground_under`: `spawn_wall` lays its `leaves_behind` under the ground-row cubes the moment it rises, for the wall's rounds plus its own. A walker stands in both and still burns once: `_statuses` rolls each status once per check (on entering, at turn start), and of a `StatusEffect.group` only the highest `rank`. `StatusManager.apply` holds the same rule: Searing replaces Burning, Burning never lands over Searing.
- `leaves_behind`: as its cubes run out, `_leave_behind` also lays (or tops up) that surface (2-round Fire) on ground that passes through a ground-row cube. `_age` ages the ground before the clouds, so the leftover keeps its whole duration.
- The AI does not cast LineTargeting abilities, and does not avoid walking through a wall.

## Cloud grid (cloud_grid.gd, cloud_cell.gd, cloud_patch.gd)
- The 3D counterpart. Each world has one `CloudGrid` (`WorldContext.cloud_grid`, via `_clouds_for`) of 1 m cubes keyed by Vector3i, one cloud per cube. A cube holds its Surface and its own `rounds` left.
- `_fill` floods out from the cast point's cube: a neighbour is taken if its centre is within the radius and a physics ray to it is clear, so walls and ceilings stop the cloud and it climbs stairwells. The first ray starts 0.1 m above the point so a ground cast isn't blocked by its own floor. An optional `point_of(key)` picks each cube's ray point instead of its centre (walls use it).
- Each cast is one `CloudPatch` with one visual. The same cloud cast again tops up the cubes it covers (they stay with their old visual); another cloud takes them, and the old visual recedes them.
- Holding is polled: `_process` compares each unit's surfaces (`_holding` = ground under its feet + cubes touching its capsule) with last frame's, inflicting on entry and releasing on exit. No Area3D.
- Ageing is per cube (`_age_clouds`); `expire_cloud_cells` recedes those that ran out, `expire_all_clouds(context)` runs a world out. `cloud_at(point, context)` answers what fills a point.
- Visual: `fog_cloud.gd` emits from points in the cubes; a per-cloud 3D mask texture (`cloud_mask.gdshaderinc`, one texel per cube) thins a receding cube's puffs in place over `recede_seconds` without restarting the emitter.

## Ground films (decal_surface.gd)
- A Decal, so the film drapes over steps and slopes. A Decal can't run a shader, so the scene's `film` ShaderMaterial (canvas_item, edited in the inspector) is duplicated per pass and rendered into SubViewports sized at `pixels_per_meter` (64, up to `max_resolution` 1024): albedo, normal map, and emission when `glows`. Viewports redraw only while cells arrive or recede.
- The patch's cells reach the shader as `cell_mask`, one RGBA8 texel per cell over the patch's box plus 2 cells of padding: R = coverage (arrival times not-receded), G = meters in from the patch edge / 4, A = recede progress. The box is fitted to the cells each redraw. The mask is flat, so a cell paints every floor inside the box above and below it (1.2 m reach). Each redraw is read back on `frame_post_draw` and set as a NEW ImageTexture: the decal atlas shows neither a ViewportTexture nor an `ImageTexture.update()`.
- A film shader includes `film_common.gdshaderinc`, defines `film_height(p)`, `film_albedo(p, h)` and `film_emission(p, h)`, then includes `film_passes.gdshaderinc`; every pass derives from the one height, so bumps and glow sit exactly on the film.
- `liquid_film` covers Grease, Water, Blood and Acid through uniforms (colors, alpha_max, droplets, lumpiness, bubbles, glow_color, wet_rim/wet_color for the dark wet band under the edge, ripple_drift). Every film edge gets small bites from `edge_detail` in `film_common`. Ice has Voronoi cracks and a frosted rim; Web draws spokes and spiral rings in meters, one large web plus three small ones; Fire's scorch is BG3-style char: dark flaky crust (fine fbm in `film_height`, so the normal pass gives it relief) with pale ash flecks, its edge crumbling into pieces within `crumble_m` of the outline; embers are a narrow cut of it - thin ridged-noise cracks and fine flecks - each pulsing in place on `loop_phase`, red-orange with the hot color held below white; a few linger as it recedes.
- A film can loop: `loop_frames` > 0 draws that many pictures of the emission pass (and the normal pass too when `ripples_move`) once the film has spread (the shader loops on `loop_phase`, from `film_common`), then `_process` cycles them at `loop_fps`. No redraws while it plays; any change of cells drops back to the one live picture. Fire uses 12 at 10 fps; water, blood and acid loop their ripples.
- Fire adds, emitted from points scattered over its cells (`_cells_shown`, rebuilt only when the cells change): Flames (camera-facing quads, `flame.gdshader`: frames of `assets/vfx/fire_flipbook.png`, an 8x8 grayscale flipbook baked in Blender by `tools/vfx/bake_fire_flipbook.py`, each particle at its own frame offset, half mirrored, blended between frames, colored by a ramp, additive, depth-softened; flames stand only `flame_inset_m` in from the outline, on the solid char past the crumbling edge (`DecalSurface._depths`); the ground fire keeps them few and small, 1.6 per m², cut to a teardrop by `taper` so a small flame never reads as a box), Sparks (`spark.gdshader`, twinkling additive dots with turbulence), Smoke (dark `fog_puff` puffs rising from 1.2 m), Haze (an upright camera-facing quad bending the screen texture, `render_priority` -1 so it draws before the flames and never wipes them) and a flickering OmniLight. `dissipate()` stops the emitters and fades the light and haze, then the scorch recedes.
- Look demo of all seven: `tools/surfaces_look_demo.tscn` (recorded, not a test).

## Darkness (data/abilities/darkness.tres)
- Fog Cloud's rules (sight blocked, Blinded inside, 10 rounds), radius 5 m, plus `dark_vision_sees_through`: a unit with **Dark Vision** (`Unit.dark_vision`, cascaded from UnitDefinition; GURPS B47) is neither walled off nor Blinded by it (`_sees_through`, surface_manager.gd). Fog still stops them.
- Dark Vision: Night, Haunt, Foul, Fallen. Darkness is given to the tiefling wizard (who lacks Dark Vision).
- Visual: `darkness.tscn` inherits fog_cloud.tscn: a near-black core (opacity 0.97, 48 puffs) plus a `Tendrils` layer of 16 billboards drifting outward through the cubes. `darkness_tendril.gdshader` draws curling strands (ridged noise in polar coordinates, tapered) over a soft dark body, with a faint violet edge glow. fog_cloud.gd sets colors, opacity and `dissipate` on every GPUParticles3D child, so the tendrils erode with the core.

## State it owns (source of truth)
| State | Where | Persisted? |
|---|---|---|
| Cloud cubes and patches for each world | `CloudGrid`, via `_clouds_for(context)` | no |
| Ground cells and patches for each world | `SurfaceGrid`, via `_grid_for(context)` | no |
| Clouds when no world is loaded | `_detached_clouds` | no |
| Per cube: surface, key, `rounds`, patch; per cast: cells, visual, **context** | cloud_cell.gd, cloud_patch.gd | no |
| Definition: shape, duration, status, `status_only_inside`, `blocks_sight`, cost, visuals and FX | surface.gd | authored .tres |

## World scoping
Every surface belongs to a world.
- `spawn` files it into the caster's `WorldContext` and parents it under that world's root. With no world loaded, it uses the scene root and then the caster's own parent.
- Turn start, the cost sampler and sight blocking all read the world of the unit concerned, never the focused world.
- The `cloud_grid` getter (the focused world) is kept only for the world-scoping suite.

## Public surface
- **Calls in**
  - `spawn(surface, position, radius, caster)` and `spawn_wall(surface, from, to, caster)` (for a LineTarget) are called by spawn_surface_effect.gd.
  - `cost_sampler(mover)` returns `movement_cost_multiplier_at` bound to the mover's world. It is used as the RoutePlanner cost_sampler by:
    - unit_movement.gd:202
    - movement_indicator.gd:290, 353
    - fly_to_close_gap_behavior.gd:68
    - ladder.gd:171
  - `blocks_sight(viewer, from, to)` is called by LineOfSight.
- **Signals in**
  - `CombatManager.round_started_in(encounter, n)` (combat_manager.gd:58, relayed from every encounter) triggers `_on_round_started_in`. This ages the encounter's world, but only when the encounter is the first fight running there: one clock per world.
  - A Timer fires every `ROUND_SECONDS` (6 s, BG3's turn) and triggers `_on_quiet_round`, which ages each world that has no fight running.
  - `CombatManager.turn_started` triggers `_on_turn_started`, which re-applies the statuses of the surfaces a unit is inside, in its own world, each once (`_statuses`).
  - Every frame `_process` applies the status to units that came into a surface and calls `_release` for those that left.

## Lifecycle
- **Spawn:** the cells go into the caster's world grid with `rounds = duration_rounds`. Visuals are parented under that world.
- **Rounds:**
  - In combat, that world's oldest running fight ages it.
  - Out of combat, it ages once every 6 s. Expiry is at 0.
  - Combat ending does **not** clear surfaces; they finish their time.
- **Leaving / expiry:** an inside-only status comes off, unless another surface in the same world with the same status still contains the unit (`_release`).
- **World unload:** `WorldContext.dispose` clears its `surface_grid` and `cloud_grid`.
- **Save / load:** surfaces are not saved (issue 6).

## Known issues
| # | Issue | Status |
|---|---|---|
| 1-5, 7 | Focused-only aging, cross-world turn checks, expiry on any `combat_ended`, spawning into the focused world, focused-only cost sampling, no aging out of combat | FIXED (area/fog pass) |
| 6 | Surfaces are not saved. A mid-combat save drops them. | OPEN |
| 8 | A Blinded unit's attacks get −10, but attacks *against* units in fog are only blocked when ranged (by sight). A melee attack into fog gets no GURPS blind-defense rule. | OPEN, by design for now |

## Tests
- tests/combat/test_fog_cloud.gd (8 checks):
  - sight is blocked through a cloud but not by one overhead;
  - Blinded is applied inside and comes off on leaving;
  - out of combat, the cloud expires after its rounds;
  - Darkness: Dark Vision sees through and is not Blinded; without it, blocked (sabotage-checked).
  - Sabotage-checked: removing the LoS call or the release turns it red.
- tests/combat/test_surface_grid.gd (4 checks): overlapping grease pools into one patch; water cast over it takes those cells; expired cells leave the grid; expire_all_ground empties it. Sabotage-checked: no merging turns it red.
- tests/combat/test_wall_of_fire.gd (7 checks): two-click line pulled to max_length; the wall blocks sight and lays ground fire under it at once; a walker in both is Searing and not Burning; running out leaves ground fire with full rounds; a wall cast 3 m up lays none. Sabotage-checked: aging clouds before ground turns it red, and so does taking Burning out of its group.
- tests/world/test_world_scoping.gd:190-222 checks surface world scoping.

**Gaps:** no test covers two fights in one world sharing a clock, or saving.
- Lighting: the combat areas share `world/combat_environment.tres` (ACES tonemap, glow above HDR 1.0), so fire emission blooms.
