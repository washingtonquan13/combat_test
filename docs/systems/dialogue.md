# Dialogue & Negotiation

**Files:** `systems/dialogue_system/` (2647 lines; conversation.gd 482, skill_check_dice_popup.gd 351, dialogue_overlay.gd 287, dialogue_format.gd 193, choice_row.gd 182, conversations.gd 160, dialogue_staging.gd 143, dialogue_gaze.gd 118, dialogue_choice.gd 111, conversation_log.gd 106, dialogue_node_index.gd 68, quick_contest_choice.gd 60, dialogue_effect.gd 50, skill_check_choice.gd 44, dialogue_node.gd 44, give_item_effect.gd 36, participant_present_prerequisite.gd 35, line_choice.gd 32, trigger_combat_effect.gd 29, sacrifice_* 22-27, dialogue_root_option.gd 19); `systems/negotiation_system/` (244; negotiation_outcome_effect.gd 107, shift_mood_effect.gd 41, negotiation_opening_effect.gd 40, sacrifice_negotiated_gold_effect.gd 24, spend_pardon_effect.gd 18, volatile_mood_effect.gd 14); `ui/negotiation_panel.gd`; entry points `talk_interaction.gd` 75, `negotiate_interaction.gd` 82. Data: `data/dialogue/` (21 .tres), `data/negotiation/conversations/` (10 personality trees); 61 node files, 2504 lines.
**Autoloads owned:** `Conversations` (project.godot:28)

## Purpose
Runs one player-facing conversation at a time: a `Conversation` (RefCounted) walks a tree of `DialogueNode` .tres files, resolves choices (lines, skill checks, quick contests), applies effects (flags, items, combat trigger, negotiation mood/gold/pardon/outcome) and exposes a pull-model `snapshot()` to presenters. Negotiation is the same engine with `presentation = negotiation` and a different panel. It does NOT own UI layout (overlay/panel follow it), camera (asks CinematicDirector), or persistence (it has none).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| The one live conversation | conversations.gd:24 `var current` | No |
| Seed counter for conversation RNG | conversations.gd:28 | No |
| Folders already linted | conversations.gd:31 | No |
| Cast, vars (mood/gold/pardon), transcript, rng | conversation.gd:50, :54, :61, :65 | No |
| presentation / node_dir / dead_end_effect / ended | conversation.gd:70, :73, :79, :85 | No |
| Used (non-repeatable) choices | conversation.gd:89 (per conversation) | No |
| Node-id index cache per folder | conversation.gd:109 static `_indexes`; dialogue_node_index.gd:46-68 | No |
| Authored tree (node id, speaker, text, choices, next ids, effects) | dialogue_node.gd:18-44 | Content (.tres) |

Side effects that DO persist live in other systems: `FlagManager.set_flag` (dialogue_choice.gd:65), alignment tags on actor (:58), items via party_overview (give_item_effect.gd:27), combat start (trigger_combat_effect.gd:29).

## Derived / cached state
- `GameMode.current_mode` derives DIALOGUE/NEGOTIATION from `Conversations.current` (game_mode.gd:98-100); `input_is_taken` likewise (:129-130). If `current` is stale, mode is stale.
- `DialogueOverlay._conversation` connection (dialogue_overlay.gd:114, :124-136) - a second copy of "which conversation"; cleared only on `ended` (:228-233).
- `MusicManager` reads `Conversations.current` and began/ended (music_manager.gd:78-79, :216).
- Static `_indexes` (conversation.gd:109, :477-482) caches folder scans for the process lifetime; new .tres added at runtime are invisible (editor-only concern).

## Public surface
- **Calls in**: `Conversations.begin(c)` from talk_interaction.gd:39-49 and negotiate_interaction.gd:32-46; `Conversations.follow(presenter)` from dialogue_overlay.gd:114, negotiation_panel.gd:55, dialogue_staging.gd:57, dialogue_gaze.gd:36, party_panel.gd:131; `Conversation.choose()` from overlay/panel (negotiation_panel.gd:138-139); `attach/detach` + `complete()` from skill_check_dice_popup.gd:112, :134, :143; `Conversations.problems_in()` from tests.
- **Signals out**: `Conversations.began/ended` (conversations.gd:21-22) -> overlay, panel, staging, gaze, MusicManager; `Conversation.changed` (conversation.gd:32) -> whoever followed.
- **Signals in**: only its own conversation's `changed` (conversations.gd:57, :96-102). Listens to nothing from WorldManager or SaveManager.

## Depends on
- GameMode.input_is_taken (conversations.gd:52) - refuses to begin under another mode.
- FlagManager (dialogue_choice.gd:65), CombatManager.start_combat_from_hostile_act (trigger_combat_effect.gd:29), PartyManager.leader + UnitQuery.core_party_units (talk_interaction.gd:70-72), SystemLog (negotiate_interaction.gd:60-71), CinematicDirector.play/camera (dialogue_staging.gd:111, :116-120), tree group `party_overview` (give_item_effect.gd:27).

## Assumptions and invariants
- Exactly one conversation process-wide (conversations.gd:24, refused if `current != null` :52). Comment at world_context.gd:22-27 calls it PLAYER-scoped, which is consistent with one focused world - but see cast below.
- `current` is cleared only when the conversation itself reports `ended` (conversations.gd:96-102). Invariant "every conversation reaches end()" is only enforced by authoring + lint; there is no external terminator.
- Cast is built tree-wide, not per world: `UnitQuery.core_party_units(tree)` (talk_interaction.gd:72 -> unit_query.gd:135-140, uses all_units :52-59, not `_in_world_of` :99-111). **STALE** single-world assumption: WorldManager keeps multiple resident worlds (world_manager.gd:1062).
- Talk refuses if any participant is in combat (talk_interaction.gd:24-29); Negotiate requires the actor IS in combat (negotiate_interaction.gd:35).
- `next_node_id` strings must match a node `id` in the same folder; unknown id at runtime = push_error + dead end (conversation.gd:389-398).
- Duplicate node ids: later file wins with a warning (dialogue_node_index.gd ~:65).
- No save during dialogue: `can_save` false in DIALOGUE/NEGOTIATION (save_manager.gd:292-302), so no save_state is needed - but LOAD is not gated (issue 1).

## Lifecycle
- **Begin**: interaction -> `Conversations.begin` sets current, connects, emits began, `c.start()` (conversations.gd:49-60); overlay opens only for `presentation == dialogue` (dialogue_overlay.gd:124-136), negotiation panel for negotiation.
- **Step**: `choose()` awaits `choice.resolve()` (conversation.gd:141-163) which may await dice (`show()` awaits `_wait_completed`, returns immediately with no presenter :304-310); `advance()` / `complete()` :168-185.
- **End**: `end()` (conversation.gd:190-202) -> changed -> Conversations clears current, emits ended -> overlay closes.
- **Combat start** (TriggerCombatEffect): does not end the conversation; relies on authored empty next id (trigger_combat_effect.gd:12-16).
- **Travel**: blocked while a conversation runs (world_manager.gd:258-272).
- **Save**: refused. **Load / new game**: not handled (issue 1).
- **Player abort**: none - Leave/History/Settings chips are stubs (dialogue_overlay.gd:103, :262-263); overlay `closes_on_cancel=false` (MainRoot.tscn:394-397).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | (a) `current` cleared only on end; load / new game mid-dialogue leaves it set forever. Path: Esc pushes esc_menu even over the overlay (ui_stack.gd:136-145, push ignores can_open :80-85) -> Load (esc_menu.gd:79-80) -> save_load_panel.gd:136 -> SaveManager.load_file (save_manager.gd:388, :405-427) -> discard_worlds (world_manager.gd:334-338, gated only by can_rebuild :292-293) -> world_loading + UIStack.close_all (:343-344, :381). Conversations never listens. Result: GameMode stuck DIALOGUE/NEGOTIATION, input_is_taken true (no new talk/stash), can_save false, can_travel false (world_manager.gd:258-272), can_switch_focus false (:1051-1056). new_game same path (save_manager.gd:540-564). Main-menu-from-Esc is refused mid-dialogue (esc_menu.gd:90-93). | conversations.gd:96-102 | CONFIRMED |
| 2 | (b) Data format: one .tres per node, choices as sub-resources with hand-typed `next_node_id` / `success_node_id` strings (e.g. data/dialogue/scared_townsperson/quest_details.tres:12, :25-26, :37). Mean 41 lines/node (not ~70), max 84 (scared_townsperson/quest_intro.tres), hub.tres 79. Lint runs only in debug builds, once per folder: dialogue dir at boot (conversations.gd:38-39, :110-115), negotiation dir at first negotiation (negotiate_interaction.gd:39). Release builds get runtime push_error + dead end (conversation.gd:393-397). | conversations.gd:110-115 | CONFIRMED (size overstated) |
| 3 | (b) No localization: all text inline English in .tres (quest_details.tres:14, :50) and code (shift_mood_effect.gd:32-38, negotiation_outcome_effect.gd:43, :75-85, dialogue_choice.gd:62, skill_check_choice.gd:29, conversation.gd:232); no tr()/TranslationServer in either folder. | as listed | CONFIRMED |
| 4 | Overlay keeps a stale `_conversation` connection after issue 1 (only cleared on ended). | dialogue_overlay.gd:114, :228-233 | NEW |
| 5 | Tree-wide cast: split-party members / leader in another resident world join the cast, affecting ParticipantPresentPrerequisite (participant_present_prerequisite.gd:34-35), assist bonuses (conversation.gd:334-341), gaze/staging, and Talk refusal when a member fights elsewhere (talk_interaction.gd:25-27). | talk_interaction.gd:70-74; unit_query.gd:135-140 | NEW |
| 6 | Index scans only `get_extension() == "tres"`; an export that converts text resources to binary yields `.remap` entries and the index may be empty. Unverified, export-only. | dialogue_node_index.gd ~:61 | NEW (unverified) |
| 7 | Per-node staged cutscenes are inert: `res://cinematics/dialogue_bindings.tres` does not exist; loaded only if present. | dialogue_staging.gd:48, :55-56 | NEW |
| 8 | No player-side exit from a conversation (stub chips, no cancel). A tree without a reachable end soft-locks input. | dialogue_overlay.gd:103, :262-263 | NEW |
| 9 | `is_repeatable` memory is per conversation; re-talking resets it unless authors also gate on a flag. | conversation.gd:89, :369 | NEW |
| 10 | Alignment tag applied to actor without validity check; dead-actor check only when dead_end_effect set. | dialogue_choice.gd:58, :74 | NEW |
| 11 | TriggerCombatEffect leaves the conversation running unless the author pairs it with an empty next id. | trigger_combat_effect.gd:12-16 | NEW |

## Tests
`tests/conversation/` (conversation_driver, a_check_waits_for_its_dice, a_conversation_opens_clean, a_conversation_walks_its_tree, a_demon_answers_in_turns, a_negotiation_opens_on_terms, every_negotiation_ends_somewhere, talking_needs_no_fight, the_authored_trees_hold [pins negotiation content], the_band_follows_the_conversation, the_demon_speaks_in_its_panel); `tests/dialogue/` (a_skill_shows_its_level, gaze_follows_the_speaker, the_band_leaves_the_world_alone, the_log_keeps_up, the_party_stays_reachable). Gaps: no test for load / new game mid-conversation (issue 1); no split-party cast test; no export-build index test.
