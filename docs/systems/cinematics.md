# Cinematics

**Files:** `systems/cinematic_system/` (3230 lines; cinematic_stage.gd 879, cinematic_director.gd 310, cinematic_beat.gd 214, scene_cast.gd 189, camera_framing.gd 180, stage_role.gd 167, walk_to_beat.gd 149, framing_rig.gd 148, cinematic_camera.gd 134, cinematic_cues.gd 126, line_beat.gd 125, cinematic_overlay.gd 94, spawn_beat.gd 90, silhouette_beat.gd 84, place/face beats 66, despawn 43, clip 41, effect 40, sound 38, scene_binding 35, wait 12); authoring guide `CINEMATICS.md` (529); cutscenes `cinematics/demo_conversation.tscn`, `fusion.tscn`, `test_arena_arrival.tscn`.
**Autoloads owned:** `CinematicDirector` (project.godot:41). Scene nodes: `CinematicCamera` (MainRoot.tscn:67), `CinematicCues` (MainRoot.tscn:70).

## Purpose
Plays authored cutscenes: a stage .tscn is a timeline of beats (line, walk, spawn, face, clip, effect, sound, wait...) against a `SceneCast` of bound roles and marks, driven by one director with one cinematic camera and overlay. `CinematicCues` decides when to auto-play (area intros, combat intros). It does NOT know about Conversations (cinematic_director.gd:13) - dialogue staging asks it, not the reverse - and it does not own camera control in gameplay (CameraDirector does).

## Stand-ins and scene templates
A staged scene never moves a gameplay unit. `StandIn.raise(unit, at, facing)` (stand_in.gd) duplicates the unit's live `CharacterModel` under a top-level child of the unit named `StandIn`, hides the unit's own body, and `strike()` (or the node leaving the tree) puts the body back. The unit's transform, collision and nav occupancy are never written. `SceneTemplate` (scene_template.gd) is a .tscn of `Marker3D` marks named by cast role; `fit(cast)` puts its origin on the `anchor_role` unit, turns -Z toward the `toward_role` unit, checks every mark for floor within 0.4 m of the origin's height and standing room (trying turns of 0, +-30, +-60 degrees), and returns `{}` when the cast (radius over `widest_radius`, flying, dead) or the ground does not fit. No fit is ordinary: the scene plays on the units as they stand.
- **Animation on the copy**: the duplicate would carry the unit's `BodyAnimationTree` and share its root (its playback), so `raise` frees it (and the shared `BodyFlinch`) and gives the copy a `BodyAnimationTree` of its own on its own player, so it layers as the unit's body does. `StandIn.play(clip, blend, layer)` goes through that tree. Reading where the original's clip had got to (`_stand_idle`, `match_original`) goes through the original's tree.
- **Layers in a scene**: `CinematicStage.clip(role, name, claims, layer, blend)`; `ClipBeat` exports `layer` (BODY / UPPER / FLINCH; UPPER with no clip lowers the upper body) and `blend` (-1 = stance blend time); `WalkPathBeat.upper_animation_name` plays over the walk from the first step and comes down on arrival. A BODY clip in a scene leaves an upper clip the scene put up in place; the first claim lowers whatever gameplay had up.
- **Paired actions**: `PairedClip` (paired_clip.gd; `lead_clip`, `partner_clip`, `partner_from_lead`, `contact_time`, `length`, `kills_partner`) and `PairedActionBeat` (beats/paired_action_beat.gd). The beat owns the distance: `places()` works out both bodies' places (midpoint and line kept, or lead on `mark`), `tick` eases both there over the first 75% of the time to contact, and `_end` puts the lead on its idle (a finished one-shot scene clip otherwise restarts, because `play_cutscene_clip` makes it the base clip) and, for a kill, sets the partner's `death_animation` to the clip, calls `die()` and seeks to the end so they do not fall twice. The unit then goes through ordinary death (model freed after `death_cleanup_delay`). First pair: `assets/paired_clips/stab.tres`, clips in `assets/paired_animations.tres` (library `Paired` on placeholder_model.tscn only), generated with kimodo.cpp and baked by `tools/kimodo/make_paired_animations.gd` from `tools/kimodo/takes/`. Scene `cinematics/paired_stab.tscn`, walkthrough `tools/paired_stab_demo.tscn`.
- **Outcomes into gameplay**: `HurtBeat` (beats/hurt_beat.gd; WOUNDED sets HP via `set_pool`, DEAD via `static kill(unit, clip)`, which PairedActionBeat's kill also uses) and `AreaBeat` (beats/area_beat.gd; `area_of` walks up to the GameArea and calls `method`). A dead unit's corpse timer (`UnitDeath._clear_corpse_after`) waits while a stand-in of it is up, then the usual `death_cleanup_delay`, so a body killed mid-scene does not vanish from a shot. The raid: `cinematics/camp_raid.tscn` (generated, 59 s, 13 roles), played once on first arrival by `RaidCamp._on_world_focused` (flag `raid_camp.raid_played`), which starts combat with the party, the goblins and the armed camp; the campers stay out. Scene clips (Shout, Cower, Fall_Wall) in `assets/scene_animations.tres` (library `Scene`, baked by `tools/kimodo/make_scene_animations.gd`); the chop pair in `assets/paired_clips/chop.tres`. Walkthrough `tools/raid_demo.tscn`.
- **Readers that ask the stand-in first**: `CameraFraming._read_source`, `SceneCast.point`, `FaceDriver.of`, `DialogueGaze`, `DialogueStaging._keep_side`. Gameplay never reads it.
- **Cutscenes**: a stage with `performs_on_stand_ins` routes every beat that moves, turns or animates a body through `CinematicStage.body(role)`, which raises a stand-in where the unit stands on first use (`put`, `move`, `face`, `clip`, driven markers, `locate`, `point`). Units stay where the game has them for the whole scene. `CinematicDirector._run_timeline` calls `stage.commit_stand_ins()` when the scene finished or was settled (skip, abort): each unit goes to the nearest standable point to its copy, facing as the copy faced, and the copies are struck. A scene cancelled without settling (world loading) strikes the copies and moves nobody. Roles the scene spawned itself (`SceneCast.is_held`) are moved directly. Without the flag (the default; fusion) beats act on the unit as before. Used by `cinematics/goblin_camp_ambush.tscn`.
- **Player feedback**: `raise` frees the copy's twins of the body's `outline_mesh` and `highlight_mesh` (which holds the ring decals and drop line), so a ring or hover outline showing at the moment of the copy is not frozen into the shot. The unit's own stay on its hidden body and come back on `strike`.
- **Clip blending**: `CinematicStage.clip` crossfades on the actor's `UnitAnimator.stance_blend_time`, through `StandIn.play(clip, blend)` or `UnitAnimator.play_cutscene_clip(clip, blend)`, so scene clips no longer cut pose to pose.
- **Limits**: effects and floating text stay on the real unit; on a stage without `performs_on_stand_ins`, clip and walk beats animate the unit itself; the copy is taken once at raise, so gear changed mid-scene does not show.

## Shots
- `FramingRig` (framing_rig.gd) mirrors every CameraFraming field, including `pan_degrees` and `focus_blur`, through `_fill`. Keying the stage's `shot` is a cut; keying a rig's numbers is a move.
- `CameraPathRig` (camera_path_rig.gd) extends it: the eye is `path` (a Path3D, stage-owned) sampled at `progress` 0..1 by baked distance; the aim is the usual look role/mark, or `aim_path` at the same progress. Its framing (`_Riding`) never `shares_subject_with` another, so it is always a cut. No line resolves to ZERO and the camera holds.
- A held line (`wait_for_advance`) sets the timeline's speed_scale to 0, so keyed moves freeze during it.
- The goblin camp ambush opens on `camp_crane` (a ride) and ends on `hobgoblin_push` (keyed distance and fov on the unheld last bark).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Running flag | cinematic_director.gd:53 | No |
| Mounted stage | cinematic_director.gd:56 | No |
| Generation counter (cancel token) | cinematic_director.gd:59 | No |
| Settle-on-cancel, skip/advance requests | cinematic_director.gd:62, :65-66 | No |
| Registered camera and overlay | cinematic_director.gd:70-71, :82-95 | No |
| Role/unit claims during a scene | scene_cast.gd:121-138; clip claims cinematic_stage.gd:596-609 | No |
| Stand-in per unit (node `StandIn` under the unit) and the hidden body's prior visibility | stand_in.gd | No |
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
`tests/cinematic/` (13): a_paired_kill_lands (tip in the chest at contact from five starts up to half a metre out), a_shot_can_ride_a_line, a_stand_in_wears_no_rings, dialogue_stand_ins, a_scene_performs_on_stand_ins, a_scene_can_direct_a_performance, a_scene_is_a_timeline, framing_and_transit, fusion_plays_without_dialogue, new_callers_cost_nothing, staging_stays_out_of_the_dialogue, the_rig_speaks_one_vocabulary, the_seam (world_loading cancel). Also tests/combat/test_run_and_shoot.gd: legs of a run with the bow up match a plain run, a hit on the run flinches, and a WalkPathBeat with an upper clip shows it on the stand-in and lowers it on arrival. Gaps: no multi-resident-world mark lookup test; no combat-intro-in-unfocused-world test.
