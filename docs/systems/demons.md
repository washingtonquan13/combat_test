# Demons

**Files:** `systems/demon_system/` — `demon_roster.gd` (151, autoload), `demon_compendium.gd` (95, autoload), `fusion_ritual.gd` (158), `fusion_calculator.gd` (37), `fusion_chart.gd` (25), `fusion_greetings.gd` (30), `fusion_recipe.gd` (11), `owned_demon.gd` (49), `demon_database.gd` (69), `spawnable_unit_database.gd` (77), `unit_definition.gd` (252). UI: `ui/fusion_menu.gd`, `ui/compendium_menu.gd`, `ui/demon_compendium_panel.gd`. Summon effect: `summon_demon_effect.gd`.
**Autoloads owned:** `DemonRoster`, `DemonCompendium`.

## Purpose
Owns which demons the player has recruited (stock), which species are registered in the Compendium and their re-summon cost, and fusion of two owned demons into a new one. NOT responsible for a fielded demon's live combat state (that is a Unit), for negotiation (dialogue/negotiation outcome effects call `recruit`), or for party membership (summons are refused by PartyManager.add_member, party_manager.gd:235).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Owned demons list | demon_roster.gd:27 | Yes `demons` (`save_state` :123-135) |
| Per demon: species, `stats` (pool currents; empty = full), has_been_summoned, is_dead | owned_demon.gd | Yes |
| max_active_summons (default) | demon_roster.gd:35, :44 | Yes (in `demons`) |
| Compendium registered species | demon_compendium.gd:32 | Yes `compendium` (:42) |
| Species definitions | res://data/units/demons/ via demon_database.gd:32-53 | No (authored data) |

## Derived / cached state
- `is_fielded` is a global scan of live units, not stored (demon_roster.gd:108-112).
- A summoned Unit takes `stats_from_dict(owned.stats)` at summon (summon_demon_effect.gd); during the fight the Unit is the truth, synced back by `capture_pools` only on dismiss and `_dismiss_fielded_demons` (world_manager.gd). Two truths while fielded.
- Compendium cost is derived, 50 x rank^2 (demon_compendium.gd:28, :59-60).
- `ui/demon_compendium_panel.gd:59-70` reads the roster once per refresh; no signal to refresh on change.

## Public surface
- **Calls in:** `DemonRoster.recruit` :72-78 (negotiation_outcome_effect.gd:74, compendium summon, fusion, debug panel demon_compendium_panel.gd:182), `release` :84 (fusion, panel :165), `is_owned` :88, `is_fielded` :108, `all_owned` :117. `DemonCompendium.register` :47-52 (compendium_menu.gd:243), `why_not_summon` :64-69, `summon` :74-79. `FusionRitual.preview` :72-78, `perform` :88-110 (ui/fusion_menu.gd). `FusionCalculator` :13-37. `DemonDatabase.find/get_all/members_of_order` :32-53.
- **Signals out:** `DemonCompendium.changed` :24 (also on load :88-95). DemonRoster has no signals.
- **Signals in:** none. Death reaches OwnedDemon by direct write in unit_combat.gd:1498-1502 (`_die`).

## Depends on
- SaveManager.register `&"demons"` (demon_roster.gd:66-67), `&"compendium"` (demon_compendium.gd:42).
- CurrencyManager.has_gold/spend_gold (demon_compendium.gd:64-79).
- CinematicDirector.play for fusion (fusion_ritual.gd:101-103).
- UnitQuery `all_units_near` for summon cap (summon_demon_effect.gd:48-55).
- WorldManager `_dismiss_fielded_demons` on travel (world_manager.gd:409, :1169-1175).

## Assumptions and invariants
- `demon_roster.gd:9-10` says there is no save system yet. **STALE** (it registers at :66-67).
- `demon_roster.gd:20-25` accepts that fielded demons are not re-summoned on load because `can_save` excludes combat. **STALE**: combat saves are allowed (save_manager.gd:292-302); Encounter saves turn_order ids (encounter.gd:145-162) but the summoned Unit is never respawned.
- Fusion consumes exactly two owned, non-fielded demons (fusion_ritual.gd:97-99); tie in rank average resolves to lower rank (fusion_calculator.gd:13-37).
- Demons have no identity beyond the OwnedDemon object; no id field (owned_demon.gd:19-29).

## Lifecycle
Autoloads, permanent. New game: `load_state({})` clears both (save_manager.gd:540-627). Summon: summon_demon_effect.gd:29-76 sets `has_been_summoned` (:76). Death in combat: `is_dead = true`, not released (unit_combat.gd:1498-1502 (`_die`)). Travel: fielded demons synced and expired (world_manager.gd:1169-1175). Fusion: release + recruit then cutscene (fusion_ritual.gd:97-103). Save/load: five fields per demon; load emits nothing for the roster (:141-155).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Fielded demons dropped from combat saves | demon_roster.gd:20-25; encounter.gd:145-162 | CONFIRMED; review 11-15: still open |
| 2 | OwnedDemon has no level/XP/learned abilities; Compendium records species only | owned_demon.gd:19-29; demon_compendium.gd:12-16 | CONFIRMED |
| 3 | DemonRoster `load_state` emits no signal (roster has no signals at all) | demon_roster.gd:138-151 | CONFIRMED |
| 4 | `is_dead` is never cleared: no revive path for owned demons | unit_combat.gd:1498-1502 (`_die`); no other writer | NEW; review 11-15: still open, see DLG-18 |
| 5 | Dead demons can be fused: fusion menu checks only `is_fielded` | ui/fusion_menu.gd:169 | NEW; review 11-15: still open, see DLG-18 |
| 6 | Compendium register accepts dead demons (no dead check) | compendium_menu.gd:243 | NEW; review 11-15: still open, see DLG-18 |
| 7 | Stale "no save system yet" header | demon_roster.gd:9-10 | NEW; review 11-15: still open (stale header, see DLG-19) |
| 8 | Fielded hp/fp duplicated into Unit; only written back on travel, not on save mid-fight | summon_demon_effect.gd:63-66; world_manager.gd:1169-1175 | NEW; review 11-15: still open |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| DLG-15 | The demon system reaches up into the interaction system to find its own trees: `UnitDefinition` uses `NegotiateInteraction.CONVERSATIONS_DIR`, and `dialogue_options` has no matching directory constant. | unit_definition.gd:204-208, :174; negotiate_interaction.gd | The directory constant was left in the first place that needed it. | The directory is a constant in `systems/negotiation_system/` and both read it. | R4 | S | LEFTOVER |
| DLG-16 | Recruit, heal and flee remove the demon by `expire()` inside a dialogue effect, while it is still in `c.cast` and held by presenters. Safe only because `end()` follows in the same call; it breaks if anything awaits between (a spoken farewell, a cutscene on recruit). | negotiation_outcome_effect.gd:72-83, :91, :63-67 | The effect concludes the demon and the conversation in one synchronous call. | `conclude` ends the conversation first and expires the demon on `ended`. | R5 | S | INTENTIONAL; document why: synchronous expire-then-end, with the reason in the comment at negotiation_outcome_effect.gd:63-67 |
| DLG-17 | Two databases answer "which species has this id", and only one works in an export. DemonDatabase passes `handle_remap` false, so in an export the compendium lists nothing and every fusion finds no candidates (the roster loads through SpawnableUnitDatabase). Unverified (no export run). | demon_database.gd:68; spawnable_unit_database.gd:76; resource_catalog.gd:21-27, :142-145; fusion_calculator.gd:19; compendium_menu.gd:113; demon_compendium_panel.gd:170 | The catalog refactor kept each database's old behaviour "since that's a behaviour change", and `project.godot` leaves text-to-binary conversion on, so exported `.tres` are `.tres.remap`. | ResourceCatalog always strips `.remap` (no option), and DemonDatabase becomes a filter over SpawnableUnitDatabase instead of a second scan. | R6 | S | DECISION NEEDED: the `handle_remap` deferral is documented in the catalog header; keep it, or fix now since in an export it makes the compendium and fusion empty? |
| DLG-18 | Dead demons are never revived, still fusable and still registrable. The only writer of `is_dead` is `_die`; the fusion menu checks only `is_fielded`; the compendium has no dead check; summon paths do check. | unit_combat.gd:1502; owned_demon.gd:29-31; fusion_menu.gd:169; compendium_menu.gd; summon_demon_effect.gd:33; dock_slot.gd:326 | `is_dead` was added with a "revive later" comment and no shared predicate. | `OwnedDemon.is_usable()` (alive and not fielded) asked by all four callers, plus the revive path the comment promises (Cathedral, gold). | R4 | S (predicate), M (revive) | KNOWN (rows 4-6) |
| DLG-19 | Demon headers describe a project without saves or progression: "no save system yet", "can_save only allows EXPLORATION/OVERWORLD", "no progression/XP system yet". Rows 1 and 8 are unchanged in code. | demon_roster.gd:9-10, :19, :67, :23-25, :40-43; project.godot:40 | Comments were not updated when save and Progression were added. | Rewrite the headers; row 1 is the real work. | - | S (comments), L (row 1) | LEFTOVER |
| DLG-20 | `UnitDefinition.resolved_ai_smartness` cannot tell an authored default from unset, and a comment block above `@export_group("Character")` describes something else. | unit_definition.gd:236-239, :148-154 | A sentinel default doubles as "unset", and the comment was left behind when fields moved. | A real unset marker (or a nullable) for the smartness, and move the comment to the field it describes. | - | S | DECISION NEEDED: is the sentinel default for `ai_smartness` intended, or should unset be distinguishable? |
| WLD-14 | same as DLG-17 (demons.md) for the DemonDatabase half | | | | R6 | | see world.md |

Review 11-15 notes added to the body: `UnitDefinition.level` feeds XP (encounter.gd:600 -> progression.gd:89-90), while demons receive no progression; DemonDatabase has no `.remap` handling (DLG-17). Header line counts and the `unit_combat.gd`, `fusion_menu.gd` and roster `save_state`/`load_state` references above were corrected in place.

## Tests
tests/world/test_the_fusion_menu.gd, test_the_compendium_menu.gd, test_the_cathedral_is_a_room_not_a_menu.gd, tests/cinematic/test_fusion_plays_without_dialogue.gd, tests/conversation/test_every_negotiation_ends_somewhere.gd (recruit), and persistence suites (test_persistence_is_a_registry.gd, test_load_restores_every_area.gd, test_a_new_game_is_new.gd). Gaps: no test for dead-demon fusion/summon, no test for summons across a combat save.
