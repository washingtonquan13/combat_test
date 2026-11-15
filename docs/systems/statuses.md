# Status effects

**Files:** `systems/ability_system/status_effect.gd` (103), `status_behavior.gd` (87), 13 behaviors: `stat_modifier_behavior.gd` (25), `damage_over_time_behavior.gd` (36), `heal_over_time_behavior.gd` (33), `fp_drain_behavior.gd` (39), `incapacitate_behavior.gd` (33), `prone_behavior.gd` (31), `remove_on_damage_behavior.gd` (15), `death_rolls_behavior.gd` (64), `despawn_on_expire_behavior.gd` (19), `force_land_on_expire_behavior.gd` (22), `flight_behavior.gd` (17), `incoming_attack_modifier_behavior.gd` (19), `outgoing_attack_modifier_behavior.gd` (18); plus `active_stat_modifier.gd` (21). Applying/removing effects: `apply_status_effect.gd` (24), `area_apply_status_effect.gd` (43), `remove_status_effect.gd` (31). Data: `data/statuses/` (5 .tres). Runtime per-unit container: `systems/unit_system/status_manager.gd` (205) + `active_status.gd` (17) — **owned by the Unit doc**, referenced here.
**Autoloads owned:** none.

## Purpose
`StatusEffect` is shared data: name, duration, stack rule, curable flag, a list of `StatusBehavior` hooks, and FX (`status_effect.gd:8-94`). Behaviors are stateless hook objects that StatusManager calls on apply/remove/turn start/damage and that to-hit/flight queries poll (`status_behavior.gd:16-86`). NOT responsible for: per-unit active state, durations, ticking or save (StatusManager/Unit), ground surfaces (surface system, which only points at a StatusEffect, `surface.gd:43`). `AltitudeAdvantageBehavior` lives in this folder but is NOT a status (`altitude_advantage_behavior.gd:2` extends Resource; used as a constant by UnitCombat).

## Inventory
**10 statuses listed below (original audit): 5 files, 5 inline sub_resources. At HEAD 14cb4ad9 (review 11-15) `data/statuses/` holds 14 standalone files, and inline StatusEffect sub_resources live in 23 files: 14 ability files (bless, cling, cure, darkness, enlarge_person, explosive_fireball, fire_breath, fog_cloud, grease, reduce_person, shield, sleep_dart, wall_of_fire, weaken) and 9 surface files (electrified_steam_cloud, electrified_wall_of_water, electrified_water, fire, ice, steam_cloud, wall_of_water, water, web).**
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
| Status definitions | `data/statuses/*.tres`, inline in 23 ability and surface `.tres` files; schema `status_effect.gd:8-94` | Static. Active instances saved by `resource_path` under `statuses` (`status_manager.gd:35-46`, `unit.gd:1488`) |
| Active statuses, turns, stacks | StatusManager `active` (`status_manager.gd:22`), `ActiveStatus` (`active_status.gd:10-12`) — Unit doc | Yes: `{effect, turns, stacks}` per unit |

## Derived / cached state
- Stat modifiers from `StatModifierBehavior` are registered on the unit's StatInstances (stats.md) on apply (`status_manager.gd:83-84`) and unregistered on remove (`:103-104`). This registry is a second truth for "is Shield active"; `load_state` rebuilds `active` without re-registering (issue 3).
- `UnitCombat._downed_status` static cache of `downed.tres` (`unit_combat.gd:605-610`); `CRIT_FAIL_PENALTY` preload (`unit_combat.gd:32`).

## Public surface
- **Resistance** (committed in 82eb3dc7): `resisted_by` (a stat id, editor-suggested via `@tool` `_validate_property`) and `resistance_modifier` on StatusEffect. ApplyStatusEffect, AreaApplyStatusEffect and surfaces call `Unit.inflict_status`, which rolls it (unit.md, Resistance); a resisted single-target status returns `resisted_status`. Resisted: Sleep (HT, sleep_dart.tres inline), Weakened (HT), Slipped (DX, grease.tres inline). Not resisted: buffs, Burning, Off-Balance, rule statuses.
- **Calls in**: `Unit.apply_status/remove_status/has_status/status_turns_remaining` (`unit.gd:1094-1109`) from `ApplyStatusEffect` (`apply_status_effect.gd:19`), `AreaApplyStatusEffect` (`:36`), `RemoveStatusEffect` (`:25`), surfaces, `unit_combat.gd:381` (crit fail), downed flow (`unit_combat.gd:595,629`), Fly/Land/summon effects, behaviors themselves (`fp_drain_behavior.gd:32`, `remove_on_damage_behavior.gd:11`). AI reads `effect.status` (`support_ally_behavior.gd:74,84`), `flight_ai_util.gd:55`.
- **Behavior hooks** called by StatusManager: `on_apply` (`status_manager.gd:81-82`), `on_remove` (`:101-102`), `on_turn_start` (`:131-132`), `prevents_turn` (`:143-148`), `on_damage_taken` (`:153-156`), `grants_flight` (`:162-183`), to-hit modifiers (`:189-200`, summed into `unit_combat.gd:419-425`).
- **Signals out**: none in this system; StatusManager emits `status_applied/removed/ticked` (`status_manager.gd:17-19`, Unit doc).
- **Signals in**: none.

## Depends on
- `Unit`: `ground_if_flying` (`incapacitate_behavior.gd:25`), `take_damage`/`get_stat` (`damage_over_time_behavior.gd:24-25`), `heal` (`heal_over_time_behavior.gd:19`), `current_fp` (`fp_drain_behavior.gd:26-35`), `die`/`roll_while_downed` (`death_rolls_behavior.gd`), `expire` (`despawn_on_expire_behavior.gd:15`), `land` (`force_land_on_expire_behavior.gd:18`), `remove_status`.
- `MeleeEnemyTargeting`/`RangedEnemyTargeting` type checks — `prone_behavior.gd:23-26`.
- `SystemLog`/`LogFormat` — `heal_over_time_behavior.gd:22`, `death_rolls_behavior.gd`.
- Turn ticking comes only from `Encounter` (`encounter.gd:488` -> `unit.gd:1147`).

## Assumptions and invariants
- Status identity is Resource identity: `_find` compares `a.effect == effect` (`status_manager.gd:117-121`). Every caller must hold the SAME instance (e.g. Cure and Weaken both ext_resource `weakened.tres`, `cure.tres:6`, `weaken.tres:6`). A duplicated/reloaded copy is a different status.
- Durations are combat turns only: the sole ticker is `encounter.gd:488`. Out of combat nothing expires (Sleep, Slipped, Shielded, Flying last until the next fight). Implicit "statuses are a combat thing" assumption.
- Behaviors carry no per-unit state; per-unit state is `ActiveStatus` (`active_status.gd:10-12`). Shared behavior instances across units are safe only because of this.
- `on_remove` hooks cannot tell expiry from cure/dismiss. `ActiveStatus.stopped` freezes the timer (saved); `ActiveStatus.tally` holds per-application counts (saved). `on_damage_taken` gets a `critical` flag (Gear/StDamageEffect pass it). Downed (DeathRolls): each turn rolls HT − depth (`Unit.roll_while_downed`), success +1 stable / failure +1 death, criticals +2; 3 stable = `Unit.is_stable` (still Downed, no more rolls), 3 death = dies. Every hit +1 death (crit +2); a hit on a stable unit resets both tracks first. Fight end (`Unit.stabilize`) marks stable, HP kept, still Downed. `DespawnOnExpire` and `ForceLandOnExpire` fire on ANY removal (`despawn_on_expire_behavior.gd:14-15`, `force_land_on_expire_behavior.gd:17-18`).
- `StatusEffect.counters` (groups): applying a status to a unit holding a status of a countered group removes that one and does not land (`StatusManager.countered_by`); `ApplyStatusEffect` reports `countered_status`. Resistance still applies first. Enlarged/Reduced counter each other, so size steps −1 ↔ 0 ↔ +1. By group, not by resource, to avoid an ext_resource cycle.
- Stacks multiply DoT/HoT/FP drain (`damage_over_time_behavior.gd:21`, `fp_drain_behavior.gd:25`) but not stat modifiers, which register once (`status_manager.gd:83-84`). All 10 statuses use `stack_mode = 0` (REFRESH), so stacking is untested in data.

- Permanent statuses (review 2026-11-15): `add_permanent` (`status_manager.gd:133`) holds a status with no duration for a toggle's `while_on`; permanent statuses are not in a save (`status_manager.gd:63`; U5) and `add_permanent` has no duplicate guard (U15).

## Lifecycle
- Definitions are loaded with their owning .tres (inline ones only exist once the owning ability .tres is loaded).
- Apply: `StatusManager.apply` (`status_manager.gd:64-85`). Tick: start of the unit's encounter turn (`status_manager.gd:129-137`). Remove: expiry, cure, behavior-driven, Land.
- Save: path + turns + stacks; effects with empty `resource_path` are dropped (`status_manager.gd:38-40`). Load: rebuilds `active` directly, no `on_apply`, no signals (deliberate, comment at `status_manager.gd:57-63`); stat modifiers are re-registered since `status_manager.gd:82` (review 11-15, DOC DRIFT fixed in doc).
- Combat end / world travel / dialogue / cutscene: no status handling in this system.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | 5 of 10 statuses are inline sub_resources in ability .tres files (Blessed, Shielded, Sleep, Burning, Slipped); their saved `resource_path` is `res://data/abilities/<x>.tres::Resource_<id>`, tied to an editor-assigned local id that changes on "Make Unique"/copy/restructure. `load()` of a `::` sub-path also only resolves if the parent ability is already loaded and cached | `bless.tres:17`, `shield.tres:18`, `sleep_dart.tres:37`, `explosive_fireball.tres:108`, `grease.tres:25`; `status_manager.gd:42,56` | CONFIRMED; review 11-15: still open, worse (23 files define statuses inline), see U3 |
| 2 | StatusEffect has no id field; only `status_name` (display) and path | `status_effect.gd:8` | CONFIRMED (part of the "no stable ids" family); review 11-15: still open, see U3 |
| 3 | Loaded statuses with `StatModifierBehavior` (Shielded +3 DR, Weakened -2 DR) are restored in `active` but never re-registered with Unit's stat modifiers, so the stat effect is lost after load; removal later calls `unregister` for something never registered | `status_manager.gd:53-61` vs `:83-84,103-104`; `unit.gd:1345-1350` | FIXED (status_manager.gd:82), confirmed by review 11-15; `on_apply` still skipped on load, see U4 |
| 4 | Statuses never tick out of combat; only `Encounter` calls `tick_statuses` | `encounter.gd:488`; `unit.gd:1147`; `status_manager.gd:129` | NEW (may be intended; undocumented); review 11-15: still open, see U23 |
| 5 | `DespawnOnExpire` / `ForceLandOnExpire` run on any removal, not only expiry (a future Cure of Summoned would despawn the summon) | `despawn_on_expire_behavior.gd:14-15`; `summon_duration.tres` lacks `curable=false` | NEW |
| 6 | `downed.tres` has no `uid=` in its header (other 4 do); it is only referenced by path (`unit_combat.gd:609`) | `data/statuses/downed.tres:1` | NEW (minor); review 11-15: still open |
| 7 | `StatModifierBehavior` ignores stacks | `status_manager.gd:83-84` | NEW (latent; no STACK data); review 11-15: still open, see U14 |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| U3 | Statuses are saved by resource path while 23 files now define statuses inline (an inline path is `res://x.tres::StatusEffect_abc`); a re-save or rename changes the id and `load()` returns null, so the status silently vanishes on load. | status_manager.gd:44-48, 74-76 (documented choice at 37-40) | Surfaces and elemental spells (6677d929, 96958ec4, 1d5e7cf2) authored statuses inside their own files and the save format was not revisited. | An `id: StringName` on StatusEffect and a `StatusDatabase` on the ResourceCatalog pattern AdvantageDatabase uses (advantage_database.gd:35); save the id and warn on an unknown one; inline statuses that must persist become files. | R2 | M-L | KNOWN (#1, #2) |
| U4 | Loading restores stat modifiers but not what `on_apply` did (pose, VFX loop, flags), so a loaded Incapacitated or Downed unit has the status listed without its lying pose. | status_manager.gd:64-83; rooted_behavior.gd:16; incapacitate_behavior.gd:28; held_by_rule_behavior.gd:9; death_rolls_behavior.gd:20 | `load_state` avoids `apply()` so durations are not reset (comment 57-63); behaviors were never given a restore step. | `StatusBehavior.on_restore(unit, active)` defaulting to nothing, and a `status_restored` signal that vfx, sfx and animator treat as show-without-flourish. | R2 | S-M | KNOWN (unit.md #1) |
| U10 | Downed is announced by hand (`downed_changed` and `downed_tally_changed`) at each place it changes; `unit_death.gd:59` and `load_state` change it with no emit. | unit_combat.gd:1420, 1440, 1469; death_rolls_behavior.gd:57; unit_death.gd:59 | A quick fix from 82eb3dc7. | Unit listens to its own `status_applied` / `status_removed` and emits `downed_changed` when the effect is `downed_status()`; delete the hand emits. | R4 | S | KNOWN (unit.md #9) |
| U13 | Every status mechanic costs three edits: a virtual on StatusBehavior, an aggregate on StatusManager (eleven near-identical double loops) and a forward on Unit. | status_manager.gd:243-369; unit.gd:1622, 1566, 1573, 1678-1710 | Catfall, Super Jump, Hard to Kill and Charismatic (03c63f48) each repeated the pattern. | Generic folds on StatusManager (`any`, `sum`, `product`), or behaviors contribute named stat modifiers so jump multiplier and fall reduction become derived stats with no new code. | R7 | M | DECISION NEEDED: add generic folds or derived stats now, or keep adding the three edits per mechanic? |
| U14 | Stacking a status does not stack its stat modifiers (registered once on first apply); no STACK status with a modifier exists in data yet. | status_manager.gd:114-125 | Modifiers were wired to first apply only. | Register per stack or scale the amount by `stacks`; `apply` and `remove` call `_set_stat_modifiers`. | R4 | S-M | KNOWN (#7; unit.md #19) |
| U15 | `add_permanent` has no duplicate guard and `remove` takes the first identity match, so a toggle reached twice leaves two entries and one `remove` leaves a ghost with no modifiers. | status_manager.gd:133-141, 172-184, 213-217; unit_advantages.gd:59-60 | Permanent statuses were added for toggles without the guard `apply` has. | `add_permanent` returns early when `_find(effect)` is non-null. | R2 | S | BUG (latent) |
| U23 | Statuses tick only inside an encounter, so Burning, Bless and a summon's duration freeze when combat ends. | unit.gd:1615-1616; encounter.gd:488 | Ticking was written as a combat-turn hook. | Real-time seconds per turn out of combat is the usual answer; needs the rule first, then M. | R4 | design question, then M | DECISION NEEDED: what ticks statuses outside combat (real-time seconds per turn, or never)? Same as #4, unit.md #12 |

## Tests
- `tests/world/test_persistence.gd:19,51-73` — Weakened survives save/load (checks `has_status` only, NOT the DR modifier, so it misses issue 3; uses a file-backed status, so it misses issue 1).
- `tests/combat/test_downed.gd` — Downed two tracks: hit = death mark (crit 2), turns end stable-or-dead within 5, hit on stable restarts, heal/pick-up at negative HP, fight end leaves stable.
- Gaps: no test for inline-status save/load, stacking, out-of-combat duration, or cure interactions.
