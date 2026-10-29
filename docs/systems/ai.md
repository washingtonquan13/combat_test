# AI

**Files:** `systems/combat_system/combat_ai.gd` (175, turn driver), `systems/ai_system/` — `ai_scorer.gd` (1150, all valuation), `ai_plan.gd` (117), `ai_behavior.gd` (147, contract + plan builders), `ai_archetype.gd` (40), `flight_ai_util.gd` (60), 11 behaviors: `area_target` (92), `flee` (89), `fly_to_close_gap` (71), `focus_fire` (61), `heal_wounded_ally` (38), `hold_range` (90), `land_before_exhaustion` (106), `prefer_flight` (63), `support_ally` (88), `use_ability_on_nearest_hostile` (32), `withdraw_after_attack` (62).
**Autoloads owned:** `CombatAi` (project.godot:22 → combat_ai.gd). `AiScorer` is a static `RefCounted` class, not an autoload (ai_scorer.gd:1-2).

## Purpose
Drives the turn of every unit whose faction is AI-controlled: asks `AiScorer.best_plan()` for one plan, moves, uses an ability, re-asks after each move / free action, and ends the turn (combat_ai.gd:42-173). `AiScorer` enumerates "every damaging single-target ability × every hostile" plus behavior proposals, filters by affordability/reach, and prices everything in one HP currency (ai_scorer.gd:144-178, 264-278, 347-394). NOT responsible for: turn order, whose turn it is, combat start/end (Encounter/CombatManager), ability resolution (Unit/UnitCombat), pathing (Unit.plan_route / NavigationGrid), or player-faction units (never driven).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| `ai_factions = [enemy, neutral]` | combat_ai.gd:26 | No (export default) |
| `_acting_unit` (single global) | combat_ai.gd:34 | No |
| `_move_attempts` (cap 5) | combat_ai.gd:32,35 | No |
| `_free_actions_used` (cap 3) | combat_ai.gd:124-125 | No |
| `AiScorer._success_cache` (3d6 TN → p) | ai_scorer.gd:124 | No (static, never cleared; deterministic) |
| `AiScorer._position_cache` ([unit id, pos] → score) | ai_scorer.gd:134, cleared 148, 195 | No (static) |
| Per-unit config: `Unit.ai_behaviors`, `Unit.ai_smartness` | unit.gd:277, 283; filled from definition unit.gd:51-52 | Via UnitDefinition, not AI |
| Archetype data (behaviors, smartness, role) | ai_archetype.gd:30-40; merged unit_definition.gd:197-212 | Resource data |

## Derived / cached state
- `_acting_unit` is a copy of "whose turn is it", whose truth is `Encounter.current_unit` — per encounter. One global copy vs N encounters (see issue 1).
- `_success_probability` re-implements `SuccessRoll.roll_vs` crit rules (ai_scorer.gd:1088-1110 vs success_roll.gd:25-34) — two truths for crit thresholds.
- `_plan_end_position` re-derives `GrantFlightEffect.apply()`'s altitude clamp (ai_scorer.gd:513-522) and LandEffect's ground (523-524).
- `_unsustainable_flight_cost` / `_forced_descent_cost` re-derive fall damage as `dice*3.5+bonus` from `FLIGHT_RULES` (ai_scorer.gd:951-955, 1015-1019).
- `_position_cache` caches threat per position for one `best_plan` call; valid only while no unit moves mid-scoring.

## Public surface
- **Calls in**
  - `AiScorer.best_plan(unit)` — combat_ai.gd:60 (only production caller).
  - `AiScorer.describe_candidates(unit)` — debug dump (ai_scorer.gd:194-222).
  - `AiScorer.standoff_goal` — fly_to_close_gap_behavior.gd:44, ai_scorer.gd:622, 742.
  - `AiScorer.threat_output / incoming_threat / sustained_incoming_threat / score_position` — public static helpers (ai_scorer.gd:317, 769, 818, 908); tests use them.
  - `AiBehavior.propose(unit)` — ai_scorer.gd:158, 200.
- **Signals out:** none. Side effects only: `CombatManager.end_turn(unit)` (combat_ai.gd:65, 81, 102, 111, 132, 144, 148, 162, 170), `unit.use_ability` (99), `unit.move_to` (157), `unit.set_flight_altitude` (69).
- **Signals in**
  - `CombatManager.turn_started(unit)` — combat_ai.gd:39; relayed from EVERY encounter by combat_manager.gd:362-365.
  - `unit.movement_finished(unit)` one-shot — combat_ai.gd:155 (signal unit.gd:465).
  - `unit.became_idle` one-shot, unit bound — combat_ai.gd:115.

## Depends on
- CombatManager: `turn_started` (combat_ai.gd:39), `end_turn` (above) → `_encounter_for` falls back to `focused_encounter` when `unit.encounter` is null (combat_manager.gd:345-348).
- Unit: `faction` (combat_ai.gd:43), `is_in_range`/`use_ability`/`uses_attack_action` (80, 98-99), `is_busy`/`became_idle` (114-115), `has_move_remaining`/`move_to`/`arrival_tolerance` (138-157), `plan_route` (ai_scorer.gd:588, 612, 623), `move_remaining`, `current_fp`, `hp_to_death`, `attack_skill`, to-hit modifier hooks (ai_scorer.gd:357-359, 469, 690, 1070-1073), live `global_position` writes (320, 334, 681-683, 771, 794, 820, 862), `flight_target_altitude` writes (551-558).
- UnitQuery: `living_units_near`, `nearest_hostile`, `living_allies`, `all_units_near` (ai_scorer.gd:246, 268, 322, 774, 823, 1039; behaviors).
- UnitCombat: `ALTITUDE_ADVANTAGE` (ai_scorer.gd:1074).
- Ability/AbilityEffect: `expected_damage(attacker)`, `expected_heal(attacker)` (ability_effect.gd:36, 43; ai_scorer.gd:296, 327, 663-664, 782, 834), `GrantFlightEffect`, `LandEffect` (513, 523), `targeting.approach_range()`.
- NavigationGrid constants FLIGHT_MIN_ALTITUDE / FLIGHT_CEILING_HEIGHT (ai_scorer.gd:519-520); UnitMovement.FLIGHT_RULES (951, 1011).
- Physics: `direct_space_state.intersect_ray` per `_ground_y_at` call (ai_scorer.gd:1049-1052).
- FlightAiUtil (ai_scorer.gd:885, 938, 998).

## Assumptions and invariants
- **ONE AI TURN AT A TIME, GLOBALLY — STALE.** `_acting_unit`/`_move_attempts`/`_free_actions_used` are single fields (combat_ai.gd:34-35, 125) reset by any `turn_started` (45-47). The codebase now runs several encounters simultaneously (tests/combat/test_encounters.gd:39-53; per-encounter `turn_started` encounter.gd:62, relayed combat_manager.gd:362-365).
- **Every non-player, non-AI faction is "externally driven" — STALE in principle.** combat_ai.gd:16-26. `Unit.faction` is a free StringName export (unit.gd:259); only player/enemy/neutral are authored today, and nothing else drives any other faction.
- Downed units never receive `turn_started` (encounter.gd:485-490), so CombatAi never acts for one. Downed rule is player-only (unit.gd:1245-1246), so no AI-driven unit is ever Downed.
- Scoring a hypothetical is done by mutating the live unit (position, flight altitude) and restoring it synchronously (ai_scorer.gd:318-334, 551-558, 680-683, 770-794). Correct only because nothing awaits mid-score; any physics callback or signal during the write sees a fake position.
- `has_destination=false` returned from `best_plan` means "already in range" (_resolve_reach, ai_scorer.gd:594) — EXCEPT `_feral_plan` (245-252), which breaks it (issue 8).
- Behavior contract: propose, never price, |bias| ≤ 10 (ai_behavior.gd:50-84; debug-only asserts).
- Encounter.end_turn ends `current_unit`, not the caller's unit (encounter.gd:341-346); CombatAi relies on `unit` being current when it calls end_turn.

## Lifecycle
- Autoload, created at boot, connects once (combat_ai.gd:38-39). No teardown, no `combat_ended`/`unit_left_combat` handling.
- Per turn: `turn_started` → reset counters → `_attempt_action`; loops through `movement_finished` / `became_idle` until it calls end_turn.
- New game / world travel: nothing reset; a stale `_acting_unit` can survive (harmless only because the next `turn_started` overwrites it).
- Save/load: nothing saved. On combat-save resume the encounter re-emits `turn_started` for the current unit (encounter.gd:188), so an AI turn restarts from scratch with counters at 0.
- Dialogue/cutscene: no awareness; relies on Encounter not emitting turns.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | One global `_acting_unit`/`_move_attempts`/`_free_actions_used` across all encounters. Encounter B's AI turn starting while A's AI unit is mid-walk overwrites `_acting_unit`; A's `movement_finished` / `became_idle` handlers then bail (`unit != _acting_unit`) without ending A's turn → A freezes in Phase.ACTIVE. Also B resets A's move/free-action caps. | combat_ai.gd:34-35, 42-48, 125, 128-130, 165-167; relay combat_manager.gd:362-365; concurrent fights tests/combat/test_encounters.gd:39-53 | CONFIRMED |
| 2 | `ai_factions = [enemy, neutral]`: a unit of any other non-player faction (summon copying a custom faction, future faction) gets `turn_started`, CombatAi returns, nothing calls end_turn → that encounter soft-locks. Latent: only player/enemy/neutral authored today. | combat_ai.gd:26, 43-44; free-form faction unit.gd:259; summons copy faction summon_effect.gd:41, summon_demon_effect.gd:66; player test unit.gd:919-920 | CONFIRMED (latent) |
| 3 | Crit thresholds duplicated. Note: the duplicate is of `SuccessRoll.roll_vs`, not unit_combat (UnitCombat/Unit delegate to SuccessRoll, unit.gd:1423-1424). The ~1088-1110 range is ai_scorer's own copy. | ai_scorer.gd:1097-1104 vs success_roll.gd:28-34 | CONFIRMED (source corrected) |
| 4 | Hypotheticals scored by writing `global_position`/`flight_target_altitude` on the live unit then restoring. Cost per `best_plan`: candidates (abilities × hostiles + behavior plans) × `_resolve_reach` (1-2 A* `plan_route` each) + `_apply_positional_value` → `score_position` → `sustained_incoming_threat` (hostiles × their abilities × `_chance_to_hit`) + `_forced_descent_cost`/`_unsustainable_flight_cost` (raycast + another threat pass) + `threat_output` ×2-3 (each a `nearest_hostile` scan). `_kill` term calls `threat_output(target)` per lethal candidate. Only `score_position` is cached. | ai_scorer.gd:151-169, 274-276, 317-335, 410-451, 588-633, 702, 769-795, 818-863, 908-914, 934-966, 995-1023, 1049-1052 | CONFIRMED |
| 5 | "AI healer heals Downed allies instead of Pick Up." No AI-driven unit can have a Downed ally: downed rule is player-faction only and player faction is never AI-driven. Latent only if ally AI is added — then `HealWoundedAllyBehavior` would target a Downed ally (negative HP passes the fraction check) and `living_allies` includes Downed units. | unit.gd:1239-1246; combat_ai.gd:26, 43; heal_wounded_ally_behavior.gd:29-37; unit_query.gd:199-204 | NOT REPRODUCED (latent) |
| 6 | No AI code references `pick_up.tres` / `Unit.pick_up()`; only the player click route does. | unit_combat.gd:39, 210-212; no hit under systems/ai_system | CONFIRMED |
| 7 | `expected_damage(attacker)` / `expected_heal(attacker)` take no target: damage types, resistances, target DR cannot be priced. Every scorer call site passes only the attacker. | ability_effect.gd:36, 43; damage_effect.gd:37-38; ai_scorer.gd:296, 327, 479, 663-664, 782, 834 | CONFIRMED |
| 8 | Feral tier (`ai_smartness <= 0`) never approaches: `_feral_plan` returns a plan with no destination; `_attempt_action` sees out-of-range and ends the turn. Header comment calls tier 0 "the pre-scorer baseline". No authored unit uses 0 today. | ai_scorer.gd:145-146, 245-252; combat_ai.gd:71-82; ai_archetype.gd:37-40 | NEW |
| 9 | Downed party members count as hostiles: they are `is_alive()`, so they are attack candidates, `nearest_hostile` picks, and full threat sources in `incoming_threat`/`sustained_incoming_threat`/`threat_output` despite being incapacitated (no `is_downed` check anywhere in ai_system). Inflates flee/position scoring; whether attacking a Downed PC is desired is a design call. | unit.gd:1239-1240; ai_scorer.gd:268-270, 322, 774-776, 823-825; unit_query.gd:155-157; incapacitate in data/statuses/downed.tres | NEW |
| 10 | `end_turn(unit)` on a unit already released from its encounter (`unit.encounter = null`) falls back to `focused_encounter`, and `Encounter.end_turn` ends whoever is current there — CombatAi can end another fight's turn. Reachable when a fight ends/unit leaves during an AI async move or free action. | combat_manager.gd:185-188, 345-348; encounter.gd:250-251, 341-346; combat_ai.gd:132, 170 | NEW |
| 11 | Header says register as "CombatAI"; autoload name is `CombatAi`. Comments elsewhere (combat_manager.gd:181) say CombatAI. | combat_ai.gd:2-4; project.godot:22 | NEW (cosmetic) |
| 12 | `living_allies` = every non-hostile unit, so support/heal/focus-fire behaviors count neutral bystanders as allies. | unit_query.gd:199-204; support_ally_behavior.gd:38-44; focus_fire_behavior.gd:37 | NEW (verify intent) |

## Tests
- `tests/ai/`: `test_scoring.gd` (149), `test_behaviors.gd` (144), `test_flight_decisions.gd` (126), `test_archetypes.gd` (73), `test_behavior_contract.gd` (59), `test_turn_economy.gd` (51); base `tests/ai_test_case.gd`; runner `tests/run.sh`.
- Gaps: nothing drives two AI encounters' turns concurrently (test_encounters.gd checks independent state, not CombatAi); no test for an unlisted faction's turn; no feral-tier approach test; no test of AI vs Downed targets; no perf budget for `best_plan`; no check that the scorer's crit math matches `SuccessRoll`.
