# Abilities & effects

**Files:** `systems/ability_system/` (60 .gd, 3306 lines total; this doc covers the ability half). Key files: `ability.gd` (249), `ability_manager.gd` (143), `ability_database.gd` (53), `ability_effect.gd` (44), `ability_targeting.gd` (132), `ability_timing.gd` (38). 18 `AbilityEffect` subclasses (`*_effect.gd`), 7 targeting classes (`melee_enemy`, `ranged_enemy`, `ground_point`, `area`, `aerial_area` (extends area), `self`, `dismiss`), VFX/animation composition (`vfx_effect.gd`, 6 `*_step.gd`, `animation_sequence.gd`, `animation_phase.gd`, `magic_missile_projectile.gd/.tscn`). Data: `data/abilities/` (**19 .tres**). Execution lives in `systems/unit_system/unit_combat.gd:264-447` (owned by the Unit doc).
**Autoloads owned:** `AbilityManager` (`project.godot:23`).

## Purpose
Defines what an ability IS: a data-only `Ability` Resource composed of one targeting shape, an ordered list of effects, costs, optional timing, and cast/armed presentation (`ability.gd:22-150`). `AbilityManager` tracks the one "armed" ability for click-to-target (`ability_manager.gd:29-36`). `AbilityDatabase` resolves abilities by name for save/load and debug grant lists (`ability_database.gd:36`). NOT responsible for: executing an ability (to-hit roll, cost spending, effect loop are `UnitCombat.use_ability`, `unit_combat.gd:264-409`), status lifetime (see statuses.md), hotbar UI (`ui/ability_hotbar.gd`, `ui/hotbar_slot.gd`), AI choice (`systems/ai_system/`).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Ability definitions (targeting, effects, costs, FX) | `data/abilities/*.tres`, schema `ability.gd:22-150` | Static data. Units reference by `ability_name` (party: `abilities` / `custom_slots`, `party_manager.gd:506-511`) |
| Armed ability | `ability_manager.gd:29` `armed_ability` | No |
| Who it is armed for | `ability_manager.gd:36` `armed_unit` | No |
| Watched unit (ability_used hook) | `ability_manager.gd:43` `_watched_unit` | No |
| Aerial aim height override | `ability_manager.gd:58-59` | No |
| Name->Ability cache | `ability_database.gd:20,52` (static `ResourceCatalog`) | No (rebuilt from disk) |

## Derived / cached state
- `AbilityDatabase._catalog` caches a one-time scan of `data/abilities/` (`ability_database.gd:52`); stale if a .tres is added at runtime without `refresh()` (`:43`).
- `Ability.indicator_ids()` / `get_pathed_projectile_step()` / `get_move_caster_effect()` are derived from composition at call time, not stored (`ability.gd:180-233`), so they cannot drift.
- `armed_unit` duplicates "who is commanded" (`PlayerInteractionState.get_active_unit()`, read at `ability_manager.gd:63,103`); it is only refreshed by `arm()`/`disarm()`, so it can disagree with the active unit (see Known issues 3).
- `Unit.abilities` / `custom_slots` (Unit doc) and `PartyMemberData.abilities` are copies of references to the shared .tres (`party_manager.gd:390-391,740-741`).

## Public surface
- **Calls in**
  - `AbilityManager.arm(ability)` — `ui/hotbar_slot.gd:110,169`; `disarm()` — `ui/ability_hotbar.gd:116,131,170,232`, `ui/hotbar_slot.gd:108`, `systems/interaction_system/aiming_intent.gd:47`, `systems/save_system/save_manager.gd:620` (new_game only).
  - `AbilityManager.armed_ability` read by 6 indicators, `ground_click_target.gd`, `ui/hotbar_slot.gd`, and `unit_combat.gd:211-213` (`resolve_click_ability`). `set_aim_height_override` / `aim_height_override` — `aerial_area_indicator.gd:82,113`, `aerial_area_targeting.gd:36-37`.
  - `AbilityDatabase.find(name)` — `party_manager.gd:650,660`; `get_all()` — `ui/party_overview.gd:196` (debug grant list).
  - `Ability.is_in_range`, `attack_action_spent_by`, `indicator_ids` (`ability.gd:158,248,180`) — UnitCombat, hotbar, indicators. `AbilityEffect.apply/expected_damage/expected_heal/describe` (`ability_effect.gd:19,36,43,25`) — `unit_combat.gd:437`, AiScorer, tooltips. `AbilityTargeting.*` queries (`ability_targeting.gd:17-131`) — UnitCombat, click routing, AI.
- **Signals out**
  - `AbilityManager.ability_armed(ability)` (`ability_manager.gd:27`) → `unit_animator.gd:187`, `unit_sfx.gd:114`, `unit_vfx.gd:91` (each filters on `armed_unit`, e.g. `unit_animator.gd:315`), `ui/ability_hotbar.gd:57`.
- **Signals in**
  - `Unit.ability_used` of the watched unit → `_on_watched_unit_ability_used` (`ability_manager.gd:109,126`), auto-disarms when `_is_still_usable` fails (`:138-143`).

## Depends on
- `PlayerInteractionState.get_active_unit()` — `ability_manager.gd:63,103`.
- `Unit` API: `in_combat`, `has_attacked`, `has_move_remaining` (`ability.gd:249`, `ability_manager.gd:141`); `take_damage`, `heal`, `apply_status` from effects; DR is read only by `DamageResolver.injury` (`systems/combat_system/damage_resolver.gd`), which every damaging effect calls. Every damaging effect (and `WeaponData`) carries a `wound_type` — the GURPS damage type, cr/cut/imp/pi-/pi/pi+/pi++/burn/cor/tox (B379) — whose torso wounding multiplier the resolver applies after DR, rounded down, min 1 if anything penetrates. A punch and a fall are crushing. Not modelled: fatigue damage, armor divisors, corrosion's DR loss, Injury Tolerance (e.g. `damage_effect.gd:20-21`, `heal_effect.gd:19`, `apply_status_effect.gd:19`).
- `UnitCombat.DamageType` / `WeaponData.DamageType` / `EquipSlot.Slot` — `gear_damage_effect.gd:42-43,58-75`, `st_damage_effect.gd:8`.
- `UnitQuery.area_affected` — `area_damage_effect.gd:49`, `area_heal_effect.gd:34`, `area_apply_status_effect.gd:35`.
- `NavigationGrid.nearest_valid_point` — `knockback_effect.gd:66`.
- `SystemLog`/`LogFormat` — `heal_effect.gd:22`, `area_heal_effect.gd:44`.
- `ResourceCatalog` — `ability_database.gd:52`.

## Assumptions and invariants
- An `Ability` resource is shared and never mutated at runtime: no code assigns to Ability fields or appends to `effects` (grep of `systems/ ui/ world/` finds no writes). Required because one .tres is shared by many units (issue 5).
- `ability_name` is unique across `data/abilities/` — it is the save key (`ability_database.gd:36`, `party_manager.gd:508`). Not enforced; first file wins silently (`ability_database.gd:52` passes `find_first_wins=true`; `resource_catalog.gd:157-159`).
- To-hit is rolled once per use, before any effect; a miss skips every effect (`ability.gd:38-42`, `unit_combat.gd:367-383`).
- Effects run in array order with the same `is_critical` flag (`unit_combat.gd:436-437`).
- Area effects read radius from the sibling `AreaTargeting` (`area_damage_effect.gd:41-46`); an area effect on a non-area targeting silently does nothing (`:42-43`).
- **Only one armed ability, for one unit, globally** (`ability_manager.gd:29,36`). Comment `:346-350` already notes the party can be in two worlds; the single global arm is still assumed. Not STALE yet because hotbar disarms on world focus (`ui/ability_hotbar.gd:228-232`), but it encodes "one focused world".
- `resolve_click_ability` uses `armed_ability` without checking `armed_unit == acting_unit` (`unit_combat.gd:213`); correctness relies on the hotbar disarming on every selection/turn change.

## Lifecycle
- `AbilityManager`: autoload, lives for the whole process, no save/load hooks. Disarmed on: turn start in view (`ability_hotbar.gd:116`), combat end (`:131`), out-of-combat selection change (`:170`), world focus change (`:232`), right-click (`aiming_intent.gd:47`), new game (`save_manager.gd:620`), attack action spent / move exhausted (`ability_manager.gd:126-143`). NOT on save load (`_perform_load`, `save_manager.gd:405-539`, has no disarm call); this relies on the world-focus disarm.
- `AbilityDatabase`: lazy static scan on first `find/get_all` (`ability_database.gd:50-53`); never invalidated except `refresh()`.
- Cutscene/dialogue: no handling in this system; the presentation listeners gate themselves (`unit_animator.gd:313`).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | No stable ability id: `AbilityDatabase` is keyed on `ability_name`; party `abilities` and hotbar `custom_slots` are saved as display names, so renaming an ability breaks saves (load warns and puts null) | `ability_database.gd:36,52`; `party_manager.gd:508,511,650-664` | CONFIRMED |
| 2 | Duplicate `ability_name`s collide silently (first wins, no warning); `get_all()` still returns both | `ability_database.gd:52`; `resource_catalog.gd:157-159,93-94` | NEW |
| 3 | `AbilityManager.armed_unit` is not cleared when the armed unit dies or is downed: no died/downed listener anywhere in AbilityManager; only cleared indirectly by hotbar turn/selection/world changes. `resolve_click_ability` keeps using `armed_ability` for whoever acts | `ability_manager.gd:36,62-80` (only writers); `ui/ability_hotbar.gd:116,170,232`; `unit_combat.gd:213` | CONFIRMED |
| 4 | Duplicate enums: `WeaponData.DamageType {SWING,THRUST,FIXED}` vs `UnitCombat.DamageType {SWING,THRUST}`, translated by a hand `match`; `GearItem.SlotType` (one `RING`) vs `EquipSlot.Slot` (`RING_1/RING_2`), so int values diverge from GLOVES onward. The Slot split is documented as intentional; both are per-node authored in party_overview.tscn | `weapon_data.gd:16`; `unit_combat.gd:88`; `gear_damage_effect.gd:62-75`; `gear_item.gd:18-21`; `equip_slot.gd:8-25` | CONFIRMED (enum ownership is the inventory doc's; listed here for the GearDamageEffect consumer) |
| 5 | Shared `basic_attack_melee.tres` / `basic_attack_ranged.tres` referenced by 28 demon, 4 companion, 1 summon .tres (+ chargen `character_creation.gd:424`, AI, tests). No runtime mutation found, so it is a working flyweight today; any per-demon variation needs a new .tres, and `GearDamageEffect` falls back to ST swing for weaponless demons | `data/units/demons/*.tres` (28 files); `gear_damage_effect.gd:57-59` | CONFIRMED (risk, not a live bug) |
| 6 | Exported builds: `AbilityDatabase` passes `handle_remap=false`, so `.tres.remap` files are skipped and `find()` returns null; every saved ability fails to resolve on load | `ability_database.gd:52`; `resource_catalog.gd:21-27,142-145` | NEW |
| 7 | `DamageEffect` and `AreaDamageEffect` ignore `is_critical` (no max damage, DR still applied), unlike `StDamageEffect`/`GearDamageEffect` (crit = max damage, ignores DR) | `damage_effect.gd:15-21`; `area_damage_effect.gd:37,50-51`; vs `st_damage_effect.gd:23-25`, `gear_damage_effect.gd:30` | NEW |
| 8 | After `waits_for_impact` await, effects apply to `target` without re-checking it still exists/lives | `unit_combat.gd:388-397,436-437` | NEW (unverified risk) |
| 9 | Load does not disarm; an ability armed for a now-freed unit survives until the hotbar's world-focus handler fires | `save_manager.gd:405-539` vs `:620`; `ui/ability_hotbar.gd:228-232` | NEW |

## Tests
- `tests/interaction/test_intent_has_one_owner.gd` (arms/disarms Grease, `:195-381`).
- `tests/combat/test_fireball_animation.gd`, `test_flight_animation.gd`, `test_jump_animation.gd` (cast presentation).
- AI tests under `tests/ai/` use basic attacks via `tests/ai_test_case.gd`.
- Gaps: no test for `AbilityDatabase` name collisions or rename-safety, armed state across unit death/downed, crit handling per damage effect, or exported-build (`.remap`) resolution.
