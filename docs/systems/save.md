# Save

**Files:** `systems/save_system/save_manager.gd` (883)
**Autoloads owned:** SaveManager (project.godot:43)

## Purpose
SaveManager writes and reads ConfigFile saves under `user://saves/` (save_manager.gd:108-110). It does this through a registry of persistable sections (`register` :162-189). It also owns the three derived sections, `meta`, `world` and `combat` (:144). It orchestrates load: tear down every world, push section state, then rebuild areas. It also runs `new_game()`.

It does NOT own:
- any section's data (each registrant serializes itself)
- the world lifecycle (WorldManager)
- the decision about when saving is allowed beyond a mode check (GameMode)

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Registered persistables | save_manager.gd:139 `_persistables` | n/a, the registry itself |
| Pending party transforms, used during a rebuild | :118 | written as `[world] party_transforms` (:344) |
| Pending encounters to restore | :123 | written as `[combat]` (:356) |
| Format version constant | :110 `FORMAT_VERSION = 1` | `[meta] format_version` (:336), never read back (S1) |

### Registered sections
All autoload registrants call `register` from `_register_persistence`, deferred out of `_ready`. No registrant declares an `after` dependency, so `_load_order` (:218-242) degenerates to registration order.

| Section | Registered by (file:line) | Notes |
|---|---|---|
| `flags` | systems/flag_system/flag_manager.gd:45 | Also carries AreaState (`areastate/` prefix, area_state.gd:35) |
| `demons` | demon_roster.gd:67 | |
| `compendium` | demon_compendium.gd:42 | call_deferred at ~:37 |
| `currency` | currency_manager.gd:49 | |
| `factions` | faction_relations.gd:78 | |
| `party` | party_manager.gd:448 | |
| `inventory` | party_manager.gd:478 | `PartyManager.inventory`, an ItemContainer (RefCounted), registered alongside `party`. No screen involved |
| `meta`, `world`, `combat` | save_manager.gd:144 (derived) | Written inline at :332-356 |

## Derived / cached state
- `[world] party_transforms` is a snapshot of member positions (`_capture_party_transforms` :695). It is applied only on REBUILD (`_on_world_loaded` :716-735).
- The `list_saves` metadata (:646-666) duplicates the leader name and area display name at save time.
- `_restore_encounters_here` (:834-847) keys on `WorldManager.current_area()` at :837. That is correct only because `world_loaded` fires after focus (world_manager.gd:757-760).

## Public surface
- **Calls in**
  - `save(name)` :309: save_load_panel.gd:128
  - `can_save` :292: esc_menu.gd:58, save_load_panel.gd:69
  - `load_file(path)` :388, via `WorldManager.behind_black`: main_menu.gd:104, save_load_panel.gd:135-139
  - `new_game` :540: main_menu.gd:86, character_creation.gd:160-161
  - `list_saves`, `most_recent`, `delete_save` (:646-676): main_menu.gd:50-55, save_load_panel.gd:160
  - `register` / `unregister` / `is_registered`: the registrants in the table above
- **Signals out**
  - `save_completed` :64
  - `load_completed` :65, listened to by esc_menu.gd:52
  - `load_finished(path, ok, reason)` :86, listened to by save_load_panel.gd:40
  - `load_started` :94
  - `new_game_started` :106
  - music_manager.gd:85-86 listens to load and new-game signals
- **Signals in:** `WorldManager.world_loaded` (:280-281) → `_on_world_loaded`

## Depends on
- WorldManager:
  - `current_area` (:313, :837)
  - `discard_worlds` (:426)
  - `rebuild_area` (:470-492)
  - `can_rebuild` (:752)
  - encounter aggregation (:356)
- GameMode: `current_mode` in `can_save` (:292-302), which allows only EXPLORATION, OVERWORLD and COMBAT
- PartyManager: `capture` (:324); `pending_leader` and `clear_members` in new_game
- CombatManager: `restore_combat` (:834-847)
- AbilityManager: `disarm`. SelectionManager: deselect. SystemLog: `clear_log` (new_game :540-638)
- SceneTree group `party_overview` (:763)

## Assumptions and invariants
- **"Being LAST" in the autoload list** (:6). STALE: DetectionManager (project.godot:44) and ScreenFade (:45) load after it. This is harmless today because registration is deferred.
- **Every non-derived section is registered before any save or load.** `_warn_about_unclaimed_sections` (:270) only warns on load.
- **A section missing from the file is loaded as `{}`** (:442-447), so the registrant resets to empty. This makes S3 destructive.
- **Load runs behind black and assumes the base mode.** `_perform_load` never checks GameMode or Conversations (:405-504). Only the structural gates in `_why_load_would_fail` apply (:782-801).
- **Saving during COMBAT is allowed** (:292-302). The old "no saving in combat" rule is gone, and `[combat]` stores every area's encounters.

## Lifecycle
- **Boot:** connects `world_loaded` (:281). Registrants arrive deferred.
- **Save** (:309-364):
  1. refuse unless `can_save` and a current area exists
  2. `PartyManager.capture`; since the baseline `save()` also calls `WorldManager.record_area_states()` (save_manager.gd:338) so the area you are standing in is saved as it is now, not as it was when last left (35c5bc9c). That call writes into FlagManager and must stay above the `flags` section write (:370). Area autosaves (`AREA_AUTOSAVE`/`FIGHT_AUTOSAVE` :111-112, `autosave` :702-704) are slot saves requested from signals and skipped when `can_save()` is false.
  3. build the path from the integer unix time (:328-329)
  4. write meta (:332-336)
  5. write world (:343-344)
  6. write each section's `save_state` (:348-353)
  7. write combat (:356)
  8. `cfg.save` (:358)
- **Load:** `load_file` (:388-397) emits started, completed and finished around `_perform_load` (:405-504). `_perform_load`:
  1. checks the file and the structural refusal (:418)
  2. `discard_worlds` (:426)
  3. calls `load_state` on each section in order (:442-447)
  4. stashes pending transforms and encounters (:453-457)
  5. rebuilds the other party-holding areas (:470-482), then the saved area last (:486-492)
  6. `_on_world_loaded` applies transforms and restores encounters per world
  7. clears pendings (:499)
- **New game** (:540-638): structural refusal, `discard_worlds`, `load_state({})` on every section, then clears party, abilities, selection and log.
- **Travel / combat / dialogue:** passive. `can_save` is false in DIALOGUE, NEGOTIATION, LOOTING and CUTSCENE.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| S1 | `format_version` is written but never read. Neither `_perform_load` nor `list_saves` checks it, so an incompatible future save loads silently. | save_manager.gd:110, :336, :405-504, :646-666 (review 11-15: `FORMAT_VERSION` :108, written :352; `_perform_load` :422-521; `list_saves` :663-684) | CONFIRMED; review 11-15: still open, see WLD-11 |
| S2 | Filename is `int(unix_time)`, so two saves in the same second overwrite each other. There is no slot, quicksave or autosave API; `save(name)` is the only entry point. (Review 11-15, DOC DRIFT fixed in doc: slots and autosaves now exist: `save(save_name, slot)` :320, `FIGHT_AUTOSAVE`/`AREA_AUTOSAVE` :111-112, `autosaves_enabled` :115, `autosave` :702-704, `_autosave_on_entry` :721-724, `most_recent_except` :708, `slot_path` :716. Only the same-second collision for named saves remains, :342-343.) | save_manager.gd:328-329, :309 | HALF FIXED: slots and autosaves exist; named saves in the same second still overwrite each other, see WLD-11 |
| S3 | The `party_overview` requirement is checked only on load and new_game (`_structural_refusal` :763, called from :546 and :787). `save()` does not check it. A save made without PartyOverview lacks `[inventory]`, and loading that save calls `load_state({})`, which **wipes the inventory**. | save_manager.gd:309-364, :442-447, :749-766; ui/party_overview.gd:176 | FIXED (item layer): the inventory no longer depends on PartyOverview, and the `party_overview` refusal is removed; confirmed by review 11-15 |
| S4 | **Esc → Load during dialogue soft-locks.** The chain:<br>1. UIStack pushes the esc menu on ui_cancel without `can_open`, even over DialogueOverlay (`closes_on_cancel=false`).<br>2. The Load button is never gated.<br>3. `load_file` never checks the mode.<br>4. Teardown's `close_all` pops the overlay, but `Conversations.current` is never cleared.<br>5. GameMode stays DIALOGUE, so travel, save and camera control are all refused. | ui_stack.gd:142-145; MainRoot.tscn:397; ui/esc_menu.gd:55-58, :79-80; save_manager.gd:405-504; world_manager.gd:381; conversations.gd:24, ~:96-102; game_mode.gd:98-100 (review 11-15: esc menu flags now MainRoot.tscn:365-369, :373-376) | CONFIRMED; review 11-15: still open, see WLD-10 (mode_and_ui_stack.md) |
| S5 | The same path during a stash or cutscene is safe: stash_panel closes the stash when it is hidden, and CinematicDirector aborts on `world_loading`. | ui/stash_panel.gd:69-71; cinematic_director.gd:79 | NOT REPRODUCED (for stash/cutscene) |
| S6 | Stale "Being LAST" header. | save_manager.gd:6 (review 11-15: :141-143); project.godot:44-45 (DetectionManager and ScreenFade load after SaveManager) | NEW; review 11-15: still open (stale) |
| S7 | No section declares `after`, so load order is registration order. That order depends on deferred-call timing and scene `_ready` for `inventory`. Any future cross-section dependency must be declared or it will be order-fragile. | save_manager.gd:218-249; registrant lines above | NEW |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| WLD-5 | AreaState is written at two moments by two rules (teardown capture and save-time `record_area_states`), and deaths at a third (`unit_death`). The save-time capture is a side effect written into FlagManager before the `flags` section is serialized, so any reorder or new section reading AreaState silently saves stale area state, and a failed save still mutates flags. | world_manager.gd:789-802; save_manager.gd:338, :370; unit_death.gd:69; area_state.gd:35 | `record_area_states` was added beside the teardown capture so a save inside an area records it as it is now (35c5bc9c) instead of becoming a section. | AreaState becomes its own registered section (`SaveManager.register(&"areas", ...)`) whose `save_state()` merges stored snapshots with a live capture of resident worlds: no pre-save call, no ordering rule, and area state stops sharing a namespace with story flags. | R7, R2 | M | INTENTIONAL; document why: save-time capture so a save inside an area is not stale (35c5bc9c) |
| WLD-8 | `_pending_encounters` is keyed by the focused area and outlives a load. | save_manager.gd:870-883 (key read :873); world_manager.gd:757-760 | Correct only because `world_loaded` is emitted after `_focus`. | Use `area_of(world)` from the signal's own world argument, which removes the ordering dependency. | R1 | S | KNOWN (world.md W8) |
| WLD-11 | Save format version is never read; named saves collide within a second; the header is stale; `can_save` doc comment says mid-combat saves are refused but the body allows COMBAT. A renamed status, ability or skill file silently drops content from old saves. | save_manager.gd:108, :352, :422-521, :663-684, :342-343, :288-310, :141-143 | `FORMAT_VERSION` is written and never checked; the filename comes from `int(unix_time)`. | Read the version and refuse or migrate on mismatch; add a counter suffix to named-save filenames; fix the two comments. | R2 | S | KNOWN (S1, S2) |
| WLD-12 | Autosaves are side effects of signals and are skipped silently when `can_save()` is false. The first arrival in an area with an `entry_scene` (and the raid arrival) starts a cutscene on the same signal, so the arrivals most likely to be followed by a fight get no area autosave. The fight autosave runs inside `start_combat`, after the raid has set `RAID_PLAYED`, released the raiders and broken the gate, so Retry loads a raid-played world with no encounter. `save()` also runs `record_area_states()` over every resident world synchronously on the frame a fight starts. | save_manager.gd:699-701, :763-768, :338; combat_manager.gd:147-148; cinematic_cues.gd:49-76; goblin_quarry.gd:236-262 | Autosave was built as a reaction to `world_loaded` and `start_combat` rather than as a request that waits for a savable moment; the raid rearranges the world before the fight starts. | An explicit checkpoint request that queues until `can_save()` is true (one pending slot), raised by travel arrival and by `start_combat` before the staging that leads to it; the raid checkpoints before `_stage_raid` covers the screen. | R3, R7 | M | DECISION NEEDED: is Retry after the camp raid meant to load a raid-played world with no encounter and rely on detection to restart the fight, and is a fight with no autosave of its own (save_manager.gd:699-701) acceptable? |

## Tests
- tests/world/:
  - test_persistence_is_a_registry
  - test_persistence
  - test_a_new_game_is_new
  - test_a_refused_load_changes_nothing
  - test_a_failed_load_leaves_a_usable_front_end
  - test_a_split_party_survives_a_save
  - test_load_restores_every_area
  - test_load_restores_combat_elsewhere
  - test_a_save_can_find_every_definition
- Gaps:
  - No test loads during DIALOGUE or NEGOTIATION (S4).
  - No same-second double save (S2).
  - No version mismatch (S1).
  - No save without PartyOverview (S3).
