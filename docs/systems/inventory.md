# Inventory, stash and currency

**Files:** `systems/inventory_system/` — `item_instance.gd` (254, RefCounted), `item_modifier.gd` (38), `rune_item.gd` (24), `socket_tool.gd` (12), `item_tooltip.gd` (58) + `item_tooltip.tscn`, `item_container.gd` (183, RefCounted), `inventory.gd` (325, @tool Control), `item.gd` (271, Container), `equip_slot.gd` (119), `item_layer.gd` (59), `stash_component.gd` (69), `stash_manager.gd` (78, autoload), `item_database.gd` (48), `item_definition.gd` (26), `gear_item.gd` (70), `weapon_data.gd` (22), `attack_row.gd` (124), `context_menu.gd` (36). `systems/currency_system/currency_manager.gd` (82, autoload). Owner of the party bag: `systems/party_system/party_manager.gd` (`inventory`). Inventory parts of `ui/party_overview.gd` (422). Unit side: `systems/unit_system/unit_equipment.gd` (115).
**Autoloads owned:** `StashManager`, `CurrencyManager`.

## Purpose
A shared grid inventory (10x13), equipment slots per unit, area stashes, and gold. Data and view are split. `ItemDefinition` is the shared authored kind. `ItemInstance` is one copy: stack count, rarity, sockets and runes. `ItemContainer` is a grid of instances with change signals. The `Item`/`Inventory`/`EquipSlot` Controls only draw that model and turn drags into container/equipment calls; widgets are rebuilt from the model, never the other way round. The party bag is `PartyManager.inventory`, so it exists and saves with no screen up. A weapon's damage lives in its attack rows (`WeaponData.attacks`, see abilities.md), one pickable hotbar attack per row. NOT responsible for stat effects of equipment (UnitEquipment applies modifiers), item use (there is none), or loot generation.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Party grid contents (instance → cell) | `PartyManager.inventory` (party_manager.gd:43); item_container.gd:19 | Yes `inventory`, registered at party_manager.gd:478 |
| Per-copy state (definition, stack, rarity, sockets, runes) | item_instance.gd | Yes, `ItemInstance.to_dict()` + x, y; keys left out at their defaults, and a bare id still loads (`from_dict`) |
| Equipped gear per unit (an ItemInstance per slot) | unit_equipment.gd `_equipped` | Via the party record: `PartyMemberData.equipment` holds `ItemInstance.copy()` snapshots, saved with `to_dict()` |
| Stash contents | the stash Inventory's own ItemContainer (`get_container()`, inventory.gd:247) | Yes, AreaState inside `flags` (stash_manager.gd:66-78) |
| Gold | currency_manager.gd:27 (STARTING_GOLD 50 :25) | Yes `currency` (:49-61) |

## Derived / cached state
- Item widgets per ItemInstance (inventory.gd:225 `_widgets`), created, moved and freed from the container's signals (:264-291). Freed with remove_child + queue_free, because a widget can be the drag data of the drop in progress.
- EquipSlot shows a widget built from the unit's equipped instance (`display_instance`, equip_slot.gd:90). One truth: the unit's UnitEquipment.
- An empty EquipSlot shows its `empty_icon` (set per slot in party_overview.tscn; outlines in assets/ui_icon/equip_slot/) through the faint `EmptyIcon` TextureRect. It hides while an item or the two-hand ghost is in the slot.
- Item copies icon/width/height from its definition but not `maximum_stack_count` (item.gd:20-26). Its count label follows `ItemInstance.changed`.
- Gold label follows `gold_changed`.
- Party records store copies of the equipped instances; a respawn equips a copy again, so rarity, sockets and runes survive.
- `ItemInstance.attacks()`: the copy's own attack rows. With no local modifier it returns the shared `WeaponData.attacks`; otherwise duplicates with each modifier's local half applied (`ItemModifier.apply_to_row`), cached until the modifiers change. The shared .tres rows are never written to.
- `ItemInstance.stat_modifiers()`: the gear's own modifiers plus every rune's global half. UnitEquipment registers exactly that list on equip under `display_name()`, and re-registers it on `modifiers_changed` (a rune socketed into worn gear).

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
- Hands: `GearItem.fits` lets a one-handed weapon into the off-hand slot of its own set. `UnitEquipment.hands_allow` (through `EquipSlot.accepts`) refuses an off-hand item while the main hand holds a two-handed weapon, and a two-handed weapon while the off hand is full. It refuses rather than moving the other item to the bag. The off-hand EquipSlot then shows a grey, half-faded, non-interactive `_ghost` of the two-handed weapon (`GHOST_TINT` over a grey wash), redrawn on `Unit.equipment_changed`. Direct `Unit.equip_item` calls (code, saves) skip the check.
- Dropping onto an occupied slot is refused (`accepts_item`), not swapped.
- **Weight and encumbrance** (GURPS B17): `GearItem.weight` (lb) on every gear .tres. Only what a unit wears or wields counts; the party bag never does. `UnitEquipment.basic_lift()` = unhalved ST x ST / 5 (rounded at 10+); `encumbrance_level()` 0-4 = None/Light/Medium/Heavy/Extra-Heavy at 1/2/3/6/10 x BL (`ENCUMBRANCE_LEVELS`). Not a status: `_update_encumbrance` (on equip, unequip and any `stat_changed`) registers Dodge -level and a flat Move amount, `max(1, floor(BM x mult)) - BM`, under the source "<Level> encumbrance", so the Move/Dodge breakdowns name it. Flat rather than a multiplier because stat multipliers round up and GURPS rounds encumbered Move down; Exhausted's halving still applies after. `weight_allows` (through `EquipSlot.accepts`) refuses anything that would put worn weight past 10 x BL, not counting the item already in that slot or an item moving between slots. Losing ST can still leave a unit past the cap; it stays Extra-Heavy. Direct `Unit.equip_item` calls skip the check. Shown by `EncumbranceBar` (`ui/encumbrance_bar.tscn`, under the weapon sets): level name, "worn / 10 x BL lb", one ProgressBar per level spanning that level's band, and a StatTip-style hover breakdown (`StatTip.build`).
- **Rarity** (`ItemInstance.Rarity`: normal, magic, rare, unique) colours the tooltip name and a frame round the widget (`RARITY_COLORS`), and sets what a copy rolls.
- **Affixes** (`Affix`, `data/affixes/*.tres`, loaded by `AffixDatabase`): a prefix or suffix carrying an `ItemModifier`, the same one a rune carries, so `ItemInstance.modifiers()` merges runes, affixes and a unique's lines. Tiers of one line share a `group` (Sharp/Keen/Vicious = damage); a copy holds one per group. `level` keeps a tier off copies of a lower `item_level`; `on_weapons`/`on_armor` pick what it rolls on. Magic: 1-2 affixes, at most one prefix and one suffix; rare: 2-4, at most two of each, plus a two-word `rare_name` (`LootRoller.AFFIX_COUNTS`, `RARE_FIRST/SECOND`).
- **Uniques** (`UniqueItem`, `data/uniques/`, `UniqueDatabase`): a fixed base, name and modifiers, rolled at `level` or above; no unique available falls back to rare.
- **Item level** (`ItemInstance.item_level`) is set by whoever rolls: a monster's `UnitDefinition.level`, a chest's area `AreaDefinition.level`.
- **Identification:** `LootRoller` drops everything but normal items unidentified. An unidentified copy shows its base name and "Unidentified", and `modifiers()` is empty, so its affixes do nothing. `EquipSlot.accepts` refuses it (drag and context-menu Equip); `Unit.equip_item` from code or a save doesn't check. An `IdentifyScroll` (`data/items/identify_scroll.tres`) dropped on it calls `identify()`.
- **Loot:** `LootRoller.roll(level, rng)` is one drop: a loose non-gear item `CURRENCY_CHANCE` of the time, else a gear base, rarity by `RARITY_WEIGHTS`, affixes or unique, sockets. A killed monster's drops (`max_drops` rolls kept on `drop_chance`) go in a `Remains` at its spot (`UnitCombat._die` → `Remains.drop_for`), freed once emptied and not saved; party members and owned demons drop nothing. A `StashComponent` with `loot_rolls > 0` (`loot_chest.tscn`) rolls on its first `open_stash` and saves `rolled`. A roll that doesn't fit the grid is lost.
- **Sockets:** `max_sockets()` = min(grid cells, `GearItem.socket_limit()`). Per-slot limits are in `GearItem.SOCKET_LIMITS` (boots 2, chest 3, helmet 2, …; ring/amulet/belt/undershirt 0); a two-handed weapon gets 3. `roll_sockets(rng)` rolls 0..max for a drop (LootRoller calls it). A `SocketTool` (`data/items/socket_awl.tres`) dropped on an item adds one up to the max. Shown PoE-style by `SocketOverlay` (`socket_overlay.gd` + `socket.tscn`, a round StyleBoxFlat authored at 42 px and scaled): one per cell in reading order; an axis with no full line of sockets is centred (no full row → centred across, no full column → centred down), a full line pins that axis to the cells; a filled socket showing the rune's round icon. On the grid widget only, never the shrunken equipped preview; `ItemTooltip` shows the item art at 2x (64 px cells) with the same overlay, so a worn item's sockets show on hover.
- **Runes** (`RuneItem`, `data/items/iron|hawk|vigor_rune.tres`) are permanent: no removing, no overwriting; a full item refuses them. Each has an `on_weapon` and an `on_armor` `ItemModifier`; `ItemInstance.is_weapon()` (attack rows, not a shield) picks which. A modifier's **local** half (`damage_bonus`, `to_hit_bonus`) changes the copy's rows; its **global** half (`stat_modifiers`) goes on the wearer. Armour's DR is global.
- Applying one item to another is `ItemDefinition.can_apply_to/apply_to`: `Item._can_drop_data` asks it, `_drop_data` applies it and spends one of the stack. Any future currency is a new ItemDefinition subclass.
- Per-copy magazine: `ItemInstance._shots_left` (-1 = full) for weapons with `WeaponData.shots`. Runtime only, not in the save dict.
- Equip picks the first global `equip_slots` node (context_menu.gd:18-24): assumes one viewed unit's slots.
- Stash keyed by current area (stash_manager.gd:66-78): assumes one focused world.

## Lifecycle
PartyManager owns the bag for the whole session; party_overview only binds its Inventory widget to it on ready. The widget shows it at 52px cells, 10x13 with no scrolling. A grid's cell size is set in one place, `Inventory.cell_size_px` (per instance in the .tscn): `InventoryGridLayer` and every `Item` in it read it from there, so item art always matches its footprint; `Inventory.set_filter(callable)` dims (modulate) items the filter rejects without hiding or moving them, reapplied on add and move. The bag sits in `%BagSlot`, its own VBox, so StashPanel putting it back can't reorder it past the header or footer. New game: `load_state({})` empties the bag and resets gold to 50. Load: `ItemContainer.load_state` clears (emitting item_removed, which frees widgets) and places fresh instances; one whose saved cell no longer fits (a save from the old 12-wide bag) goes to the first free spot instead. Stash: open loads from AreaState, close persists (stash_manager.gd:26-78). World travel: inventory unaffected (autoload-owned); equipment rides the party record. Combat/dialogue: dialogue effects give/sacrifice items.

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
| 12 | Per-copy state is dropped when a member is captured to a record and respawned (the record keeps definitions) | the record keeps `ItemInstance.copy()` and saves `to_dict()` | FIXED (sockets) |
| 13 | party_overview's stat column only refreshed in `open_for`, so equipping or socketing showed stale DR/HP | it now follows the shown unit's `equipment_changed` | FIXED (sockets) |

## Tests
Only indirect: persistence suites (tests/world/test_persistence_is_a_registry.gd, test_a_new_game_is_new.gd, test_a_refused_load_changes_nothing.gd, test_load_restores_every_area.gd; some still install a party_overview they no longer need), tests/combat/test_defenses.gd (shield as an ItemInstance), tests/combat/test_mode_is_derived.gd (StashManager), conversation suites (CurrencyManager). No direct tests of grid placement, consume, stash round-trip or equip in the suite. `tools/item_layer_demo.tscn` (see tools/README.md) drives all of those through the real UI and prints 27 PASS/FAIL checks. It passed 27/27 on 2026-11-01. `tests/project/test_rune_sockets.gd` (12 checks): socket limits, the awl's cap, permanent runes, per-copy rows leaving the shared row alone, a rune socketed into worn armour adding DR and unequipping removing it, and the save round trip. `tools/sockets_demo.tscn` does the same through real drags and a hover tooltip (12/12 on 2026-11-02). `tests/project/test_encumbrance.gd` (5 checks): BL from ST, the level and its Move/Dodge for a known weight, the 10 x BL cap, and unequipping restoring both.
