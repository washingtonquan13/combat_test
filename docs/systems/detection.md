# Detection

**Files:** `systems/detection_system/`:
- `detection_manager.gd` (338)
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
  - `scan()` runs from `_physics_process` every 0.2 s (detection_manager.gd:68, 4e171c70). Tests also call it directly. It returns at once while `CinematicDirector.is_active()` (detection_manager.gd:84-88): the ambush's units are walked into view by a cutscene and must not start the fight early (6f345c96), and the caller starts that fight itself once `play()` returns. The gate is deliberate, but it is global: it also stops `_draw_in_latecomers` and noticing in every world, not only the one playing the scene (C-5 below).
  - `obscurity_at(pos)` (283-284).
  - `UnitAwareness.is_aware_of(unit)` (unit_awareness.gd:77-78).
  - sight_cone_indicator.gd:237 reads awareness state for display.
- **Signals out**
  - `awareness_changed(observer, subject, state)` (detection_manager.gd:56) goes to the UI cone and indicator (sight_cone_indicator.gd).
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
- STALE claim: the header says scanning is gated by mode, dialogue or cutscene (24), but the code gates only on `enabled` and on a running cutscene (`CinematicDirector.is_active()`, 84-88); dialogue and mode are not gated.

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
- **Dialogue / cutscene:** a cutscene stops scanning in every world (C-5 below); dialogue is not gated (issue 3).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | The report that "detection is O(n^2) every 0.2 s" does not match the code. The main loop costs (out-of-combat NPC observers) x (player units in the same world), with an early distance reject. The extra cost while any fight runs is `_draw_in_latecomers`, at (all units) x (combatants across all encounters). A perf test enforces 2 ms/sweep for 12 observers x 4 party. | detection_manager.gd:92-118, 135-174, 212-213; tests/detection/test_detection_perf.gd:18 | NOT REPRODUCED. Review 11-15 adds: the cutscene gate also stops `_draw_in_latecomers` in every world (C-5) |
| 2 | Awareness locks onto the first subject it identifies, even a neutral one. `notice` returns false once AWARE of anyone. Noticing a non-hostile unit therefore blocks later hostile detection until a fight ends in that world. | unit_awareness.gd:62-68; detection_manager.gd:182-186 | NEW |
| 3 | The header claims gating by mode, dialogue and cutscene, but `_process` checks only `enabled`. Detection can start a fight during dialogue or a cutscene. | detection_manager.gd:24 vs 68-75 | HALF FIXED: `scan()` returns while `CinematicDirector.is_active()` (detection_manager.gd:84-88); dialogue and mode are still not gated and the header (:24) still claims more than the code does; review 11-15, see C-5 |
| 4 | A SUSPICIOUS state with `subject == null` (from hearing) passes the `subject != null` guard. It re-emits `awareness_changed` on every hearing tick. | unit_awareness.gd:62 | NEW |
| 5 | Awareness never decays and is never reset outside a fight ending. An observer that becomes SUSPICIOUS without a fight stays SUSPICIOUS forever. | unit_awareness.gd:84-87; detection_manager.gd:326-330 | NEW; review 11-15: still open, the reset is now detection_manager.gd:334-338 |
| 6 | Awareness is not saved. Reloading clears suspicion and awareness. | unit_awareness.gd (no save_state) | NEW |
| 7 | `obscurity_at` is a stub that always returns CLEAR, so the stealth and obscurity path is untested in practice. | detection_manager.gd:283-284 | NEW |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| C-5 | Detection is switched off in every world while any cutscene plays: `scan()` returns first thing while `CinematicDirector.is_active()`, before `_draw_in_latecomers`. It names one caller's need, it is global (a fight in an unfocused world gets no latecomers and no NPC there can notice the other party group for as long as a cutscene plays in the focused world), and it covers cutscenes only, so detection.md #3 is half open and the header claim (:24) is still wrong. | detection_manager.gd:84-88, 94-95, 24 | 6f345c96: ambush units are walked into view by the scene and must not start the fight early. | The scene, not detection, says who is out of play: `CinematicDirector`/`SceneCast` marks its tracked units (and their world) as staged, and `scan()` skips observers and subjects for which `unit.is_staged()` (or `CinematicDirector.is_staging(world)`) holds; the same hook serves dialogue (`Conversations.current` participants). Other worlds keep scanning. | R1 | M | INTENTIONAL; document why: ambush needs no detection during its cutscene (6f345c96); the global scope is the R1 defect, not the gate |
| C-18 | Combat end forgets all awareness in the world, even with another fight running there: an NPC scrap ends and every unit in that world, including observers about to join the party's fight on suspicion, is reset. Minor. | detection_manager.gd:334-338 | The same "a fight ended" means "all fights ended" assumption, at world scale. | Reset only `encounter.turn_order` members and units whose awareness subject was in that encounter (needs C-7's named signal, combat.md). | R1 | S (after C-7) | BUG |
| CINE-14 | same as C-5 in part (cinematics.md): cinematic_cues.gd:39, 80-87 reads `current_world()` on any `combat_started`; C-5 is the detection side of the same cutscene gate | cinematic_cues.gd:39, 80-87 | | | R1 | | see cinematics.md |

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
