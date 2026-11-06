# Areas & bootstrap

**Files:**
- **Bootstrap:** `main_root.gd` (83) with MainRoot.tscn.
- **Area contract and data:** `systems/world_system/game_area.gd` (100), area_definition.gd (33), area_database.gd (51), area_exit.gd (94), area_validator.gd (180), and `systems/interaction_system/travel_interaction.gd`.
- **Area scripts in `world/`:** test_arena.gd (111), overworld.gd (268), overworld_avatar.gd (287), overworld_door.gd (96), overworld_district.gd (46), cathedral_of_shadows.gd (88), ladder.gd (309), proto_block.gd (43), city_geometry.gd (59).
- **Debug:** `debug/debug_spawner.gd` (115), debug_combat_harness.gd (166).
- **Data:** `data/areas/*.tres` — test_arena, test_area_2, test_area_3, overworld, cathedral_of_shadows.

WorldManager internals (residency, focus, teardown) are documented in world.md.

**Autoloads owned:** DebugSpawner (project.godot autoload list).

## Purpose
This system covers how the game boots and how a `.tscn` becomes a playable area.

Boot pushes the title screen and loads no world (main_root.gd:1-20, 80-83). An area is two files:
- an AreaDefinition `.tres` holding id, display_name and world_scene (area_definition.gd:22-32)
- a scene whose root is a GameArea or a subclass of one

GameArea provides the duck-typed contract that WorldManager, GameMode and CinematicCues query (game_area.gd:3-27, 57-90).

This system does not hold residency, party embodiment or save state. Those belong to WorldManager, PartyManager and SaveManager.

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Area catalog, loaded lazily from res://data/areas/ | area_database.gd:21-23, 45-51 | No (static data) |
| AreaDefinition id, display_name and world_scene | area_definition.gd:22-32 | No (static data) |
| AreaExit target_area, target_spawn_point and arrival_point | area_exit.gd:31, 41, 52 | No (authored) |
| GameArea entry_scene and combat_intro_scene | game_area.gd:51, 54 | Seen-flag `ENTRY_FLAG_PREFIX+id` is saved through FlagManager (cinematic_cues.gd:66-69) |
| Overworld avatars per PartyGroup, plus the district currently shown | overworld.gd:60, 64-67 | No. The avatar writes `group.overworld_position` every physics frame (overworld_avatar.gd:122-124), and that is saved by PartyManager (party_manager.gd:487, 597) |
| Test-arena goblinoid watch | test_arena.gd:8, 98-111 | Result saved as flag `townsperson_raids_resolved` |
| DebugSpawner armed_definition and armed_faction, and its SpawningIntent | debug_spawner.gd:27-34 | No |

## Derived / cached state
- **Spawn point.** Resolved by name, then the `party_spawn_point` export, then a node named "PartySpawnPoint", then a node named "Start" (game_area.gd:78-90). If none is found, WorldManager spawns at world origin with a warning (world_manager.gd:1186-1194).
- **Entry spawn name.** WorldManager writes it into `_pending_spawn_point_name` *before* add_child (world_manager.gd:721, 1213-1238). The overworld reads it during avatar creation (overworld.gd:263-266). For the overworld it is used only when `overworld_position == ZERO`, so a returning group ignores the door back-link and reappears at its remembered position (overworld.gd:263-267).
- **Base mode.** GameMode derives it from `world.get_base_mode()` (game_mode.gd:133-136):
  - EXPLORATION is the default (game_area.gd:57-58).
  - The overworld returns OVERWORLD (overworld.gd:174-175).
  - The cathedral returns FACILITY (cathedral_of_shadows.gd:42-43).
- **Tactical camera.** Uses the `tactical_camera` export, or else the first Camera3D found (game_area.gd:65-68, 93-100).
- **Global shader params.** `deck_cutaway_radius` and `player_position` are process-global, not per-world (overworld.gd:75, 90, 148; overworld_avatar.gd:126).

## Public surface
- **Calls in**
  - AreaDatabase.find, called by:
    - WorldManager (world_manager.gd:651, 850)
    - SaveManager (save_manager.gd:795)
    - OverworldDoor (overworld_door.gd:76, 95)
  - AreaDatabase.get_all, called by AreaValidator (area_validator.gd:45).
  - AreaExit.travel() is called from:
    - TravelInteraction (travel_interaction.gd:10-14)
    - OverworldDoor.activate (overworld_door.gd:70-79), after the avatar's shrink animation (overworld_avatar.gd:249-264)
  - GameArea get_spawn_point, get_tactical_camera, spawns_party and get_base_mode are called by WorldManager (world_manager.gd:384, 479, 555, 1188) and GameMode (game_mode.gd:135).
  - The entry_scene and combat_intro_scene exports are read by CinematicCues (cinematic_cues.gd:63, 84).
  - The first world load comes from CharacterCreation confirm: `travel_area(&"test_arena")` (character_creation.gd:451).
  - `DebugSpawner.arm / disarm / spawn_at` (debug_spawner.gd:43-115) are driven by the debug spawn panel.
- **Signals out**
  - `DebugSpawner.armed_changed` (debug_spawner.gd:25).
  - `get_tree().call_group(&"area_label", &"show_area", …)` sends overworld district names to the area label (overworld.gd:131).
- **Signals in**
  - WorldManager.world_focused, received by Overworld (overworld.gd:74, 87-100), OverworldDoor (overworld_door.gd:37-44) and CityGeometry (city_geometry.gd:17-30, which disconnects on exit).
  - `Unit.died`, received by TestArena (test_arena.gd:104-105).

## Depends on
- **MainRoot** registers the shell with the autoloads (main_root.gd):
  - WorldManager: scene root (23), world host (27), attention nodes (41-44).
  - UIStack: HUD (62), party rail (71).
  - CinematicDirector: overlay (78).
  - It also adds DialogueGaze (51) and DialogueStaging (57).
- **TestArena** reaches into PartyManager: members, roster, add_member, set_leader, pending_leader and spawn_member (test_arena.gd:39-61). It also calls FlagManager.set_flag (111).
- **Cathedral** finds CathedralMenu through the `cathedral_menu` group and calls `present()` (cathedral_of_shadows.gd:56-67). It reads FusionRitual.DEVICE_MARK (85).
- **Overworld** reaches into PartyManager (groups_in_area, active_group; overworld.gd:195-221) and calls `WorldManager.area_of` and `pending_spawn_point_name` (195, 264).
- **OverworldAvatar** uses PartyManager.leader_alignment and active_group (overworld_avatar.gd:179, 284).
- **DebugSpawner**:
  - WorldManager.spawn_parent (debug_spawner.gd:101)
  - CombatManager.add_unit_to_combat and running_encounter_in_world_of (107-108)
  - PartyManager.add_member (115)
  - the `click_router` group (44, 67)

## Assumptions and invariants
- **Boot is not a world load.** Mode is MAIN_MENU because no world is focused (main_root.gd:80-83). The only front-end world load is character creation's travel to the hard-coded test_arena (character_creation.gd:447-451).
- **test_arena is the implicit start area.** It builds the starting party in `_ready` only when PartyManager is empty (test_arena.gd:39-46). Pointing new game at any other area would produce no party.
- **GameArea defines no `_ready`, on purpose.** Subclasses therefore never need super() (game_area.gd:15-19; cathedral_of_shadows.gd:35-37).
- **A world's `_ready` runs inside add_child, before WorldManager registers its resident and context.** The world is added to the viewport before `resident.context` and `_residents[id]` are set (world_manager.gd:746 vs 750, 755). So `WorldManager.area_of(self)` returns null during `_ready`, and the Overworld's `_ready` sync_avatars and snap_to_target do nothing (overworld.gd:83-84, 195-198). World_focused, which follows straight after, does the real work (overworld.gd:87-91).
- **"The fight starting is in the world on screen."** cinematic_cues `_on_combat_started` picks the intro from `WorldManager.current_world()`, not from the fight's world (cinematic_cues.gd:80-84). STALE: fights run in non-focused worlds (see world.md and combat.md).
- **The overworld spawns no party.** It draws one avatar per abstract group (overworld.gd:182-183, 194-238). The cathedral also spawns no party (cathedral_of_shadows.gd:46-47). WorldManager's `_embody_into` disembodies the group there (world_manager.gd:479-481).
- **The cathedral has no exit other than its menu.** If CathedralMenu is missing, the player is stranded, and the code warns loudly about it (cathedral_of_shadows.gd:56-66).
- **AreaExit takes travellers from SelectionManager**, filtered to valid party members (area_exit.gd:83-88). The load is deferred (88).

## Lifecycle
- **Boot.** Autoloads run, then MainRoot._ready registers everything and pushes MainMenu (main_root.gd:22-83). No world exists yet.
- **New game.** Character creation sets `PartyManager.pending_leader` (character_creation.gd:445) and calls travel_area(&"test_arena") (451). TestArena._ready spawns the leader from pending_leader, followed by three data-defined companions (test_arena.gd:42-80). CinematicCues may then play entry_scene once, guarded by its flag (cinematic_cues.gd:57-70).
- **Travel.** Exits are either a door's AreaExit or a TravelInteraction. They call WorldManager.travel_area (area_exit.gd:93-94), which runs behind the black screen and calls UIStack.close_all (world_manager.gd:875-889). A resident world is re-entered without `_ready`. Area scripts that need to refresh on re-entry listen to world_focused (overworld.gd:87; overworld_door.gd:40-44).
- **Load.** SaveManager rebuilds areas through AreaDatabase (save_manager.gd:795-798) and `WorldManager.rebuild_area` (world_manager.gd:650-660). TestArena's party block is skipped because the roster is restored first (test_arena.gd:37-40).
- **Combat.** combat_intro_scene plays through CinematicCues (cinematic_cues.gd:80-87). DebugCombatHarness can start a fight with every living unit in the focused world (debug_combat_harness.gd:70-92).
- **Debug spawn.** The spawned unit goes into the focused world and joins that world's running fight (debug_spawner.gd:80-115). It is not persisted (AreaState diffs authored content only).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | AreaValidator.validate() has no caller anywhere: no test, tool or editor hook. Missing music, broken exits and one-way links go unreported. | area_validator.gd:43; repo-wide grep finds only comments in music_manager.gd and world_manager.gd:826 | NEW |
| 2 | A fight's intro cutscene is chosen from the focused world, not the fight's world. A fight breaking out off-screen plays the on-screen area's combat_intro_scene, or none. | cinematic_cues.gd:80-84 | NEW |
| 3 | The start area is hard-coded twice: in character_creation and in test_arena's party bootstrap. No AreaDefinition says "start here". | character_creation.gd:451; test_arena.gd:39-46 | CONFIRMED (known design) |
| 4 | Overworld `_ready` calls sync_avatars and snap_to_target, but `area_of(self)` is still null at that point, so both are no-ops on first build. This is harmless only because world_focused follows. | overworld.gd:83-84, 195-198; world_manager.gd:746-755 | NEW (minor) |
| 5 | The goblinoid quest hook is bound by hard-coded node names (`GoblinRogue`, `Hobgoblin`). A rename silently disables the flag. | test_arena.gd:98-105 | NEW (minor) |
| 6 | The global shader params are written by whichever overworld or avatar runs last. This is not world-scoped, but only one overworld exists today. | overworld.gd:75, 148; overworld_avatar.gd:125-126 | NEW (minor) |
| 7 | The main_root.gd header is stale. It says MainRoot "owns two registrations", but it makes six. It also says music starts from `world_loaded`. | main_root.gd:2-3, 17-20 vs 22-83 | NEW (doc) |
| 8 | DebugSpawner keeps its SpawningIntent pushed on ClickRouter across a travel or load. The intent survives because ClickRouter is a persistent attention node. Debug only. | debug_spawner.gd:54-61; ground_click_target.gd:144-153 | NEW (minor) |

## Tests
- tests/world/test_arrival_placement.gd (back-link spawn)
- test_the_starting_party_has_bodies.gd (test_arena bootstrap)
- test_the_cathedral_is_a_room_not_a_menu.gd
- test_avatar_shrinks_into_a_door.gd
- test_the_overworld_names_where_you_are.gd (districts)
- test_the_harness_stands_up_a_world.gd
- test_the_city_is_solid.gd
- test_world_hosting.gd
- test_residency.gd
- test_a_rebuild_is_not_a_journey.gd
- test_load_restores_every_area.gd

Gaps:
- No test runs AreaValidator (issue 1).
- No test covers a combat intro for an off-screen fight (issue 2).
