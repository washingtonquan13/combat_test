# Interaction

**Files:** `systems/interaction_system/` (sizes at review 11-15: interaction_approach.gd 153, interaction_menu.gd 102, interact_prompt.gd 91, negotiate_interaction.gd 82, talk_interaction.gd 75, player_interaction_state.gd 73, player_intent.gd 107, aiming_intent.gd 120, idle_intent.gd 114, click_hit.gd 38, interaction_option.gd 55; also `aim.gd`, `cursor.gd` and, from the movement scope, `movable_prop.gd`, `prop_drag.gd`, `dragging_intent.gd`; interactable_prop.gd 33, attack_interaction.gd 27, locked_intent.gd 26, travel_interaction.gd 21, examine_interaction.gd 21, loot_interaction.gd 15); click router `systems/indicator_system/ground_click_target.gd` 1226 (`class_name ClickRouter`) + hover helpers in `indicator_base.gd`; data `data/interactions/` (attack, examine, loot, negotiate, talk, travel .tres).
**Autoloads owned:** `InteractionMenu` (project.godot:26)

## Purpose
Turns mouse/keyboard input into intents (idle / aiming / locked / pushed) and dispatches clicks: move, attack, use ground-targeted ability, or open a right-click context menu of `InteractionOption`s offered by the target unit or prop. Also owns the overworld "Space to interact" prompt. It does NOT run what the option starts - talk/negotiate hand off to Conversations, loot to StashManager, use to Terminal, travel to AreaExit, attack to combat.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Open context menu: popup, actor, target, options | interaction_menu.gd:19-22 | No |
| Pushed intent stack | ground_click_target.gd:144-153 | No |
| Last emitted intent | ground_click_target.gd:113, :165-171 | No |
| A verb walking to its target (pending verb, actor, target) | interaction_approach.gd, an `InteractionApproach` child of the actor | No |
| Overworld prompt current target | interact_prompt.gd:36-42, :75-84 | No |
| Option lists on units / props | unit.gd:350 `interactions`, :844-849; interactable_prop.gd:16-33 | Content |

- A prop with a `Breakable` child gets Attack added to its `interactions` at `_ready` (a fresh array; the scene's own is untouched). Picking it calls `use_ability(default_ability(), breakable)`. Like attacking a unit, it does **not** walk to the target: `InteractionApproach` walks only when `option.reach > 0`, and attack.tres has reach 0. ClickRouter's `click_breakable` uses the armed single-target attack on the prop under the mouse at once. Only an ability that `Breakable.hurt_by` allows counts: not for allies, and with a damage effect. `UnitCombat.use_ability` refuses any other as `invalid_target`, so a heal or a shove on a crate never spends the action.
- A MovableProp saves its own parts: WorldManager calls only the persistent node's `save_state` when it has one (a child's is used only when the node has none), so `MovableProp.save_state` also writes its StashComponent's contents (`stash`) and its Breakable's `hp`, and `load_state` restores them. Without that, a crate's loot re-rolled on every reload.

## Derived / cached state
- Intent is recomputed each frame (`intent()` ground_click_target.gd:129-139) from CameraDirector.has_control, pushed intents and AbilityManager.armed_ability; only `_last` is cached for change detection. Cleared on world_focused (:161-162).
- `InteractionMenu._actor/_target/_options` are copies of selection at open time, not refreshed (interaction_menu.gd:19-22; options filtered once at `open_for`, :35-51).
- Active unit is read from selection via player_interaction_state.gd:69-73.

## Public surface
- **Calls in**: `InteractionMenu.open_for(actor, target)` from idle_intent.gd:36-45; `close()` / `is_open()` from travel_interaction.gd:13-21, WorldManager.can_travel (world_manager.gd:259) and _leave_focused (:380); `ClickRouter.push_intent/pop_intent` (:144-153), `click_unit` (:239-260), `use_ground_targeted` (:267-284), `command_move` (:305-337); `interact_prompt.activate` -> overworld_door.gd:70.
- **Signals out**: `ClickRouter.intent_changed` (:165-171) -> indicators toggled in `_apply_intent` (:188-194).
- **Signals in**: WorldManager.world_focused (ground_click_target.gd:113), world_loading/world_focused (interact_prompt.gd:41-42).

## Depends on
- CameraDirector.has_control (ground_click_target.gd:129-131); AbilityManager.armed_ability (:134-139); FormationPlanner in command_move (:305-337).
- WorldManager.focused_camera for menu placement (interaction_menu.gd:86-96); viewport camera / world_3d raycasts for hover (hover and picking now live in ground_click_target.gd:457-656; the indicator_base.gd cites are stale).
- Option executors:
  - talk -> Conversations.begin (talk_interaction.gd:39-49); cast adds PartyManager.leader + core party (:68-75)
  - negotiate -> Conversations.begin with negotiation presentation (negotiate_interaction.gd:32-46)
  - loot -> StashManager.open_stash (loot_interaction.gd:14-15)
  - travel -> closes menu, AreaExit.travel (travel_interaction.gd:13-21)
  - examine -> SystemLog (examine_interaction.gd:13-21)
  - use (terminal) -> `Terminal.use` (systems/terminal_system/use_terminal_interaction.gd; data/interactions/use_terminal.tres, reach 1.2). The view glides into the prop's screen, a TerminalOverlay UIScreen hides the HUD, and GameMode reads TERMINAL until Escape steps away. The screen is a SubViewport page (terminal_screen.gd) drawn onto the glass through crt_screen.gdshader (designed on a 640x480 grid, rendered at 1280x960; bundled OFL fonts in assets/fonts, `Terminal.face` picks DotGothic16 or VT323). Screen/ScreenLight is the green spill on the room, flickering with the glass. Demo: tools/terminal_demo.tscn (TERMINAL_FACE=vt323 for the other face).
  - attack -> combat (attack_interaction.gd:26-27)
- Unit-side option assembly: unit.gd:844-849 (get_interactions), dialogue root via unit.gd:863-867 and `dialogue_options` export :364.
- GameMode: prompt visible only in OVERWORLD (interact_prompt.gd:88).

## Assumptions and invariants
- One router in the tree (group `click_router`, ground_click_target.gd:73) and one context menu process-wide. Both act on the focused world only; hover raycasts use `get_viewport().get_camera_3d()` (indicator_base.gd:107), so they assume the focused world owns the main viewport camera - single-focused-world assumption, consistent with WorldManager focus model.
- Intent has one owner (pinned by tests/interaction/test_intent_has_one_owner.gd).
- Menu actor/target stay valid between open and click - not checked (issue 1).
- A picked verb runs through `InteractionApproach.run`: an `InteractionOption.reach` above 0 (Talk 2.0 m, Open 1.5 m, body to body) walks the actor there first, party in formation, out of combat only. It is called off by any other order (the actor's route stops ending where it sent it), a target that is gone, dead or no longer offering the verb, or combat. A stop short of a target that moved walks again, up to 3 times.
- A plain left click on a non-party, non-hostile, non-downed unit, with nothing armed and out of combat, is Talk, not an attack (`ClickRouter._click_talk_on`; cursor answer `talk`; picked by an `is TalkInteraction` test at `ground_click_target.gd:1016-1025`). This is deliberate: a friendly NPC talks on left click and a verb picked out of reach walks there first (d3fbf882).
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
| 1 | Context-menu click executes the option on stored `_actor/_target` with no `is_instance_valid` check; a target freed (killed, despawned) while the popup is open would error. | interaction_menu.gd:99-102 | NEW; review 11-15: still open, see ABIL-5 |
| 2 | Talk cast pulls core-party units tree-wide, not from the actor's world (split party). Documented in dialogue.md #5. | talk_interaction.gd:72 | NEW; review 11-15: still open (tree-wide `core_party_units`) |
| 3 | Hover/raycast uses the viewport's current camera and world rather than an explicit focused world; relies on CameraDirector keeping the focused world's camera current. | ground_click_target.gd:457,504,554,595,656; indicator_base.gd:232 | NEW (assumption, not a bug today); review 11-15: still open, see ABIL-18 |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| ABIL-2 | Three answers to "who is the caster": world-filtered `active_unit()`, unfiltered `PlayerInteractionState.get_active_unit()`, and `AbilityManager.armed_unit`. The preview is built for the filtered one and the click executes for the unfiltered one, so with the active unit in another world nothing draws and the click still casts | `ground_click_target.gd:541-548` (filtered; used `:397,491,805,1137`), `:879,913,1001,1017,1059,1074,1109,1129` (unfiltered), `:914` (membership test); `aim.gd:34`; `ability_manager.gd:74,139`; `aiming_intent.gd:70-82` | `7c3b3aa1` introduced `Aim` and the filtered `active_unit()` for drawing; the click handlers kept their older lookups. | `Aim` carries `caster`; click handlers take the `Aim` drawn that frame and never look the caster up again; `get_active_unit()` becomes private to the router. | R4, R1 | M | BUG (risk, made worse by the router rewrite) |
| ABIL-4 | `_answer()` re-implements each intent's click decision to choose the cursor shape, in the same branch order as the intents, plus the crawl special case | `ground_click_target.gd:1039-1086`; `idle_intent.gd:27-46`; `aiming_intent.gd:36-50` | `581d28c8` (context cursor) was added after `f2ff8d7c` had put the click rules in the intents. | Each intent has one `decide(cursor) -> ClickAnswer`; the cursor shape reads it and the release handler executes it. | R4 | M | BUG (latent: the two will drift) |
| ABIL-5 | Interaction menu acts on a stale actor, target and option | `interaction_menu.gd:19-22,57-58,99-102`; `interaction_approach.gd:42-46` | `close()` keeps the stored fields and the pick passes them straight to `InteractionApproach.run` with no validity or `is_available` re-check (`d3fbf882` rerouted the pick without adding one). | `_on_id_pressed` validates actor and target and re-asks `option.is_available`; `close()` clears the fields; the menu closes on the target's `tree_exiting` and `died`. | R5 | S | KNOWN (#1): see row 1 above |
| ABIL-6 | "Is this still my move order" is guessed from the route's end point, in two places. A new order ending near the stand point does not cancel the verb; a re-planned route reads as "the player took over" and drops it | `interaction_approach.gd:67-71,74-93,142-145`; `click_feedback.gd:150-157` | `d3fbf882` had no way to ask the mover which order is running, so it compares route ends (`OWN_ROUTE_SLACK`, `TARGET_MOVED`) and renames itself to free the node name. | `UnitMovement` hands back an order id (or emits `order_replaced` / `order_finished`); the approach and the destination marker hold the id. Needs move scope. | R3 | M | BUG |
| ABIL-7 | A pending walk-then-verb survives cutscenes, world changes and load: no `CameraDirector.has_control()`, UIStack or world check, so a walk started before the camp raid can arrive during it and open dialogue under the cutscene | `interaction_approach.gd:96-103,134-139` | `_still_wanted` checks only alive, not in combat, in tree and `is_available`; nothing tells the approach a cutscene or world change started. | One "player orders are cancelled" call (cutscene start, world unfocus, load, mode change) that clears routes and pending verbs for the party; `_still_wanted` asks the same "is the world listening" query as ABIL-9. | R3, R5 | S (after ABIL-9) | BUG |
| ABIL-8 | Left-click talk picks the option by type (`is TalkInteraction`) with its own gate list (armed, in combat, player controlled, downed) | `ground_click_target.gd:1016-1025` | A left-click on a friendly NPC talks, and a verb picked out of reach walks there first (d3fbf882). | `InteractionOption.is_default_click` (or `default_priority`) so loot, travel and doors can be left-click defaults without another `is` test; the gates move into `is_available`. | R8 | S | INTENTIONAL; document why: friendly-NPC left-click talks (d3fbf882) |
| ABIL-9 | Three answers to "is the world taking input right now": camera director control, `UIStack.can_open()` plus mouse-over-GUI, and mode == OVERWORLD, with the approach checking none | `ground_click_target.gd:257,781-782,1198-1199`; `selection_manager.gd:219,223-231`; `interact_prompt.gd:88`; `interaction_approach.gd:96-103` | Each handler added its own gate when it was written. | One query (for example `PlayerInput.accepts_world_input()`) that every keyboard and mouse handler in this scope asks. | R3, R4 | S-M | BUG (latent: handlers disagree, ABIL-7 depends on it) |
| ABIL-15 | Crawl, jump and flight each have their own branch in the click path; the wall threshold is written as the literals `0.7` and `* 0.3` in `cursor.gd` and as `UnitMovement.CLING_BELOW` elsewhere; the jump landing runs a private occupancy scan | `cursor.gd:104-105`; `unit_movement.gd:104`; `ground_click_target.gd:1052`; `click_feedback.gd:127-129`; `ground_point_targeting.gd:56-61,81-106,169-183` | Wall crawl (ee4efa10, 1b94bff0) and the jump arc (a53e17f6) each added a branch beside the nav layer, which cannot say what kind of surface a point is. | The nav layer answers one question, "can this unit stand at this point, and on what kind of surface (floor, wall, ceiling, ladder, air)", and the cursor, click answer, destination marker and jump landing all ask it. Needs move scope. | R4 | M | BUG (latent: the literal can drift from `CLING_BELOW`) |
| ABIL-18 | Two cameras for picking and placing: `get_viewport().get_camera_3d()` in the router and indicators, `WorldManager.focused_camera()` in the menu and drag box; indicator placement is not gated during a cutscene | `ground_click_target.gd:457,504,554,595,656`; `indicator_base.gd:232`; `interaction_menu.gd:93`; `drag_select_box.gd:93`; `hit_chance_indicator.gd:40-47` | Hover grew up reading the viewport camera; later code asked WorldManager. | The Cursor carries the camera it was built from; nothing else looks one up. | R1 | S | KNOWN (#3): see row 3 above |
| ABIL-D | Doc text was behind the code (file sizes, missing files, stale cites, undocumented walk-then-verb) | rows and bullets edited in place | | | - | S | DOC DRIFT; fixed in doc |

## Tests
`tests/interaction/test_intent_has_one_owner.gd`; `tests/interaction/test_talking_walks_up_first.gd` (left click talks, walks into reach, a move order cancels). Gaps: no test for menu-target invalidation, option availability rules, or the overworld prompt.
