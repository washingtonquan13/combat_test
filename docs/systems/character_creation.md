# Character Creation

**Files:** `systems/character_creation_system/character_creation.gd` 795, `point_buy_table.gd` 55, `character_creation.tscn`, `point_buy_row.tscn`; `mockup/wizard_mockup.gd` 77 + `wizard_mockup.tscn` + `wizard_theme.tres` (static level-up mockup, not wired; the real level-up is a mode of character_creation.gd, see Progression below); data `data/character_creation/attribute_costs.tres`, `skill_costs.tres`.
**Autoloads owned:** none (UIScreen node `CharacterCreation` under MainRoot CanvasLayer, MainRoot.tscn:414-418)

## Purpose
Point-buy screen for the player character: attributes and skills bought from cost tables, a portrait picked from a folder, derived stats previewed, then a `PartyMemberData` record handed to PartyManager as the pending leader and the game travels to the start area. It does NOT spawn the unit (`StartingParty` does, systems/party_system/starting_party.gd:52-54), or persist anything itself. It also has a level-up mode (see Progression).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Attribute values, skill values, selected portrait | character_creation.gd:127-143 | No (screen-local) |
| Cost tables (min/max/default/pool, cost dict) | point_buy_table.gd:21-28; data/character_creation/*.tres | Content |
| Built leader record (handoff) | written to PartyManager.pending_leader (character_creation.gd:445; party_manager.gd:88) | No - consumed by StartingParty (:679 sets it), then persisted as the leader's party data by the party system |

## Derived / cached state
- Remaining points / affordability computed from tables (character_creation.gd:159-166 and the cost rows); attribute rows from `StatDatabase.get_bought()`; derived-stat preview via `StatDatabase.value_of` (`_preview_value`); the record carries a `stats` dict.
- Skill rows built once from SkillDatabase in `_ready` (:159-166); portrait grid built once from disk (:172, :533-559).
- `PartyManager.pending_leader` is a cache between this screen and `StartingParty.bootstrap` (starting_party.gd:52-54).

## Public surface
- **Calls in**: main_menu.gd:85-89 Start -> `SaveManager.new_game()` then push `character_creation`; `reset()` (character_creation.gd:197-222) from visibility_changed and SaveManager.new_game_started (:185-186); tests call `reset()` (tests/world/test_a_new_game_is_new.gd:358-359).
- **Signals out**: none.
- **Signals in**: `visibility_changed` (:152), `SaveManager.new_game_started` (:185-186).

## Depends on
- SkillDatabase (character_creation.gd:139-141), StatDatabase (stats.md), PartyManager.pending_leader (:679), WorldManager.travel_area (:685), SaveManager signal (:185-186), UIStack back to main_menu (:788-795), DirAccess on `res://assets/portraits/` (:533-559).
- GameMode reports CHARACTER_CREATION while the screen is open (group `character_creation` :151; game_mode.gd:137-138, :159-161).

## Assumptions and invariants
- Confirm requires exactly 0 points remaining (point_buy_table.gd:49-54; character_creation.gd:361-373).
- Every purchasable value has a cost entry; missing keys cost 0 (point_buy_table.gd:31-32) - issue 2.
- The start area is `goblin_quarry` (character_creation.gd:685); `pending_leader` is consumed by `StartingParty.bootstrap` (starting_party.gd:52-54), called from three area scripts (areas_bootstrap.md, WLD-13) - hard-coded single-start assumption (review 11-15 corrected this from test_arena).
- The PC uses `player_character.tres` and a fixed ability list (character_creation.gd:635, :657-661).
- Skill `levels_purchased = relative + 1` (character_creation.gd:676) must match SkillDatabase's level convention.

## Lifecycle
- Screen exists for the whole session under MainRoot; reset each time it becomes visible and on new_game_started.
- **New game**: main menu -> SaveManager.new_game (clears pending_leader, save_manager.gd:605; emits new_game_started :637) -> screen. Back returns to main menu (:788-795).
- **Confirm** (character_creation.gd:620-690):
  1. build PartyMemberData from attribute/skill values and portrait;
  2. attach hard-coded definition (:635) and abilities (:657-661);
  3. skills as `levels_purchased = relative + 1` (:676);
  4. `PartyManager.pending_leader = record` (:679);
  5. `WorldManager.travel_area(&"goblin_quarry")` (:685); StartingParty consumes it (starting_party.gd:52-54).
- **Shortcuts**: auto-fill (:458-476) and debug quick create (:97-98, :494-499).
- **Save / load**: nothing saved here; a load before StartingParty consumes pending_leader leaves it dangling until next new_game.
- **Combat / dialogue / cutscene**: not reachable (blocks_input_below, closes_on_cancel=false, MainRoot.tscn:414-418).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Start area hard-coded to `&"test_arena"`; pending_leader only consumed there, so changing the start area silently drops the created character. | character_creation.gd:685; starting_party.gd:52-54; party_manager.gd:88 | NEW; review 11-15: risk reduced, still open: the start area is now `goblin_quarry` and `pending_leader` is consumed by StartingParty (world scope), not by one area; the start area is still a literal in a UI screen, see DLG-26 |
| 2 | `cost_for` returns 0 for values missing from the table - a gap in the .tres makes that step free instead of failing. | point_buy_table.gd:31-32 | NEW |
| 3 | Portrait grid lists source jpg/png via DirAccess; exported builds ship only imported resources, so the grid may be empty in export. Unverified. | character_creation.gd:533-559 | NEW (unverified); review 11-15: still open, severity up (Confirm needs a portrait, so an export cannot start a game), see DLG-21 |
| 4 | Dead guard `if SaveManager.has_signal("new_game_started")` - the signal exists. | character_creation.gd:185, :340; save_manager.gd:106 | NEW (cosmetic); review 11-15: still open |
| 5 | Hard-coded definition and ability list for the PC. | character_creation.gd:635, :657-661 | NEW; review 11-15: still open, see DLG-26 |
| 6 | Level-up wizard is a static mockup, not wired. | mockup/wizard_mockup.gd | NEW (scope note); review 11-15: obsolete, level-up now exists (character_creation.gd:51-62, :307-318, :692-736), opened from party_overview.gd:454 via `Progression.open_level_up`; the mockup is still unwired |

### Review 2026-11-15 (HEAD 14cb4ad9)
Progression has no doc of its own yet. It lives in `systems/progression_system/` (progression.gd 206, progression_table.gd 65), data `data/progression/progression.tres`, autoload `Progression` (project.godot:40), save key `progression`. It grants party XP and levels (progression.gd:83-111, from `UnitDefinition.level` via encounter.gd:600) and opens this screen in level-up mode through `Progression.open_level_up` (progression.gd:163-167, called from party_overview.gd:454). The level-up mode reuses the point-buy rows (character_creation.gd:51-62, :307-318, :692-736); it was built that way at a first cut (acd94dff), and progression is paused. The rows DLG-22 to DLG-25 below cover progression.

| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| DLG-21 | The portrait grid lists source images, an export has only `*.png.import`, and Confirm is disabled without a portrait, so a new game cannot start in a release export. Unverified (no export run). | character_creation.gd:534-541, :581-584, :747-748, :170 | The grid lists the folder with DirAccess and `load(path)` on source files, so in an export it is empty and the auto-fill finds nothing. | Strip `.import` before the extension check (as the catalog's remap strip), or author a `PortraitSet` resource. Add an export smoke test. | R6 | S | BUG |
| DLG-22 | Level-up is a flag inside the creation screen with its own cost model: `_level_up_unit != null` branches cost "1 per +1" in level-up and use the table in creation, `_spend_round_robin` is only right in creation mode, and `Progression.open_level_up` finds the screen by group and `has_method`. | character_creation.gd:200-214, :419-421, :434-436, :442-445, :577-579, :619-621, :789-791, :767-776, :151; progression.gd:163-167; game_mode.gd:137 | acd94dff reused the point-buy rows for level-up instead of making a second screen. | A `PointBuySession` (values, floors, pool, cost function) with two constructors; the screen renders a session and never asks which mode it is. | R7 | M | INTENTIONAL; document why: progression paused at a first cut (acd94dff) |
| DLG-23 | Level-up writes onto the live Unit in a fixed order: points are spent first (`:699`), then stats, and the new SkillInstance is parented to the screen for one line so `add_skill` can reparent it. A failure after the spend loses the points. Abilities are compared by `ability_name`. | character_creation.gd:699, :707-713, :729-730, :733, :694-696, :300; progression_table.gd:63 | The unit has no `learn_skill` that makes the instance itself. | `Unit.learn_skill(skill, levels)` creates the instance; apply the writes, then spend. | R5 | S | BUG (quick fix; commented as a workaround in the code) |
| DLG-24 | Progression reads create state: `member_id` mints a `persistent_id` on any Unit asked about and `_points_of` inserts an entry, via `has_unspent` called by stats_column.gd:108 for whatever unit the sheet shows. Opening the sheet on an enemy mints an id. | progression.gd:116-121, :153-156, :176-177; ui/stats_column.gd:108 | A query was written as a lookup-or-create. | `has_unspent` and `unspent` return zeros for a unit with no id; only `_grant_level_to_party` and `spend` create. | R4 | S | BUG (quick fix; comment at progression.gd:114-115) |
| DLG-25 | Who levels: members present at the moment of the level, nobody after. Unspent points are a running total, so a companion recruited at level 4 is three bundles behind for good, and the quest turn-in grants no XP. | progression.gd:100-111, :13-14, :83-92 | Points are granted by event to `PartyManager.everyone()` plus `fallen` at that instant, not derived from level. | Store only what was spent per member and derive available as `(level - joined_level_floor) * bundle - spent`; give `.dlg` an `xp <n>` effect word. | R2 | M | INTENTIONAL; document why: progression paused at a first cut (acd94dff); the header says "no back-pay yet" |
| DLG-26 | Chargen still hard-codes the start area, the body and the abilities. Row 1's risk is reduced (StartingParty consumes `pending_leader`), the dead guard remains. | character_creation.gd:685, :635, :657-661, :185, :340 | The demo start was fixed in code rather than data. | A `NewGameDefinition` resource read by `SaveManager.new_game`. | - | S | INTENTIONAL; document why: demo start fixed (f52cf9cb) |
| WLD-13 | same as DLG-26 (character_creation.md) | | | | R7 | | see areas_bootstrap.md |

## Tests
tests/world/test_a_new_game_is_new.gd opens chargen (:120, :379) and checks `reset()` exists (:358-359). No dedicated chargen test (point-buy validity, confirm -> leader spawned in test_arena).
