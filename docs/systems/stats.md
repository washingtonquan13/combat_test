# Stats

**Files:** `systems/stat_system/` (574 lines) — `stat_definition.gd` (61, Resource), `stat_database.gd` (230, static), `stat_instance.gd` (77, Node), `unit_stats.gd` (184, RefCounted component of Unit), `stat_ids.gd` (22, constants). Data: `data/stats/*.tres` (15: ST, DX, IQ, HT, DR, SM, DB primaries; HP, FP, Will, Per, Move, Air Move, Basic Speed, Dodge derived). Every stat value is a float (uncommitted): `get_stat`/`value_of` keep fractions, so Basic Speed = `(DX + HT) / 4.0` reads 5.25 and turn order sorts on it (combat.md). A formula drops a fraction itself where GURPS does — Basic Move = `floori(BasicSpeed)`, Dodge = `floori(BasicSpeed) + 3` (DB, Defense Bonus from a shield, is added at defense time instead — unit.md, Active defenses). Multiplier modifiers multiply together and the product is applied after flat modifiers, rounded up: Bloodied and Exhausted together quarter Move and Dodge, and Exhausted halves ST. Encumbrance (inventory.md) is flat modifiers, not a multiplier: Dodge -level and Move `max(1, floor(BM x mult)) - BM`, so it rounds down as GURPS does, under the source "<Level> encumbrance". A multiplier is a halving of the stat itself (B426), so it never flows on: a derived stat reads its inputs before their multipliers (Exhausted ST 5 still gives HP 10), and `_damage_dice` reads `Unit.get_stat_unhalved(ST)`; skill rolls, ST checks and the sheet see the halved ST. A caller needing a whole number floors it: roll targets, DR against damage, pool maxima (base values, modifiers and pool currents stay ints). `StatDefinition.format` shows a whole value as "10" and a fractional one as "5.25". `Unit.move_per_turn()` = Move, in meters (a GURPS yard taken as a meter; the earlier × 6 turn multiplier was removed at the user's request); demons' Move bonuses are the pre-53eb9e5 ones. While flying the budget reads Air Move = `floori(BasicSpeed * 2)` instead (GURPS: twice Basic Speed, so Move bonuses don't carry into the air); taking off or landing mid-turn rescales `move_remaining` so the share of the turn left is kept. SM (Size Modifier, default 0, not bought in chargen) is added to every attack against the unit in `UnitCombat.to_hit_target`, so hit chance, AI and the readout all see it; authored on dragon (+2) and test_pixie (−4). SM is also worn physically: `Unit._bind_model` scales the body by `SizeModifier.scale_for(SM, CharacterModel.authored_size_modifier)` (B19 size table, longest dimension 2 m at SM 0, so +2 is 2.5×, −4 is 0.25×), and with it the collision shape, `radius` and `height` (so nav-grid clearance and edge-to-edge melee reach), anchors, selection ring and pick area (with a minimum so tiny units stay clickable). `avoidance_margin` is not scaled. It is worn again whenever SM changes (`Unit._on_own_stat_changed`): shape, radius and pick area change at once, the body and ring tween over `SIZE_CHANGE_SECONDS` (0.8 s). Size also gives or takes ST: `Unit._fit_size_strength` keeps a flat modifier under the source "Size" of ST × (length ratio to the unit's base SM − 1), rounded (SM 0→+1 is ×1.5, a dragon 2→1 is ×0.6), and clamps current HP to the new max (max HP grows, current HP does not). Enlarge Person / Reduce Person (`data/abilities/`) apply the Enlarged/Reduced statuses (SM ±1, groups `enlarge`/`reduce` so neither stacks with itself, both together cancel; resisted by HT only when hostile). Their targeting sets `AbilityTargeting.any_unit`, so a click on any unit, self included, casts them. Any stat can be a status's `resisted_by` (statuses.md). ST's thrust/swing dice are not a stat: `UnitCombat._damage_dice` computes them from ST with the Basic Set table as a formula (ported from GCS's BasicSet progression, matches it for ST 1–1000; +1d per 10 ST past 100), so there is no table to extend.
**Autoloads owned:** none.

## Purpose
What stats exist and how a derived stat is computed, as data: one `StatDefinition` .tres per stat, read by `StatDatabase`. Each Unit holds its own numbers in a `Stats` node of `StatInstance` children, one per stat, built by `UnitStats`. Adding a stat is dropping in a file; changing a formula is editing a file. NOT responsible for: what statuses or gear do (they register `StatModifierBehavior`s through Unit), point-buy costs (`PointBuyTable`, referenced from a definition's `point_buy`), or Downed/death rules (unit_combat.gd).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Stat definitions (id, display, kind, formula, default, is_pool, point_buy) | data/stats/*.tres; stat_definition.gd | Content |
| Per-unit base of every stat (primary = the stat; derived = bought bonus over the formula) | StatInstance.base (stat_instance.gd:22) | Yes — `stats.stats` in Unit.save_state, PartyMemberData.stats, OwnedDemon.stats |
| Per-unit pool current (HP, FP) | StatInstance.current (stat_instance.gd:32) | Yes — `stats.pools`, same three places |
| Active modifiers per stat, with source | StatInstance._modifiers (stat_instance.gd:40) | No — statuses and gear re-register on restore |
| Species stat bases (differences from defaults only) | UnitDefinition.stats | Content |
| Per-placement overrides | Unit.stat_overrides (e.g. test_arena's Scared Townperson DX 18) | Content |

## Derived / cached state
- No finished value is cached anywhere: `StatDatabase.value_of` recomputes formula + base + modifiers on every read, so a status on DX changes Move and the turn budget at once (this closed unit.md #17).
- Parsed `Expression`s and the derived-stat dependency order are cached once per load in StatDatabase (`_formulas`, `_derived_order`); `refresh()` re-scans.
- `UnitDefinition.stat_value(id)` and character creation's `_preview_value(id)` run the same `value_of` against a dictionary instead of a unit — one formula, three callers.

## Public surface
- **Calls in:** everything reads through Unit's forwarders: `get_stat`, `get_base_stat`/`set_base_stat`, `get_unmodified_stat`, `get_pool`/`set_pool`/`spend_pool`/`restore_pool`/`fill_pools`, `register_stat_modifier`/`unregister_stat_modifier` (source string on both), `stat_modifier_sources`, `stats_to_dict`/`stats_from_dict`. Non-unit callers: `UnitDefinition.stat_value` (compendium, demon sheet, hotbar), character_creation.gd (`get_bought`, `get_all`, `value_of`), `StatDatabase.suggest_ids` from `@tool` resources' `_validate_property` (StatModifierBehavior.stat_name, AttributePrerequisite.attribute_name, Skill.controlling_attribute).
- **Signals out:** `Unit.stat_changed(unit, id)` and `Unit.pool_changed(unit, id, current, maximum)`, relayed from UnitStats. No listeners yet; the UI still polls.
- **Signals in:** StatInstance.changed → UnitStats (internal).

## Depends on
- ResourceCatalog (stat_database.gd `_ensure_loaded`) for the scan of `res://data/stats/`.
- Godot `Expression` for formulas.

## Assumptions and invariants
- A stat id is a valid identifier: formulas read other stats by exactly the id.
- Startup validation fails loudly, by name: a formula that does not parse, names an unknown stat, does not evaluate to a number at all-10s, or forms a cycle; a duplicate id; an empty directory. A bad stat then reads 0 — loud, not silent.
- Pools are capped at their maximum on write and never floored (HP below 0 is Downed, down to -5×HP).
- `from_dict` merges what is present and skips unknown ids (a removed stat must not break saves); `reset` (the definition setter) is a full overwrite, so a re-assigned species keeps nothing of the old one.
- UnitStats is built lazily by `Unit._unit_stats()`, not in `_ready`, because the `definition` setter writes stats while the scene is still instantiating.
- Saves from before the conversion (`hp`/`fp` keys, per-field party/demon records) do not restore stats — no converter, by decision.

## Lifecycle
- Database: loaded on first read, static for the process. New game, travel and load do not touch it.
- Per unit: Stats node created on first stat access; reset by the `definition` setter; `stat_overrides` applied after the definition (declaration order). Saved and restored through `stats_to_dict`/`stats_from_dict` by Unit.save_state, PartyManager capture/spawn, and the OwnedDemon summon/dismiss round trip (`capture_pools` on dismiss, `stats_from_dict(owned.stats)` on summon).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | No listener uses `stat_changed`/`pool_changed`; HP bars and sheets still poll. | ui/ | NEW (by design for now) |
| 2 | Character creation's attribute rows come from `get_bought()`, but the stats column on the party screen is still scene-authored labels — a new stat appears in chargen but not there. | ui/stats_column.gd | NEW |
| 3 | `DefaultRule.source_name` stays a String with no suggestions: it names an attribute or a skill. | default_rule.gd | NEW (accepted) |

## Tests
- tests/project/test_secondary_stats_derive.gd — beast's derived stats match their pre-conversion numbers; raising ST/IQ/HT carries through. Sabotage-checked: an unknown name and an unparseable formula in move.tres both error at load and turn it red.
- Persistence, split-party save, load-restores, downed and compendium suites exercise the dict round trip and pools.
