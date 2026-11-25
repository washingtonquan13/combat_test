# Factions, flags and quests

**Files:** `systems/faction_system/faction_relations.gd` (177, autoload); `systems/flag_system/flag_manager.gd` (96, autoload); `systems/quest_system/` — `quest.gd` (56), `quest_database.gd` (58, static), `quest_stage.gd` (18). Data: `data/quests/scared_townsperson_raids.tres`. AreaState (`systems/world_system/area_state.gd`) stores inside FlagManager.
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
- **Calls in:** `FactionRelations.get_relation` :91 (AI, detection, Unit hostility), `set_relation` :102 (no callers), `escalate` :116-120 (unit_combat.gd:464, trigger_combat_effect.gd:28). `FlagManager.set_flag` :65 (dialogue_choice.gd:65, cinematic_cues.gd:74, passive_skill_prerequisite.gd:51, area_state.gd:39/53, world/goblin_quarry.gd:84-92 and 174-180); music cues also read flags through `FlagManager.has_flag` (music_manager.gd:339), `get_flag` :69, `has_flag` :73, `clear_flag` :77 and `get_flag_names_with_prefix` :85 (only area_state.gd:72-73). `QuestDatabase.find/get_all/refresh` :32-49 (party_overview.gd:394).
- **Signals out:** FactionRelations signals (faction_relations.gd:37-39). FlagManager: `flag_changed(flag_name)` (flag_manager.gd:26), raised by `set_flag`/`clear_flag` and not by `load_state`; listeners are `music_manager.gd:121` (music cues read flags) and `goblin_quarry.gd:165`. Quests: none.
- **Signals in:** FactionRelations ← `CombatManager.combat_ended` (faction_relations.gd:58).
- **Quest content (Scared Townsperson):** the raiders are human bandits led by a captain (data/units/npcs/bandit_*.tres, fight-only); quest text in data/quests/scared_townsperson_raids.tres and data/dialogue/townsperson.dlg. Flags and node names still say goblin, see CINE-18 (cinematics.md).

## Depends on
- SaveManager.register `&"factions"` (faction_relations.gd:78), `&"flags"` (flag_manager.gd:45).
- CombatManager.combat_ended, relayed for every encounter (combat_manager.gd:383, :404).
- Quest → FlagManager (quest.gd:32).

## Assumptions and invariants
- `_on_combat_ended` clears ALL temporary hostility when any encounter ends (faction_relations.gd:123-132). Encodes "only one fight at a time". **STALE**: encounters are per-instance and CombatManager relays each one's end globally (combat_manager.gd:383-405).
- Temporary hostility not saved because saves can't happen in combat (faction_relations.gd:135-139). **STALE**: combat saves allowed (save_manager.gd:292-302).
- Unlisted faction pair → HOSTILE (faction_relations.gd:91); `neutral` is a wildcard (:35, :89-90). The base table has one authored pair, `townsfolk` vs player = ALLIED (faction_relations.gd:58), seeded in code and kept across loads (:159-160); the player/enemy hostility still relies on the default. This is deliberate: the Town Watchman had to be allied and there was no data file for relations (6f345c96, comment :54-57 "Authored seed").
- Quest stages are linear and positional; flags are assumed never cleared once set (quest.gd:37-42). Stage reached = `has_flag`, not truthy value (quest.gd:32).
- FlagManager has no namespacing beyond convention; the `areastate/` prefix is reserved by convention only.

## Lifecycle
Autoloads, permanent. New game: `load_state({})` empties flags (quests, cinematic play-once flags and AreaState go with it, save_manager.gd:620-630) and base relations; `_temporary_hostile` is not touched by load (faction_relations.gd:161-176). Load: flags replaced wholesale, no signal (flag_manager.gd:57-58). Combat: `escalate` on hostile action; any encounter end clears all. Dialogue/cinematics write flags.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Any encounter's end clears all temporary hostility, including other running fights | faction_relations.gd:123-132; combat_manager.gd:383, :404 | CONFIRMED; review 11-15: still open, see C-8 (faction_relations.gd:128-132; relay lines now combat_manager.gd:393, :414; comment :123-127 still says one combat at a time). Break sequence: the party provokes neutral villagers in world 1, a goblin-vs-wolf fight in world 2 ends, `_temporary_hostile.clear()` runs, and the world 1 fight sees no hostile pair and ends as if won. Sustainable fix: the escalation belongs to the fight: `Encounter` holds `provoked_pairs` and `is_temporary_hostile` is answered from running encounters (or FactionRelations keeps `pair -> Array[Encounter]` and removes an encounter's pairs on that encounter's end), so `Encounter.save_state` carries it and load clears it for free (fixes rows 2 and 3 too). Size M, root R1 |
| 2 | Temporary hostility not saved despite combat saves | faction_relations.gd:135-141; save_manager.gd:292-302 | CONFIRMED; review 11-15: still open (the code comment now admits it, faction_relations.gd:135-139), see C-8 |
| 3 | `load_state` leaves stale `_temporary_hostile` from the previous game | faction_relations.gd:161-176 | CONFIRMED; review 11-15: still open (`load_state` now :157-173), see C-8 |
| 4 | Base table never seeded; unlisted pairs hostile; `set_relation` has no callers | faction_relations.gd:54, :91, :102 | PARTLY WRONG: "base table never seeded" is false (one pair is seeded in code, faction_relations.gd:58, see C-2); "unlisted pairs hostile" and "`set_relation` has no callers" are still true (:91, :102), confirmed by review 11-15 |
| 5 | FlagManager `load_state` emits no change signal (none exist) | flag_manager.gd:57-58 | HALF FIXED: a change signal exists (`flag_changed`, flag_manager.gd:26); `load_state` (:61-62) still emits nothing, by stated design (:24-25); review 11-15, see C-16 |
| 6 | Quests cannot fail or branch; strictly linear stage list | quest.gd:23, :43-56; quest_stage.gd:17-18 | CONFIRMED |
| 7 | A flag set to `false` counts as a reached quest stage (has_flag) — passive checks write false | quest.gd:32; passive_skill_prerequisite.gd:51 | NEW |
| 8 | Quest completion for the one quest is hardcoded in an area script by kill count | world/goblin_quarry.gd:84-92 (moved from test_arena.gd:105-111) | NEW; review 11-15: still open, see C-17. A second flag chain (`goblin_raid.begun`/`raid_played`/`broken`, goblin_quarry.gd:21-23) drives the raid and the music cues and had no doc |
| 9 | AreaState shares the flag namespace; any flag starting `areastate/` is cleared by `clear_area` | area_state.gd:70-73 | NEW (latent) |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| C-2 | The one authored faction relation is hard-coded in the autoload: `_base[townsfolk|player] = ALLIED`. The header still says the base layer is authored "via set_relation()", which has no caller. Any pair not written is HOSTILE, so `townsfolk` vs any future third faction is hostile by default. | faction_relations.gd:58-59, 9-10, 91, 102, 159-160 | 6f345c96: the watchman had to be allied and there was no data file for relations. | A `FactionTable` resource (`data/factions/relations.tres`: rows of faction_a, faction_b, tier) loaded in `_ready` into `_base` and `_authored_defaults`; the merge logic at :157-161 is already the right load rule. | R8 | S-M | INTENTIONAL; document why: allied watchman seeded in code, no relations data file yet (6f345c96) |
| C-8 | Same defect as #1 above (any fight ending clears every temporary hostility), with #2 and #3 as its save/load sides. Detail and fix are in row 1's status. | faction_relations.gd:128-132, 157-173 | Escalation is global, not per fight. | See #1. | R1 | M | KNOWN (#1) |
| C-16 | `flag_changed` is the only change signal and a load does not raise it: every flag listener needs a live path and a load path (`music_manager.gd:117-121` and `goblin_quarry.gd:165-166, 189-198` each hand-roll theirs), a third listener that forgets silently keeps pre-load state, and `set_flag` emits even when the value did not change (AreaState writes flags constantly, so the music manager keeps a filter set). | flag_manager.gd:26, 61-62, 69-71, 84; music_manager.gd:97-99, 117-121; goblin_quarry.gd:165-166, 189-198 | 2be9e020 added the signal for music cues only. | Emit only on a real change; add `flags_reloaded` emitted by `load_state` (or emit `flag_changed` for each differing key, as `FactionRelations.load_state` does for relations, :162-173); move `areastate/` out of the flag dictionary (#9) so listeners need no filter. | - | S-M | INTENTIONAL; document why: music follows story state, signal added for music cues only and load answered by `SaveManager.load_finished` (2be9e020) |
| C-17 | Quest completion and raid progress are flags set by an area script counting deaths: `townsperson_raids_resolved` is set when a hand-built list of goblinoids is empty, and RAID_BROKEN likewise. A goblin killed while the area is not loaded is handled only because the script re-derives the list on load. Each new "kill these" objective will copy this. This is #8 above, grown a sibling. | world/goblin_quarry.gd:84-92, 174-180; data/quests/scared_townsperson_raids.tres:13; quest.gd:28-33 | First quest content written as an area script (memory: quest failure refactor deferred to the second quest). | A data objective in quest_system: `QuestStage.condition` (e.g. `UnitsRemoved(area_id, persistent_ids)`) evaluated from AreaState's removed records, which already persist; no area script, no death signals. | R7, R8 | M | INTENTIONAL; document why: POC story wiring in the area script (goblin ambush 6f345c96; raid 1515bdab, 14cb4ad9) |
| CINE-6 | same as C-17 (factions_flags_quests.md): the quarry script counts kills and sets the quest flags | goblin_quarry.gd:21-52 | | | R7 | | see cinematics.md |

## Tests
Factions: tests/detection/test_join_leave_combat.gd, tests/world/test_a_new_game_is_new.gd (relation reset). Flags: conversation suites (test_a_conversation_walks_its_tree.gd, test_a_negotiation_opens_on_terms.gd), tests/cinematic/test_new_callers_cost_nothing.gd, persistence suites. Quests: no tests. Gaps: no test for two concurrent encounters and escalation, no test of escalation across a combat save.
