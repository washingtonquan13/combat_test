# Inventory, stash and currency

**Files:** `systems/inventory_system/` — `inventory.gd` (362, @tool Control), `item.gd` (203, Container), `equip_slot.gd` (103), `item_layer.gd` (59), `stash_component.gd` (69), `stash_manager.gd` (78, autoload), `item_database.gd` (48), `item_definition.gd` (26), `gear_item.gd` (34), `weapon_data.gd` (27), `context_menu.gd` (36). `systems/currency_system/currency_manager.gd` (82, autoload). Inventory parts of `ui/party_overview.gd` (453). Unit side: `systems/unit_system/unit_equipment.gd` (64).
**Autoloads owned:** `StashManager`, `CurrencyManager`.

## Purpose
A shared grid inventory (12x6), equipment slots per unit, area stashes, and gold. The inventory is a UI tree: items are Control nodes inside the party_overview screen, which is also the persistence owner. NOT responsible for stat effects of equipment (UnitEquipment applies modifiers, unit_equipment.gd:47-64), item use (there is none), or loot generation.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Grid contents (Item nodes and positions) | inventory.gd:18-25, children; saved :300-312 | Yes `inventory`, registered by party_overview.gd:175-176 |
| Item definition / gear_data / stack count | item.gd:20-35, :56 | Yes (path + count) |
| Equipped gear per unit | unit_equipment.gd:47-64 (dict) | Via party record `gear_data` paths (party_manager.gd:402-405) |
| Stash contents | stash_component.gd:38-43 | Yes, AreaState inside `flags` (stash_manager.gd:66-78) |
| Gold | currency_manager.gd:27 (STARTING_GOLD 50 :25) | Yes `currency` (:49-61) |

## Derived / cached state
- EquipSlot UI holds Item nodes mirroring a unit's UnitEquipment (equip_slot.gd:62-93; swapped by party_overview.gd:273-286). Two truths: the slot node and the unit dict.
- Item copies icon/width/height from its definition but not `maximum_stack_count` (item.gd:20-26).
- Gold label (party_overview.gd:189-190, :452-453) follows `gold_changed`.
- Party records store gear paths (party_manager.gd:402-405), re-instantiated on spawn (:752-755).

## Public surface
- **Calls in:** `request_item_drop` :207, `auto_place_item` :225, `sort_items` :235, `has_item(GearItem)` :257, `consume_item(GearItem)` :263-273 — reached via `get_tree().get_first_node_in_group("party_overview").get_inventory()` (party_overview.gd:162, :238) from give_item_effect.gd:27/34, sacrifice_item_effect.gd:16/20, item_owned_prerequisite.gd:14-15. `party_overview.open_for` :248-263. `StashManager.open_stash` :26-32 / `close_stash` :44-57. `CurrencyManager.add_gold` :64, `spend_gold` :73, `has_gold` :81 (DemonCompendium, negotiation).
- **Signals out:** StashManager signals (stash_manager.gd:13-14); `gold_changed` (currency_manager.gd:16) → party_overview gold label. Inventory has none.
- **Signals in:** none for Inventory.

## Depends on
- SaveManager: `&"inventory"` registered by the UI node (party_overview.gd:175-176, unregistered :206-208); SaveManager refuses load without a party_overview (save_manager.gd:763). `&"currency"` (currency_manager.gd:49).
- AreaState / WorldManager.current_area() for stashes (stash_manager.gd:66-78).
- UnitEquipment for equip/unequip (equip_slot.gd:62-75).

## Assumptions and invariants
- A party_overview node exists in the tree whenever anything gives, takes or checks items, or saves/loads. Group lookup, no fallback.
- Every item an effect references is a GearItem (has_item/consume_item typed GearItem :257, :263); a plain ItemDefinition (data/items/healing_potion.tres) can't be checked or consumed.
- Equip picks the first global `equip_slots` node (context_menu.gd:18-24): assumes one viewed unit's slots.
- Stash keyed by current area (stash_manager.gd:66-78): assumes one focused world.

## Lifecycle
party_overview builds the grid and registers persistence on ready (:175-176), unregisters on exit (:206-208). New game: `load_state({})` empties grid and resets gold to 50. Load: `inventory.load_state` frees old items and rebuilds (:323-349). Stash: open loads from AreaState, close persists (stash_manager.gd:26-78). World travel: inventory unaffected (UI-owned, global); equipment rides the party record. Combat/dialogue: dialogue effects give/sacrifice items.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Inventory state is owned by a UI screen, not a system | party_overview.gd:175-176, :238; save_manager.gd:763 | CONFIRMED |
| 2 | Item extends Container (UI node is the item model) | item.gd:3 | CONFIRMED |
| 3 | has_item/consume_item typed GearItem; non-gear items unusable by effects | inventory.gd:257-273; give_item_effect.gd:27,34 | CONFIRMED |
| 4 | Healing potion has no use hook; ItemDefinition has none; context menu has Equip/Drop/Inspect only | item_definition.gd:55-60; context_menu.gd:18-36 | CONFIRMED |
| 5 | `load_state` uses queue_free without remove_child: old items still occupy the grid during the same frame's rebuild | inventory.gd:334-336 | NEW |
| 6 | Loaded stack count never updates its label; stacking never implemented (`maximum_stack_count` unread) | inventory.gd:346; item.gd:56, :131; item.tscn:29-30 | NEW |
| 7 | Drop permanently deletes the item, no confirmation or world drop | context_menu.gd:27-32 | NEW |
| 8 | Equip targets the first global equip_slots node | context_menu.gd:18-24 | NEW |
| 9 | Items of the last-viewed unit remain parented in UI EquipSlots after close; swapped only on next open_for (risk if that unit is freed) | party_overview.gd:273-286 | NEW |
| 10 | No inventory change signals; consumers poll | inventory.gd (none declared) | NEW |
| 11 | Inspect is a stub | context_menu.gd:34-36 | NEW |

## Tests
Only indirect: persistence suites install a party_overview (tests/world/test_persistence_is_a_registry.gd, test_a_new_game_is_new.gd, test_a_refused_load_changes_nothing.gd, test_load_restores_every_area.gd), tests/combat/test_mode_is_derived.gd (StashManager), conversation suites (CurrencyManager). No direct tests of grid placement, consume_item, stash round-trip or equip.
