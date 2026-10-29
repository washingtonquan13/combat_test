# Selection & indicators

**Files:**
- `systems/selection_system/`: selection_manager.gd (114), drag_select_box.gd (142).
- `systems/indicator_system/`:
  - indicator_base.gd (283)
  - ground_click_target.gd (ClickRouter, 337)
  - movement_indicator.gd (649)
  - sight_cone_indicator.gd (243)
  - seeking_indicator.gd (148)
  - area_indicator.gd (132)
  - aerial_area_indicator.gd (131)
  - line_of_sight_indicator.gd (107)
  - jump_indicator.gd (72)
  - alignment_grid.gd (62)
- Scene nodes: MainRoot.tscn:82-108. The Indicators parent holds UnitAimFacing, Movement, LineOfSight, Jump, Area, AerialArea, SightCone, Seeking and NavDebugOverlay.

**Autoloads owned:** SelectionManager (project.godot autoload list, first entry).

## Purpose
- **SelectionManager** holds which player units are selected.
- **DragSelectBox** turns a mouse rectangle into a select() call.
- **ClickRouter** (ground_click_target.gd) decides what a world click *means* through a stack of intents: idle, locked, aiming, pushed. It also switches indicators live or off.
- **Indicators** are read-only overlays that preview movement, area, line of sight and so on for the active unit.

None of these validate or execute actions. Execution goes to CombatManager, AbilityManager and the unit's own commands (combat.md, abilities.md).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| `selected_units: Array[Unit]` | selection_manager.gd:19 | No |
| ClickRouter intent stack (pushed intents over a derived base intent) | ground_click_target.gd:129-153 | No |
| ClickRouter `_last` applied intent | ground_click_target.gd:113, 161-162 | No |
| Each indicator's live flag and owned meshes | indicator_base.gd:38, 66-83 | No |
| Movement indicator altitude-drag state | movement_indicator.gd:97-103 | No |

## Derived / cached state
- **Raycast cache.** A static `_raycast_cache` keyed by collision mask and stamped with the frame (indicator_base.gd:30, 101-120). It is shared by every indicator instance and is *not* keyed by viewport or World3D (issue 4).
- **Movement path cache.** `_last_query_unit`, the start and destination cells and `_last_waypoints` (movement_indicator.gd:88-92). This caches a NavigationGrid answer.
- **Active unit.** `_get_active_unit()` reads PlayerInteractionState and drops units outside the focused world (indicator_base.gd:238-245).
- **The selection array itself.** It is emitted by reference on every selection_changed, so listeners hold the live array, not a copy (selection_manager.gd:17, 94-96).

## Public surface
- **Calls in**
  - **SelectionManager:**
    - select (selection_manager.gd:53-69) keeps player-controlled units only.
    - add (76-83), deselect (86-91), deselect_all (94-96).
    - Callers:
      - DragSelectBox (drag_select_box.gd:126-142)
      - UnitPortrait (unit_portrait.gd:139-164)
      - WorldManager._leave_focused (world_manager.gd:379)
      - unit_death.gd:74-75
  - **ClickRouter:** intent() (129-139), push_intent / pop_intent (144-153) from DebugSpawner (debug_spawner.gd:60, 69) and ability arming, click_unit (239-260), use_ground_targeted (267-284), command_move (305-337).
  - **Indicators:** set_live, hide_visuals and serves (indicator_base.gd:66-83), driven by ClickRouter._apply_intent through the `indicators` group (ground_click_target.gd:188-194; group joined at indicator_base.gd:50).
- **Signals out**
  - SelectionManager.selection_changed goes to AbilityHotbar (ability_hotbar.gd:55-62) and others.
- **Signals in**
  - SelectionManager listens to CombatManager.turn_started, world-scoped (selection_manager.gd:43-47).
  - ClickRouter listens to WorldManager.world_focused, which resets `_last` (ground_click_target.gd:113, 161-162).

## Depends on
- WorldManager:
  - `focused_camera` is used by the drag box (drag_select_box.gd:91).
  - `context()` is used for world filtering (drag_select_box.gd:97-106; indicator_base.gd:242; selection_manager.gd:44).
- CameraDirector.has_control gates the drag box (drag_select_box.gd:51).
- PlayerInteractionState.get_active_unit (indicator_base.gd:239).
- NavigationGrid.update_occupancy and FormationPlanner for group moves (ground_click_target.gd:305-337).
- CombatManager.combat_running_in_world_of for the sight cone (sight_cone_indicator.gd:133).

## Assumptions and invariants
- **Indicators, ClickRouter and DragSelectBox are attention nodes.** WorldManager reparents them into the focused world's viewport (main_root.gd:41-44; world_manager.gd:230-239). They only ever raycast and render in *one* world: the focused one. This is a deliberate "one focused world" assumption, and it still holds, because only one world is on screen.
- **ClickRouter sets process_priority -10** (ground_click_target.gd:95) so it decides the intent before the indicators read it.
- **Freed selection entries are not cleaned up proactively.**
  - Only `_clear_all_except` filters freed entries (selection_manager.gd:99-114), and only when the next select or deselect happens.
  - Only unit_death removes a unit (unit_death.gd:74-75). Despawn, `_disembody` (world_manager.gd:410-427) and the debug-panel removal (debug_spawn_panel.gd:146-151) leave dangling entries.
  - Every reader must guard with is_instance_valid. Readers that do:
    - area_exit.gd:84
    - player_interaction_state.gd:70-72
    - ground_click_target.gd:308
- **The selection is world-agnostic storage.** Nothing stops it from holding units in a non-focused world. The turn hook filters (selection_manager.gd:44-46), and travel empties it (world_manager.gd:379).

## Lifecycle
- **Boot.** The SelectionManager autoload has an empty selection. Indicators and ClickRouter are MainRoot nodes. They are registered as attention nodes in main_root.gd:41-44 and move into each focused world's viewport.
- **Travel and world switch.** `_leave_focused` calls deselect_all (world_manager.gd:379). The attention nodes are reparented (world_manager.gd:230-239). ClickRouter's `_last` resets on world_focused (ground_click_target.gd:161-162).
- **Load.** `_tear_down_worlds` → `_leave_focused` → deselect_all (world_manager.gd:343-353, 375-381). The units are then freed by `_disembody`, after the selection is already empty, so this path is safe.
- **Combat.** A turn starting in the focused world selects the acting unit (selection_manager.gd:43-47). Turns elsewhere leave the selection alone.
- **Dialogue and cutscene.** The drag box is off when CameraDirector lacks control (drag_select_box.gd:51). The indicators follow ClickRouter's intent.
- **New game and save.** Nothing is saved, and nothing is reset beyond what travel does.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | movement_indicator calls `unit.is_flying()` on every selected unit without an is_instance_valid guard. If a selected unit is freed outside unit_death (despawn, debug removal), this errors on the next frame. | movement_indicator.gd:202-205; debug_spawn_panel.gd:146-151 | NEW |
| 2 | AbilityHotbar's refresh passes each selected entry to a typed `_in_view(candidate: Unit)`, which errors on a freed one. This is the same root cause as issue 1. | ability_hotbar.gd:163-164 | NEW |
| 3 | Root cause of issues 1 and 2: the selection is never pruned when a unit leaves the tree. Only the next select or deselect filters it. | selection_manager.gd:99-114; unit_death.gd:74-75 | CONFIRMED |
| 4 | `_raycast_cache` is keyed by mask and frame only. On the frame focus switches worlds, an indicator that already ran that frame could reuse a hit from the previous World3D. The window is one frame. | indicator_base.gd:30, 101-120 | NEW (minor) |
| 5 | deselect_all emits selection_changed even when nothing was selected, so listeners re-run on every travel. | selection_manager.gd:94-96 | NEW (minor) |

## Tests
- tests/combat/test_selection_is_a_node.gd
- tests/detection/test_sight_cone_indicator.gd
- tests/interaction/test_intent_has_one_owner.gd (ClickRouter intent stack)
- tests/world/test_avatar_indicator_faces_camera.gd
- tests/world/test_attention.gd (attention-node reparenting)

Gaps: no test frees a selected unit outside the death path (issues 1-3), and nothing covers the individual indicators other than the sight cone.
