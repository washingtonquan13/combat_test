# Camera

**Files:** `systems/camera_system/` — camera_director.gd (75), crpg_camera.gd (699), overworld_camera.gd (150)
**Autoloads owned:** CameraDirector (project.godot:27)

## Purpose
CameraDirector does three things:
- remembers which Camera3D is "the tactical one"
- hands the view to cinematic cameras and back (camera_director.gd:65-75)
- answers `has_control()`: may the 3D camera, selection and ground clicks take input (:55-58)

CRPGCamera is the tactical orbit camera in combat areas (crpg_camera.gd:1-68). OverworldCamera is a fixed-pitch follow camera, with a tactical top-down toggle, for the overworld (overworld_camera.gd:1-16).

It is NOT responsible for:
- which world is visible (WorldManager / ResidentWorld.set_focused)
- shot composition in cutscenes (cinematic_camera.gd)

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Registered tactical camera (single slot) | camera_director.gd:26 | no |
| CRPG follow target (BOUND when set) | crpg_camera.gd:85 `focus_target`, mode derived at :270-271 | no |
| CRPG yaw/pitch/distance/anchor, target and current values | crpg_camera.gd:218-267 | no |
| Load-focus settle latch | crpg_camera.gd:267 | no |
| Overworld yaw, tactical toggle, blend, range | overworld_camera.gd:41-48, :33 | no |

## Derived / cached state
- Pitch is always derived from distance (crpg_camera.gd:421).
- `desired_position` is recomputed every physics frame from anchor, forward and collision-reduced distance (:427-441).
- `_smoothed_distance_reduction` and the height lift are eased magnitudes, never written into the true distance or anchor (header :48-57).
- `CameraDirector._tactical_camera` caches "the focused world's camera". It is valid only because WorldManager re-registers on every `_focus` (world_manager.gd:555-561) and unregisters in `_leave_focused` (:384-387).

## Public surface
- **Calls in**
  - `register_tactical_camera`: crpg_camera.gd:275 (self, in `_ready`), world_manager.gd:558
  - `unregister_tactical_camera`: world_manager.gd:387
  - `activate_cinematic_camera` / `deactivate_cinematic_camera`: cinematic_camera.gd:134, :82
  - `has_control`:
    - crpg_camera.gd:391, :406
    - ground_click_target.gd:130, :210
    - drag_select_box.gd:51
  - `OverworldCamera.snap_to_target`: overworld.gd. `get_yaw`, `is_tactical`, `view_scale`, `tactical_blend` (overworld_camera.gd:117-134): read by OverworldAvatar and the overworld presentation.
- **Signals out:** none.
- **Signals in (CRPGCamera)**
  - `CombatManager.turn_started` → `_on_turn_started` (:276, :335)
  - `CombatManager.combat_ended` → `_on_combat_ended` (:277, :347)
  - `WorldManager.world_loaded` → `_on_world_loaded` (:283, :365-371), guarded by `world.is_ancestor_of(self)`

## Depends on
- GameMode: `current_mode` in `has_control` (camera_director.gd:58) and in the overworld gates (overworld_camera.gd:79, :95)
- InteractionMenu: `is_open` (camera_director.gd:56)
- PartyManager: `leader` (crpg_camera.gd:368-370, :382)
- CombatManager: the global relayed signals (combat_manager.gd:360-364, :404)
- Physics: ray at `_ready` (crpg_camera.gd:315-320); collision sweep in `_update_distance_reduction` (:488-579)

## Assumptions and invariants
- **One tactical camera at a time** (camera_director.gd:26). This is a "one focused world" assumption, kept true by WorldManager's re-register on focus. Self-registration in `_ready` (crpg_camera.gd:275) is redundant, and it is briefly wrong during `_enter_world`: the new camera registers on `add_child` (world_manager.gd:747), before the old world is unfocused at `_focus` (:757).
- **`has_control()` is global, not per world.** CRPGCameras in UNFOCUSED resident worlds keep processing (resident_world.gd:83-85) and poll `Input` in `_process` (crpg_camera.gd:405-410, :588-590). STALE under residency (C2).
- **CombatManager's `turn_started` / `combat_ended` are unfiltered relays of every encounter** (combat_manager.gd:360-364, :404). CRPGCamera assumes they are its own world's fight: the old "only one fight" assumption. STALE (C1).
- **OverworldCamera assumes CRPGCamera is never resident at the same time** (overworld_camera.gd:12-14, "freed before this loads"). STALE: residency keeps arenas alive. There is no conflict in practice because each camera gates on mode.
- **Occlusion fade is a stub**, documented as the intended fix for corners (crpg_camera.gd:59-66, :579).

## Lifecycle
- CameraDirector lives for the session.
- Each area .tscn instantiates its own camera.
- On focus, WorldManager registers it and calls `make_current` (world_manager.gd:555-561). On leaving focus, it unregisters it (:384-387).
- On `world_loaded` for its own world, CRPGCamera binds to `PartyManager.leader` until settled, then drops back to UNBOUND (crpg_camera.gd:365-387, :466-467).
- Combat: every turn start binds `focus_target` to the acting unit; combat end unbinds it (:335-348).
- Cutscene: a cinematic camera takes `make_current`, then `deactivate` returns to the registered tactical camera (camera_director.gd:65-75).
- Dialogue, menus and FACILITY: `has_control` is false, so there is no orbit input.
- Save/load: nothing is persisted; the camera refocuses the leader on load via `world_loaded`.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| C1 | Every CRPGCamera follows every encounter's turns. `turn_started` is a global relay, so a camera whose world has no fight binds `focus_target` to a unit in ANOTHER World3D and swings to that unit's coordinates. Likewise, any fight ending unbinds every camera, including one following an ongoing fight in its own world. | crpg_camera.gd:276-277, :335-348; combat_manager.gd:360-364, :404 | NEW |
| C2 | Hidden resident CRPGCameras keep consuming WASD/Q/E. `has_control()` reads the focused world's mode, and an unfocused world still processes, so its camera drifts off while you play elsewhere. | resident_world.gd:83-85; crpg_camera.gd:405-410, :588-590; camera_director.gd:55-58 | NEW |
| C3 | No refocus when re-entering a resident world. Re-entry skips instantiation (world_manager.gd:699-710), and `_ready` and the ancestor-matched `world_loaded` handler leave the camera where it was. The camera does not listen to `world_focused`. | crpg_camera.gd:283, :365-371; world_manager.gd:95 | NEW |
| C4 | `_on_world_loaded` targets the global `PartyManager.leader` even when the leader's group is in another area (a split party). The ancestor guard scopes the camera, but not the target. | crpg_camera.gd:368-370; world_manager.gd:436 | NEW |
| C5 | Stale comments. CameraDirector says it is re-registered "by WorldManager.load_world()" (actually `_focus`), and overworld_camera claims crpg_camera "is freed before this loads". | camera_director.gd:28-33; overworld_camera.gd:12-14; world_manager.gd:555-561 | NEW |
| C6 | Occlusion fade is unimplemented, so tight corners still pull the camera close. | crpg_camera.gd:59-66, :576-580 | CONFIRMED (known, by design) |

## Tests
- tests/cinematic/test_the_seam.gd:65 (has_control during a cutscene)
- tests/interaction/test_intent_has_one_owner.gd:189, :345
- tests/world/test_the_cathedral_is_a_room_not_a_menu.gd:150
- tests/world/test_the_tactical_view_clears_the_haze.gd (overworld tactical view)

Gaps: nothing covers CRPGCamera follow behavior with two resident fights (C1), input to unfocused cameras (C2), or re-entry framing (C3).
