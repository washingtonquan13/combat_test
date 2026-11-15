# HUD & screens

**Files:** `ui/` — party_overview.gd (574), party_panel.gd (490), ui/hotbar/dock.gd (259), ui/hotbar/dock_slot.gd, unit_portrait.gd, esc_menu.gd (105), menu_button.gd, main_menu.gd, save_load_panel.gd, stash_panel.gd, demon_compendium_panel.gd, compendium_menu.gd, cathedral_menu.gd, area_label.gd, equip_slot.gd; `systems/log_system/` — system_log.gd, log.gd, log_format.gd. Layout lives in MainRoot.tscn (TacticalUI 120-201, PartyRail/PartyPanel 215-238, screens 310-418).
**Autoloads owned:** SystemLog (project.godot autoload list). UIStack belongs to mode_and_ui_stack.md.

## Purpose
These scripts draw game state and send player intent back to the systems that own that state. The rule is that a screen owns no game state. They are not responsible for screen stacking or HUD hiding (UIStack/UIScreen, see mode_and_ui_stack.md), and they do not own combat HUD widgets such as initiative_row.gd and end_turn_button.gd (see combat.md). PartyOverview used to own the party inventory; it now only binds its Inventory widget to `PartyManager.inventory`.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| ~~Party shared Inventory~~ moved: the contents are `PartyManager.inventory`; `%Inventory` here is only a view bound to it (`Inventory.bind`). StashPanel still borrows the widget via `get_inventory()`. | ui/party_overview.gd | Saved by PartyManager, not here |
| Log transcript `lines`, capped at max_lines 500 | systems/log_system/system_log.gd:28, 35 | No |
| Hotbar custom slot assignment. The UI writes it, but it is stored on the Unit. | ui/hotbar/dock_slot.gd:54-55 (via `unit.set_custom_slot`, dock_slot.gd:102-107) | Saved with the unit (unit.md) |

Everything else is view state: the open tab, row caches and the selected slot.

## Derived / cached state
- **PartyPanel rows.** Cached per Unit or PartyMemberData (party_panel.gd:88-90) and rebuilt from PartyManager and WorldManager signals (111-131). `_mark_absent_members` derives which members are "elsewhere" (261-278). Summons are detected by parsing `result["effects"][i]["summoned"]` (423-434). That is a string-keyed dependency on ability result dictionaries.
- **PartyOverview Inventory tab** (layout 2026-11-02, mockup v2): fixed-pixel columns at 1600 wide: party rail 0-96 (one button per `PartyManager.members`, demons excluded; HP bar; gold frame on the shown unit), StatsColumn 96-496 (attributes, Dodge/Parry/Block/DR tiles, attacks, conditions), paperdoll 496-1016 (72px slots, 280x492 portrait, 96px melee/ranged sets, both always live), party bag 1016-end (10x13 at 52px, All/Gear/Use/Runes filter that dims, Sort, gold). Click a rail button or press Q/E to switch member without closing: `show_unit(unit)`; `open_for` = `show_unit` + open. The cameras skip Q/E while a blocking screen is up (`UIStack.can_open()`). The rail is rebuilt on open and on member_added/removed; a switch only re-highlights. Every stat and defense tile on StatsColumn has an Owlcat-style hover breakdown (`ui/stat_tip.gd`, `StatTip._make_custom_tooltip`): title, one-line description, then a part/amount grid from `Unit.stat_breakdown(id)` or `dodge_parts`/`parry_parts`/`block_parts`. Parry and Block targets are the sum of those parts, so the tip can't disagree with the number. No footnotes on the sheet: explanations go in the hover.
- **PartyOverview panels.** These are snapshots taken at show_unit(unit) and are not live, except the stat columns, which follow the shown unit's `equipment_changed`. They show gold (CurrencyManager.gold, 189-190), the journal (QuestDatabase/FlagManager, 390-405) and skills (SkillCalculator, 325).
- **Equip-slot item display.** Equipped Item nodes are reparented under EquipSlot.item_layer (equip_slot.gd:84-98). This puts a second parent for an item in the UI tree (see issue 3).
- **AbilityHotbar's shown unit.** `_in_view` (ui/hotbar/dock.gd:103-107) and `_refresh_out_of_combat_unit` (157-181) derive it from SelectionManager.selected_units only.
- **DemonCompendiumPanel summon-cap spinbox.** Set once in _ready (demon_compendium_panel.gd:59) from DemonRoster.max_active_summons.
- **Log view.** A RichTextLabel copy of SystemLog.lines, kept in sync only by signals (log.gd:59-62).

## Public surface
- **Calls in**
  - PartyOverview: `open_for(unit)` from the C key and from portraits; `show_unit(unit)` from the rail and Q/E; `get_inventory()`/`get_inventory_slot()` (`%BagSlot`) from stash_panel.gd only (the widget, to reparent it and put it back). `open_on_tab` (party_overview.gd:390) has no callers.
  - SystemLog: `print()` (system_log.gd:38-44) and `clear_log()` (47-48), called from everywhere and from SaveManager.new_game (save_manager.gd:624).
  - CompendiumMenu: `begin()` (compendium_menu.gd:82-84), called from CathedralMenu.
  - CathedralMenu: `present()` (cathedral_menu.gd:60), called from cathedral_of_shadows.gd:67.
- **Signals out**
  - SystemLog.line_logged and log_rebuilt go to log.gd:59-62.
- **Signals in**
  - AbilityHotbar listens to CombatManager.turn_started and combat_ended, AbilityManager.ability_armed, SelectionManager.selection_changed and WorldManager.world_focused (ui/hotbar/dock.gd:55-62).
  - PartyPanel listens to PartyManager member_added, member_removed and leader_changed; WorldManager world_loading, world_loaded and world_focused; CombatManager.attention_changed; and Conversations.follow (party_panel.gd:111-131).
  - EscMenu listens to SaveManager.load_completed (esc_menu.gd:52, 362-364).
  - MainMenu listens to SaveManager.load_completed (main_menu.gd:50).
  - SaveLoadPanel listens to SaveManager.load_finished (save_load_panel.gd:40, 146).
  - AreaLabel listens to WorldManager world_loading and world_focused and to GameMode.mode_changed (area_label.gd:27-29).

## Depends on
Writes that go from a screen straight into a system:
- The PartyOverview debug grant writes `unit.abilities` directly (party_overview.gd:493, `_unit.add_ability`).
- DemonCompendiumPanel writes DemonRoster.max_active_summons (60) and calls release (165), recruit (182) and FusionRitual.perform (129).
- CathedralMenu calls FusionRitual.perform (cathedral_menu.gd:80) and travels to the overworld (105).
- HotbarSlot arms and disarms through AbilityManager (ui/hotbar/dock_slot.gd:107-110, 169).
- StashPanel reparents both the party inventory and the stash inventory into itself (stash_panel.gd:74-89) and closes the stash on hide (69-71).
- SaveLoadPanel saves (128), loads behind_black (135-136) and deletes (160).
- MainMenu: new_game (86), continue (101-104), MusicManager.play_main_menu (58).
- EscMenu: debug exit with travel_area(&"overworld") (esc_menu.gd:331); main menu via behind_black, unload and UIStack.push (349-359).
- UnitPortrait click: WorldManager.reveal then SelectionManager.select (unit_portrait.gd:139-164).

## Assumptions and invariants
- **A screen is rebuilt on open, never kept live.** The code is safe after a load only because WorldManager._leave_focused calls UIStack.close_all (world_manager.gd:381, reached from _tear_down_worlds 343-353) and travel_area calls it too (884).
- **The party inventory lives as long as MainRoot.** No longer a UI assumption: it lives on PartyManager (autoload).
- **"The hotbar's unit is in the one focused world"** (ui/hotbar/dock.gd:103-107). STALE in part. `_on_combat_ended` (130-139) assumes the only fight is the one on screen. Fights run in non-focused worlds (combat_manager.gd:360 relays every encounter, and combat_ended carries only the faction, 404).
- `_in_view`'s comment claims it matches CombatManager._is_watched. It does not (issue 2).
- **The orphaned ui/esc_menu.tscn is unused.** It references res://src/esc_menu.gd. The live EscMenu is inlined in MainRoot.tscn:317.
- **Esc can stack on any screen.** menu_button.gd pushes and pops esc_menu, so EscMenu can sit over PartyOverview (blocks_input_below MainRoot.tscn:310-311).

## Lifecycle
- **Boot.** Every screen is a persistent MainRoot.tscn node. main_root.gd:83 pushes MainMenu.
- **New game.** SaveManager.new_game calls SystemLog.clear_log() (save_manager.gd:624). The log *view* is not cleared (issue 6).
- **Save.** Nothing is saved from here any more; the inventory moved to PartyManager.
- **Load.**
  - `_tear_down_worlds` → `_leave_focused` → UIStack.close_all (world_manager.gd:353, 381).
  - EscMenu closes itself on load_completed (esc_menu.gd:362-364).
  - The log is not cleared (issue 7).
- **Travel.**
  - travel_area → UIStack.close_all (world_manager.gd:884).
  - The selection is emptied (world_manager.gd:379), so the hotbar goes blank (issue 1b).
  - AreaLabel shows only in OVERWORLD (area_label.gd:63).
- **Combat.** The hotbar disarms on every turn_started (ui/hotbar/dock.gd:110-127) and clears on every combat_ended (130-139).
- **Dialogue and cutscene.** DialogueOverlay, Negotiation, MainMenu and CharacterCreation screens set hides_hud with closes_on_cancel=false (MainRoot.tscn:393-418). CinematicOverlay hides the HUD through UIStack (main_root.gd:73-78).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1a | Any fight ending anywhere disarms, clears and hides the hotbar. There is no world guard, so a fight finishing off-screen wipes the on-screen bar. | ui/hotbar/dock.gd:130-139; combat_manager.gd:404 (faction only) | CONFIRMED; review 11-15: still open (now ui/hotbar/dock.gd:133-140), see UI-1 |
| 1b | The hotbar does not restore itself after travel or a world switch. `_on_world_focused` re-reads the selection, which travel just emptied. Only a portrait click re-selects. | ui/hotbar/dock.gd:229-236; world_manager.gd:379; unit_portrait.gd:149-154 | CONFIRMED; review 11-15: probably closed by c4d350c (selection never empty); confirm with the abil scope (now dock.gd:176-183) |
| 2 | `_in_view` returns false for an invalid unit and true for a null context. `_is_watched`, which its comment says it mirrors, does the opposite. The typed `_in_view(candidate: Unit)` call in the refresh loop also errors on a freed unit still in selected_units. | ui/hotbar/dock.gd:103-107, 163-164; combat_manager.gd:547-552 | NEW; review 11-15: still open (dock.gd:113-117), see UI-2 |
| 3 | After a load, an equipped Item from the previous game stays parented under the EquipSlot. `_swap_equipment` only moves items out when `previous_unit` is valid, and the world teardown has freed it. Traced, not run. | party_overview.gd `_swap_equipment` | FIXED (item layer, confirmed by review 11-15): slots show views rebuilt per unit; `clear_display` frees the old widget |
| 4 | PartyOverview or Compendium showing stale data after a load. The code disagrees: close_all pops every screen, and reopening rebuilds. | world_manager.gd:353→381; party_overview.gd:248-263; compendium_menu.gd:82-84 | NOT REPRODUCED |
| 5 | FIXED (committed 82eb3dc7; review 11-15 corrected "uncommitted"): `DownedTracker` (ui/downed_tracker.tscn, a child of unit.tscn) shows the two tracks over a Downed unit — three green bars toward stable, three red toward death — and swaps to a stable icon once stable. Fed by `downed_changed`, `downed_tally_changed`, `status_applied/removed`, `died`. The portrait still shows only the HP fraction. | ui/downed_tracker.gd; death_rolls_behavior.gd `_mark`; unit_combat.gd `stabilize` | FIXED (82eb3dc7), confirmed by review 11-15 |
| 6 | `clear_log()` empties `lines` without emitting log_rebuilt, so the on-screen log keeps the old game's transcript after New Game. | system_log.gd:47-48; log.gd:59-62; save_manager.gd:624 | NEW; review 11-15: still open (save_manager.gd:641), see UI-33 |
| 7 | A load never clears the log, so the previous session's lines carry over. | save_manager.gd:388-398 (no SystemLog call) | NEW; review 11-15: still open, see UI-33 |
| 8 | The summon-cap spinbox is read only in _ready, but `max_active_summons` is saved, so the spinbox is stale after a load (debug only). | demon_compendium_panel.gd:59; demon_roster.gd:137 | NEW (minor); review 11-15: still open (demon_compendium_panel.gd:59-60), see UI-23 |
| 9 | `set_elsewhere` and `set_highlighted` both write `modulate`, so whichever runs last wins. | unit_portrait.gd:189-195, 204-206 | NEW (minor); review 11-15: still open (unit_portrait.gd:189-206), see UI-16 |
| 10 | Dead code: `open_on_tab` has no callers and would not refresh. ui/esc_menu.tscn points at a nonexistent script. The system_log.gd header names combat_log.gd, which no longer exists. | party_overview.gd:292; esc_menu.tscn; system_log.gd header | NEW (minor); review 11-15: still open (esc_menu.tscn:3, party_overview.gd:390), see UI-15, UI-22 |
| 11 | PartyOverview, a screen, owns save-registered game state (the inventory). This breaks the "screens own nothing" rule. | party_overview.gd:88, 176 | FIXED (the inventory moved to PartyManager; review 11-15 corrected CONFIRMED, which contradicted the State table) |

### Review 2026-11-15 (HEAD 14cb4ad9)
Doc drift fixed in place above: the hotbar is `ui/hotbar/dock.gd` and `dock_slot.gd` (not ability_hotbar.gd and hotbar_slot.gd), party_overview.gd is 574 lines, `open_on_tab` is :390, the debug grant is :493. The Files list still omits `ui/hotbar/`, downed_tracker.gd, game_over.gd, stats_column.gd, stat_tip.gd, encumbrance_bar.gd, demon_sheet.gd, fusion_menu.gd, compendium_menu.gd, negotiation_panel.gd and screen_fade.gd. Undocumented in the body: the game over screen, LEVEL UP button, stat tips, encumbrance bar, party rail, weapon-set swap, globes, aim and deceptive toggles, demon picker. Two decisions the body now records: the esc menu and cathedral menu name the `overworld` area because overworld work is paused (UI-21); remains are not saved because spawned units do not persist (UI-28, inventory.md).

| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| UI-1 | A far fight ending disarms the hotbar: `_on_combat_ended` has no world or encounter guard (the turn handler has). The armed ability is dropped and the dock swaps to the first selected unit mid-turn. | ui/hotbar/dock.gd:133-140, :120-130; combat_manager.gd:53, :414 | The dock (f31df5fe) carried the old hotbar's handler over, and `combat_ended_in_world` was added later and never used. | Connect to `combat_ended_in_world` and return unless it is the focused world (or the dock's acting unit is in that encounter). | R1 | S | BUG |
| UI-2 | `_in_view` claims to match `CombatManager._is_watched` and does the opposite for an invalid unit and a null context. The typed call errors on a freed unit still in `selected_units`. | dock.gd:113-117, :152-156; combat_manager.gd:565-569; selection_manager.gd:346-351 | A copied predicate, each side then patched for its own crash. | One public `CombatManager.is_watched(unit)` (or `WorldManager.is_in_focused_world`) for both; SelectionManager prunes on `tree_exiting`. | R4 | S | BUG (ui.md issue 2) |
| UI-3 | The slot composes its own "can this be used" answer and ignores FP cost, turn order and move remaining, so a slot can look live and the click be refused, or the reverse. | ui/hotbar/dock_slot.gd:262-263; ability_manager.gd:174-179; unit_combat.gd:560 | Each new cost (ammo b10f303f, attack action, move bar da330426) added its own clause where it was noticed. | One `Ability.why_not_usable(unit) -> String` on the rules side, used by `use_ability`, `_is_still_usable` and the slot (reason in the tooltip). | R9 | M | DECISION NEEDED: the report does not say whether the slot's own check is a bug or the intended split between display and rules; which should hold? |
| UI-4 | Two to-hit numbers. The dock tooltip re-adds the hit-location penalty and `-2 * deceptive_level()` by hand, while the sheet shows `unit.to_hit_target(null, ability)` without them. | dock_slot.gd:207-223; stats_column.gd:179; unit_combat.gd:830-853 | f582f7ac and e32e8bde added the modifiers to the target path only; the tooltip patched the gap. | `UnitCombat.to_hit_parts(target_or_null, ability)` returning named parts; both views print it. | R9, R4 | S-M | BUG |
| UI-5 | Aim and Deceptive toggles are hard-coded by name: every unit gets `AIM_TOGGLES` and `DECEPTIVE_ATTACK` (a spider gets a face-aim toggle), and the slot special-cases `DECEPTIVE_ATTACK` for its tooltip. | dock.gd:264-266; dock_slot.gd:182-183 | Built as constants to ship f582f7ac and e32e8bde ("maneuver toggles stack on attacks"). | Toggles are abilities with `is_toggle`, granted by the ability list or body plan; the dock lists `unit.toggles()`; the tooltip comes from the ability. | R8 | M | DECISION NEEDED: report marks it "intentional?" (f582f7ac, e32e8bde); are the by-name constants the intended design or a shortcut to replace? |
| UI-6 | A summon slot never shows as armed: `_on_demon_picked` arms `ability.duplicate()`, so `ability == armed_ability` is never true, and a second click reopens the picker instead of disarming. | dock_slot.gd:311-343, :258, :297, :311-333 | f30cac11 (summon picker) needed per-cast data and put it in a copy of the resource. | Cast parameters travel beside the ability (`AbilityManager.arm(ability, {"demon": id})`); the picker becomes a generic "needs a choice first" hook on Ability. | R4 | M | BUG |
| UI-7 | The move bar is polled every frame; no signal exists for it. | dock.gd:371-383 | da330426 "Move bar drains while the unit walks". | `set_process(true)` only while the shown unit moves, or movement emits `move_spent_changed`. | - | S | DECISION NEEDED: report marks it "intentional?" (da330426); is per-frame polling acceptable? |
| UI-8 | `static var visible_rows` is a player preference that nothing saves; it resets each launch and survives New Game and load within a session. | dock.gd:41 | A static variable was used as the settings store. | A settings file (`user://settings.cfg`) owned by one Settings autoload. | R2 | S | BUG (minor) |
| UI-9 | `_on_loadout_changed` disarms by checking the armed ability for a `GearDamageEffect`, and `WOUND_TAGS` keeps damage-type abbreviations in the view. | dock.gd:215-220; dock_slot.gd:74-85 | Rules and display data placed in the view where the need appeared. | `ability.depends_on_loadout()`; abbreviations on the damage-type definition. | R9 | S | BUG (quick fix) |
| UI-10 | Three views of the same HP, three signal sets: the sheet connects only `equipment_changed`, the portrait follows `took_damage/healed/died` (`healed` is emitted in one place), the dock is correct. A burning tick leaves the sheet HP stale; a +HT item does not rescale the portrait bar. | party_overview.gd:280-298, :362-371; unit_portrait.gd:127-129; unit_combat.gd:1370; unit.gd:474 | Each view was written against the signals that existed then (the portrait predates `pool_changed`). | One `Unit.sheet_changed` (or a `UnitWatch` helper connecting pool, stat, status and equipment); every view uses it. | R9 | M | BUG |
| UI-12 | The party panel keeps its own list of who is summoned by parsing `result["effects"][i]["summoned"]`, clears it on world loading, and never rebuilds it. After save and load the summon is alive and its chip is gone; summons by other paths never get a chip. | party_panel.gd:423-434, :216-218, :318-325, :415-421 | Written before DemonRoster tracked fielded demons. | Read the DemonRoster fielded list and its signal; chips are a pure function of it. | R2, R9 | M | BUG |
| UI-13 | A screen-space Control lives under each Unit (DownedTracker): `hides_hud` screens do not hide it, and a stand-in hides only the CharacterModel, so a Downed unit's tracker floats over a cutscene at the hidden original's position. It projects with whichever camera is live. | downed_tracker.gd:44, :70-76; unit.tscn:47; stand_in.gd:76 | 82eb3dc7 put the widget on the unit so it follows it for free. | A HUD-layer `WorldMarkers` node drawing one marker per Downed unit of the focused world, skipping hidden or cutscene-held units. | R1, R5 | M | BUG (latent; needs a Downed unit at cutscene start) |
| UI-14 | LEVEL UP closes the overview, opens the level-up screen, and reopens the overview if refused: it flickers and loses tab state. | party_overview.gd:450-459 | The refusal is only known after the screen is asked. | Ask `Progression.why_cannot_level_up()` first; close only then. | R3 | S | DECISION NEEDED: the report gives no status; is the close-then-maybe-reopen order intended? |
| UI-15 | Dead code: `open_on_tab` has no callers, the "party_overview" group is used only by tools and tests, header comments name PlayerInteractionState and ability_hotbar.gd, and a doc block sits on the wrong function. | party_overview.gd:390, :178, :251-256 | Left over from earlier layouts. | Delete them. | - | S | LEFTOVER |
| UI-16 | `set_elsewhere` and `set_highlighted` both write `modulate`; the last caller wins. | unit_portrait.gd:189-195, :204-206 | Two features share one property with no combining step. | One `_restyle()` from two booleans. | R4 | S | KNOWN (row 9) |
| UI-17 | Rule text typed into tips ("half the attack skill, plus 3") that would not follow a rule change; `chip.set_script(StatTip)` at runtime; condition chips have no tip. | stats_column.gd:138, :142, :206, :221-224; encumbrance_bar.gd:42 | The numbers come from `parry_parts()` but the sentence is typed in the view. | Descriptions on StatDefinition (Dodge already does this, :136); a StatTip scene or `StatTip.new()`. | R9 | S | DECISION NEEDED: the report gives no status; is typed tip text acceptable until the rules settle? |
| UI-18 | A screen ends fights and picks the winner: `_end_party_fights` walks all encounters, picks the first living non-party faction and calls `end_combat`. | game_over.gd:55-69 | 5c9e994f: CombatManager has no "party wiped" outcome, and the comment says the fight is lost so it ends now. | CombatManager (or the emitter of `PartyManager.defeated`) ends the party's encounters; the screen only shows. | R9, R1 | S-M | DECISION NEEDED: report marks it "intentional?" (5c9e994f); should the rules move out of the screen now? |
| UI-19 | The `_loading` flag in game_over hides `PartyManager.defeated` firing during a load: a half-rebuilt party reads as defeated, and any other listener to `defeated` has the same hole. | game_over.gd:24, :31-32, :41; party_manager.gd:308-310 | `_check_defeat` is deferred and evaluates a half-built party. | PartyManager does not evaluate defeat between `load_started` and `load_finished` (world scope owns the fix). | R2, R5 | S | DECISION NEEDED: the report gives no status; should the guard stay in the screen until PartyManager owns it? |
| UI-20 | (a) `await WorldManager.behind_black(open)` then "if not open, open()" as a fallback for a refused fade. (b) `_load` ignores a refused `behind_black`, so the button can do nothing. (c) The exit-to-main-menu sequence exists in game_over and esc_menu and differs by the `can_travel()` question. | game_over.gd:48-50, :79-82, :87-92; esc_menu.gd:59-69; main_menu.gd (continue) | `behind_black` returns no result, so callers cannot tell a refusal. | `behind_black` queues or returns a result callers handle; one `WorldManager.exit_to_main_menu(force)`. | R3 | S | BUG (quick fix) |
| UI-21 | Area ids named in UI (`HOME_AREA := &"overworld"`, cathedral `_on_leave` travels to `overworld`) with the return value ignored. | esc_menu.gd; cathedral_menu.gd `_on_leave` | A parked special case: overworld work is paused. | The exit comes from the area's own AreaExit or back-link. | R8 | S | INTENTIONAL; document why: overworld paused |
| UI-22 | `ui/esc_menu.tscn:3` points at `res://src/esc_menu.gd`, which does not exist; MainRoot.tscn:15 uses `ui/esc_menu.gd` directly, so the scene is an orphan. | esc_menu.tscn:3; MainRoot.tscn:15 | The script moved and the scene was left. | Delete the scene. | - | S | LEFTOVER |
| UI-23 | Two fusion UIs, one rule set: FusionMenu refuses a fielded demon, the compendium panel does not, and `FusionRitual.perform` has no guard, so the panel can fuse a demon standing in the world anywhere. The summon-cap spinbox is read only in `_ready`, and `await FusionRitual.perform` then `refresh()` can hit a closed panel. | demon_compendium_panel.gd `_on_fuse_pressed`, :59-60; fusion_menu.gd `_why_not` (~:129-132); fusion_ritual.gd:88-100; party_overview.gd:156 | The panel is the older debug UI; the cathedral menu (c2908cf) was built beside it. | `FusionRitual.why_not(a, b)` holds every rule and both UIs call it, or retire the panel's fuse button. | R9, R4 | S (guard) / M (merge) | BUG |
| UI-33 | `clear_log()` empties `lines` without emitting `log_rebuilt`, so the on-screen log keeps the old transcript after New Game. A load never clears it and the log is not saved. `system_log.gd:9` names a `combat_log.gd` that does not exist. | system_log.gd:47-48, :9; ui/log.gd:59-78; save_manager.gd:641 | `clear_log()` changes the data and not the view's signal. | `clear_log()` emits; SaveManager clears on load (or saves the last N lines). | R2 | S | KNOWN (rows 6, 7) |
| UI-34 | `SfxLayer.play()` awaits a timer on `context.get_tree()` then `context.add_child(player)` with no validity check; if the world parent is freed during the delay (travel, load) it errors on a freed object. | audio_system/sfx_layer.gd:29, :35; unit_sfx.gd:201 | The context is trusted across an await. | Check `is_instance_valid(context) and context.is_inside_tree()` after the await; better, one timer node owned by the layer. | R5 | S | BUG (latent) |
| WLD-9 | same as UI-33 for the New Game and load half (ui.md, rows 6, 7) | | | | R2 | | see world.md |
| WLD-1 | same as UI-19 (ui.md): `defeated` fires on a half-rebuilt party | | | | R2 | | see party.md |

## Tests
- tests/world/: test_the_hud_follows_the_eye.gd (hotbar), test_party_panel_rows.gd, test_initiative_row_scope.gd, test_the_compendium_menu.gd, test_the_fusion_menu.gd, test_a_new_game_is_new.gd
- tests/dialogue/: test_the_log_keeps_up.gd, test_the_party_stays_reachable.gd
- tests/combat/: test_commanding.gd

Gaps:
- No test covers issues 1a, 1b, 3, 6 or 7.
- test_a_new_game_is_new does not assert that the log *view* is empty.
- Nothing asserts the equip-slot contents after a load.
