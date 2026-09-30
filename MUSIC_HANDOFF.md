# Music system handoff: sfzplayer into combat_test

Written 2026-09-23 by the sfpp_test session for whichever session works on
music in combat_test next. It covers what the plugin is, what the owner has
decided, what to build, and the rules that have cost real time to learn.

## 1. What is being installed

`addons/sfzplayer` is an SFZ music engine. Music is written as text scores
(`.score`), and sfizz plays them live through sampled instruments, so the game
ships notes instead of rendered WAVs. It was built and tested in
`C:/Godot Projects/sfpp_test`, where the full test suite lives.

| Piece | What it is |
|---|---|
| `addons/sfzplayer/bin/*.dll` | sfizz wrapped as a GDExtension (Windows x86_64 only). It is the editor build, and it also loads in an exported game; this was proven on 2026-09-20. |
| `SfzMusicDirector` (`runtime/music_director.gd`) | The public API. Enabling the plugin adds it as the autoload `Music`. |
| `scores/<id>.score` | The pieces. |
| `ensembles/<id>.json` | Mix only: part → instrument, gain, pan, voices, transpose. |
| `registry/<library>.json` | Instrument facts read from the SFZ files: controls, keyswitches, range, bend range, drum keys. |
| `music/transitions.json` | Areas (area → ensemble + score) and the rules for how one piece becomes another. |
| `scores/loudness.json` | Gain per score, written by `tools/loudness_fix.py`. |
| `samples/` | 22 GB of SFZ libraries. It has been copied into combat_test and is gitignored. **Never commit it.** Keep its `.gdignore`, or the editor will try to import every WAV. |

Read first: `addons/sfzplayer/README.md`, `addons/sfzplayer/COMPOSING.md`, and
in sfpp_test `docs/GOALS.md` (the spec), `docs/SYSTEM.md` and
`docs/REGISTRY.md`.

## 2. The owner's decisions

- **sfpp_test stays the plugin's development project and test bed.** Day-to-day
  plugin work will mostly happen in combat_test, because this is the game that
  uses it. Port
  plugin changes back to sfpp_test so its test suite keeps covering them. A
  change to `addons/sfzplayer` that has not been ported back is unfinished.
- **Map existing scores. Do not transcribe the old tracks.**

  | Old track | Where it is used | New area → score (ensemble) |
  |---|---|---|
  | `neon_pulse` | default combat | `low-end` (band) |
  | `negotiation` | default negotiation; the `cathedral_of_shadows` area | `decadence-rite` (decadence) |
  | `algon_headquarters` | default exploration | `sealed-ward` (tonewheel) |
  | `tokyo_smt4` | `test_area_2` | `decadence` (decadence) |
  | `long_time_way` | `overworld` | `long-time-way` (wayfarer) |
  | `level_up_groovy` | main menu | `level-up-groovy` (groovy) |

  `battle-sting` (band) is the sting sfpp_test plays going into battle. Use it
  only if the owner wants one; the old system had no stings.
- **Replace the old system; don't wrap it.** The director was designed so the
  game decides what plays and when, and the director and its transitions table
  decide how. `MusicManager`'s game rules stay: combat music only for a fight
  on screen, combat resumes after a negotiation, and the menu piece. Its old
  model goes.

## 3. What to build

1. **Install.** Copy `addons/sfzplayer` (with `bin/`), and copy `scores/`,
   `ensembles/`, `registry/`, `music/transitions.json` and
   `scores/loudness.json` from sfpp_test. Enable the plugin; that adds the
   `Music` autoload. Set `sfzplayer/audio/bus` to the existing `Music` bus so
   the game's volume slider still controls the music.
2. **Areas.** Rewrite `music/transitions.json` with areas keyed the way the
   game thinks: one per piece in the table above, or one per game area if
   several game areas share a piece. Changes into combat must be
   `"urgent": true`, because `max_wait` only caps urgent exits. A non-urgent
   `exit: "section"` waits for the end of the current section, which can be
   many seconds after the fight has started.
3. **Replace `systems/music_system/`.**
   - Delete: `music_track.gd`, `music_stem.gd`, `music_track_database.gd`,
	 `data/music/*.tres`, the stem players, and the fade and intro timers.
   - Change `area_definition.gd`'s `exploration_track`, `combat_track` and
	 `negotiation_track` to name director areas instead of `MusicTrack`
	 resources, and update the four `data/areas/*.tres` files.
   - `MusicManager` becomes a thin layer that turns the `WorldManager`,
	 `CombatManager` and `Conversations` signals into `Music.go_to()`
	 calls. The hardcoded fallback ids at `music_manager.gd:113-119` become
	 area names.
   - Rebuild the debug Music tab (`debug/debug_music_panel.gd`,
	 `ui/party_overview`) on `Music.state()`, `stats()`, `position()` and
	 `is_playing()`. Intro/loop/outro phases and `seek` have no meaning here;
	 don't fake them.
4. **Preload.** Loading an ensemble takes 0.3 - 0.7 s with the current sfizz
   patches (measured 2026-09-24, warm file cache: groovy 0.3 s, band 0.6 s,
   tonewheel 0.6 - 0.7 s), and reading and compiling the score adds 0.1 - 0.6 s.
   The old system started at once.
   On `world_loaded`, call `Music.preload_area(<that area's combat area>)` so a
   fight that starts suddenly has its music ready. Measure what a fight
   sounds like when it starts before the preload has finished; it should not
   be silent.
5. **Export.** In `export_presets.cfg`:
   - `include_filter="*.score,*.json,*.sfz"`. These are not Godot resources,
	 so without it the game dies with `ScoreParser: cannot open`.
   - `exclude_filter="res://samples/*"`, because sfizz reads samples from
	 disk, not from the .pck.
   - Ship `samples/` as a folder next to the exe. `settings.gd` finds it there
	 in an exported game.
   - Drop the 536 MB of WAVs in `assets/audio/` once nothing references them.
6. **Test it in the game.** Areas change on the bar/section the table says, a
   fight's music arrives within `max_wait`, negotiation returns to combat, the
   menu plays groovy, `late_frames` stays 0, and an export plays.

## 4. Rules learned the hard way

- **The owner is the only ear.** Measurements (peaks, LUFS, spectra) describe
  signals, not how it sounds. Every change to the sound goes to the owner as a
  before/after render: `addons/sfzplayer/tools/render.tscn` in sfpp_test (see its README), as MP3s they can play on a
  phone. Never report a quality rating from your own reading.
- **Licensing:** HamOrg (used by the groovy, combo and tonewheel ensembles)
  "may not be shipped inside a game". metal-gtx and sm-drums have sourcing and
  redistribution problems. That is fine for the owner's own builds and blocks
  a public release. The plugin ships a format, not instruments.
- **Do not change sfizz** or its patches (`native/` in sfpp_test) without the
  owner's word. The shared sample store (sfizz-shared-samples.patch) serves a
  sample as it was first read until every synth holding it is freed, so a
  sample edited on disk while its ensemble is loaded is not picked up; see
  `native/patches/README.md`.
- **Never recursively delete a folder that contains a samples junction.** It
  deletes the 22 GB it points at.
- **Naming a voice on a lane casts it.** It silently drops every other layer,
  so check the ensemble before the notes.
- **Release samples cut notes** in Standard Bass and metal-gtx. The
  `release_cuts` ensemble flag handles it; keep it on for those layers.
- **Check a library's own controls before adding an engine feature.** The
  missing bass bottom was an unmapped CC.
- **Loudness normalisation punishes dynamics:** a quiet section makes the
  climax more limited, not less.
- **A test harness can fake the defect it is looking for.** Check the
  harness before chasing a hitch.
- **Working style:**
  - Fix causes, not symptoms. No aliases or leftover shims.
  - Run only the tests a change touches, and the full suite once before a
	merge. Add no new tests unless asked.
  - Report when a multi-agent workflow finishes, and never chain into another
	without the owner's yes.
  - Show the list before deleting anything.

## 5. Known open items

- combo's pad peaks at 1.80 (above full scale) in `ensemble_test`. This
  predates the registry work. Check whether the limiter hides it, and listen.
- `render` test in sfpp_test: its hole detector cannot tell a 150 ms dropout.
  This is a known baseline failure, not a regression; the owner decides if it
  gets fixed.
- Windows x86_64 only. combat_test's navigation extension is too, so this
  costs nothing today.
- Pending owner question: should combo's guitar (metal-gtx) switch to marcato
  on accents? An A/B render was offered.

## 6. Tooling

- Godot 4.4.1: `D:/PortablePrograms/Godot_v4.4.1-stable_win64.exe/` is a
  **folder**. Use `Godot_v4.4.1-stable_win64_console.exe` inside it for
  scripted runs. `--headless` forces the Dummy audio driver; for a real audio
  test add `--audio-driver WASAPI`.
- Rebuilding the DLL: use the CMake bundled with VS Build Tools 2022 (3.31.6).
  The CMake on PATH (4.3.3) cannot configure sfizz's abseil.
- Tests (in sfpp_test):
  `GODOT=".../Godot_v4.4.1-stable_win64_console.exe" python tools/run_tests.py [names]`.
  The full suite takes about 8 minutes, with 32 of 33 passing (render is the
  known failure).
- Impact of an instrument change: `check.gd -- --impact <instrument>`.
