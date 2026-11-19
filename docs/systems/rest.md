# Rest

**Files:** `systems/rest_system/` — `rest.gd` (Rest, static rules), `rest_key.gd` (the R key, a node in MainRoot.tscn), `rest_spot.gd` (RestSpot, a safe spot's interact prompt). Data: `data/items/camp_supplies.tres`.
**Autoloads owned:** none.

## Purpose
Owns resting: what a short rest and a full rest restore, what they cost, and when they can be taken. NOT responsible for the overworld's random encounters (the overworld owns those, including the short rest's ambush roll; see areas_bootstrap.md "Random encounters"), for the item or pool mechanics it spends and fills (inventory.md, stats.md), or for any time of day (there is no clock).

- **Short rest:** R, anywhere, out of combat. Free. Each standing party member gets back half the maximum of HP and of FP (`SHORT_FRACTION`). The Downed stay down. First, the focused world is asked `roll_rest_ambush()` (duck-typed); on the overworld that rolls the district's danger, and an ambush means the rest is not taken.
- **Full rest:** at a safe spot (the Inn plate on Morrow's square, `Inn/SafeSpot`), press interact. Costs one Camp Supplies. Fills every party member's HP and FP, picks up the Downed (`heal()` does), refills every unfielded, living demon in the roster. Never ambushed.
- **Both** repopulate the overworld: `OverworldEncounters.clear_all()`.
- The dead (`has_died`) are not touched by either.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| None. Supplies are ordinary items in `PartyManager.inventory`; pools are the units'. | | |

## Derived / cached state
- The safe spot's prompt text carries the supplies count, re-offered after each rest (rest_spot.gd `activate`). It does not refresh if supplies change while you stand there for another reason.

## Public surface
- **Calls in:** `Rest.short_rest()` (rest_key.gd), `Rest.full_rest()` (rest_spot.gd), `Rest.blocked_reason()`, `has_supplies()`, `supplies_count()`.
- **Calls out to a world:** `roll_rest_ambush() -> bool` on the focused world, if it has one (overworld.gd).
- **Signals:** none. Results go to the SystemLog.

## Depends on
- `CombatManager.any_combat_running()`, `GameMode.current_mode()` (only EXPLORATION or OVERWORLD rest).
- `PartyManager.members`, `PartyManager.inventory` (`has`, `consume`, `items`).
- `DemonRoster.all_owned()`, `is_fielded()`, `OwnedDemon.fill_pools()`.
- `OverworldEncounters.clear_all()`.
- StartingParty gives 3 Camp Supplies (`STARTING_COUNT`, starting_party.gd), as part of giving every item in `data/items/`.

## Assumptions and invariants
- A rest is party-wide: every member in `PartyManager.members`, whichever group or world it is in.
- R is read as a physical key (like the hotbar's F), not an InputMap action, so it can't be rebound.

## Lifecycle
Stateless. RestKey lives as long as MainRoot. A RestSpot offers itself while the commanded overworld avatar stands in it, and again on world focus (same as OverworldDoor).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| REST-1 | Feedback is the SystemLog only; on the overworld there is no other sign a rest was taken. | rest.gd | NEW |
| REST-2 | Supplies can only be got from the starting gift; nothing sells or drops them yet. | starting_party.gd | NEW |

## Tests
- test_a_rest_restores_the_party.gd (short rest restores half and leaves the Downed; full rest spends supplies, fills, picks up; both clear encounter counts; no supplies refuses).
