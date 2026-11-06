# Character Creation

**Files:** `systems/character_creation/character_creation.gd` 506, `point_buy_table.gd` 54, `character_creation.tscn`, `point_buy_row.tscn`; `mockup/wizard_mockup.gd` 77 + `wizard_mockup.tscn` + `wizard_theme.tres` (static level-up mockup built by tools/_probe/build_wizard_mockup.gd, not wired into the game); data `data/character_creation/attribute_costs.tres`, `skill_costs.tres`.
**Autoloads owned:** none (UIScreen node `CharacterCreation` under MainRoot CanvasLayer, MainRoot.tscn:414-418)

## Purpose
Point-buy screen for the player character: attributes and skills bought from cost tables, a portrait picked from a folder, derived stats previewed, then a `PartyMemberData` record handed to PartyManager as the pending leader and the game travels to the start area. It does NOT spawn the unit (test_arena does), persist anything itself, or handle level-up (mockup only).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Attribute values, skill values, selected portrait | character_creation.gd:115-120 | No (screen-local) |
| Cost tables (min/max/default/pool, cost dict) | point_buy_table.gd:21-28; data/character_creation/*.tres | Content |
| Built leader record (handoff) | written to PartyManager.pending_leader (character_creation.gd:445; party_manager.gd:88) | No - consumed on spawn, then persisted as the leader's party data by the party system |

## Derived / cached state
- Remaining points / affordability computed from tables (character_creation.gd:255-263, :272-310); attribute rows from `StatDatabase.get_bought()`; derived-stat preview via `StatDatabase.value_of` (`_preview_value`); the record carries a `stats` dict.
- Skill rows built once from SkillDatabase in `_ready` (:139-141); portrait grid built once from disk (:147, :318-344).
- `PartyManager.pending_leader` is a cache between this screen and test_arena's `_build_leader` (world/test_arena.gd:57-60).

## Public surface
- **Calls in**: main_menu.gd:85-89 Start -> `SaveManager.new_game()` then push `character_creation`; `reset()` (character_creation.gd:172-195) from visibility_changed (:198-200) and SaveManager.new_game_started (:160-161); tests call `reset()` (tests/world/test_a_new_game_is_new.gd:358-359).
- **Signals out**: none.
- **Signals in**: `visibility_changed` (:152), `SaveManager.new_game_started` (:160-161; disconnected in _exit_tree :207-209).

## Depends on
- SkillDatabase (character_creation.gd:139-141), StatDatabase (stats.md), PartyManager.pending_leader (:445), WorldManager.travel_area (:451), SaveManager signal (:160-161), UIStack back to main_menu (:502-506), DirAccess on `res://assets/portraits/` (:72, :318-344).
- GameMode reports CHARACTER_CREATION while the screen is open (group `character_creation` :128; game_mode.gd:137-138, :159-161).

## Assumptions and invariants
- Confirm requires exactly 0 points remaining (point_buy_table.gd:49-54; character_creation.gd:361-373).
- Every purchasable value has a cost entry; missing keys cost 0 (point_buy_table.gd:31-32) - issue 2.
- The start area is test_arena and it is the only consumer of pending_leader (character_creation.gd:451; world/test_arena.gd:57-60) - hard-coded single-start assumption.
- The PC uses `player_character.tres` and a fixed ability list (character_creation.gd:400, :423-427).
- Skill `levels_purchased = relative + 1` (character_creation.gd:442) must match SkillDatabase's level convention.

## Lifecycle
- Screen exists for the whole session under MainRoot; reset each time it becomes visible and on new_game_started.
- **New game**: main menu -> SaveManager.new_game (clears pending_leader, save_manager.gd:605; emits new_game_started :637) -> screen. Back returns to main menu (:502-506).
- **Confirm** (character_creation.gd:384-451):
  1. build PartyMemberData from attribute/skill values and portrait;
  2. attach hard-coded definition (:400) and abilities (:423-427);
  3. skills as `levels_purchased = relative + 1` (:442);
  4. `PartyManager.pending_leader = record` (:445);
  5. `WorldManager.travel_area(&"test_arena")` (:451); test_arena `_build_leader` consumes it (world/test_arena.gd:57-60).
- **Shortcuts**: auto-fill (:458-476) and debug quick create (:97-98, :494-499).
- **Save / load**: nothing saved here; a load before test_arena consumes pending_leader leaves it dangling until next new_game.
- **Combat / dialogue / cutscene**: not reachable (blocks_input_below, closes_on_cancel=false, MainRoot.tscn:414-418).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Start area hard-coded to `&"test_arena"`; pending_leader only consumed there, so changing the start area silently drops the created character. | character_creation.gd:451; world/test_arena.gd:57-60; party_manager.gd:88 | NEW |
| 2 | `cost_for` returns 0 for values missing from the table - a gap in the .tres makes that step free instead of failing. | point_buy_table.gd:31-32 | NEW |
| 3 | Portrait grid lists source jpg/png via DirAccess; exported builds ship only imported resources, so the grid may be empty in export. Unverified. | character_creation.gd:318-344 | NEW (unverified) |
| 4 | Dead guard `if SaveManager.has_signal("new_game_started")` - the signal exists. | character_creation.gd:160-161; save_manager.gd:106 | NEW (cosmetic) |
| 5 | Hard-coded definition and ability list for the PC. | character_creation.gd:400, :423-427 | NEW |
| 6 | Level-up wizard is a static mockup, not wired. | mockup/wizard_mockup.gd | NEW (scope note) |

## Tests
tests/world/test_a_new_game_is_new.gd opens chargen (:120, :379) and checks `reset()` exists (:358-359). No dedicated chargen test (point-buy validity, confirm -> leader spawned in test_arena).
