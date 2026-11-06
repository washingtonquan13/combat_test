# Music & audio

**Files:**
- `systems/music_system/music_manager.gd` (258).
- `systems/audio_system/`: sfx_cue.gd (22), sfx_layer.gd (41).
- The consumer of SfxCue is `systems/unit_system/unit_sfx.gd`.
- The director is `addons/sfzplayer/runtime/music_director.gd` (866, class SfzMusicDirector). This doc covers it only as far as MusicManager uses it.
- Debug: `debug/debug_music_panel.gd` (93).

**Autoloads owned:** MusicManager (project.godot:37). Music, the sfizz director, is at project.godot:36 and is owned by the addon.

## Purpose
- **MusicManager** decides *what* music is wanted. It works from live game state: no world means the title; otherwise the focused area's id plus a moment (exploration, combat or negotiation). It turns that into `Music.go_to()` calls (music_manager.gd:1-32, 197-221). It also chooses what to preload.
- **The director** owns all of the following, along with every timing decision (music_manager.gd:5-10):
  - fades
  - bar-aligned transitions
  - ensemble loading
  - resume positions
- **SfxCue and SfxLayer** are fire-and-forget layered one-shot sounds. They are data on abilities, statuses, surfaces and cinematic beats (sfx_cue.gd:1-14; ability.gd:117, 139; status_effect.gd:36-94; surface.gd:82-84; sound_beat.gd:13).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| `_loading` (between load_started and load_finished) | music_manager.gd:72, 164-171 | No |
| `_reported_missing`, the set of music names already warned about | music_manager.gd:52, 248-250 | No |
| `_threat_seen_msec`, `_poll_elapsed` (combat-preload hold timer) | music_manager.gd:65-67, 96-123 | No |
| Music.preload_hold = SCORES, memory_budget = 256 MB (set on the director at boot) | music_manager.gd:87-90; music_director.gd:78, 81 | No |
| Director: current `area`, `positions` (resume points), preloaded slot | music_director.gd:106, 112, 280-281 | No |

Nothing about music is saved. On load it is re-derived from state (music_manager.gd:168-171).

## Derived / cached state
- **The wanted music.** It is never stored. It is always recomputed from `WorldManager.current_area()`, `Conversations.current.presentation` and `CombatManager.a_watched_fight_is_running()` (music_manager.gd:197-221). The name is `"<area id>.<moment>"`, built in one place, `music_area()` (149-150). AreaValidator reuses it (area_validator.gd:102-103).
- **The next-likely preload.**
  - Exploration preloads combat; combat preloads negotiation; negotiation preloads combat (music_manager.gd:227-237).
  - The preload runs only after the transition lands and PRELOAD_DELAY (3 s) passes (245-258).
- **Combat ensemble hold.**
  - Trigger: a hostile within `max_sight_range` of a party member in the focused world, polled every 0.5 s (music_manager.gd:104-144).
  - On trigger: the full ENSEMBLE is loaded.
  - Release: 10 s after no hostile is within 1.25× range (56-63, 118-123).

## Public surface
- **Calls in**
  - `play_main_menu()` (music_manager.gd:155), called from main_menu.gd:58.
  - `music_area()` (149), called from AreaValidator and tests.
  - `a_hostile_is_in_range()` (129), called from tests/detection/test_combat_music_range.gd.
  - `SfxCue.play(context, pos)` (sfx_cue.gd:19), called from unit_sfx.gd:196, cinematic_stage.gd:635 and surface_manager.gd:81.
- **Signals out**
  - `requested(music)` (music_manager.gd:37, 246). Listened to by tests (test_a_split_party_survives_a_save.gd:96-110; conversation_driver.gd:1184-1195).
- **Signals in**
  - Each of these calls `_reconcile` (music_manager.gd:76-86):
    - CombatManager.combat_started (urgent only if the fight is on screen, 177-190)
    - CombatManager.combat_ended
    - Conversations.began and ended
    - WorldManager.world_focused
  - SaveManager.load_started and load_finished set and clear `_loading`.

## Depends on
- Music director API:
  - go_to (music_director.gd:298)
  - preload_area (220)
  - release_preload (260)
  - preloaded (280)
  - is_busy (163)
  - table and area (110-112)
- WorldManager.current_area and context (music_manager.gd:110, 130, 184, 200; world_manager.gd:920, 936)
- GameMode.current_mode (music_manager.gd:204)
- Conversations.current (216)
- CombatManager.a_watched_fight_is_running (219; combat_manager.gd:437)
- UnitQuery.living_units (133)
- The transitions table, music/transitions.json, through `Music.table.has_area` (114, 247, 254).

## Assumptions and invariants
- **Only a fight in the world on SCREEN is scored.** This is the "one focused world" rule, stated deliberately and implemented correctly. `a_watched_fight_is_running` is world-scoped, and combat_started is urgent only when it is on screen (music_manager.gd:174-190, 211-221). Not stale.
- **Signal order cannot matter.** The state is re-derived on every signal, and asking for the playing area again is a no-op in the director (music_manager.gd:193-196; music_director.gd:306-307).
- **No requests during a load.** `_reconcile` and `_hold_combat_if_near` both return while `_loading` is set (music_manager.gd:108, 198). The coroutine in `_go()` does *not* check `_loading` (issue 1).
- **An area missing from the table keeps the previous music, with one warning** (music_manager.gd:247-251; area_validator.gd:97-105).
- **SFX never blocks.** The layer delay is an internal await (sfx_layer.gd:24-29).
- **The main_root.gd header says the area's music starts from MusicManager's `world_loaded` handler** (main_root.gd:17-20). That is STALE. MusicManager listens to `world_focused` (music_manager.gd:84).

## Lifecycle
- **Boot.** `_ready` wires the signals and sets the director's hold and budget (music_manager.gd:75-93). The title music is not preloaded (91-93).
- **Title.** MainMenu → play_main_menu → `_reconcile`. With no area and Mode MAIN_MENU, the target is `"main_menu"` (music_manager.gd:200-206). Character creation keeps whatever is playing (202-203).
- **New game and travel.** world_focused → `_reconcile` → `<area>.exploration`, with a combat preload after 3 s.
- **Load.** load_started suppresses every intermediate world's focus (music_manager.gd:159-166). load_finished reconciles once for the final state (168-171).
- **Combat.** Combat starts and ends with a reconcile. The combat ensemble may already be held from proximity (104-123).
- **Dialogue.** Only `presentation == &"negotiation"` changes the moment (music_manager.gd:216-218). Ordinary dialogue leaves the music alone.
- **Cutscene.** MusicManager has no cutscene hook. Cutscene SFX go through SfxCue (cinematic_stage.gd:632-635).
- **Save.** Nothing is saved.

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | The fire-and-forget preload in `_go()` survives a load into the same area id. The coroutine sleeps PRELOAD_DELAY, then checks only `Music.area == music and not Music.is_busy()`, not `_loading`. A save loaded within 3 s of a transition into the same area preloads mid-load. | music_manager.gd:252-258 (no `_loading` check) vs 108, 198 | CONFIRMED |
| 2 | Unit SFX are parented to `WorldManager.spawn_parent()`, which is the *focused* world, not the unit's own world. A fight running off-screen plays its impact and status sounds as 3D players in the on-screen world, at the off-screen unit's coordinates. surface_manager.gd:61-81 does the same. | unit_sfx.gd:193-196; world_manager.gd:962-963 | NEW |
| 3 | SfxLayer awaits `context.get_tree()` for its delay, then calls `context.add_child`. If the context (a world) is freed during the delay, for example by travel, the spawn hits a freed node. | sfx_layer.gd:25-36 | NEW (minor) |
| 4 | The debug music panel calls `Music.go_to` and `Music.silence` directly, bypassing MusicManager. The next reconcile silently overrides it. This is a second writer of the director, debug only. | debug_music_panel.gd:30, 65 | NEW (minor) |
| 5 | The main_root.gd header names the wrong signal (`world_loaded`) as the music trigger. | main_root.gd:17-20; music_manager.gd:84 | NEW (doc) |

## Tests
- tests/detection/test_combat_music_range.gd (range predicate)
- tests/music/test_music_outlives_a_stall.gd (director under a game-thread stall)
- tests/world/test_a_split_party_survives_a_save.gd:96-110 (a load asks for exactly one piece)
- tests/conversation/conversation_driver.gd:1184-1195 (negotiation music requested)

Gaps:
- No test covers the preload-after-load race (issue 1).
- No test covers SFX world scoping (issue 2).
- Nothing exercises the hold or release timer (RELEASE_AFTER).
