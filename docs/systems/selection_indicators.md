# Selection & indicators

**Files:**
- `systems/selection_system/`: selection_manager.gd (114), drag_select_box.gd (142).
- `systems/indicator_system/`:
  - indicator_base.gd (live/draw contract + line meshes only)
  - ground_click_target.gd (ClickRouter: the one Cursor, the one Aim, the draw loop)
  - movement_indicator.gd (649)
  - sight_cone_indicator.gd (243)
  - seeking_indicator.gd (148)
  - area_indicator.gd (132)
  - aerial_area_indicator.gd (131)
  - line_of_sight_indicator.gd (107)
  - jump_indicator.gd (72)
  - hit_chance_indicator.gd — serves `hit_chance` (idle and aiming intents): "NN%" beside the cursor over a unit the click would attack with a to-hit roll, from `Unit.hit_chance`, plus one line per resistible status the ability applies ("Sleep NN%" = hit chance × `status_land_chance`). Its Label is TacticalUI/HitChanceLabel in MainRoot, styled there (uncommitted)
  - alignment_grid.gd (62)
- `systems/interaction_system/`: cursor.gd (Cursor: what the mouse is over this frame), aim.gd (Aim: what the player is aiming, built from the Cursor).
- Scene nodes: MainRoot.tscn:82-108. The Indicators parent holds UnitAimFacing, Movement, LineOfSight, Jump, Area, AerialArea, SightCone, Seeking, HitChance and NavDebugOverlay.

**Autoloads owned:** SelectionManager (project.godot autoload list, first entry).

## Purpose
- **SelectionManager** holds which player units are selected.
- **DragSelectBox** turns a mouse rectangle into a select() call.
- **ClickRouter** (ground_click_target.gd) decides what a world click *means* through a stack of intents: idle, locked, aiming, pushed. It also switches indicators live or off.
- **ClickRouter owns "where is the player aiming".** Each frame, in `_process`:
  1. derive the intent; on change `_apply_intent` + `intent_changed`;
  2. `cursor = resolve_cursor(intent)`: the one raycast for ground/unit/interactable, plus the Ctrl height drag (holds the ground point only when `intent.drags_height()`, height snapped to 0.25 m);
  3. `intent.steer(router, cursor)`: AimingIntent writes `AbilityManager.set_aim_height_override` (its only writer), IdleIntent sets fliers' altitude;
  4. `aim = Aim.build(cursor, intent)`: caster = `ClickRouter.active_unit()`, point = `targeting.resolve_target_point(ground)`, hostile;
  5. `draw(aim)` on every live intent-driven indicator.
  Clicks re-resolve the cursor in `_unhandled_input` (input runs before process).
- **Indicators only draw.** No raycasts, no mouse/Ctrl reads, no validity rules of their own. Colours come from `targeting.check()` (a Reach: OK / OUT_OF_RANGE / BLOCKED / INVALID; `is_valid_target` is `check() == OK`); the movement path from `Unit.preview_route()`, which mirrors `move_to`'s ladder/flight/query order.
- Before 2026-11-04 each indicator raycast for itself through a shared static cache, the Ctrl-held point was a static written by whichever live indicator ran first, and range/LoS colour rules were copied per indicator: three owners of the aim, which is why the movement preview kept old behaviour after the targeting change.

None of these validate or execute actions. Execution goes to CombatManager, AbilityManager and the unit's own commands (combat.md, abilities.md).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| `selected_units: Array[Unit]` | selection_manager.gd:19 | No |
| ClickRouter intent stack (pushed intents over a derived base intent) | ground_click_target.gd:129-153 | No |
| ClickRouter `_last` applied intent | ground_click_target.gd:113, 161-162 | No |
| Each indicator's live flag and owned meshes | indicator_base.gd | No |
| This frame's `cursor` / `aim`, and `_held_ground` (Ctrl drag) | ground_click_target.gd | No |

## Derived / cached state
- **Movement preview cache.** `_preview_*` on UnitMovement: the find_path answer keyed by start cell, destination cell and flying. It is not invalidated when other units move, so the preview can be stale until the cursor or unit changes cell; `move_to` always searches fresh.
- **Active unit.** `ClickRouter.active_unit()` reads PlayerInteractionState and drops units outside the focused world; it is `Aim.caster`.
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
  - **Indicators:** set_live, hide_visuals, serves and draw(aim), driven by ClickRouter (`_apply_intent` for live, `_process` for draw) through the `indicators` group. Sight cone and nav overlay serve `""` and keep their own `_process`; the nav overlay reads `router.cursor`.
- **Signals out**
  - SelectionManager.selection_changed goes to AbilityHotbar (ability_hotbar.gd:55-62) and others.
  - A non-additive select() of a unit that is already in a group still emits: dropping the others is a change. Before this, the hotbar stayed on whichever unit was first.
- **Signals in**
  - SelectionManager listens to CombatManager.turn_started, world-scoped (selection_manager.gd:43-47).
  - ClickRouter listens to WorldManager.world_focused, which resets `_last` (ground_click_target.gd:113, 161-162).

## Depends on
- WorldManager:
  - `focused_camera` is used by the drag box (drag_select_box.gd:91).
  - `context()` is used for world filtering (drag_select_box.gd:97-106; indicator_base.gd:242; selection_manager.gd:44).
- CameraDirector.has_control gates the drag box (drag_select_box.gd:51).
- PlayerInteractionState.get_active_unit (ClickRouter.active_unit).
- NavigationGrid.update_occupancy and FormationPlanner for group moves (ground_click_target.gd:305-337).
- CombatManager.combat_running_in_world_of for the sight cone (sight_cone_indicator.gd:133).

## Assumptions and invariants
- **Indicators, ClickRouter and DragSelectBox are attention nodes.** WorldManager reparents them into the focused world's viewport (main_root.gd:41-44; world_manager.gd:230-239). They only ever raycast and render in *one* world: the focused one. This is a deliberate "one focused world" assumption, and it still holds, because only one world is on screen.
- **ClickRouter sets process_priority -10** so it runs before nodes that read its cursor (nav overlay). Intent-driven indicators no longer process; the router draws them after the intent is applied.
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
| 1 | IdleIntent.flying_units_for_altitude (moved from movement_indicator) guards each selected unit with is_instance_valid before `is_flying()`. | idle_intent.gd | FIXED |
| 2 | AbilityHotbar's refresh passes each selected entry to a typed `_in_view(candidate: Unit)`, which errors on a freed one. This is the same root cause as issue 1. | ability_hotbar.gd:163-164 | NEW |
| 3 | Root cause of issues 1 and 2: the selection is never pruned when a unit leaves the tree. Only the next select or deselect filters it. | selection_manager.gd:99-114; unit_death.gd:74-75 | CONFIRMED |
| 4 | (was: static `_raycast_cache` shared across worlds) | removed with the cache 2026-11-04 | FIXED |
| 5 | deselect_all emits selection_changed even when nothing was selected, so listeners re-run on every travel. | selection_manager.gd:94-96 | NEW (minor) |

## Tests
- tests/combat/test_selection_is_a_node.gd
- tests/detection/test_sight_cone_indicator.gd
- tests/interaction/test_intent_has_one_owner.gd (ClickRouter intent stack; router moves before the indicator it lit is drawn, same frame)
- tests/interaction/test_height_drag_holds_ground.gd (Ctrl hold only for intents that drag height; release frees it)
- tests/world/test_avatar_indicator_faces_camera.gd
- tests/world/test_attention.gd (attention-node reparenting)

Gaps: no test frees a selected unit outside the death path (issues 1-3), and nothing covers the individual indicators other than the sight cone.
