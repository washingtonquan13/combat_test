# Unit

**Files:** `systems/unit_system/` (5830 lines of .gd) — `unit.gd` (1568, facade + exported data), `unit_combat.gd` (675), `unit_movement.gd` (638), `unit_animator.gd` (784, Node), `character_model.gd` (351, Node3D), `unit_vfx.gd` (262, Node), `unit_sfx.gd` (213, Node), `unit_selection.gd` (211, Node), `status_manager.gd` (205), `unit_query.gd` (204, static), `unit_action_state.gd` (118), `unit_death.gd` (116), `unit_facing.gd` (80), `flight_rules.gd` (77), `unit_alignment.gd` (67), `unit_equipment.gd` (64), `unit_skills.gd`/`unit_aim_facing.gd` (43), `active_status.gd` (17), `unit.tscn`. Stats are their own system — `systems/stat_system/`, see [stats.md](stats.md). Also composed: `systems/detection_system/unit_awareness.gd` (87).
**Autoloads owned:** none.

## Purpose
A `Unit` (CharacterBody3D) is one combatant/NPC/party body: attributes and derived stats, HP/FP, turn action budget, status effects, movement/flight execution, ability resolution, damage/downed/death, body (CharacterModel) adoption and its animation/VFX/SFX/selection presentation. `unit.gd` is a thin facade that forwards to RefCounted components built in `_ready` (unit.gd:744-770) and Node children authored in unit.tscn (unit.tscn:27-38) or added in code (`Selection`, unit.gd:760-762). It does NOT own turn order, combat start/end (Encounter/CombatManager), pathfinding (NavigationGrid), faction relations, party membership, AI decisions, or area persistence storage (AreaState/WorldManager).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| faction, abilities, ai_behaviors, senses, alignment | unit.gd:87-102, 255-283, 129-147 (exports; overwritten by `definition` setter unit.gd:21-61) | No (re-derived from scene/definition) |
| Stat bases, HP/FP pools, stat modifiers | `Stats` node of StatInstances (stats.md); reset by `definition`, then `stat_overrides` | Yes `stats` (`stats_to_dict`); modifiers no |
| has_died | unit.gd:122, set unit_death.gd:56 | No (death recorded via AreaState.mark_removed, unit_death.gd:69) |
| move_remaining / has_attacked / busy count | unit_action_state.gd (forwarded unit.gd:535-541) | `move_remaining`, `has_attacked` yes; busy count no |
| Active statuses (effect, turns, stacks) | status_manager.gd:22, active_status.gd:10-12 | Yes `statuses` as `{effect: resource_path, turns, stacks}` (status_manager.gd:35-46) |
| transform, flight_target_altitude | unit.gd:227 | Yes `transform`, `flight_altitude` |
| visual_state / posed_status | unit.gd:516-529 (written by unit_animator.gd:432-433) | No |
| encounter membership | unit.gd:891 (set by Encounter) | No (Encounter's own save) |
| Equipment, skills (child nodes), alignment, awareness | unit_equipment.gd, unit_skills.gd, unit_alignment.gd, unit_awareness.gd | Not by Unit.save_state (unit.gd:1480-1491); awareness deliberately excluded (unit.gd:1476-1478) |
| persistent_id | unit.gd:79 | identity key for AreaState |

## Derived / cached state
- Every stat read is `get_stat(id)`, recomputed with modifiers on each read (stats.md); the old raw getters are gone (issue 17).
- Stat modifiers on the StatInstances (stats.md) mirrors `StatModifierBehavior`s of active statuses; kept in sync only by apply/remove (status_manager.gd:83-84, 103-104).
- `abilities`, `dialogue_options` are aliased (not copied) from `definition` (unit.gd:48, 61).
- `radius`/`avoidance_margin`/`height`/collision shape copied from the CharacterModel at `_enter_tree` (unit.gd:657-660); shape shared, not duplicated (unit.gd:734-741).
- `is_party_leader` is computed from PartyManager (unit.gd:491-492); `is_hovered`/`is_selected` forwarded from UnitSelection (unit.gd:483-486).
- `posed_status` is the animator's cached copy of "which status pose is held" (unit.gd:529).

## Public surface
- **Calls in:** Encounter/CombatManager — `reset_turn_actions` (unit.gd:1087), `tick_statuses` (unit.gd:1147; only caller encounter.gd:470), `stabilize` (encounter.gd:322), `is_busy`/`became_idle`. AI + AbilityManager + ClickRouter — `use_ability` (unit.gd:1464, async), `move_to`/`plan_route` (unit.gd:986-998), `click_ability_for` (unit.gd:836 → unit_combat.gd:210), `is_commandable` (unit.gd:1197). Effects/behaviors — `take_damage`, `heal`, `apply_status`/`remove_status`, `die` (death_rolls_behavior.gd), `expire`, `land`, `ground_if_flying`. WorldManager — `save_state`/`load_state` (world_manager.gd:785, 820). PartyManager/debug spawner — `definition` setter before add_child (unit.gd:25-33). UI — `get_stat`, `stat_modifier_sources`, equipment/skills API (unit.gd:1361-1402); ui/party_overview.gd:372 appends to `abilities`.
- **Signals out** (unit.gd:398-477): `hover_started/ended`, `selected/deselected` (relayed from UnitSelection, unit.gd:778-781); `ability_use_started`, `ability_used` → Encounter (occupancy), animator/vfx/sfx (unit_animator.gd:190, unit_vfx.gd:92); `attacked_non_hostile_unit`; `took_damage`, `healed`; `died` → Encounter turn pruning, animator, vfx (unit_animator.gd:192); `downed_changed` → Encounter._on_unit_downed_changed (encounter.gd:232, 609), DownedTracker; `downed_tally_changed` (DeathRollsBehavior._mark, UnitCombat.stabilize) → DownedTracker; `impact_triggered`, `cast_released`; `status_applied/removed/ticked` (relayed from StatusManager, unit.gd:782-784) → animator/vfx/sfx; `visual_state_changed`; `movement_started/finished`; `took_off/touched_down`; `became_idle` (relayed from UnitActionState, unit.gd:777) → CombatManager end-turn deferral.
- **Signals in:** `mouse_entered/exited` (unit.gd:813-814); UnitSelection ← `GameMode.mode_changed` (unit_selection.gd:103-104, disconnects in `_exit_tree` unit_selection.gd:146-148); animator/vfx/sfx ← `AbilityManager.ability_armed` (unit_animator.gd:187, unit_vfx.gd:91, unit_sfx.gd:114) — safe, these are Nodes.

## Depends on
Autoloads reached directly from unit_system (9, not ~12):
- FactionRelations — `is_hostile_to` (unit.gd:880), `escalate_to_temporary_hostile` (unit_combat.gd:464)
- CombatManager — `start_combat_from_hostile_act` (unit_combat.gd:467)
- AbilityManager — `armed_ability` read in click routing (unit_combat.gd:211, 213); `armed_unit`/`ability_armed` (unit_animator.gd:187, 315; unit_sfx.gd:114, 124; unit_vfx.gd:91)
- PartyManager — `is_leader` (unit.gd:492)
- WorldManager — `current_area` (unit_death.gd:68-69), `spawn_parent` (unit_sfx.gd:198, unit_vfx.gd:262)
- SelectionManager — `deselect` (unit_death.gd:75)
- SurfaceManager — movement cost (unit_movement.gd:202)
- SystemLog — combat log lines throughout unit_combat.gd (e.g. :379, :566), unit_death.gd:34
- GameMode — highlight refresh (unit_selection.gd:103)
Static classes: AreaState.mark_removed (unit_death.gd:69), NavigationGrid.find_path/constants (unit_movement.gd:188-192, 531), RoutePlanner, Ladder (unit_movement.gd:149), SkillCalculator (unit_combat.gd:178), SuccessRoll, Encounter (via `encounter` field, unit.gd:891-903), UnitAwareness (detection system). Hard-coded resources: crit_fail_penalty.tres, pick_up.tres, altitude_advantage.tres (unit_combat.gd:32-45), downed.tres (unit_combat.gd:609).

## Assumptions and invariants
- Definition must be assigned BEFORE `add_child`, else the body is never adopted (warns only, unit.gd:30-33; `_enter_tree` guard unit.gd:602-604).
- Combat gating is per-unit, not global: `in_combat()` = `encounter != null and encounter.is_running` (unit.gd:897-898); `_maybe_trigger_combat` checks only this unit (unit_combat.gd:450-453). Good — not a one-fight assumption.
- `is_player_controlled()` == `faction == &"player"` (unit.gd:919-920): "player side" and "party" are one faction string. `uses_downed_rule()` builds on it (unit.gd:1246-1247).
- `is_alive()` = `not has_died and (hp > 0 or uses_downed_rule())` (unit.gd:1239-1240) — death of a downed-rule unit is ONLY `has_died`, never HP.
- Death removes from `"units"` group immediately and queue_frees (possibly delayed) (unit_death.gd:71, 113-116); everything querying units must use the group, not held references.
- Status effects are shared Resources compared by identity (status_manager.gd:117-121); per-unit state lives in ActiveStatus.
- Behaviors polled live (prevents_turn, grants_flight, to-hit modifiers, on_turn_start) work from `active` alone; on_apply side effects and stat modifiers require going through `apply()` (status_manager.gd:79-85).
- **Active defenses** (uncommitted): in `UnitCombat.use_ability`, every to-hit success except a critical one is followed by ONE roll against the defender's `best_defense(attacker, ability)` — the highest of Dodge, Parry, Block (ties: Dodge, then Parry); a success makes it a miss (log line "dodges"/"parries"/"blocks", `result.defense`). Dodge: melee and ranged, no limit (RAW; the Martial Arts −1 per dodge was declined). Parry = 3 + floor(Basic Attack / 2) + DB, melee only, −4 per parry already made; an empty-handed parry against an attacker holding a melee weapon is a further −3. Block = 3 + floor(Basic Attack / 2) + DB, melee and ranged, once, needs a `GearItem.is_shield` item in a melee hand. Both limits count attempts and reset in `Unit.reset_turn_actions` (the defender's own turn); saved with the unit. A shield's Defense Bonus is a DB stat modifier (wooden shield DB +2, no DR) and also adds to Dodge, at defense time (`UnitCombat.dodge_target`), so Bloodied/Exhausted halving Dodge leaves DB whole (Kromm: external bonuses after halving). Only a Unit target that `can_dodge()` — alive, not Downed, no turn-preventing status (Sleep, Stun) — so point/area abilities aimed at a Vector3 are never dodged. `hit_chance(target, ability)` = P(crit) + (P(hit) − P(crit)) × (1 − P(defense)), the same `best_defense`, from `to_hit_target` (skill + outgoing + incoming + altitude) and `SuccessRoll.chances`; the AI and the hit-chance readout both use it.
- **Resistance** (uncommitted): `inflict_status(effect, source) -> bool` is how abilities and surfaces put a status on; `apply_status` stays for rule statuses (Downed, Flying, summon timer, crit-fail penalty). If the status names `resisted_by`, `UnitCombat.resists` rolls `SuccessRoll.roll_vs(stat + resistance_modifier)`; a success blocks it (log line "resists"). Rolled only when the source is null (a surface) or hostile; an ally's status is never resisted. Asleep/Downed units still roll. `status_land_chance` gives the odds for the readout.
- STALE-risk: `unit_death.gd:68` assumes the dying unit is in the focused area; encounters-as-instances (background worlds) broke that — see issue 4.
- Status durations tick only on the unit's own combat turn (encounter.gd:470) — "statuses are a combat thing" assumption; out-of-combat statuses are frozen (issue 12).

## Lifecycle
- **Create:** `definition` setter copies template (unit.gd:21-61) → `_enter_tree` swaps/binds body once (unit.gd:601-613) → `_ready` builds components, applies `_pending_state`, definition skills, relays signals, joins `"units"` (unit.gd:744-814).
- **Load / world travel:** WorldManager reconciles a world before it enters the tree; `load_state` stashes into `_pending_state` and applies in `_ready`, or immediately if already ready (unit.gd:1495-1513). Removed persistent units are freed by WorldManager (world_manager.gd:798-801). Statuses restored via `StatusManager.load_state` (no apply hooks — issue 1).
- **Combat start:** Encounter sets `encounter`, connects `downed_changed` (encounter.gd:232). Each turn: `reset_turn_actions` then `tick_statuses` (encounter.gd:469-470).
- **Combat end:** Encounter stabilizes Downed party members (encounter.gd:322).
- **Death:** `take_damage` → `_die` → `handle_death` + `died` (unit_combat.gd:670-676); summon expiry via `expire` (unit_death.gd:33-43); dependents cascade-expire (unit_death.gd:110-111).
- **New game / dialogue / cutscene:** nothing unit-specific; cinematics use `animator()`, `anchor()`, `gaze_at()` (unit.gd:685-721).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | `load_state` rebuilds `active` without `on_apply`, `register_stat_modifier`, or `status_applied`. Loaded stat-modifier statuses (Weakened, etc.) have no stat effect; no pose/VFX (animator only poses on `status_applied`, unit_animator.gd:425-435; flyers not visually lifted, :426-427). Live-polled behaviors (prevents_turn, flight, to-hit) DO still work. Test only checks `has_status` (tests/world/test_persistence.gd:71-72). | status_manager.gd:53-61 vs 79-85 | CONFIRMED |
| 2 | `load_state` also `active.clear()`s without `on_remove`/`unregister_stat_modifier`, so loading onto a unit that already has statuses leaves orphaned stat modifiers. | status_manager.gd:54; unit_stat_modifiers.gd:4 | NEW |
| 3 | Statuses saved by `resource_path`. Inline statuses (bless, cure, shield, sleep_dart, weaken, grease, explosive_fireball) save as `res://...ability.tres::Resource_id`; restore depends on the sub-resource id staying the same across editor re-saves AND the parent ability already being in ResourceCache for `load()` to resolve a `::` path. Runtime-built effects are dropped silently. | status_manager.gd:38-45, 56; data/abilities/bless.tres:17, sleep_dart.tres:16-57 | CONFIRMED |
| 4 | Persistent-NPC death recorded under `WorldManager.current_area()` (the focused area), not the dying unit's area; a death in a background-world encounter is written to the wrong area. `WorldManager.area_of(node)` exists for this. | unit_death.gd:68-69; world_manager.gd:920, 1061-1065 | CONFIRMED |
| 5 | Fall damage before tween: `_apply_fall_damage` can kill, then `begin_busy`/`create_tween` run on the dead unit. `queue_free` is deferred so the object is NOT yet freed — no crash; the corpse still tweens down and emits `touched_down` (or the tween dies with the node and `end_busy` never fires). Cosmetic, not a freed-instance error. | unit_movement.gd:608-617, 627-638; unit_death.gd:113-116 | NOT REPRODUCED (as a crash); dead-unit tween CONFIRMED |
| 6 | `unit_combat` await has no `is_instance_valid` guard: `_wait_for_impact_or_timeout` loops `await _owner.get_tree().process_frame`; if the attacker is freed mid-wait, the RefCounted coroutine keeps running and dereferences a freed `_owner`; `use_ability` continues to `end_busy`/`_apply_effects`/`ability_used.emit` on it. | unit_combat.gd:388-391, 497-498, 400-410 | CONFIRMED |
| 7 | `stabilize()` sets HP to 1 unconditionally; a Downed unit healed above 1 (heal doesn't clear Downed) is lowered to 1, and `healed` is emitted with a negative amount. | unit_combat.gd:627-631 | CONFIRMED |
| 8 | `heal()` never clears Downed or emits `downed_changed`; a unit healed to full stays Downed, incapacitated, on its death timer. | unit_combat.gd:540-548 | CONFIRMED |
| 9 | `downed_changed` emitted by hand at 3 sites (pick_up, stabilize, _roll_to_stay_up), not from status apply/remove. DeathRolls killing, and `handle_death`'s removal (unit_death.gd:59) never emit it; any other `apply_status(downed)` caller would skip it too. | unit_combat.gd:597, 632, 661; death_rolls_behavior.gd | CONFIRMED |
| 10 | downed.tres `stack_mode = 0` = REFRESH (status_effect.gd:15-16), so a reapply resets the timer to 3. take_damage guards with `was_downed` (unit_combat.gd:567, 576) so only an external `apply_status` reaches it. | data/statuses/downed.tres:21; status_manager.gd:71-73 | CONFIRMED (latent) |
| 11 | `uses_downed_rule()` is a live faction/summon check feeding `is_alive()`; if faction or `owned_demon` changes while at HP<=0, the unit flips alive<->dead without `died` or `handle_death`. | unit.gd:1239-1247 | CONFIRMED |
| 12 | Downed outside an encounter never ticks or ends — `tick_statuses` only called from encounter.gd:470. Only hits (DeathRolls death marks) can advance it; fight end leaves it stable. | encounter.gd:470; unit.gd:1147-1148 | CONFIRMED |
| 13 | `Unit.die()` calls private `_combat._die()`; tests also reach into `_combat._thresholds_crossed`. | unit.gd:1275-1276; tests/combat/test_downed.gd:27-29 | CONFIRMED |
| 14 | Autoload coupling: 9 autoloads (list above), not ~12. `unit_combat` reads `AbilityManager.armed_ability` (global UI state inside rules code) and calls `CombatManager.start_combat_from_hostile_act`. | unit_combat.gd:211-213, 467 | CONFIRMED (count corrected to 9) |
| 15 | `get_stat(String)` matches literal "ST"/"DX"/... ; a typo gets base 0 + any modifiers, no warning. `get_attribute_value` forwards the same. | unit.gd:1314-1325, 1299-1300 | FIXED (data-driven stats, uncommitted) — ids are StatDefinition ids; an unknown id errors by name (unit_stats.gd `_instance`) |
| 16 | `abilities = definition.abilities` aliases the template array; ui/party_overview.gd:372 `_unit.abilities.append(...)` mutates the shared UnitDefinition for every unit of that species. Same aliasing for `dialogue_options`. | unit.gd:48, 61; ui/party_overview.gd:372 | CONFIRMED |
| 17 | Two Move/HP answers: `move` and `maximum_hp` getters read raw DX/HT/ST, so status modifiers to DX/HT/ST don't change the turn budget (`reset_turn_actions` uses `move`, unit.gd:1087-1088) while `get_stat("Move")` does. | unit.gd:110-115, 164-166 vs 1323 | FIXED (data-driven stats, uncommitted) — one `get_stat`; the turn budget is `move_per_turn()` = `get_stat(StatIds.MOVE)` |
| 18 | HT roll to stay up uses raw `_owner.health`, ignoring HT modifiers. | unit_combat.gd:653 | FIXED (data-driven stats, uncommitted) — `get_stat(StatIds.HT)` |
| 19 | STACK mode increments `stacks` but stat modifiers are registered once; stacks never scale modifier amount. | status_manager.gd:74-77, 83-84 | NEW |
| 20 | `Unit.save_state` omits equipment, skills, alignment and `has_died`; a persistent NPC's alignment shift or equipment change is lost on world unload (party members may be saved elsewhere). | unit.gd:1480-1491 | NEW |

## Tests
- tests/combat/test_dodge.gd — 10/10/10 Dodge is 8, hit chance is the exact formula, a Downed defender cannot dodge.
- tests/combat/test_defenses.gd — Parry chosen over a lower Dodge vs melee only, −4 after a parry, reset on the turn, shield DB raises the Dodge target, Block vs ranged once.
- tests/combat/test_resistance.gd — Sleep is resisted by HT, Basic Speed 10/10 is 5, a hostile's Sleep lands on HT 10 half the time, an ally's status is never resisted.
- tests/combat/test_downed.gd — thresholds, death depth, timer, pick_up, stabilize-at-fight-end (no heal-while-downed, no out-of-combat case).
- tests/world/test_persistence.gd — status round-trip checks `has_status` only (:53, :71-72), not stat effect or pose; no inline-status case.
- tests/combat/test_a_body_*.gd, test_a_definition_*.gd — body adoption/anchors/definition. test_selection_is_a_node.gd, test_commanding.gd, test_flight_animation.gd, test_flight_decisions.gd.
- Gaps: no test for death-in-background-area recording, fall-damage lethality, freed-attacker await, `get_stat` typos, definition-array aliasing, modified Move budget.
