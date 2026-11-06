# Factions, flags and quests

**Files:** `systems/faction_system/faction_relations.gd` (180, autoload); `systems/flag_system/flag_manager.gd` (90, autoload); `systems/quest_system/` — `quest.gd` (56), `quest_database.gd` (58, static), `quest_stage.gd` (18). Data: `data/quests/scared_townsperson_raids.tres`. AreaState (`systems/world_system/area_state.gd`) stores inside FlagManager.
**Autoloads owned:** `FactionRelations`, `FlagManager`.

## Purpose
FactionRelations answers "is faction A hostile to B" with a saved base table plus temporary combat hostility. FlagManager is a flat string-keyed world-state dictionary (dialogue, cinematics, passive checks, AreaState records). Quests are read-only views that derive progress from flags. None of these own combat start/end, dialogue flow, or journal UI (party_overview.gd:390-430).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Base relations | faction_relations.gd:41 | Yes `factions` (:78, :140-141) |
| Temporary hostility (escalations) | faction_relations.gd:42 | No (:135-139) |
| Authored defaults | faction_relations.gd:54 (empty) | n/a |
| Flags (incl. `areastate/` records) | flag_manager.gd:24 | Yes `flags` (:45, :53-58) |
| Quest definitions | data/quests/*.tres via quest_database.gd:26-58 | No (authored) |

## Derived / cached state
- Quest stage/started/complete derived from `FlagManager.has_flag` at read time (quest.gd:29-56). No stored quest state.
- QuestDatabase caches the scan in a static ResourceCatalog (quest_database.gd:28, :52-58).
- AreaState records are flags under a reserved prefix (area_state.gd:7-8, :38-73).
- PassiveSkillPrerequisite caches a roll result as a flag (passive_skill_prerequisite.gd:45-51).

## Public surface
- **Calls in:** `FactionRelations.get_relation` :91 (AI, detection, Unit hostility), `set_relation` :102 (no callers), `escalate` :116-120 (unit_combat.gd:464, trigger_combat_effect.gd:28). `FlagManager.set_flag` :65 (dialogue_choice.gd:65, cinematic_cues.gd:74, passive_skill_prerequisite.gd:51, area_state.gd:39/53, test_arena.gd:111), `get_flag` :69, `has_flag` :73, `clear_flag` :77 and `get_flag_names_with_prefix` :85 (only area_state.gd:72-73). `QuestDatabase.find/get_all/refresh` :32-49 (party_overview.gd:394).
- **Signals out:** FactionRelations signals (faction_relations.gd:37-39). FlagManager: none. Quests: none.
- **Signals in:** FactionRelations ← `CombatManager.combat_ended` (faction_relations.gd:58).

## Depends on
- SaveManager.register `&"factions"` (faction_relations.gd:78), `&"flags"` (flag_manager.gd:45).
- CombatManager.combat_ended, relayed for every encounter (combat_manager.gd:383, :404).
- Quest → FlagManager (quest.gd:32).

## Assumptions and invariants
- `_on_combat_ended` clears ALL temporary hostility when any encounter ends (faction_relations.gd:123-132). Encodes "only one fight at a time". **STALE**: encounters are per-instance and CombatManager relays each one's end globally (combat_manager.gd:383-405).
- Temporary hostility not saved because saves can't happen in combat (faction_relations.gd:135-139). **STALE**: combat saves allowed (save_manager.gd:292-302).
- Unlisted faction pair → HOSTILE (faction_relations.gd:91); `neutral` is a wildcard (:35, :89-90). Base table is never seeded (:54), so player/enemy hostility relies on the default.
- Quest stages are linear and positional; flags are assumed never cleared once set (quest.gd:37-42). Stage reached = `has_flag`, not truthy value (quest.gd:32).
- FlagManager has no namespacing beyond convention; the `areastate/` prefix is reserved by convention only.

## Lifecycle
Autoloads, permanent. New game: `load_state({})` empties flags (quests, cinematic play-once flags and AreaState go with it, save_manager.gd:620-630) and base relations; `_temporary_hostile` is not touched by load (faction_relations.gd:161-176). Load: flags replaced wholesale, no signal (flag_manager.gd:57-58). Combat: `escalate` on hostile action; any encounter end clears all. Dialogue/cinematics write flags.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Any encounter's end clears all temporary hostility, including other running fights | faction_relations.gd:123-132; combat_manager.gd:383, :404 | CONFIRMED |
| 2 | Temporary hostility not saved despite combat saves | faction_relations.gd:135-141; save_manager.gd:292-302 | CONFIRMED |
| 3 | `load_state` leaves stale `_temporary_hostile` from the previous game | faction_relations.gd:161-176 | CONFIRMED |
| 4 | Base table never seeded; unlisted pairs hostile; `set_relation` has no callers | faction_relations.gd:54, :91, :102 | CONFIRMED |
| 5 | FlagManager `load_state` emits no change signal (none exist) | flag_manager.gd:57-58 | CONFIRMED |
| 6 | Quests cannot fail or branch; strictly linear stage list | quest.gd:23, :43-56; quest_stage.gd:17-18 | CONFIRMED |
| 7 | A flag set to `false` counts as a reached quest stage (has_flag) — passive checks write false | quest.gd:32; passive_skill_prerequisite.gd:51 | NEW |
| 8 | Quest completion for the one quest is hardcoded in an area script by kill count | test_arena.gd:105-111 | NEW |
| 9 | AreaState shares the flag namespace; any flag starting `areastate/` is cleared by `clear_area` | area_state.gd:70-73 | NEW (latent) |

## Tests
Factions: tests/detection/test_join_leave_combat.gd, tests/world/test_a_new_game_is_new.gd (relation reset). Flags: conversation suites (test_a_conversation_walks_its_tree.gd, test_a_negotiation_opens_on_terms.gd), tests/cinematic/test_new_callers_cost_nothing.gd, persistence suites. Quests: no tests. Gaps: no test for two concurrent encounters and escalation, no test of escalation across a combat save.
