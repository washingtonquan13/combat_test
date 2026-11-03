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
BG3's "areas": a ground surface (Grease) or a 3D cloud (Fog Cloud). A cloud gets a detection Area3D and a visual; a ground surface spills into the world's surface grid. While it lasts it applies its status effect to units that enter it or start a turn inside it, and with `status_only_inside` takes the status off again when they leave. A cloud with `blocks_sight` blocks line of sight through it. A surface also supplies the movement-cost multiplier for route planning. It expires by round count, in or out of combat. It does NOT define what the status does (status system), compute routes (`navigation.md`), or decide when it is cast (`spawn_surface_effect.gd`).

## Shapes
- `Surface.Shape.DISC`: spilled over the ground's `SurfaceGrid` cells (see Surface grid below). "Inside" is any cell under the unit's footprint.
- `Surface.Shape.SPHERE`: a `SphereShape3D` centered on the point, which may be midair (cast with AerialAreaTargeting; Ctrl-drag sets the height). "Inside" uses the nearest point of the unit's feet→eye segment, so a cloud at head height covers the unit (`_contains`, surface_manager.gd:169). The visual scales uniformly.

## Fog Cloud (data/abilities/fog_cloud.tres)
- The rule is BG3's, with GURPS numbers.
  - A sphere 5 m in radius, up to 18 m away, lasting 10 rounds. It needs no to-hit roll.
  - It blocks sight: no ranged targeting into, out of or across it. `blocks_sight` (surface_manager.gd:181) runs a segment-vs-sphere test, called from `LineOfSight.has_clear_shot_to_point` (line_of_sight.gd:63) once the wall ray is clear. Detection, AoE aiming and the indicators all go through LineOfSight, so fog blocks them too.
  - Units inside are **Blinded** (data/statuses/blinded.tres: −10 to their attacks, no resistance, not curable), and only while inside.
- Visual: soft billboard particles, BG3-style. 36 slowly turning puffs (`fog_puff.gdshader`: procedural noise, top-lit, faded where they meet geometry via the depth texture) drift inside a unit sphere in local coordinates, so the uniform radius scale sizes the whole cloud. No ground ring; it reads the same on the ground or in midair. On expiry `_expire` calls the visual's `dissipate()` if it has one (else frees it): over 3.5 s, driven by one progress value so the motion and the thinning are a single movement, the cloud spreads �1.35, lifts, and the shader's per-instance `dissipate` erodes each puff from its thin edges inward (each puff starting a little later than the last) while the whole cloud fades, then the node frees itself. Sight clears at expiry, not at the end of the fade.
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
- Clouds (SPHERE) are not on the grid; they keep ActiveSurface + Area3D.
- Merge demo: `tools/surface_merge_demo.tscn` (recorded, not a test): overlapping casts, a step, water over grease, partial drying.

## Ground films (decal_surface.gd)
- A Decal, so the film drapes over steps and slopes. A Decal can't run a shader, so the scene's `film` ShaderMaterial (canvas_item, edited in the inspector) is duplicated per pass and rendered into SubViewports sized at `pixels_per_meter` (64, up to `max_resolution` 1024): albedo, normal map, and emission when `glows`. Viewports redraw only while cells arrive or recede.
- The patch's cells reach the shader as `cell_mask`, one RGBA8 texel per cell over the patch's box plus 2 cells of padding: R = coverage (arrival times not-receded), G = meters in from the patch edge / 4, A = recede progress. The box is fitted to the cells each redraw. The mask is flat, so a cell paints every floor inside the box above and below it (1.2 m reach). Each redraw is read back on `frame_post_draw` and set as a NEW ImageTexture: the decal atlas shows neither a ViewportTexture nor an `ImageTexture.update()`.
- A film shader includes `film_common.gdshaderinc`, defines `film_height(p)`, `film_albedo(p, h)` and `film_emission(p, h)`, then includes `film_passes.gdshaderinc`; every pass derives from the one height, so bumps and glow sit exactly on the film.
- `liquid_film` covers Grease, Water, Blood and Acid through uniforms (colors, alpha_max, droplets, lumpiness, bubbles, glow_color). Ice has Voronoi cracks and a frosted rim; Web draws spokes and spiral rings in meters, one large web plus three small ones; Fire's scorch glows while burning: boiling heat under dark crust plates, dying back to ember veins as it recedes.
- A glow can loop: `glow_frames` > 0 draws that many emission pictures once the film has spread (the shader loops on `glow_phase`, from `film_common`), then `_process` cycles them at `glow_fps`. No redraws while it plays; any change of cells drops back to the one live picture. Fire uses 8 at 8 fps.
- Fire adds, emitted from points scattered over its cells (`_cells_shown`, rebuilt only when the cells change): Flames (camera-facing quads, `flame.gdshader`: round base, noise-eroded into tongues, additive, depth-softened), Sparks (`spark.gdshader`, twinkling additive dots with turbulence), Smoke (dark `fog_puff` puffs rising from 1.2 m), Haze (an upright camera-facing quad bending the screen texture, `render_priority` -1 so it draws before the flames and never wipes them) and a flickering OmniLight. `dissipate()` stops the emitters and fades the light and haze, then the scorch recedes.
- Look demo of all seven: `tools/surfaces_look_demo.tscn` (recorded, not a test).

## Darkness (data/abilities/darkness.tres)
- Fog Cloud's rules (sight blocked, Blinded inside, 10 rounds), radius 5 m, plus `dark_vision_sees_through`: a unit with **Dark Vision** (`Unit.dark_vision`, cascaded from UnitDefinition; GURPS B47) is neither walled off nor Blinded by it (`_sees_through`, surface_manager.gd). Fog still stops them.
- Dark Vision: Night, Haunt, Foul, Fallen. Darkness is given to the tiefling wizard (who lacks Dark Vision).
- Visual: `darkness.tscn` inherits fog_cloud.tscn: a near-black core (opacity 0.97, 48 puffs) plus a `Tendrils` layer of 16 billboards on the sphere's surface drifting outward. `darkness_tendril.gdshader` draws curling strands (ridged noise in polar coordinates, tapered) over a soft dark body, with a faint violet edge glow. fog_cloud.gd sets colors, opacity and `dissipate` on every GPUParticles3D child, so the tendrils erode with the core.

## State it owns (source of truth)
| State | Where | Persisted? |
|---|---|---|
| Live clouds for each world | `WorldContext.surfaces`, via `_list_for(context)` | no |
| Ground cells and patches for each world | `SurfaceGrid`, via `_grid_for(context)` | no |
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
- tests/combat/test_fog_cloud.gd (8 checks):
  - sight is blocked through a cloud but not by one overhead;
  - Blinded is applied inside and comes off on leaving;
  - out of combat, the cloud expires after its rounds;
  - Darkness: Dark Vision sees through and is not Blinded; without it, blocked (sabotage-checked).
  - Sabotage-checked: removing the LoS call or the release turns it red.
- tests/combat/test_surface_grid.gd (4 checks): overlapping grease pools into one patch; water cast over it takes those cells; expired cells leave the grid; expire_all_ground empties it. Sabotage-checked: no merging turns it red.
- tests/world/test_world_scoping.gd:190-222 checks surface world scoping.

**Gaps:** no test covers two fights in one world sharing a clock, or saving.
