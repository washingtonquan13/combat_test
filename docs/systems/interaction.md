# Interaction

**Files:** `systems/interaction_system/` (822 lines; interaction_menu.gd 102, interact_prompt.gd 91, negotiate_interaction.gd 82, talk_interaction.gd 75, player_interaction_state.gd 73, player_intent.gd 63, aiming_intent.gd 62, idle_intent.gd 57, click_hit.gd 38, interaction_option.gd 36, interactable_prop.gd 33, attack_interaction.gd 27, locked_intent.gd 26, travel_interaction.gd 21, examine_interaction.gd 21, loot_interaction.gd 15); click router `systems/indicator_system/ground_click_target.gd` 337 (`class_name ClickRouter`) + hover helpers in `indicator_base.gd`; data `data/interactions/` (attack, examine, loot, negotiate, talk, travel .tres).
**Autoloads owned:** `InteractionMenu` (project.godot:26)

## Purpose
Turns mouse/keyboard input into intents (idle / aiming / locked / pushed) and dispatches clicks: move, attack, use ground-targeted ability, or open a right-click context menu of `InteractionOption`s offered by the target unit or prop. Also owns the overworld "Space to interact" prompt. It does NOT run what the option starts - talk/negotiate hand off to Conversations, loot to StashManager, travel to AreaExit, attack to combat.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Open context menu: popup, actor, target, options | interaction_menu.gd:19-22 | No |
| Pushed intent stack | ground_click_target.gd:144-153 | No |
| Last emitted intent | ground_click_target.gd:113, :165-171 | No |
| Overworld prompt current target | interact_prompt.gd:36-42, :75-84 | No |
| Option lists on units / props | unit.gd:350 `interactions`, :844-849; interactable_prop.gd:16-33 | Content |

## Derived / cached state
- Intent is recomputed each frame (`intent()` ground_click_target.gd:129-139) from CameraDirector.has_control, pushed intents and AbilityManager.armed_ability; only `_last` is cached for change detection. Cleared on world_focused (:161-162).
- `InteractionMenu._actor/_target` are copies of selection at open time, not refreshed (interaction_menu.gd:35-51).
- Active unit is read from selection via player_interaction_state.gd:69-73.

## Public surface
- **Calls in**: `InteractionMenu.open_for(actor, target)` from idle_intent.gd:36-45; `close()` / `is_open()` from travel_interaction.gd:13-21, WorldManager.can_travel (world_manager.gd:259) and _leave_focused (:380); `ClickRouter.push_intent/pop_intent` (:144-153), `click_unit` (:239-260), `use_ground_targeted` (:267-284), `command_move` (:305-337); `interact_prompt.activate` -> overworld_door.gd:70.
- **Signals out**: `ClickRouter.intent_changed` (:165-171) -> indicators toggled in `_apply_intent` (:188-194).
- **Signals in**: WorldManager.world_focused (ground_click_target.gd:113), world_loading/world_focused (interact_prompt.gd:41-42).

## Depends on
- CameraDirector.has_control (ground_click_target.gd:129-131); AbilityManager.armed_ability (:134-139); FormationPlanner in command_move (:305-337).
- WorldManager.focused_camera for menu placement (interaction_menu.gd:86-96); viewport camera / world_3d raycasts for hover (indicator_base.gd:107, :114, :153, :164, :175).
- Option executors:
  - talk -> Conversations.begin (talk_interaction.gd:39-49); cast adds PartyManager.leader + core party (:68-75)
  - negotiate -> Conversations.begin with negotiation presentation (negotiate_interaction.gd:32-46)
  - loot -> StashManager.open_stash (loot_interaction.gd:14-15)
  - travel -> closes menu, AreaExit.travel (travel_interaction.gd:13-21)
  - examine -> SystemLog (examine_interaction.gd:13-21)
  - attack -> combat (attack_interaction.gd:26-27)
- Unit-side option assembly: unit.gd:844-849 (get_interactions), dialogue root via unit.gd:863-867 and `dialogue_options` export :364.
- GameMode: prompt visible only in OVERWORLD (interact_prompt.gd:88).

## Assumptions and invariants
- One router in the tree (group `click_router`, ground_click_target.gd:73) and one context menu process-wide. Both act on the focused world only; hover raycasts use `get_viewport().get_camera_3d()` (indicator_base.gd:107), so they assume the focused world owns the main viewport camera - single-focused-world assumption, consistent with WorldManager focus model.
- Intent has one owner (pinned by tests/interaction/test_intent_has_one_owner.gd).
- Menu actor/target stay valid between open and click - not checked (issue 1).
- Talk is out-of-combat only, Negotiate in-combat only (talk_interaction.gd:24-29; negotiate_interaction.gd:35, :74-78).

## Lifecycle
- Router lives under MainRoot; menu autoload lives forever.
- **World travel / focus switch**: `_leave_focused` closes the menu (world_manager.gd:380); router `_last` reset on world_focused (:161-162); prompt clears on world_loading/world_focused (interact_prompt.gd:75-84). Attention nodes reparented on travel (world_manager.gd:230-239).
- **Combat**: intents switch to aiming when an ability is armed; locked when camera control is taken (cutscene) (locked_intent.gd:21-26).
- **Dialogue / cutscene**: input above is blocked by UIStack (overlay blocks_input_below) and CameraDirector control.
- **Save / load / new game**: no state to save; menu closed by _leave_focused.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Context-menu click executes the option on stored `_actor/_target` with no `is_instance_valid` check; a target freed (killed, despawned) while the popup is open would error. | interaction_menu.gd:99-102 | NEW |
| 2 | Talk cast pulls core-party units tree-wide, not from the actor's world (split party). Documented in dialogue.md #5. | talk_interaction.gd:70-72 | NEW |
| 3 | Hover/raycast uses the viewport's current camera and world rather than an explicit focused world; relies on CameraDirector keeping the focused world's camera current. | indicator_base.gd:107, :114 | NEW (assumption, not a bug today) |

## Tests
`tests/interaction/test_intent_has_one_owner.gd` only. Gaps: no test for menu-target invalidation, option availability rules, or the overworld prompt.
