# Cinematics

**Files:** `systems/cinematic_system/` (3230 lines; cinematic_stage.gd 879, cinematic_director.gd 310, cinematic_beat.gd 214, scene_cast.gd 189, camera_framing.gd 180, stage_role.gd 167, walk_to_beat.gd 149, framing_rig.gd 148, cinematic_camera.gd 134, cinematic_cues.gd 126, line_beat.gd 125, cinematic_overlay.gd 94, spawn_beat.gd 90, silhouette_beat.gd 84, place/face beats 66, despawn 43, clip 41, effect 40, sound 38, scene_binding 35, wait 12); authoring guide `CINEMATICS.md` (529); cutscenes `cinematics/demo_conversation.tscn`, `fusion.tscn`, `test_arena_arrival.tscn`.
**Autoloads owned:** `CinematicDirector` (project.godot:41). Scene nodes: `CinematicCamera` (MainRoot.tscn:67), `CinematicCues` (MainRoot.tscn:70).

## Purpose
Plays authored cutscenes: a stage .tscn is a timeline of beats (line, walk, spawn, face, clip, effect, sound, wait...) against a `SceneCast` of bound roles and marks, driven by one director with one cinematic camera and overlay. `CinematicCues` decides when to auto-play (area intros, combat intros). It does NOT know about Conversations (cinematic_director.gd:13) - dialogue staging asks it, not the reverse - and it does not own camera control in gameplay (CameraDirector does).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Running flag | cinematic_director.gd:53 | No |
| Mounted stage | cinematic_director.gd:56 | No |
| Generation counter (cancel token) | cinematic_director.gd:59 | No |
| Settle-on-cancel, skip/advance requests | cinematic_director.gd:62, :65-66 | No |
| Registered camera and overlay | cinematic_director.gd:70-71, :82-95 | No |
| Role/unit claims during a scene | scene_cast.gd:121-138; clip claims cinematic_stage.gd:596-609 | No |
| Spawned role nodes | cinematic_stage.gd:532-571 | No |
| "Intro already played" | cinematic_cues.gd:57-75 via FlagManager | Yes, as a flag (FlagManager save) |

## Derived / cached state
- `GameMode` CUTSCENE derives from `CinematicDirector.is_active()` and is asked first (game_mode.gd:95-97; cinematic_director.gd:98-99). Cancel is deferred one frame, so `_running` (and CUTSCENE) persists through a synchronous load (issue 2).
- `CinematicCues` reads `WorldManager.current_world()` for combat intros instead of the encounter's world (cinematic_cues.gd:80-87).

## Public surface
- **Calls in**: `CinematicDirector.play(scene, cast)` from fusion_ritual.gd:102, cinematic_cues.gd:93, dialogue_staging.gd:111 (not awaited, return ignored), debug/debug_cutscene_harness.gd:93, :131; `abort()` (:175-176); `camera()` from dialogue_staging.gd:116-120; `register_camera` (cinematic_camera.gd:48), `register_overlay` (main_root.gd:78); `is_active()` from GameMode.
- **Signals out**: `scene_started`, `scene_finished` (cinematic_director.gd:48-49).
- **Signals in**: `WorldManager.world_loading` -> `_cancel(false)` (cinematic_director.gd:74-79, :309-310); CinematicCues listens to world_loaded / world_focused / CombatManager.combat_started (cinematic_cues.gd:36-39).

## Depends on
- WorldManager.spawn_parent() for mounting and spawns (cinematic_director.gd:207-232; cinematic_stage.gd:541, :620, :632; spawn_parent = focused world or _scene_root, world_manager.gd:962-963).
- CameraDirector.activate/deactivate_cinematic_camera (cinematic_camera.gd:75-82, :130-134; camera_director.gd:65-75).
- PartyManager.leader for cue casts (cinematic_cues.gd:124-126); FlagManager for intro flags (:57-75).
- Tree group of marks (scene_cast.gd:155-177).

## Assumptions and invariants
- One cutscene at a time; `play` refuses while running (cinematic_director.gd:131-134).
- One registered cinematic camera/overlay process-wide (cinematic_director.gd:82-95).
- Stage mounts in the focused world (spawn_parent). Marks are looked up tree-wide, first match by name (scene_cast.gd:155-177) - **STALE** with multiple resident worlds (world_manager.gd:1062): a mark of the same name in a non-focused world can win.
- Combat intro assumes the fight is in the focused world (cinematic_cues.gd:80-87) - **STALE** single-focused-world/single-fight assumption now that encounters are per-world instances.
- No save during a cutscene: can_save refuses CUTSCENE (save_manager.gd:300-302). Load is not gated by mode but world_loading cancels the scene.
- Cancel is cooperative: the polled loop checks generation each frame (cinematic_director.gd:244-300); a vanished stage cancels (:262-264).

## Lifecycle
- **Play**: mount stage under spawn_parent, bind cast, await `_run_timeline`, release claims, clear running (cinematic_director.gd:127-165). Skip/advance via `_input` (:191-199), stage `skip_to_end` (cinematic_stage.gd:471).
- **Cancel**: `_cancel` bumps generation (:179-183); camera released (:296-298); stage unbinds (cinematic_stage.gd:380).
- **World travel / load / new game**: world_loading is emitted by both `_tear_down_worlds` (world_manager.gd:344) and `_enter_world` (:678) -> cancel.
- **Combat start**: CinematicCues may play a combat intro (cinematic_cues.gd:80-87); camera released only on completion (:92-102).
- **Dialogue**: DialogueStaging plays per-node scenes when bindings exist (inert today, see dialogue.md #7) and frames speakers via `camera()`.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | (c) CinematicDirector cancels on world_loading. | cinematic_director.gd:74-79, :309-310; test tests/cinematic/test_the_seam.gd:133, :146-149 | CONFIRMED (handled) |
| 2 | Cancel lands next frame, so `_running` / GameMode CUTSCENE is still true during the synchronous load_file that emitted world_loading; anything querying mode mid-load sees CUTSCENE. | cinematic_director.gd:179-183, :244-300 | NEW (minor) |
| 3 | Marks resolved tree-wide, first by name - not scoped to the focused/stage world. | scene_cast.gd:155-177 | NEW |
| 4 | Combat intro uses focused world, not the encounter's world. | cinematic_cues.gd:80-87 | NEW |
| 5 | CinematicCues releases the camera only on normal completion; cancellation path relies on director's release (:296-298). | cinematic_cues.gd:92-102 | NEW (check) |
| 6 | Intro flag set before play; a cancelled intro is never replayed. | cinematic_cues.gd:57-75 | NEW (design choice?) |
| 7 | dialogue_staging calls play without awaiting or checking refusal; a staged node during a running cutscene is silently dropped. | dialogue_staging.gd:111 | NEW |

## Tests
`tests/cinematic/` (8): a_scene_can_direct_a_performance, a_scene_is_a_timeline, framing_and_transit, fusion_plays_without_dialogue, new_callers_cost_nothing, staging_stays_out_of_the_dialogue, the_rig_speaks_one_vocabulary, the_seam (world_loading cancel). Gaps: no multi-resident-world mark lookup test; no combat-intro-in-unfocused-world test.
