# Status effects

**Files:** `systems/ability_system/status_effect.gd` (103), `status_behavior.gd` (87), 13 behaviors: `stat_modifier_behavior.gd` (25), `damage_over_time_behavior.gd` (36), `heal_over_time_behavior.gd` (33), `fp_drain_behavior.gd` (39), `incapacitate_behavior.gd` (33), `prone_behavior.gd` (31), `remove_on_damage_behavior.gd` (15), `death_rolls_behavior.gd` (64), `despawn_on_expire_behavior.gd` (19), `force_land_on_expire_behavior.gd` (22), `flight_behavior.gd` (17), `incoming_attack_modifier_behavior.gd` (19), `outgoing_attack_modifier_behavior.gd` (18); plus `active_stat_modifier.gd` (21). Applying/removing effects: `apply_status_effect.gd` (24), `area_apply_status_effect.gd` (43), `remove_status_effect.gd` (31). Data: `data/statuses/` (5 .tres). Runtime per-unit container: `systems/unit_system/status_manager.gd` (205) + `active_status.gd` (17) — **owned by the Unit doc**, referenced here.
**Autoloads owned:** none.

## Purpose
`StatusEffect` is shared data: name, duration, stack rule, curable flag, a list of `StatusBehavior` hooks, and FX (`status_effect.gd:8-94`). Behaviors are stateless hook objects that StatusManager calls on apply/remove/turn start/damage and that to-hit/flight queries poll (`status_behavior.gd:16-86`). NOT responsible for: per-unit active state, durations, ticking or save (StatusManager/Unit), ground surfaces (surface system, which only points at a StatusEffect, `surface.gd:43`). `AltitudeAdvantageBehavior` lives in this folder but is NOT a status (`altitude_advantage_behavior.gd:2` extends Resource; used as a constant by UnitCombat).

## Inventory
**10 statuses total: 5 files, 5 inline sub_resources.**
| Status | Where | Behaviors |
|---|---|---|
| Off-Balance | `data/statuses/crit_fail_penalty.tres:14` | OutgoingAttackModifier -2 |
| Downed | `data/statuses/downed.tres:20` (curable=false) | Incapacitate, DeathRolls (two tracks in `ActiveStatus.tally`; timer `stopped` from apply) |
| Flying | `data/statuses/flying.tres:24` (99 turns) | Flight, ForceLandOnExpire, FpDrain 1 |
| Summoned | `data/statuses/summon_duration.tres:13` | DespawnOnExpire |
| Weakened | `data/statuses/weakened.tres:15` | StatModifier DR -2 |
| Blessed | inline `data/abilities/bless.tres:17` (`Resource_status`) | OutgoingAttackModifier |
| Shielded | inline `data/abilities/shield.tres:18` (`Resource_status`) | StatModifier +3 |
| Sleep | inline `data/abilities/sleep_dart.tres:37` (`Resource_qnicf`) | Incapacitate, RemoveOnDamage |
| Burning | inline `data/abilities/explosive_fireball.tres:108` (`Resource_inwvo`) | DamageOverTime |
| Slipped | inline `data/abilities/grease.tres:25` (`Resource_efyr5`), also the Grease surface's status (`grease.tres:44`) | Incapacitate, Prone |
Unused behaviors: `HealOverTimeBehavior`, `IncomingAttackModifierBehavior` (no .tres references them). `StatModifierBehavior` is also reused by 7 items in `data/items/`.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Status definitions | `data/statuses/*.tres`, 5 inline in `data/abilities/*.tres`; schema `status_effect.gd:8-94` | Static. Active instances saved by `resource_path` under `statuses` (`status_manager.gd:35-46`, `unit.gd:1488`) |
| Active statuses, turns, stacks | StatusManager `active` (`status_manager.gd:22`), `ActiveStatus` (`active_status.gd:10-12`) — Unit doc | Yes: `{effect, turns, stacks}` per unit |

## Derived / cached state
- Stat modifiers from `StatModifierBehavior` are registered on the unit's StatInstances (stats.md) on apply (`status_manager.gd:83-84`) and unregistered on remove (`:103-104`). This registry is a second truth for "is Shield active"; `load_state` rebuilds `active` without re-registering (issue 3).
- `UnitCombat._downed_status` static cache of `downed.tres` (`unit_combat.gd:605-610`); `CRIT_FAIL_PENALTY` preload (`unit_combat.gd:32`).

## Public surface
- **Resistance** (uncommitted): `resisted_by` (a stat id, editor-suggested via `@tool` `_validate_property`) and `resistance_modifier` on StatusEffect. ApplyStatusEffect, AreaApplyStatusEffect and surfaces call `Unit.inflict_status`, which rolls it (unit.md, Resistance); a resisted single-target status returns `resisted_status`. Resisted: Sleep (HT, sleep_dart.tres inline), Weakened (HT), Slipped (DX, grease.tres inline). Not resisted: buffs, Burning, Off-Balance, rule statuses.
- **Calls in**: `Unit.apply_status/remove_status/has_status/status_turns_remaining` (`unit.gd:1094-1109`) from `ApplyStatusEffect` (`apply_status_effect.gd:19`), `AreaApplyStatusEffect` (`:36`), `RemoveStatusEffect` (`:25`), surfaces, `unit_combat.gd:381` (crit fail), downed flow (`unit_combat.gd:595,629`), Fly/Land/summon effects, behaviors themselves (`fp_drain_behavior.gd:32`, `remove_on_damage_behavior.gd:11`). AI reads `effect.status` (`support_ally_behavior.gd:74,84`), `flight_ai_util.gd:55`.
- **Behavior hooks** called by StatusManager: `on_apply` (`status_manager.gd:81-82`), `on_remove` (`:101-102`), `on_turn_start` (`:131-132`), `prevents_turn` (`:143-148`), `on_damage_taken` (`:153-156`), `grants_flight` (`:162-183`), to-hit modifiers (`:189-200`, summed into `unit_combat.gd:419-425`).
- **Signals out**: none in this system; StatusManager emits `status_applied/removed/ticked` (`status_manager.gd:17-19`, Unit doc).
- **Signals in**: none.

## Depends on
- `Unit`: `ground_if_flying` (`incapacitate_behavior.gd:25`), `take_damage`/`get_stat` (`damage_over_time_behavior.gd:24-25`), `heal` (`heal_over_time_behavior.gd:19`), `current_fp` (`fp_drain_behavior.gd:26-35`), `die`/`roll_while_downed` (`death_rolls_behavior.gd`), `expire` (`despawn_on_expire_behavior.gd:15`), `land` (`force_land_on_expire_behavior.gd:18`), `remove_status`.
- `MeleeEnemyTargeting`/`RangedEnemyTargeting` type checks — `prone_behavior.gd:23-26`.
- `SystemLog`/`LogFormat` — `heal_over_time_behavior.gd:22`, `death_rolls_behavior.gd`.
- Turn ticking comes only from `Encounter` (`encounter.gd:470` -> `unit.gd:1147`).

## Assumptions and invariants
- Status identity is Resource identity: `_find` compares `a.effect == effect` (`status_manager.gd:117-121`). Every caller must hold the SAME instance (e.g. Cure and Weaken both ext_resource `weakened.tres`, `cure.tres:6`, `weaken.tres:6`). A duplicated/reloaded copy is a different status.
- Durations are combat turns only: the sole ticker is `encounter.gd:470`. Out of combat nothing expires (Sleep, Slipped, Shielded, Flying last until the next fight). Implicit "statuses are a combat thing" assumption.
- Behaviors carry no per-unit state; per-unit state is `ActiveStatus` (`active_status.gd:10-12`). Shared behavior instances across units are safe only because of this.
- `on_remove` hooks cannot tell expiry from cure/dismiss. `ActiveStatus.stopped` freezes the timer (saved); `ActiveStatus.tally` holds per-application counts (saved). `on_damage_taken` gets a `critical` flag (Gear/StDamageEffect pass it). Downed (DeathRolls): each turn rolls HT − depth (`Unit.roll_while_downed`), success +1 stable / failure +1 death, criticals +2; 3 stable = `Unit.is_stable` (still Downed, no more rolls), 3 death = dies. Every hit +1 death (crit +2); a hit on a stable unit resets both tracks first. Fight end (`Unit.stabilize`) marks stable, HP kept, still Downed. `DespawnOnExpire` and `ForceLandOnExpire` fire on ANY removal (`despawn_on_expire_behavior.gd:14-15`, `force_land_on_expire_behavior.gd:17-18`).
- `StatusEffect.counters` (groups): applying a status to a unit holding a status of a countered group removes that one and does not land (`StatusManager.countered_by`); `ApplyStatusEffect` reports `countered_status`. Resistance still applies first. Enlarged/Reduced counter each other, so size steps −1 ↔ 0 ↔ +1. By group, not by resource, to avoid an ext_resource cycle.
- Stacks multiply DoT/HoT/FP drain (`damage_over_time_behavior.gd:21`, `fp_drain_behavior.gd:25`) but not stat modifiers, which register once (`status_manager.gd:83-84`). All 10 statuses use `stack_mode = 0` (REFRESH), so stacking is untested in data.

## Lifecycle
- Definitions are loaded with their owning .tres (inline ones only exist once the owning ability .tres is loaded).
- Apply: `StatusManager.apply` (`status_manager.gd:64-85`). Tick: start of the unit's encounter turn (`status_manager.gd:129-137`). Remove: expiry, cure, behavior-driven, Land.
- Save: path + turns + stacks; effects with empty `resource_path` are dropped (`status_manager.gd:38-40`). Load: rebuilds `active` directly, no `on_apply`, no signals (`status_manager.gd:53-61`, deliberate per `:49-52`).
- Combat end / world travel / dialogue / cutscene: no status handling in this system.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | 5 of 10 statuses are inline sub_resources in ability .tres files (Blessed, Shielded, Sleep, Burning, Slipped); their saved `resource_path` is `res://data/abilities/<x>.tres::Resource_<id>`, tied to an editor-assigned local id that changes on "Make Unique"/copy/restructure. `load()` of a `::` sub-path also only resolves if the parent ability is already loaded and cached | `bless.tres:17`, `shield.tres:18`, `sleep_dart.tres:37`, `explosive_fireball.tres:108`, `grease.tres:25`; `status_manager.gd:42,56` | CONFIRMED |
| 2 | StatusEffect has no id field; only `status_name` (display) and path | `status_effect.gd:8` | CONFIRMED (part of the "no stable ids" family) |
| 3 | Loaded statuses with `StatModifierBehavior` (Shielded +3 DR, Weakened -2 DR) are restored in `active` but never re-registered with Unit's stat modifiers, so the stat effect is lost after load; removal later calls `unregister` for something never registered | `status_manager.gd:53-61` vs `:83-84,103-104`; `unit.gd:1345-1350` | NEW |
| 4 | Statuses never tick out of combat; only `Encounter` calls `tick_statuses` | `encounter.gd:470`; `unit.gd:1147`; `status_manager.gd:129` | NEW (may be intended; undocumented) |
| 5 | `DespawnOnExpire` / `ForceLandOnExpire` run on any removal, not only expiry (a future Cure of Summoned would despawn the summon) | `despawn_on_expire_behavior.gd:14-15`; `summon_duration.tres` lacks `curable=false` | NEW |
| 6 | `downed.tres` has no `uid=` in its header (other 4 do); it is only referenced by path (`unit_combat.gd:609`) | `data/statuses/downed.tres:1` | NEW (minor) |
| 7 | `StatModifierBehavior` ignores stacks | `status_manager.gd:83-84` | NEW (latent; no STACK data) |

## Tests
- `tests/world/test_persistence.gd:19,51-73` — Weakened survives save/load (checks `has_status` only, NOT the DR modifier, so it misses issue 3; uses a file-backed status, so it misses issue 1).
- `tests/combat/test_downed.gd` — Downed two tracks: hit = death mark (crit 2), turns end stable-or-dead within 5, hit on stable restarts, heal/pick-up at negative HP, fight end leaves stable.
- Gaps: no test for inline-status save/load, stacking, out-of-combat duration, or cure interactions.
