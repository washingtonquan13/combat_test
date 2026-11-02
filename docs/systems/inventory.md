# Inventory, stash and currency

**Files:** `systems/inventory_system/` — `item_instance.gd` (40, RefCounted), `item_container.gd` (183, RefCounted), `inventory.gd` (325, @tool Control), `item.gd` (231, Container), `equip_slot.gd` (119), `item_layer.gd` (59), `stash_component.gd` (69), `stash_manager.gd` (78, autoload), `item_database.gd` (48), `item_definition.gd` (26), `gear_item.gd` (34), `weapon_data.gd` (27), `context_menu.gd` (36). `systems/currency_system/currency_manager.gd` (82, autoload). Owner of the party bag: `systems/party_system/party_manager.gd` (`inventory`). Inventory parts of `ui/party_overview.gd` (422). Unit side: `systems/unit_system/unit_equipment.gd` (62).
**Autoloads owned:** `StashManager`, `CurrencyManager`.

## Purpose
A shared grid inventory (12x6), equipment slots per unit, area stashes, and gold. Data and view are split. `ItemDefinition` is the shared authored kind. `ItemInstance` is one copy: a stack count today, rolled per-copy state later. `ItemContainer` is a grid of instances with change signals. The `Item`/`Inventory`/`EquipSlot` Controls only draw that model and turn drags into container/equipment calls; widgets are rebuilt from the model, never the other way round. The party bag is `PartyManager.inventory`, so it exists and saves with no screen up. NOT responsible for stat effects of equipment (UnitEquipment applies modifiers), item use (there is none), or loot generation.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Party grid contents (instance → cell) | `PartyManager.inventory` (party_manager.gd:43); item_container.gd:19 | Yes `inventory`, registered at party_manager.gd:478 |
| Per-copy state (definition, stack count) | item_instance.gd:18-23 | Yes, `{id, x, y, stack}` (item_container.gd:138-162) |
| Equipped gear per unit (an ItemInstance per slot) | unit_equipment.gd `_equipped` | Via the party record's definitions (party_manager.gd:429-432) |
| Stash contents | the stash Inventory's own ItemContainer (`get_container()`, inventory.gd:247) | Yes, AreaState inside `flags` (stash_manager.gd:66-78) |
| Gold | currency_manager.gd:27 (STARTING_GOLD 50 :25) | Yes `currency` (:49-61) |

## Derived / cached state
- Item widgets per ItemInstance (inventory.gd:225 `_widgets`), created, moved and freed from the container's signals (:264-291). Freed with remove_child + queue_free, because a widget can be the drag data of the drop in progress.
- EquipSlot shows a widget built from the unit's equipped instance (`display_instance`, equip_slot.gd:90). One truth: the unit's UnitEquipment.
- Item copies icon/width/height from its definition but not `maximum_stack_count` (item.gd:20-26). Its count label follows `ItemInstance.changed`.
- Gold label follows `gold_changed`.
- Party records store gear definitions (party_manager.gd:429-432), re-instanced as fresh ItemInstances on spawn (:752). Per-copy state does not survive that (issue 12).

## Public surface
- **Calls in:** `ItemContainer.add/place/remove/has/consume/sort` on `PartyManager.inventory` from give_item_effect.gd, sacrifice_item_effect.gd, item_owned_prerequisite.gd, stash_panel.gd (take-all). Widget side: `Inventory.bind(container)` :227 (party_overview binds the party bag), `request_item_drop` :193, `auto_place_item` :206, `sort_items` :213; `EquipSlot.equip/unequip/display_instance`. `party_overview.open_for`. `StashManager.open_stash` :26-32 / `close_stash` :44-57. `CurrencyManager.add_gold` :64, `spend_gold` :73, `has_gold` :81 (DemonCompendium, negotiation).
- **Signals out:** `ItemContainer.item_added/item_removed/item_moved` (item_container.gd:12-14); `ItemInstance.changed`; StashManager signals (stash_manager.gd:13-14); `gold_changed` (currency_manager.gd:16) → party_overview gold label.
- **Signals in:** Inventory listens to its bound container; Item listens to its instance.

## Depends on
- SaveManager: `&"inventory"` is the ItemContainer itself, registered by PartyManager (party_manager.gd:478). No screen is needed to save or load. `&"currency"` (currency_manager.gd:49).
- ItemDatabase for id → definition on load.
- AreaState / WorldManager.current_area() for stashes (stash_manager.gd:66-78).
- UnitEquipment for equip/unequip.

## Assumptions and invariants
- An ItemInstance is in at most one place: one container or one unit slot. Moves detach first (`Item.detach_from_current_location`), then place or equip.
- `ItemContainer.sort()` plans the whole packed layout before moving anything and aborts if any item wouldn't fit, so a sort never loses an item.
- Authored Item children of an Inventory in a .tscn (chests) are adopted into its container on `_ready` or on the first `get_container()`, whichever comes first, because a stash's load_state can run before it enters the tree.
- Equip picks the first global `equip_slots` node (context_menu.gd:18-24): assumes one viewed unit's slots.
- Stash keyed by current area (stash_manager.gd:66-78): assumes one focused world.

## Lifecycle
PartyManager owns the bag for the whole session; party_overview only binds its Inventory widget to it on ready. New game: `load_state({})` empties the bag and resets gold to 50. Load: `ItemContainer.load_state` clears (emitting item_removed, which frees widgets) and places fresh instances. Stash: open loads from AreaState, close persists (stash_manager.gd:26-78). World travel: inventory unaffected (autoload-owned); equipment rides the party record. Combat/dialogue: dialogue effects give/sacrifice items.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | Inventory state is owned by a UI screen, not a system | now `PartyManager.inventory` | FIXED (item layer) |
| 2 | Item extends Container (UI node is the item model) | model is ItemInstance/ItemContainer; Item is a view | FIXED (item layer) |
| 3 | has_item/consume_item typed GearItem; non-gear items unusable by effects | `ItemContainer.has/consume` take any ItemDefinition | FIXED (item layer); effects still export GearItem |
| 4 | Healing potion has no use hook; ItemDefinition has none; context menu has Equip/Drop/Inspect only | item_definition.gd; context_menu.gd:18-36 | CONFIRMED |
| 5 | `load_state` used queue_free without remove_child, so old items occupied the grid during the rebuild | occupancy is the container's, not the widgets' | FIXED (item layer) |
| 6 | Loaded stack count never updated its label; stacking never implemented (`maximum_stack_count` unread) | label follows ItemInstance.changed; merging stacks still unbuilt | PARTLY FIXED |
| 7 | Drop permanently deletes the item, no confirmation or world drop | context_menu.gd:27-32 | NEW |
| 8 | Equip targets the first global equip_slots node | context_menu.gd:18-24 | NEW |
| 9 | Items of the last-viewed unit stayed parented in UI EquipSlots after close | slots now show views of the unit's instances; the gear lives on the unit | FIXED (item layer) |
| 10 | No inventory change signals; consumers poll | ItemContainer signals | FIXED (item layer) |
| 11 | Inspect is a stub | context_menu.gd:34-36 | NEW |
| 12 | Per-copy state is dropped when a member is captured to a record and respawned (the record keeps definitions) | party_manager.gd:429-432, :752 | NEW; matters once affixes exist |

## Tests
Only indirect: persistence suites (tests/world/test_persistence_is_a_registry.gd, test_a_new_game_is_new.gd, test_a_refused_load_changes_nothing.gd, test_load_restores_every_area.gd; some still install a party_overview they no longer need), tests/combat/test_defenses.gd (shield as an ItemInstance), tests/combat/test_mode_is_derived.gd (StashManager), conversation suites (CurrencyManager). No direct tests of grid placement, consume, stash round-trip or equip in the suite. `tools/item_layer_demo.tscn` (see tools/README.md) drives all of those through the real UI and prints 27 PASS/FAIL checks. It passed 27/27 on 2026-11-01.
