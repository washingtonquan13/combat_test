# HUD & screens

**Files:** `ui/` — party_overview.gd (453), party_panel.gd (490), ability_hotbar.gd (259), hotbar_slot.gd, unit_portrait.gd, esc_menu.gd (105), menu_button.gd, main_menu.gd, save_load_panel.gd, stash_panel.gd, demon_compendium_panel.gd, compendium_menu.gd, cathedral_menu.gd, area_label.gd, equip_slot.gd; `systems/log_system/` — system_log.gd, log.gd, log_format.gd. Layout lives in MainRoot.tscn (TacticalUI 120-201, PartyRail/PartyPanel 215-238, screens 310-418).
**Autoloads owned:** SystemLog (project.godot autoload list). UIStack belongs to mode_and_ui_stack.md.

## Purpose
These scripts draw game state and send player intent back to the systems that own that state. The rule is that a screen owns no game state. They are not responsible for screen stacking or HUD hiding (UIStack/UIScreen, see mode_and_ui_stack.md), and they do not own combat HUD widgets such as initiative_row.gd and end_turn_button.gd (see combat.md). One exception breaks the rule: PartyOverview owns the party inventory.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| **Party shared Inventory node** (`%Inventory`), a child of the PartyOverview screen. Anything that needs it reaches it through the `party_overview` group. | ui/party_overview.gd:88, 162, 176, 238 | Yes, `inventory` (SaveManager.register at party_overview.gd:176; unregistered at 206-208) |
| Log transcript `lines`, capped at max_lines 500 | systems/log_system/system_log.gd:28, 35 | No |
| Hotbar custom slot assignment. The UI writes it, but it is stored on the Unit. | ui/hotbar_slot.gd:54-55 (writes `unit.custom_slots[i]`) | Saved with the unit (unit.md) |

Everything else is view state: the open tab, row caches and the selected slot.

## Derived / cached state
- **PartyPanel rows.** Cached per Unit or PartyMemberData (party_panel.gd:88-90) and rebuilt from PartyManager and WorldManager signals (111-131). `_mark_absent_members` derives which members are "elsewhere" (261-278). Summons are detected by parsing `result["effects"][i]["summoned"]` (423-434). That is a string-keyed dependency on ability result dictionaries.
- **PartyOverview panels.** These are snapshots taken at open_for(unit) (party_overview.gd:248-263) and are not live. They show gold (CurrencyManager.gold, 189-190), the journal (QuestDatabase/FlagManager, 390-405) and skills (SkillCalculator, 325).
- **Equip-slot item display.** Equipped Item nodes are reparented under EquipSlot.item_layer (equip_slot.gd:84-98). This puts a second parent for an item in the UI tree (see issue 3).
- **AbilityHotbar's shown unit.** `_in_view` (ability_hotbar.gd:103-107) and `_refresh_out_of_combat_unit` (157-181) derive it from SelectionManager.selected_units only.
- **DemonCompendiumPanel summon-cap spinbox.** Set once in _ready (demon_compendium_panel.gd:59) from DemonRoster.max_active_summons.
- **Log view.** A RichTextLabel copy of SystemLog.lines, kept in sync only by signals (log.gd:59-62).

## Public surface
- **Calls in**
  - PartyOverview: `open_for(unit)` (party_overview.gd:248) from the C key (211-232) and from portraits; `get_inventory()` (238) from give_item_effect.gd:27, sacrifice_item_effect.gd:16, item_owned_prerequisite.gd:14 and save_manager.gd:763 (all via the `party_overview` group). `open_on_tab` (292) has no callers.
  - SystemLog: `print()` (system_log.gd:38-44) and `clear_log()` (47-48), called from everywhere and from SaveManager.new_game (save_manager.gd:624).
  - CompendiumMenu: `begin()` (compendium_menu.gd:82-84), called from CathedralMenu.
  - CathedralMenu: `present()` (cathedral_menu.gd:60), called from cathedral_of_shadows.gd:67.
- **Signals out**
  - SystemLog.line_logged and log_rebuilt go to log.gd:59-62.
- **Signals in**
  - AbilityHotbar listens to CombatManager.turn_started and combat_ended, AbilityManager.ability_armed, SelectionManager.selection_changed and WorldManager.world_focused (ability_hotbar.gd:55-62).
  - PartyPanel listens to PartyManager member_added, member_removed and leader_changed; WorldManager world_loading, world_loaded and world_focused; CombatManager.attention_changed; and Conversations.follow (party_panel.gd:111-131).
  - EscMenu listens to SaveManager.load_completed (esc_menu.gd:52, 362-364).
  - MainMenu listens to SaveManager.load_completed (main_menu.gd:50).
  - SaveLoadPanel listens to SaveManager.load_finished (save_load_panel.gd:40, 146).
  - AreaLabel listens to WorldManager world_loading and world_focused and to GameMode.mode_changed (area_label.gd:27-29).

## Depends on
Writes that go from a screen straight into a system:
- The PartyOverview debug grant writes `unit.abilities` directly (party_overview.gd:366-373).
- DemonCompendiumPanel writes DemonRoster.max_active_summons (60) and calls release (165), recruit (182) and FusionRitual.perform (129).
- CathedralMenu calls FusionRitual.perform (cathedral_menu.gd:80) and travels to the overworld (105).
- HotbarSlot arms and disarms through AbilityManager (hotbar_slot.gd:107-110, 169).
- StashPanel reparents both the party inventory and the stash inventory into itself (stash_panel.gd:74-89) and closes the stash on hide (69-71).
- SaveLoadPanel saves (128), loads behind_black (135-136) and deletes (160).
- MainMenu: new_game (86), continue (101-104), MusicManager.play_main_menu (58).
- EscMenu: debug exit with travel_area(&"overworld") (esc_menu.gd:331); main menu via behind_black, unload and UIStack.push (349-359).
- UnitPortrait click: WorldManager.reveal then SelectionManager.select (unit_portrait.gd:139-164).

## Assumptions and invariants
- **A screen is rebuilt on open, never kept live.** The code is safe after a load only because WorldManager._leave_focused calls UIStack.close_all (world_manager.gd:381, reached from _tear_down_worlds 343-353) and travel_area calls it too (884).
- **The party inventory lives as long as MainRoot.** It does, because PartyOverview is persistent in MainRoot.tscn:310. A load is refused if the `party_overview` group is missing (save_manager.gd:756-764).
- **"The hotbar's unit is in the one focused world"** (ability_hotbar.gd:103-107). STALE in part. `_on_combat_ended` (130-139) assumes the only fight is the one on screen. Fights run in non-focused worlds (combat_manager.gd:360 relays every encounter, and combat_ended carries only the faction, 404).
- `_in_view`'s comment claims it matches CombatManager._is_watched. It does not (issue 2).
- **The orphaned ui/esc_menu.tscn is unused.** It references res://src/esc_menu.gd. The live EscMenu is inlined in MainRoot.tscn:317.
- **Esc can stack on any screen.** menu_button.gd pushes and pops esc_menu, so EscMenu can sit over PartyOverview (blocks_input_below MainRoot.tscn:310-311).

## Lifecycle
- **Boot.** Every screen is a persistent MainRoot.tscn node. main_root.gd:83 pushes MainMenu.
- **New game.** SaveManager.new_game calls SystemLog.clear_log() (save_manager.gd:624). The log *view* is not cleared (issue 6).
- **Save.** Only the inventory is saved from here (party_overview.gd:176).
- **Load.**
  - `_tear_down_worlds` → `_leave_focused` → UIStack.close_all (world_manager.gd:353, 381).
  - EscMenu closes itself on load_completed (esc_menu.gd:362-364).
  - The log is not cleared (issue 7).
- **Travel.**
  - travel_area → UIStack.close_all (world_manager.gd:884).
  - The selection is emptied (world_manager.gd:379), so the hotbar goes blank (issue 1b).
  - AreaLabel shows only in OVERWORLD (area_label.gd:63).
- **Combat.** The hotbar disarms on every turn_started (ability_hotbar.gd:110-127) and clears on every combat_ended (130-139).
- **Dialogue and cutscene.** DialogueOverlay, Negotiation, MainMenu and CharacterCreation screens set hides_hud with closes_on_cancel=false (MainRoot.tscn:393-418). CinematicOverlay hides the HUD through UIStack (main_root.gd:73-78).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1a | Any fight ending anywhere disarms, clears and hides the hotbar. There is no world guard, so a fight finishing off-screen wipes the on-screen bar. | ability_hotbar.gd:130-139; combat_manager.gd:404 (faction only) | CONFIRMED |
| 1b | The hotbar does not restore itself after travel or a world switch. `_on_world_focused` re-reads the selection, which travel just emptied. Only a portrait click re-selects. | ability_hotbar.gd:229-236; world_manager.gd:379; unit_portrait.gd:149-154 | CONFIRMED |
| 2 | `_in_view` returns false for an invalid unit and true for a null context. `_is_watched`, which its comment says it mirrors, does the opposite. The typed `_in_view(candidate: Unit)` call in the refresh loop also errors on a freed unit still in selected_units. | ability_hotbar.gd:103-107, 163-164; combat_manager.gd:547-552 | NEW |
| 3 | After a load, an equipped Item from the previous game stays parented under the EquipSlot. `_swap_equipment` only moves items out when `previous_unit` is valid, and the world teardown has freed it. Traced, not run. | party_overview.gd:273-286; equip_slot.gd:84-98; world_manager.gd:410-427 | NEW |
| 4 | PartyOverview or Compendium showing stale data after a load. The code disagrees: close_all pops every screen, and reopening rebuilds. | world_manager.gd:353→381; party_overview.gd:248-263; compendium_menu.gd:82-84 | NOT REPRODUCED |
| 5 | There is no Downed UI. `downed_turns_left` is only ever printed to SystemLog, and the portrait shows only the HP fraction. | encounter.gd:485-487; unit_combat.gd:617-621, 660; unit_portrait.gd:252-259 | CONFIRMED |
| 6 | `clear_log()` empties `lines` without emitting log_rebuilt, so the on-screen log keeps the old game's transcript after New Game. | system_log.gd:47-48; log.gd:59-62; save_manager.gd:624 | NEW |
| 7 | A load never clears the log, so the previous session's lines carry over. | save_manager.gd:388-398 (no SystemLog call) | NEW |
| 8 | The summon-cap spinbox is read only in _ready, but `max_active_summons` is saved, so the spinbox is stale after a load (debug only). | demon_compendium_panel.gd:59; demon_roster.gd:137 | NEW (minor) |
| 9 | `set_elsewhere` and `set_highlighted` both write `modulate`, so whichever runs last wins. | unit_portrait.gd:189-195, 204-206 | NEW (minor) |
| 10 | Dead code: `open_on_tab` has no callers and would not refresh. ui/esc_menu.tscn points at a nonexistent script. The system_log.gd header names combat_log.gd, which no longer exists. | party_overview.gd:292; esc_menu.tscn; system_log.gd header | NEW (minor) |
| 11 | PartyOverview, a screen, owns save-registered game state (the inventory). This breaks the "screens own nothing" rule. | party_overview.gd:88, 176 | CONFIRMED |

## Tests
- tests/world/: test_the_hud_follows_the_eye.gd (hotbar), test_party_panel_rows.gd, test_initiative_row_scope.gd, test_the_compendium_menu.gd, test_the_fusion_menu.gd, test_a_new_game_is_new.gd
- tests/dialogue/: test_the_log_keeps_up.gd, test_the_party_stays_reachable.gd
- tests/combat/: test_commanding.gd

Gaps:
- No test covers issues 1a, 1b, 3, 6 or 7.
- test_a_new_game_is_new does not assert that the log *view* is empty.
- Nothing asserts the equip-slot contents after a load.
