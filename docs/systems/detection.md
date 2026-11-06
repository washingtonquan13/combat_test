# Detection

**Files:** `systems/detection_system/`:
- `detection_manager.gd` (330)
- `unit_awareness.gd` (87)

**Autoloads owned:** `DetectionManager` (project.godot:44)

## Purpose
Lets out-of-combat NPCs notice player-controlled units before anyone is hit. It escalates each observer's awareness through sight checks (range, cone, raycast, then roll) and hearing checks. On reaching AWARE, a hostile observer starts combat (detection_manager.gd:80-118, 180-313). While any fight runs, it also pulls nearby hostile latecomers into that fight within hearing range (135-174). It does NOT handle units leaving combat (Encounter disengage, encounter.gd:514-541), AI behaviour once combat starts (`ai.md`), or faction relations (`faction_relations.gd`, which it only reads through `is_hostile_to`).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Per-unit awareness `state` (UNAWARE/SUSPICIOUS/AWARE) | unit_awareness.gd:27, 39 | no |
| `subject` (who is noticed) | unit_awareness.gd:42 | no |
| `last_known_position` | unit_awareness.gd:46 | no |
| Scan timer `_elapsed` | detection_manager.gd:58 | no |
| `enabled` toggle | detection_manager.gd:61 | no (tests disable it: ai_test_case.gd:85) |
| Tuning constants | detection_manager.gd:31-53 (listed below) | code |

The tuning constants are:
- `SCAN_INTERVAL` 0.2 (31)
- `DISTANCE_PENALTY` 0.25 (37)
- `PROXIMITY_BONUS` 4 (42)
- `HEARING_RADIUS` 22 (47)
- `EYE_HEIGHT` and `OBSTRUCTION_MASK` (52-53)

The awareness object hangs off each unit as `Unit.awareness` (unit.gd:908).

## Derived / cached state
- None cached. Each scan re-reads `UnitQuery.living_units`, combat membership, and faction hostility (detection_manager.gd:80-118).
- `obscurity_at()` is a hook that always returns CLEAR (283-284). Obscurity in UnitAwareness (unit_awareness.gd:37) is therefore never anything but CLEAR.

## Public surface
- **Calls in**
  - `scan()` runs from `_process` every 0.2 s (detection_manager.gd:68-75). Tests also call it directly.
  - `obscurity_at(pos)` (283-284).
  - `UnitAwareness.is_aware_of(unit)` (unit_awareness.gd:77-78).
  - sight_cone_indicator.gd:237 reads awareness state for display.
- **Signals out**
  - `awareness_changed(observer, state)` (detection_manager.gd:56) goes to the UI cone and indicator (sight_cone_indicator.gd).
  - Two calls go out to CombatManager:
    - `start_combat_from_hostile_act` (313)
    - `add_unit_to_combat` (170)
- **Signals in**
  - `CombatManager.combat_ended_in_world` triggers `_on_combat_ended_in_world` (detection_manager.gd:65, 326-330). This resets every awareness in that world.

## Depends on
- `UnitQuery.living_units` (detection_manager.gd:89-118).
- CombatManager calls:
  - `any_combat_running` / `all_encounters` (89-90, 135-174)
  - `combat_running_in_world_of` (292-313)
  - `add_unit_to_combat` (170)
  - `start_combat_from_hostile_act` (313)
- `LineOfSight.has_clear_shot` raycast (211-230; line_of_sight.gd).
- `SuccessRoll` (211-230; success_roll.gd).
- Stealth skill via `_stealth_of` (267-273).
- `Unit.visual_forward()` for the cone (238-248). Using it avoids the facing-offset gotcha.
- `Unit.is_hostile_to` (165, 292-313).

## Assumptions and invariants
- Only out-of-combat, non-player units observe (100-105). Only player-controlled units in the same world are subjects (107-118).
- The scan for an observer stops after its first escalation (107-118).
- Sight checks run cheapest first: range, then cone, then raycast, then roll (211-230).
- Hearing works within `HEARING_RADIUS` (255-258).
- Awareness only rises. It never decays over time. The only reset is a fight ending in that world (unit_awareness.gd:84-87; detection_manager.gd:326-330).
- The world-scoping is correct: latecomers must share the encounter's world (163), and the reset uses `combat_ended_in_world` rather than the global `combat_ended`.
- STALE claim: the header says scanning is gated by mode, dialogue or cutscene (24), but `_process` checks only `enabled` (68-75).

## Lifecycle
- **Creation:** autoload `_ready` connects `combat_ended_in_world` (64-65). Scanning starts immediately.
- **Exploration:** a tick every 0.2 s calls `scan` and `_consider` for each observer (180-199). The tick also calls `_react_to` on escalation (292-313).
  - A hostile observer reaching AWARE starts combat, unless a fight is already running in that world (`combat_running_in_world_of`, which makes `_react_to` return).
- **Combat:**
  - Combatants stop observing (100-105).
  - `_draw_in_latecomers` adds hostile units within hearing range of a combatant in the same world (135-174).
- **Combat end in a world:** all awareness in that world resets (326-330).
- **Save / load / new game:** awareness is not saved. It comes back UNAWARE (unit_awareness.gd has no save_state).
- **World travel:** subjects are filtered to the same world, so other worlds are not scanned against the player.
- **Dialogue / cutscene:** not gated (issue 3).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | The report that "detection is O(n^2) every 0.2 s" does not match the code. The main loop costs (out-of-combat NPC observers) x (player units in the same world), with an early distance reject. The extra cost while any fight runs is `_draw_in_latecomers`, at (all units) x (combatants across all encounters). A perf test enforces 2 ms/sweep for 12 observers x 4 party. | detection_manager.gd:92-118, 135-174, 212-213; tests/detection/test_detection_perf.gd:18 | NOT REPRODUCED |
| 2 | Awareness locks onto the first subject it identifies, even a neutral one. `notice` returns false once AWARE of anyone. Noticing a non-hostile unit therefore blocks later hostile detection until a fight ends in that world. | unit_awareness.gd:62-68; detection_manager.gd:182-186 | NEW |
| 3 | The header claims gating by mode, dialogue and cutscene, but `_process` checks only `enabled`. Detection can start a fight during dialogue or a cutscene. | detection_manager.gd:24 vs 68-75 | NEW |
| 4 | A SUSPICIOUS state with `subject == null` (from hearing) passes the `subject != null` guard. It re-emits `awareness_changed` on every hearing tick. | unit_awareness.gd:62 | NEW |
| 5 | Awareness never decays and is never reset outside a fight ending. An observer that becomes SUSPICIOUS without a fight stays SUSPICIOUS forever. | unit_awareness.gd:84-87; detection_manager.gd:326-330 | NEW |
| 6 | Awareness is not saved. Reloading clears suspicion and awareness. | unit_awareness.gd (no save_state) | NEW |
| 7 | `obscurity_at` is a stub that always returns CLEAR, so the stealth and obscurity path is untested in practice. | detection_manager.gd:283-284 | NEW |

## Tests
- tests/detection/test_detection.gd
- tests/detection/test_detection_perf.gd (budget at :18)
- tests/detection/test_join_leave_combat.gd
- tests/detection/test_sight_cone_indicator.gd
- tests/combat/test_encounters.gd:224
- ai_test_case.gd:85 disables detection for AI tests.

**Gaps:**
- No test covers a neutral subject lock (issue 2).
- No test covers mode gating (issue 3).
- No test covers suspicion persistence (issue 5).
- No test covers save and reload of awareness.
