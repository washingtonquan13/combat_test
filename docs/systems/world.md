# World & travel

**Files:** `systems/world_system/` — world_manager.gd (1269), area_database.gd (51), area_definition.gd (33), area_exit.gd (94), area_state.gd (81), area_validator.gd (222), game_area.gd (123, now with `arrival_scene()` :62-68 and `needs_navigation()` :80-81), resident_world.gd (120), world_context.gd (107), world_view.tscn; plus `ui/screen_fade.gd` (43)
**Autoloads owned:** WorldManager (project.godot:35); uses ScreenFade (project.godot:45)

## Purpose
This system loads, hosts, focuses and tears down area worlds. Each world gets its own SubViewport and World3D (world_manager.gd:97-119, 736-751). It moves the party's bodies into and out of worlds ("embodiment"). It diffs authored content against AreaState so kills and pickups persist per area. It runs the fade-to-black around travel and loads (`behind_black`).

It is NOT responsible for:
- the save file format: SaveManager
- party membership: PartyManager owns that; this system only calls capture/embody
- the mode precedence: GameMode
- the combat lifecycle: Encounters are held by WorldContext but owned by CombatManager

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Resident worlds, keyed by area id | world_manager.gd:132 `_residents` | Indirectly: the saved area plus each area holding party are rebuilt on load (save_manager.gd:470-492) |
| The focused resident (the "current" world) | world_manager.gd:137 `_focused` | `[world] area_id` (save_manager.gd:343) |
| World host Control, scene root | world_manager.gd:145, :121 | no |
| Attention nodes and their home parents | world_manager.gd:156, :162 | no |
| Pending spawn-point name, one-shot during entry | world_manager.gd:174 | no |
| Journey latch for the fade | world_manager.gd:183 `_journeying` | no |
| Per-resident pinned flag | resident_world.gd:32 | no |
| Per-world encounters, surfaces, nav grid registration | world_context.gd:33, :37, :50-59 | encounters under `[combat]` via SaveManager |
| Removed authored nodes and stored node state | area_state.gd:35 (FlagManager keys with the `areastate/` prefix) | yes, through the `flags` section |
| Area catalog | area_database.gd:50 (ResourceCatalog over res://data/areas/) | static data |

## Derived / cached state
- `current_area()` / `current_world()` / `context()` are derived from `_focused` (world_manager.gd:920-936). Callers that want "the area this node is in" should use `area_of()` (:1061-1065). The two differ whenever a fight runs in an unfocused resident (see issue W3).
- `ResidentWorld.is_earned()` (resident_world.gd:58-80) is derived on demand from four things: pinned, a running encounter, a group whose `current_area_id` matches, and a contained member. It decides when a world is retired (world_manager.gd:504-535).
- The arrival spawn point is derived from the destination's back-link (`_resolve_entry_spawn_point` :1213, `_find_back_link` :1226). It is never remembered.
- AreaState is applied on entry (`_reconcile_area_state` :794-820) and captured on teardown (`_capture_area_state` :773-785). Between those two points, live nodes and the stored flags can disagree. Since the baseline there is a third moment: `record_area_states()` (world_manager.gd:799-802, called from save_manager.gd:338) captures every resident world at save time (party members skipped, `skip_party` :777-778), so a save taken inside an area records it as it is now (35c5bc9c). Capture walks the live tree only (`_collect_persistent_nodes` :844-850), so a node an area script holds out of the tree (the camp-raid raiders, goblin_quarry.gd:160-162) is not captured; that is safe today because stored state is applied before `_ready` and a held node never changes, and the area script owns the holding as POC story wiring (WLD-6).
- AreaDatabase eagerly loads every `world_scene` (area_definition.gd:26-32), so the catalog holds PackedScene refs for all areas.

## Public surface
- **Calls in**
  - Travel
    - `AreaExit.travel()` → `_load` (area_exit.gd:78-93) → `travel_area` (world_manager.gd:875-885)
    - esc_menu debug exit → `travel_area` (ui/esc_menu.gd:71)
  - Load and new game
    - SaveManager → `discard_worlds` (save_manager.gd:426), `rebuild_area` (:470-492)
    - SaveManager → `can_rebuild` (:749-766)
  - `behind_black(work)` callers
    - world_manager.gd:879
    - ui/esc_menu.gd:94
    - ui/main_menu.gd:104
    - ui/save_load_panel.gd:135
  - Queries
    - `current_area` (unit_death.gd:68, stash_manager.gd:74, save_manager.gd:837)
    - `area_of` (cinematic_cues.gd:60, combat_manager.gd:556, party_group.gd:53, overworld.gd:195)
    - `can_travel` :258, `can_switch_focus` :1051
    - `focus_group` :1074, `focus_world_of` :1085, `reveal` :988
    - `spawn_parent` :962, `encounters_by_area` :1102, `set_area_pinned` :1138
  - Registration: `register_scene_root` :190, `register_world_host` :196 and `register_attention_nodes` :204 (from main_root.gd)
- **Signals out**
  - `world_loading(scene)` (:82), listened to by:
    - cinematic_director.gd:79 (aborts the cutscene)
    - interact_prompt.gd:41
    - area_label.gd:27
    - party_panel.gd:114
  - `world_loaded(world, reason)` (:91), listened to by:
    - crpg_camera.gd:283
    - cinematic_cues.gd:37
    - save_manager.gd:281
    - party_panel.gd:115
  - `world_focused(world)` (:95), listened to by:
    - combat_manager.gd:491
    - music_manager.gd:84
    - HUD: end_turn_button.gd:34, initiative_row.gd:58, ability_hotbar.gd:62, party_panel.gd:119, area_label.gd:28
    - Interaction: ground_click_target.gd:113, interact_prompt.gd:42
    - Overworld: overworld.gd:74, overworld_door.gd:37, city_geometry.gd:20
    - cinematic_cues.gd:38
- **Signals in:** a unit's `died` signal, connected per embodied member and disconnected in `_disembody` (:405-427). WorldManager has no autoload signal subscriptions of its own.

## Depends on
- PartyManager (and how it is called):
  - `capture` (world_manager.gd:408)
  - `split_off` (:436)
  - `merge_in_area` / `embody` (:470-499)
- GameMode: `can_transition` (:261, :1054), `current_mode` (:270, :325)
- InteractionMenu: `is_open` (:258), `close` (:380)
- SelectionManager: `deselect_all` (:379)
- UIStack: `close_all` (:381, :884)
- CameraDirector: `register_tactical_camera` and `unregister_tactical_camera` (:384-387, :555-561)
- CombatManager (indirectly, through running encounters) for `_any_traveller_fighting` (:299)
- NavigationGrid: `invalidate` (:363); WorldContext registers and unregisters grids (world_context.gd:50-59, :88-107)
- AreaState and FlagManager (area_state.gd:35)
- UnitQuery: `all_units`, then `unit.expire` on fielded demons (:1169-1176)
- ScreenFade: `cover` and `uncover` (:906, :912)

## Assumptions and invariants
- **The world contract is duck-typed.** It uses `get_base_mode` and `spawns_party` via `has_method`, and `get_spawn_point` / `get_tactical_camera` via GameArea (world_manager.gd:1-44; game_area.gd:57-90).
- **The spawn point must be resolved before `add_child`.** `_resolve_entry_spawn_point` runs at :721 so that `_ready` sees it.
- **`from_area_id` is honoured only for TRAVEL**, never for REBUILD (:687-689). A rebuilt world places its occupants from the save.
- **Order inside `_leave_focused`:** close_all (:381) runs BEFORE `_focused = null` (:394). StashManager's persist relies on this (see W6).
- **Many worlds can be resident; one is focused.** Unfocused worlds keep processing (resident_world.gd:83-85). Every caller of `current_area()` that means "my area" encodes the old "one world" assumption. **STALE** in unit_death.gd:68 (W3) and fragile in stash_manager.gd:74 (W6).
- **COMBAT does not block travel** unless a traveller is fighting (:258-272). Leaving a fight in progress is allowed (`can_switch_focus` :1051-1056). That is what breaks the old "one fight, in the focused world" assumption.
- **AreaDatabase requires a working directory scan.** In an exported build it cannot see `.remap` files (W5).

## Lifecycle
- **Boot:** main_root.gd registers the scene root, world host and attention nodes. There is no world until the main menu Continue or new-game flow, or the debug harness.
- **Travel:** `travel_area` (:875) runs these steps:
  1. gate on `can_travel`
  2. `behind_black`: cover (:906)
  3. `UIStack.close_all` and `load_area` → `_enter_world`, which:
     - re-enters an existing resident (:699-710), or instantiates a new one and resolves the spawn point (:721)
     - reconciles AreaState (:732)
     - mounts the world into a new view (:739-751)
     - calls `_focus` (:757), which runs `_leave_focused` on the old world (deselect, close menus, move attention home, unfocus), registers the camera and embodies the party
     - retires unearned worlds (:758-759)
     - emits `world_loaded` (:760)
  4. waits 3 settle frames (:181), then uncovers
- **Save:** WorldManager writes nothing itself. SaveManager reads `current_area` and the encounter aggregation.
- **Load / new game:** `discard_worlds` (:334) → `_tear_down_worlds` (:343-364):
  - emits `world_loading(null)`
  - disembodies every group (:351)
  - `_leave_focused` (:353)
  - captures and disposes every resident (:358-361)
  - invalidates the nav grid (:363)

  Then SaveManager rebuilds the other areas and the saved area last, each through `_enter_world(..., REBUILD)`.
- **Combat start/end:** no direct hook. The resident stays earned while an encounter runs (resident_world.gd:58-66). `WorldContext.dispose` finishes its encounters (world_context.gd:88-107).
- **Dialogue / cutscene:** travel is refused by `can_transition` (game_mode.gd:155). A cutscene aborts on `world_loading` (cinematic_director.gd:79).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| W1 | Reported: `_journeying` stays latched if `work` errors. **Not reproduced:** a GDScript runtime error aborts only the erroring callee; `work.call()` returns and :911-913 still run. | world_manager.gd:902-914 | NOT REPRODUCED |
| W2 | `behind_black` real defects: (a) no guard if `work` is a coroutine, since `work.call()` is not awaited (:909), so the screen uncovers before the work finishes; (b) a reentrant call silently returns `null` (:903-904), and main_menu.gd:104 / esc_menu.gd:94 neither await the result nor check it, so a double-click is dropped with no message. Latent (a): every current `work` is synchronous. | world_manager.gd:903-909 (review 11-15: now :919-931); ui/main_menu.gd:104; ui/esc_menu.gd:94; ui/game_over.gd:82 (third unchecked caller) | NEW; review 11-15: still open, see WLD-9 |
| W3 | unit_death records the removal under the FOCUSED area, not the unit's own area. A kill in an unfocused resident fight (allowed by `can_switch_focus`) is filed under the wrong area. The enemy respawns in its own area and a same-id node may be wrongly removed in the focused one. `area_of` exists and should be used. | unit_death.gd:68-69; world_manager.gd:1051-1056, :1061-1065; resident_world.gd:58-66 | CONFIRMED; review 11-15: still open, see WLD-4 |
| W4 | WorldManager is 1269 lines (review 11-15; was 1247) with ~10 responsibilities. Candidate seams (line ranges below are from the baseline and have shifted by about +20):<br>- viewport/attention hosting :97-240<br>- travel gates :242-303 and :1041-1056<br>- residency and teardown :306-580<br>- embodiment :397-499 and :1157-1176<br>- world entry :583-761<br>- AreaState diff :764-833<br>- fade :858-914<br>- reveal/focus :966-1091<br>- queries :917-963 and :1093-1153<br>- spawn/back-link :1179-1247 | world_manager.gd (whole file) | CONFIRMED; review 11-15: still open |
| W5 | In an exported build AreaDatabase sees no areas: ResourceCatalog only strips `.remap` when `handle_remap` is true, and area_database passes false. So `find` returns null and all travel/load fails. The same applies to the ability, demon, item, quest and skill DBs; only spawnable_unit_database passes true. Traced in code only; no export was run. (Review 11-15: advantage_database.gd:34 and stat_database.gd:167 now pass true too; area, ability, demon, item, affix, unique, quest and skill still pass false.) | resource_catalog.gd:66, :139-144 (review 11-15: strip at :142); area_database.gd:50; spawnable_unit_database.gd:76 | HALF FIXED: 3 of 12 catalogs strip `.remap`; the other 9 (including AreaDatabase) do not, see WLD-14 |
| W6 | Reported: StashManager persists into the wrong area on teardown. **Not reproduced:** close_all (:381) runs before `_focused = null` (:394), so `current_area()` is still the stash's world. Fragile: it should use `area_of(stash)`. | world_manager.gd:375-394; stash_manager.gd:66-78 (review 11-15: :72-79) | NOT REPRODUCED; review 11-15: still open (widened: `spawn_parent` world_manager.gd:979-980 also answers with the focused world), see WLD-19 |
| W7 | Stale comments. ui_stack.gd:96 says close_all is called by `load_world()`; it is actually called by `_leave_focused` (:381) and `travel_area` (:884). unit_death refers to a `_current_area` that no longer exists. | ui_stack.gd:96; world_manager.gd:381, :884 | NEW |
| W8 | `_restore_encounters_here` is correct only because `world_loaded` is emitted after `_focus`. Reordering :757-760 would silently restore encounters into the previous area. | save_manager.gd:834-847 (review 11-15: `_restore_encounters_here` is :870-883, key read at :873); world_manager.gd:757-760 | NEW; review 11-15: still open, see WLD-8 (save.md) |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| WLD-3 | Surfaces and clouds are per-world state that nothing saves; a world retire drops them. A wall of fire is gone after save and load while the Burning statuses it lit are restored. | world_context.gd:38-39, :113-114; world_manager.gd:844-850; no `save_state` in systems/surface_system/ | The grids have no save_state and `_capture_area_state` walks only nodes with a `persistent_id`. | `SurfaceGrid`/`CloudGrid` get `save_state`/`load_state` (cell, surface resource path, turns left, owner id); `_capture_area_state` stores it under a reserved per-area entity id and `_enter_world` applies it after the context exists. | R2 | M | DECISION NEEDED: should surfaces and clouds persist across save and a world retire? The baseline README already lists "surfaces not saved" and it was never decided. |
| WLD-4 | A dead unit's area is still "whatever is on screen" (W3). New: party members now always carry a `persistent_id`, so every party death writes `areastate/<area>/<member id>/removed` plus a `state` key that can never match an authored node. | unit_death.gd:68-69, :63-65; party_manager.gd:536-537; starting_party.gd:62; world_manager.gd:777-787, :1078-1082 | `unit_death` calls `WorldManager.current_area()`; the comment saying party members have no ids is stale. | `AreaState.mark_removed(WorldManager.area_of(_owner).id, ...)` and skip units that are not authored content. | R1 | S | KNOWN (W3) |
| WLD-6 | Held-out nodes are invisible to AreaState capture, and capture cannot tell "absent" from "unchanged". Sound today; a later feature that holds a node out after it changed loses the change silently. | world_manager.gd:844-850; goblin_quarry.gd:160-162 | Capture walks the live tree only, and the area script owns "exists but not in the world yet". | GameArea exposes `held_nodes()` (or holding goes through one WorldManager call) and capture walks both. | R7 | S | INTENTIONAL; document why: POC story wiring in the area script (goblin ambush 6f345c96; raid 1515bdab, 14cb4ad9) |
| WLD-9 | `behind_black` drops a second call silently and does not await coroutine work (W2). Third unchecked caller is game_over.gd:82; save_load_panel.gd:135 awaits it and can read null as a failed load. | world_manager.gd:919-931; ui/main_menu.gd:104; ui/esc_menu.gd:94; ui/game_over.gd:82; ui/save_load_panel.gd:135 | A reentrant call returns null, `work.call()` is not awaited, and the busy state is not visible to callers. | Return a small result (`REFUSED_BUSY` vs the work's value), `await work.call()`, and let callers disable their button while `_journeying`. | R3 | S | KNOWN (W2) |
| WLD-14 | Export still loses most content: 9 of 12 catalogs do not strip `.remap`, so an export has no areas and no abilities, demons, items, affixes, uniques, quests or skills. Header comment at resource_catalog.gd:21 is stale. | resource_catalog.gd:142; area_database.gd:50; ability_database.gd:52; demon_database.gd:68; item_database.gd:47; affix_database.gd:27; unique_database.gd:27; quest_database.gd:57; skill_database.gd:56 | `_handle_remap` is a per-catalog option kept "to avoid a behaviour change". | Remove the parameter and always strip; seeing `foo.tres.remap` and not loading `foo.tres` is never right. | R6 | S | KNOWN (W5) |
| WLD-18 | Stale comments that describe a removed design (`load_world()`, "no scene root or world host", removed `capture_party`, "two registrations"). | world_manager.gd:336, :657, :345-347, :372-374, :308, :373; party_manager.gd:495-501, :731; ui_stack.gd:96; game_mode.gd:36-42; main_root.gd:2-3, :17-20; ui/esc_menu.gd:83-87; character_creation.gd:35; unit_death.gd:63-66 | Comments were not updated when the design they describe was removed. | Rewrite or delete them. | - | S | LEFTOVER |
| WLD-19 | `spawn_parent` and StashManager still answer with the focused world (W6): a summon or drop from a fight in an unfocused resident world lands in the wrong World3D. | world_manager.gd:979-980; stash_manager.gd:72-79 | Both ask "the focused world" instead of the world of the node concerned; stash is safe only because `close_all` (:381) runs before `_focused = null` (:394). | `spawn_parent(for_node)` and `area_of(stash)`. | R1 | S | KNOWN (W6) |
| UI-20 | same as WLD-9 (world.md) | ui/game_over.gd:48-92; ui/esc_menu.gd:59-69 | | | R3 | | see ui.md |
| UI-27 | same as WLD-19 (world.md): StashManager persist and loot roll use `current_area()` | stash_manager.gd:67-79; stash_component.gd:39 | | | R1 | | see inventory.md |
| DLG-17 | same family as WLD-14 (world.md): DemonDatabase passes `handle_remap` false | demon_database.gd:68 | | | R6 | | see demons.md |
| DLG-21 | same family as WLD-14 (world.md): portrait grid lists source images in an export | character_creation.gd:534-541 | | | R6 | | see character_creation.md |
| UI-29 | same family as WLD-14 (world.md): loot roller scans every definition | loot_roller.gd:50-58 | | | R6 | | see inventory.md |

## Tests
- tests/world/:
  - residency and hosting: test_residency, test_world_hosting, test_world_isolation, test_world_scoping, test_attention
  - travel and arrival: test_a_rebuild_is_not_a_journey, test_arrival_placement, test_member_reachability
  - party: test_party_split, test_split_stability
  - nav and harness: test_nav_grid_worlds, test_the_harness_stands_up_a_world
  - persistence: test_persistence, test_load_restores_every_area, test_load_restores_combat_elsewhere
- Run via tests/run.sh.
- Gaps:
  - Nothing kills a unit in an unfocused resident and then checks AreaState (W3).
  - Nothing tests `behind_black` reentrancy (W2).
  - No export-build smoke test for the catalogs (W5).
  - area_validator.gd has no runner hook; only comments reference it (music_manager.gd:17, world_manager.gd:826).
