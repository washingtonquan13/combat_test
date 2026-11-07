# GameMode and UIStack

**Files:** `systems/mode_system/game_mode.gd` (176), `systems/ui_system/ui_stack.gd` (181), `systems/ui_system/ui_screen.gd` (52)
**Autoloads owned:** UIStack (project.godot:40), GameMode (project.godot:42)

## Purpose
GameMode derives the single current Mode, polled each frame. It has no state of its own. It reads other systems in a fixed precedence (game_mode.gd:95-105) and emits `mode_changed` when the answer changes (:172-176).

UIStack is a registry of open UIScreens. From that registry it derives:
- HUD visibility (ui_stack.gd:158-165)
- party-rail visibility (:177)
- `can_open()` UI-to-UI blocking (:129-133)
- which screen Escape closes (:136-155)

Neither one gates 3D input; that is CameraDirector.has_control (camera_director.gd:55-58).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Last emitted mode, used only for change detection | game_mode.gd:74 | no |
| Open screens, in open order | ui_stack.gd:29 `_stack` | no |
| HUD and party-rail controls | ui_stack.gd:30-31 (registered from main_root.gd:60-71) | no |
| Per-screen flags (authored) | ui_screen.gd:23 hides_hud, :28 blocks_input_below, :40 keeps_party_visible, :44 closes_on_cancel | scene data (MainRoot.tscn) |

## Derived / cached state
- **Mode precedence** (game_mode.gd:95-105):
  1. CUTSCENE (CinematicDirector.is_active)
  2. DIALOGUE / NEGOTIATION (`Conversations.current` and its `presentation`)
  3. LOOTING (StashManager.is_active)
  4. COMBAT (`CombatManager.a_watched_fight_is_running`, which counts only fights in the focused world involving the player, combat_manager.gd:437-443)
  5. `base_mode()`
- **`base_mode()`** (:133-139) checks, in order:
  1. focused world's `get_base_mode()`
  2. else the `character_creation` screen being open
  3. else MAIN_MENU
- **`_last_emitted`** is a cache of `current_mode()`. Between frames, listeners of `mode_changed` can be up to one frame stale versus direct `current_mode()` callers.
- **`screen.visible`** is set by push/pop (ui_stack.gd:80-94). A screen that toggles its own `visible` desyncs from `_stack`. stash_panel works around this by closing the stash on visibility change (ui/stash_panel.gd:51, :69-71).

## Public surface
- **Calls in (GameMode)**
  - `current_mode`: 12 non-test files (grep), including:
    - world_manager.gd:270, :325
    - save_manager.gd:292-302
    - camera_director.gd:58
    - overworld_camera.gd:79, :95
  - `can_transition`: world_manager.gd:261, :1054
  - `input_is_taken`: conversations.gd:52, stash_manager.gd:24-27
  - `mode_changed.connect`: unit_selection.gd:104, area_label.gd:29
- **Calls in (UIStack)**
  - registration: main_root.gd:60-83
  - `close_all`: world_manager.gd:381, :884
  - push/pop by screens:
    - esc_menu.gd:100-104, main_menu.gd:89, :116, menu_button.gd:12-15
    - party_overview.gd:215-219, stash_panel.gd:29-77
    - dialogue_overlay.gd:233-259, cinematic_overlay.gd:62
    - character_creation.gd:506, demon_compendium_panel.gd:127-128, cathedral_of_shadows.gd:54
  - `is_open`: game_mode.gd:161
- **Signals out:** `GameMode.mode_changed(mode)` (game_mode.gd:72). UIStack emits nothing.
- **Signals in:** none. GameMode polls in `_process`; UIStack handles `ui_cancel` in `_unhandled_input` (:136).

## Depends on
- GameMode reads CinematicDirector, Conversations.current, StashManager, CombatManager, WorldManager.current_world and UIStack.is_open (game_mode.gd:95-161).
- UIStack reads the `esc_menu` group from the SceneTree (ui_stack.gd:142).

## Assumptions and invariants
- **"Dependency is one-way: none of them asks GameMode back"** (game_mode.gd:36-42). STALE: WorldManager calls `GameMode.can_transition` and `current_mode` (world_manager.gd:261, :270, :1054). It works only because those calls happen at call time, not in `_ready`.
- **"Mode is derived, nothing to keep in sync".** True for GameMode itself, but it inherits any staleness in its sources. A non-null `Conversations.current` pins DIALOGUE regardless of UI (M1).
- **COMBAT means a watched fight in the FOCUSED world** (combat_manager.gd:441). Fights in other residents leave the mode at the base mode. This is deliberate and multi-world aware.
- **`can_open()` is advisory.** `push()` does not consult it (ui_stack.gd:80-85), and neither does UIStack's own Escape fallback (M2).
- **One HUD and one party rail** (ui_stack.gd:30-31): there is a single global UI layer over whichever world is focused.

## Lifecycle
- Both autoloads live for the whole session.
- UIStack is emptied by `close_all` on every focus change and teardown (world_manager.gd:381) and on travel (:884).
- GameMode needs no reset. On new game or load, its sources reset, except `Conversations.current` (M1).
- Mode transitions:
  - dialogue: `Conversations.current` set/cleared
  - cutscene: CinematicDirector.is_active
  - looting: StashManager
  - combat: an encounter in the focused world starts or ends
  - travel and load: `base_mode` changes with the focused world

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| M1 | Esc → Load mid-dialogue leaves `Conversations.current` set while the overlay is gone. The mode is stuck at DIALOGUE, so travel, save and camera control are refused. Full trace in save.md S4. GameMode has no way to tell an orphaned conversation from a live one. | game_mode.gd:98-100; conversations.gd:24; world_manager.gd:381 | CONFIRMED |
| M2 | Escape opens the esc menu without checking `can_open()`. That includes over DialogueOverlay / NegotiationPanel (both `closes_on_cancel=false`, MainRoot.tscn:397, :404), the main menu and character creation. This is the entry point for M1. | ui_stack.gd:136-145, :80-85, :129-133 | NEW |
| M3 | The "one-way dependency" header is stale (see Assumptions). | game_mode.gd:36-42; world_manager.gd:261, :1054 | NEW |
| M4 | `close_all`'s comment names `WorldManager.load_world()`, but the real callers are `_leave_focused` and `travel_area`. | ui_stack.gd:96-100; world_manager.gd:381, :884 | NEW |
| M5 | `mode_changed` is emitted from polling, up to one frame late. Listeners that act on it (unit_selection.gd:104) can briefly disagree with direct `current_mode()` readers. | game_mode.gd:172-176 | NEW (low) |

## Tests
- tests/combat/test_mode_is_derived.gd
- tests/interaction/test_intent_has_one_owner.gd
- tests/dialogue/test_the_band_leaves_the_world_alone.gd
- tests/dialogue/test_the_party_stays_reachable.gd
- tests/conversation/test_the_band_follows_the_conversation.gd
- tests/conversation/test_a_negotiation_opens_on_terms.gd
- tests/cinematic/test_the_seam.gd
- tests/world/test_the_cathedral_is_a_room_not_a_menu.gd
- tests/world/test_attention.gd

Gaps: no test presses ui_cancel during a conversation (M2), and none loads during a conversation (M1).
