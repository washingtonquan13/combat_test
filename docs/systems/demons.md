# Demons

**Files:** `systems/demon_system/` — `demon_roster.gd` (155, autoload), `demon_compendium.gd` (95, autoload), `fusion_ritual.gd` (158), `fusion_calculator.gd` (37), `fusion_chart.gd` (25), `fusion_greetings.gd` (30), `fusion_recipe.gd` (11), `owned_demon.gd` (29), `demon_database.gd` (69), `spawnable_unit_database.gd` (77), `unit_definition.gd` (215). UI: `ui/fusion_menu.gd`, `ui/compendium_menu.gd`, `ui/demon_compendium_panel.gd`. Summon effect: `summon_demon_effect.gd`.
**Autoloads owned:** `DemonRoster`, `DemonCompendium`.

## Purpose
Owns which demons the player has recruited (stock), which species are registered in the Compendium and their re-summon cost, and fusion of two owned demons into a new one. NOT responsible for a fielded demon's live combat state (that is a Unit), for negotiation (dialogue/negotiation outcome effects call `recruit`), or for party membership (summons are refused by PartyManager.add_member, party_manager.gd:235).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Owned demons list | demon_roster.gd:27 | Yes `demons` (:125-138) |
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
- **Signals in:** none. Death reaches OwnedDemon by direct write in unit_combat.gd:670-676.

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
Autoloads, permanent. New game: `load_state({})` clears both (save_manager.gd:540-627). Summon: summon_demon_effect.gd:29-76 sets `has_been_summoned` (:76). Death in combat: `is_dead = true`, not released (unit_combat.gd:670-676). Travel: fielded demons synced and expired (world_manager.gd:1169-1175). Fusion: release + recruit then cutscene (fusion_ritual.gd:97-103). Save/load: five fields per demon; load emits nothing for the roster (:141-155).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Fielded demons dropped from combat saves | demon_roster.gd:20-25; encounter.gd:145-162 | CONFIRMED |
| 2 | OwnedDemon has no level/XP/learned abilities; Compendium records species only | owned_demon.gd:19-29; demon_compendium.gd:12-16 | CONFIRMED |
| 3 | DemonRoster `load_state` emits no signal (roster has no signals at all) | demon_roster.gd:141-155 | CONFIRMED |
| 4 | `is_dead` is never cleared: no revive path for owned demons | unit_combat.gd:670-676; no other writer | NEW |
| 5 | Dead demons can be fused: fusion menu checks only `is_fielded` | ui/fusion_menu.gd:168-175 | NEW |
| 6 | Compendium register accepts dead demons (no dead check) | compendium_menu.gd:243 | NEW |
| 7 | Stale "no save system yet" header | demon_roster.gd:9-10 | NEW |
| 8 | Fielded hp/fp duplicated into Unit; only written back on travel, not on save mid-fight | summon_demon_effect.gd:63-66; world_manager.gd:1169-1175 | NEW |

## Tests
tests/world/test_the_fusion_menu.gd, test_the_compendium_menu.gd, test_the_cathedral_is_a_room_not_a_menu.gd, tests/cinematic/test_fusion_plays_without_dialogue.gd, tests/conversation/test_every_negotiation_ends_somewhere.gd (recruit), and persistence suites (test_persistence_is_a_registry.gd, test_load_restores_every_area.gd, test_a_new_game_is_new.gd). Gaps: no test for dead-demon fusion/summon, no test for summons across a combat save.
