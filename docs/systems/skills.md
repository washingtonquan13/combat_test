# Skills

**Files:** `systems/skill_system/` (20 .gd, 578 lines): `skill.gd` (33), `skill_instance.gd` (32), `skill_calculator.gd` (96), `skill_database.gd` (57), `skill_check_result.gd` (38), `default_rule.gd` (18), `prerequisite_rule.gd` (28) + 13 prerequisite subclasses (`skill_`, `passive_skill_` (52), `attribute_`, `count_` (39), `flag_`, `gold_`, `negotiated_gold_`, `mood_`, `alignment_`, `item_owned_`, `advantage_`, `tag_`, `skill_category_prerequisite.gd`). Data: `data/skills/` (20 .tres, D&D-named skills plus two GURPS-Wildcard-style catch-alls: `basic_attack.tres` (DX, every attack) and `spellcasting.tres` (IQ, every spell; nothing reads it yet, it exists so spells have a home when they arrive)). Per-unit holder: `systems/unit_system/unit_skills.gd` (43, Unit doc); party snapshot record: `systems/party_system/party_skill_record.gd` (11).
**Autoloads owned:** none.

## Purpose
GURPS-style skills: a shared `Skill` definition (controlling attribute, difficulty, defaults, learned_only) (`skill.gd:14-33`), a per-unit `SkillInstance` Node holding levels purchased (`skill_instance.gd:22-32`), and a stateless `SkillCalculator` that returns the effective level with defaults and the Rule of 20 (`skill_calculator.gd:31-72`). `PrerequisiteRule` and subclasses are the boolean condition language reused by dialogue/negotiation (`prerequisite_rule.gd:17-28`). NOT responsible for: rolling (`Unit.roll_vs`), character-creation point buys (`character_creation.gd`), dialogue check flow (`conversation.gd:339-371`), saving (PartyManager).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Skill definitions | `data/skills/*.tres`, schema `skill.gd:21-33` | Static; referenced by `skill_name` |
| Unit's trained skills + levels | `SkillInstance` children of the unit's `Skills` node (`unit_skills.gd:26-35`, `skill_instance.gd:22,28`) | Party members only: `skills: [{skill_name, levels_purchased}]` (`party_manager.gd:513-518`) |
| Authored NPC/demon skills | `UnitDefinition.skills: Array[PartySkillRecord]` (`unit_definition.gd:161`) | Static data |
| Passive check results | FlagManager flag named by `PassiveSkillPrerequisite.flag_name` (`passive_skill_prerequisite.gd:46-51`) | Via FlagManager |

## Derived / cached state
Three representations of "a unit's skills" that must be copied by hand:
- `SkillInstance` nodes (runtime truth, `unit_skills.gd:30-35`);
- `PartyMemberData.skills` (`party_member_data.gd:86`), captured from instances at `party_manager.gd:396-400` and re-spawned into instances at `party_manager.gd:745-750`;
- `UnitDefinition.skills`, materialized into instances only when the scene's `Skills` node is empty (`unit.gd:1067-1084`).
- `SkillDatabase._catalog` caches the folder scan (`skill_database.gd:51-57`).

## Public surface
- **Calls in**
  - `SkillCalculator.get_skill_level(unit, name)` — `unit_combat.gd:178` ("Basic Attack" = to-hit), `detection_manager.gd:268` ("Stealth"), `conversation.gd:339,351`, `quick_contest_choice.gd:25`, `ui/party_overview.gd:325`, `skill_prerequisite.gd:15`, `passive_skill_prerequisite.gd:49`.
  - `SkillDatabase.find(name)` — `skill_calculator.gd:36`, `party_manager.gd:668`, `character_creation.gd:434`. `get_all()` — UI lists.
  - `PrerequisiteRule.is_satisfied(unit)` / `is_satisfied_in(conversation)` — `conversation.gd:371` (choice prerequisites).
- **Signals out:** none. **Signals in:** none.

## Depends on
- `Unit.get_attribute_value` (`skill_calculator.gd:42,85`, `attribute_prerequisite.gd:11`), `Unit.get_skills` (`skill_calculator.gd:93`), `Unit.roll_vs` (`passive_skill_prerequisite.gd:50`), `alignment_category/tendency_category` (`alignment_prerequisite.gd:30`).
- `FlagManager` — `flag_prerequisite.gd:22`, `passive_skill_prerequisite.gd:46-51`.
- `CurrencyManager.has_gold` — `gold_prerequisite.gd:16`, `negotiated_gold_prerequisite.gd:19`.
- `Conversation.cast/vars/rng` — `prerequisite_rule.gd:28`, `mood_prerequisite.gd:21`, `passive_skill_prerequisite.gd:42`.
- `PartyManager.inventory` (ItemContainer) for inventory — `item_owned_prerequisite.gd`.
- `ResourceCatalog` — `skill_database.gd:56`.

## Assumptions and invariants
- `skill_name` is the identity everywhere: DB key (`skill_database.gd:55`), instance lookup (`skill_calculator.gd:94`), save key (`party_manager.gd:516,668`), default sources (`default_rule.gd:17`), prerequisite fields (`skill_prerequisite.gd:10`, `passive_skill_prerequisite.gd:31`), dialogue exports (`skill_check_choice.gd:14`, `quick_contest_choice.gd:12-13`), and code literals ("Basic Attack" `unit_combat.gd:178`, "Stealth" `detection_manager.gd:268`).
- Default chains go at most one level deep (`MAX_DEFAULT_DEPTH = 1`, `skill_calculator.gd:23,32`), so cycles are cut off rather than detected.
- Relative level = attribute + difficulty + (levels - 1) (`skill_instance.gd:31-32`); defaults cap the source at 20 before the modifier (`skill_calculator.gd:28,55`).
- Every `SkillInstance` has non-null `skill_data` (`skill_calculator.gd:94` dereferences without a check).
- A passive check is rolled once and then frozen in a flag forever (`passive_skill_prerequisite.gd:46-51`); an empty `flag_name` would make every such check share the key `""`.

## Lifecycle
- `SkillInstance` nodes are created with the unit scene, from `UnitDefinition.skills` (`unit.gd:1067-1084`), or from a party record at spawn (`party_manager.gd:745-750`); freed with the unit.
- Save: party members only, by name (`party_manager.gd:513-518`). Load: `SkillDatabase.find(skill_name)`, unknown names silently skipped (`party_manager.gd:668-670`, no warning, unlike abilities at `:654`). Non-party units are rebuilt from their definition.
- No behavior on combat start/end, travel, cutscene. Dialogue reads skills through prerequisites/checks only.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | No stable skill id: `SkillDatabase` and `SkillCalculator` key on `skill_name` display text; saves store it; renaming a skill silently drops it from loaded party members and breaks the code literals "Basic Attack"/"Stealth" (Basic Attack falling to default changes every to-hit) | `skill_database.gd:30,55`; `skill_calculator.gd:94`; `party_manager.gd:516,668-670`; `unit_combat.gd:178`; `detection_manager.gd:268` | CONFIRMED |
| 2 | Duplicate `skill_name` resolves to the LAST loaded file (`find_first_wins=false`), the opposite policy from AbilityDatabase | `skill_database.gd:56`; `resource_catalog.gd:157-161`; `ability_database.gd:52` | NEW |
| 3 | Exported builds: `handle_remap=false`, so `.tres.remap` skills are invisible; `find()` returns null for every saved/defaulted skill | `skill_database.gd:56`; `resource_catalog.gd:21-27,142-145` | NEW |
| 4 | `Skill.prerequisites` is exported but never evaluated anywhere (only `learned_only` is read) | `skill.gd:31`; only `.prerequisites` reader is `conversation.gd:371` (choices) | NEW |
| 5 | `AdvantagePrerequisite`, `TagPrerequisite`, `SkillCategoryPrerequisite` have no `is_satisfied`; the base pushes an error and returns false | `advantage_prerequisite.gd:9-11`, `tag_prerequisite.gd:11-12`, `skill_category_prerequisite.gd:9-10`; `prerequisite_rule.gd:17-19` | NEW (documented stubs) |
| 6 | `ItemOwnedPrerequisite` reads inventory from the PartyOverview UI node via a group lookup; false if the UI is not in the tree | `item_owned_prerequisite.gd` | FIXED (reads PartyManager.inventory) |
| 7 | Three hand-synced copies of a unit's skills (instances, PartyMemberData, UnitDefinition) | `party_manager.gd:396-400,745-750`; `unit.gd:1067-1084` | NEW |
| 8 | Unknown skill on load is skipped with no warning | `party_manager.gd:668-670` vs `:654` | NEW (minor) |

## Tests
- `tests/dialogue/test_a_skill_shows_its_level.gd` (level display via calculator).
- `tests/conversation/conversation_driver.gd` drives skill checks/prerequisites.
- Combat/AI tests exercise "Basic Attack" indirectly through `attack_skill()`.
- Gaps: no direct test of default resolution, Rule of 20, learned_only, depth cutoff, rename/save safety, or prerequisite stubs.
