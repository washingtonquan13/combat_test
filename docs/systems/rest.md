# Rest

**Files:** `systems/rest_system/` — `rest.gd` (Rest, static rules), `rest_key.gd` (the R key, a node in MainRoot.tscn), `rest_spot.gd` (RestSpot, the inn's corona and interact prompt). Scenes: `world/inn_rest_spot.tscn` (the corona), `world/camp.tscn` + `world/camp.gd` (Camp, a BattleField), `data/areas/camp.tres`. Data: `data/items/camp_supplies.tres`.
**Autoloads owned:** none.

## Purpose
Owns resting: where a rest is taken, what it restores, what it costs, and the camp it is taken at. Nothing about the party's state gates a rest: whoever is alive is rested, the Downed included. NOT responsible for the overworld's random encounters or the odds a camp is found (the overworld owns those, see areas_bootstrap.md "Random encounters"), for the fight itself (BattleField spawns it, combat runs it), for the item or pool mechanics it spends and fills (inventory.md, stats.md), or for any time of day (there is no clock).

- **Inn:** stand in the blue corona at the inn on Morrow's square (`Inn/SafeSpot`, an instance of `inn_rest_spot.tscn`) and press interact. Free, never ambushed. Fills every member's HP and FP, picks up the Downed (`heal()` does), refills every unfielded, living demon. The party stays where it is. The corona uses the doors' shader (`overworld_door.gdshader`), tinted blue, and brightens while the avatar stands in it, as a door does.
- **Camp:** R anywhere else, out of combat, in EXPLORATION or OVERWORLD. `plan_camp()` spends one Camp Supplies if there is one, asks the world being left for an ambush (`rest_ambush()`, duck-typed), writes `CAMP_FLAG`, and remembers where each member stood. The screen goes black and the camp area loads. There the night is taken (`rest_at_camp()`, once per camp): everything back with supplies, half of each pool's maximum without (`UNSUPPLIED_FRACTION`). A rest is never refused for want of supplies.
- **Ambush at camp:** if the plan carries one, the rest is taken, then after `Camp.ambush_delay` the fight walks in from the gap in the trees (BattleField `_start_pending`). With `Camp.ambush_interrupts`, the fight comes first and the rest is taken once it is won. Either way the party stays at camp after.
- **Break camp:** R at camp (refused in combat). Back to the area camp was made in (the overworld if that is unknown), each member where they stood.
- **Both** repopulate the overworld: `OverworldEncounters.clear_all()`.
- The dead (`has_died`) are not touched.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| The camp under way: `{from, supplied, ambush, rested}` | rest.gd `CAMP_FLAG` | yes, flag `rest/camp` |
| Where each member stood when camp was made | rest.gd `_stood` | no (REST-4) |

Supplies are ordinary items in `PartyManager.inventory`; pools are the units'. A pending camp ambush is the encounters' own flag (`OverworldEncounters.PENDING_FLAG`).

## Derived / cached state
- None beyond the above.

## Public surface
- **Calls in:** `Rest.rest_key()` (rest_key.gd), `Rest.inn_rest()` (rest_spot.gd), `Rest.rest_at_camp()` (camp.gd), `plan_camp()`, `make_camp()`, `break_camp()`, `camp()`, `restore(fraction)`, `blocked_reason()`, `has_supplies()`, `supplies_count()`.
- **Calls out to a world:** `rest_ambush() -> Dictionary` (`{group, district}` or `{}`) on the world being left, if it has one (overworld.gd).
- **Signals:** none. Results go to the SystemLog.

## Depends on
- `CombatManager.any_combat_running()`, `GameMode.current_mode()`.
- `WorldManager.travel_area`, `behind_black`, `load_area`, `current_world`, `current_area`; `AreaDatabase.find`; `UIStack.close_all`.
- `FlagManager` (`CAMP_FLAG`, and `PENDING_FLAG` for the ambush).
- BattleField (`_start_pending`, `_won`), which Camp extends.
- `PartyManager.members`, `PartyManager.inventory` (`has`, `consume`, `items`).
- `DemonRoster.all_owned()`, `is_fielded()`, `OwnedDemon.fill_pools()`.
- `OverworldEncounters.clear_all()`, and `pick_fight()` through the overworld's `rest_ambush`.
- StartingParty gives 3 Camp Supplies (`STARTING_COUNT`, starting_party.gd), as part of giving every item in `data/items/`.

## Assumptions and invariants
- A rest is party-wide: every member in `PartyManager.members`, whichever group or world it is in.
- R is read as a physical key (like the hotbar's F), not an InputMap action, so it can't be rebound.
- One camp scene for every place camp is made.

## Lifecycle
RestKey lives as long as MainRoot. A RestSpot offers itself while the commanded overworld avatar stands in it, and again on world focus (same as OverworldDoor). A camp lasts from `plan_camp` to `break_camp`; a load or Retry at camp comes back to it through the flag (a pending ambush is started again).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| REST-1 | Feedback is the SystemLog only; there is no other sign a rest was taken. | rest.gd | NEW |
| REST-2 | Supplies can only be got from the starting gift; nothing sells or drops them yet. | starting_party.gd | NEW |
| REST-3 | Camp made from an exploration area is never ambushed: only the overworld has `rest_ambush()`. | rest.gd `plan_camp` | NEW |
| REST-4 | Where members stood is not saved; a load at camp breaks it to the area's ordinary arrival point. | rest.gd `_stood` | NEW |

## Tests
- test_a_rest_restores_the_party.gd (the inn is free, fills, picks up the Downed and clears counts; a camp with no supplies is still made and gives back half, once; with supplies it spends one and fills).
- test_a_random_encounter_is_fought.gd `_camp` (a supplied camp with an ambush rests first, then the ambush spawns there; won, the party stays at camp with nothing pending).
