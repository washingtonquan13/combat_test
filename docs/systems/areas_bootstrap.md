# Areas & bootstrap

**Files:**
- **Bootstrap:** `main_root.gd` (83) with MainRoot.tscn.
- **Area contract and data:** `systems/world_system/game_area.gd` (100), area_definition.gd (33), area_database.gd (51), area_exit.gd (94), area_validator.gd (180), and `systems/interaction_system/travel_interaction.gd`.
- **Area scripts in `world/`:** test_arena.gd (111), overworld.gd (268), overworld_avatar.gd (287), overworld_door.gd (96), overworld_district.gd (46), cathedral_of_shadows.gd (88), ladder.gd (309), proto_block.gd (43), city_geometry.gd (59).
- **Debug:** `debug/debug_spawner.gd` (115), debug_combat_harness.gd (166).
- **Data:** `data/areas/*.tres` — test_arena, test_area_2, test_area_3, overworld, cathedral_of_shadows; review 11-15 adds goblin_quarry.tres and spider_cave.tres.
- **Review 11-15 additions (file list was stale):** world scripts goblin_quarry.gd (366), spider_cave.gd (10), walk_in_building.gd (31), grass_trample.gd (207), render_time.gd (83), look_test/quarry_look.gd (661); test_arena.gd is now 9 lines and no longer touches PartyManager or FlagManager directly (game_area.gd 123, area_validator.gd 222).

WorldManager internals (residency, focus, teardown) are documented in world.md.

**The overworld map (11-18).** `data/areas/overworld.tres` points at `world/morrow_overworld.tscn`, a grey-box written by `tools/blockout/morrow_overworld.py` (seeded; rerun it rather than hand-editing the scene). The map is 1.6 km square:
- **Districts** (nested squares, smallest wins in `overworld.gd` `_district_at`): Downtown Morrow, Morrow Outskirts, Greywood.
- **Doors** (`SpawnPoints/*`, AreaExit children): CathedralSteps → cathedral_of_shadows, ArenaGate → test_arena, MarketHall → test_area_2, OldDocks → test_area_3, OldQuarry → goblin_quarry (in a Greywood clearing).
- **SafeSpot:** the inn just east of the square, an instance of `world/inn_rest_spot.tscn` (a blue corona in the doors' shader, `rest_spot.gd`): stand in it and press interact for a free full rest. Owned by the rest system (rest.md).
- **Terrain (11-18, procedural stage 1).** Owned by the overworld. `tools/blockout/morrow_terrain.py` (seeded, numpy; run it before `morrow_overworld.py`) writes the ground: rolling hills outside town, a ridge in the Greywood, a flat downtown, four graded roads (grade capped at 7%), a river cut across them as fords, a lake bowl, and level pads under the doors, Start, the inn and the quarry clearing. It writes `world/morrow/terrain.json` (grid, river samples, lake level), `terrain_height.bin` and `terrain_normal.bin` (513² samples, 4 m a cell), and the two paint maps `ground_nature.png` (R soil, G rock, B dirt) and `ground_town.png` (R asphalt, G paving, B cobble), plus a top-down preview in `tools/blockout/build/morrow/` (ignored). `world/morrow/morrow_terrain.gd` (MorrowTerrain) builds it on load (about 80 ms): 64 mesh tiles drawn with `morrow_ground.gdshader`, one HeightMapShape3D, and the water: the river's ribbon and a disc for the lake, both drawn with the quarry's `quarry_water.gdshader` (ripples scaled up to 2.5 m for the high camera, its greens cooled to blue). The shader takes its flow from vertex colours: the river's run along it at `river_flow`, the lake's are still. It needs a sky to reflect, so the overworld's Environment has a ProceduralSky (horizon matched to the fog). Nothing is baked into the scene. The generator samples the same triangles the mesh draws (`Terrain.at`), and everything it places (buildings, trees, rocks, doors, Start, the lake) stands on those heights. **MorrowTerrain must stay under `Ground`:** encounters spawn only on ground under it (overworld_encounters.gd `_spawn_spot`).
- **Roads and city (11-18, procedural stages 2 and 3).** Owned by the overworld. The pipeline runs in order: `morrow_roads.py`, `morrow_terrain.py`, `morrow_city.py`, then `morrow_overworld.py` (all seeded, in `tools/blockout/`, each writing a top-down preview to `tools/blockout/build/morrow/`).
  - **Stage 2** (`morrow_roads.py`) writes `world/morrow/roads.json`: an avenue cross and a ring road downtown, side streets, the square, highways and lanes winding out of town, the quarry road, and a `bridges` list wherever a road crosses the river. Stage 1 grades and paints those roads and sets each bridge's deck height.
  - **Stage 3** (`morrow_city.py`) writes `world/morrow/city.json`. Each building has a footprint polygon, the index of its street-facing edge (`front`), `base`/`floor` heights, `storeys`, a `roof` (flat or gable), a `style` and a `district`. Downtown blocks are what is left between the roads, the square, the doors and the inn. They are split by recursive cuts into lots, with storeys rising towards the centre, and two blocks are kept as parks. Outskirts houses stand along the lanes and highways, gable roofs with the ridge along the road. The grid is 3 m façade bays, 3.5 m storeys and a 4.5 m ground floor (shops downtown). The data is meant to survive into combat-scale streets later.
  - `world/morrow/morrow_city.gd` (MorrowCity, node `City`) builds the buildings on load. It extrudes walls drawn with `morrow_facade.gdshader` (painted windows in bays and storeys, one material per style), adds flat roofs with parapets or gable roofs, and makes one trimesh `City/Solid` for collision. `City` and `Bridges` are **not** under `Ground`, so encounters never spawn on a roof or a deck.
  - **Bridges** (`Bridges/BridgeN`) are a stone deck and two railings, each a box collider, which the avatar's floor snap carries across.
  - Trees and rocks keep clear of roads and buildings using a distance map built from both (`clear_of_roads`). Downtown's parks get a loose grid of trees.
  - Wall and roof textures are in `assets/level/morrow/textures/` (Poly Haven, CC0).
- **Collision:** the terrain's heightmap, the city's trimesh, the bridges' boxes, one cylinder per tree trunk, the lake as a cylinder at its water level, and walls at the map edge.
- The New Orleans map (`world/city_overworld*`, `city_geometry.gd`) is no longer referenced but has not been deleted.

**Random encounters (11-18).** Owned by the overworld. The rest system (rest.md) calls into it, but does not own it.
- **Per district** (`overworld_district.gd`, "Random encounters" group): `danger` (chance per metre walked; a camp's ambush rolls it too), `encounters` (an Array of `EncounterGroup`, `world/encounter_group.gd`: unit definitions plus a weight; the tables are `data/encounters/*.tres`), `battle_area` (an area id) and `encounter_limit` (fights before the district goes quiet; 0 = no limit). The generator sets them: Downtown 1/1500, 2 fights; Outskirts 1/600, 4; Greywood 1/300, 6.
- **Driver:** `world/overworld_encounters.gd` (OverworldEncounters). It is made by `overworld.gd` `_ready` as the child "Encounters". Every metre the commanded avatar walks is rolled, after `grace_metres` (120) from each arrival on the overworld.
- **Chase:** on a hit, a hostile `OverworldAvatar` (`hostile = true`, red, spinning) is placed 45 m off on open ground (a drop ray that hits `Ground`, never a roof or a tree). It grows in with `appear()`, the reverse of `enter()`, then steers straight at you at 0.85 of your pace. Past 130 m it gives up (`vanish()`). Within 5 m it catches you: both icons shrink and `WorldManager.travel_area(battle_area)` runs. No first strike either way.
- **The fight:** a weighted pick from the table is stored in FlagManager as `encounter/pending` (`{group, district}`), so the fight's autosave and Retry respawn the same enemies. `world/battle_field.gd` (BattleField, a GameArea) spawns the units at its `EnemySpawns` markers as faction `enemy` and starts combat with the party. Won, it bumps `encounter/cleared/<district>` and sends the party back to the overworld, where `group.overworld_position` (untouched by any of this) puts them at the spot they were caught.
- **Battlefields:** `world/battle_downtown|outskirts|greywood.tscn` plus `data/areas/battle_*.tres`, written by `tools/blockout/battle_fields.py` (seeded; rerun it, don't hand-edit).
- **Rest:** every rest calls `OverworldEncounters.clear_all()`, which empties the cleared counts. Whether a camp is found is the overworld's: `overworld.gd` `rest_ambush()`, asked by `Rest.plan_camp()` of the world being left (duck-typed). It rolls `danger * rest_ambush_metres` (150, capped at 0.9: Downtown 10%, Outskirts 25%, Greywood 50%) and, only if the district can still fight, returns `encounters.pick_fight(district)`. The fight is not started on the overworld: the rest system carries it to the camp area, which spawns it (rest.md).
- **Limits (known):** the party is sent back `return_delay` (2 s) after the win, so there is no time to loot. The chase is a straight line with no pathing around buildings (the overworld has no navmesh). Only one chaser at a time.

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
- **test_arena is the implicit start area.** It builds the starting party in `_ready` only when PartyManager is empty (test_arena.gd:39-46). Pointing new game at any other area would produce no party. (Review 11-15, DOC DRIFT fixed in doc: new game now travels to `&"goblin_quarry"` (character_creation.gd:685), and the bootstrap is `StartingParty.bootstrap(self, $PartySpawnPoint)`, called from test_arena.gd:9, spider_cave.gd:10 and goblin_quarry.gd:72. It is still true that an area without that call cannot be a start area. This is deliberate: the demo's start party is "one character with every spell and all the gear" (e190dbdb) and the start moved to the quarry with the demo area (f52cf9cb), so each area script calls the bootstrap itself rather than WorldManager asking once; the cost is WLD-13. The goblinoid quest watch moved from test_arena to goblin_quarry.gd:79-93.)
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
- **Overworld door look (11-18).** Owned by the overworld door. An overworld door is drawn as a corona: a glowing ring on the ground with a column of light rising from it and fading upward, one shader for both (world/overworld_door.gdshader, `part` 0 column / 1 ring). The ring has a ripple running outward. Both brighten over 0.25 s while the commanded avatar stands in the door (`hot`, a per-instance shader parameter set by OverworldDoor._set_hot), which is when the Enter prompt is offered.
- **Load.** SaveManager rebuilds areas through AreaDatabase (save_manager.gd:795-798) and `WorldManager.rebuild_area` (world_manager.gd:650-660). TestArena's party block is skipped because the roster is restored first (test_arena.gd:37-40).
- **Combat.** combat_intro_scene plays through CinematicCues (cinematic_cues.gd:80-87). DebugCombatHarness can start a fight with every living unit in the focused world (debug_combat_harness.gd:70-92).
- **Debug spawn.** The spawned unit goes into the focused world and joins that world's running fight (debug_spawner.gd:80-115). It is not persisted (AreaState diffs authored content only).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | AreaValidator.validate() has no caller anywhere: no test, tool or editor hook. Missing music, broken exits and one-way links go unreported. | area_validator.gd:43; repo-wide grep finds only comments in music_manager.gd and world_manager.gd:826 | NEW; review 11-15: still open (git grep still finds only comments) |
| 2 | A fight's intro cutscene is chosen from the focused world, not the fight's world. A fight breaking out off-screen plays the on-screen area's combat_intro_scene, or none. | cinematic_cues.gd:80-84 | NEW; review 11-15: still open (now cinematic_cues.gd:80-86) |
| 3 | The start area is hard-coded twice: in character_creation and in test_arena's party bootstrap. No AreaDefinition says "start here". | character_creation.gd:451; test_arena.gd:39-46 | CONFIRMED (known design); review 11-15: changed, still open: the start area is `goblin_quarry` (character_creation.gd:685) and the bootstrap is called from three area scripts, see WLD-13 |
| 4 | Overworld `_ready` calls sync_avatars and snap_to_target, but `area_of(self)` is still null at that point, so both are no-ops on first build. This is harmless only because world_focused follows. | overworld.gd:83-84, 195-198; world_manager.gd:746-755 | NEW (minor) |
| 5 | The goblinoid quest hook is bound by hard-coded node names (`GoblinRogue`, `Hobgoblin`). A rename silently disables the flag. | test_arena.gd:98-105 | NEW (minor); review 11-15: still open, moved to goblin_quarry.gd:79-93 |
| 6 | The global shader params are written by whichever overworld or avatar runs last. This is not world-scoped, but only one overworld exists today. | overworld.gd:75, 148; overworld_avatar.gd:125-126 | NEW (minor); review 11-15: still open, widened: grass_trample.gd also writes them per world, see WLD-16 |
| 7 | The main_root.gd header is stale. It says MainRoot "owns two registrations", but it makes six. It also says music starts from `world_loaded`. | main_root.gd:2-3, 17-20 vs 22-83 (review 11-15: registrations are :23-81) | NEW (doc); review 11-15: still open (stale comment in main_root.gd) |
| 8 | DebugSpawner keeps its SpawningIntent pushed on ClickRouter across a travel or load. The intent survives because ClickRouter is a persistent attention node. Debug only. | debug_spawner.gd:54-61; ground_click_target.gd:144-153 | NEW (minor) |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| WLD-13 | Three area scripts each call the party bootstrap, and the start area is named in a fourth place. An area without the call cannot be a start area. With an emptied roster, re-entry spawns a fresh fully-equipped leader. `_resource_ids` is a private folder scan that strips `.remap`, beside the databases that do not. | test_arena.gd:9; spider_cave.gd:10; goblin_quarry.gd:72; character_creation.gd:685; starting_party.gd:40, :68-82, :87-94 | The demo loadout was added as a call in each area script, and the start area as a literal in chargen, instead of WorldManager owning "is there a party yet". | `WorldManager._enter_world` asks once and bootstraps any `spawns_party()` area. The start area id lives on one resource. The demo loadout is data, not code. | R7 | M | INTENTIONAL; document why: demo start fixed (e190dbdb, f52cf9cb) |
| WLD-16 | Global shader parameters are written per world with no owner. With two resident grassy worlds the last writer wins, and the world that exits zeroes the rect for the other. Latent: only the quarry has grass. | grass_trample.gd:105-161; overworld.gd:76, :91, :149; overworld_avatar.gd:150; city_geometry.gd:26-59 | Per-world values go to global shader params, so the world that wrote them last owns them. | Put the values on that world's material instances, or write only while `WorldManager.current_world()` is the writer's world and rewrite on `world_focused`. | R1 | S | KNOWN (#6) |
| DLG-26 | same as WLD-13 (areas_bootstrap.md) | | | | R7 | | see areas_bootstrap.md (INTENTIONAL; demo start fixed, f52cf9cb) |

## Tests
- tests/world/test_arrival_placement.gd (back-link spawn)
- test_the_starting_party_has_bodies.gd (test_arena bootstrap)
- test_the_cathedral_is_a_room_not_a_menu.gd
- test_avatar_shrinks_into_a_door.gd
- test_the_overworld_names_where_you_are.gd (districts)
- test_the_harness_stands_up_a_world.gd
- test_the_city_is_solid.gd
- test_a_random_encounter_is_fought.gd (red avatar grows in, district limit and rest, battlefield spawns the fight)
- test_world_hosting.gd
- test_residency.gd
- test_a_rebuild_is_not_a_journey.gd
- test_load_restores_every_area.gd

Gaps:
- No test runs AreaValidator (issue 1).
- No test covers a combat intro for an off-screen fight (issue 2).
