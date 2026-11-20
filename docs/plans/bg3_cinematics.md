# Goal: BG3-level cinematics, as a showreel

Three scenes good enough to show someone. Each is built by an autonomous `/goal` run and ends with a stop for the user's verdict.

- Full research and reasoning: [BG3-Level Cinematics: Proposal and Spec Sheet](https://claude.ai/artifact/QHgtbRVjNUTW7d4pDP5aMZ). Its section 5 (spec sheet) holds the numbers this doc refers to as "5.x".
- Owner system: `systems/cinematic_system` (doc: `docs/systems/cinematics.md`). Dialogue milestones also touch `systems/dialogue_system` and `systems/unit_system/face_driver.gd`; each mechanic names its owner and updates that system's doc in the same commit.

## The showreel

| # | Showcase | Proves | Milestones | Run stops when |
|---|---|---|---|---|
| 1 | The duel: cornered townsperson, hero drops in, overhead miss, sidestep thrust, fall, aftermath (~9 s) | Impact, contact, phrasing, editing | M0, M1, M2 | M2 exit criteria met, before/after renders delivered |
| 2 | A staged conversation (goblin_quarry townsperson) | Eyes, lip sync, emotions, gestures, coverage, shot lighting | M3 to M7 | M7 exit criteria met, recording delivered |
| 3 | The camp raid group fight, redone | Foreground duel plus background pairs | M8 | M8 exit criteria met, recording delivered |

One `/goal` run per showcase. Between runs the user watches the result and either approves, asks for changes, or stops.

## Decisions (2026-11-20)

- **Stop points:** one per showcase.
- **Motion source:** free mocap (Mixamo, from 2026-11-20, after the user judged the Kimodo duel takes terrible) or Kimodo (kimodo.cpp), plus contact IK. No purchased mocap pack, no video capture of the user. The user picks the clips; a run does not swap in clips the user has not picked. If the picked clips plus IK cannot meet the contact spec, the run stops and says so.
- **Contact IK is allowed.** It closes a marked contact or pins a planted foot, nothing else. Posture and stance stay source-only: a bad pose is fixed by prompt or seed, never by correction.
- **Face work is on:** eyes, lip sync and emotions.
- **Autonomy:** during a goal run, code changes and commits of verified, scoped work need no plan report first. Never push. Report at each stop point.
- **Hardware:** AMD Radeon RX 5700 XT (checked 2026-11-20). No CUDA, so Audio2Face and CUDA-only models are out. Lip sync uses forced alignment of voice audio to phonemes, baked at import.
- **Defaults taken from the proposal's recommendations** (the user can override): tier budget 70 / 25 / 5% copper / silver / gold; scratch voice generated for unvoiced lines that need timing; no hair work (frame close-ups a little wide).

## Rules for every run

- **Branch:** work on `bg3-cinematics`, cut from `cinematics-fight` at the tag `pre-bg3-cinematics`. Never commit to `main`, never merge, never push.
- **Never commit:** `unit.tscn`, `placeholder_model.tscn`, `project.godot`, `MainRoot.tscn`, `tools/_probe/*`, `.import` files (BoneMap imports excepted), `groom.tres`, sfzplayer files, `assets/paired_animations.tres`, stray `.tres` files, `assets/characters/cc/**`, `recordings/`, unrelated untracked files. Stage files by name, never `git add -A`.
- **Never** `git checkout --`, `git stash` or `git reset`.
- **Godot:** one process owner at a time. Kill only Godot processes the run started.
- **No gameplay tests through the Godot MCP.** Verify with headless scripts, measured numbers and rendered frames (contact sheets).
- **Rendering:** `light_angular_distance` stays 0; shadow blur 1.5.
- **Tests last and minimal**, after the code works.
- **Downloads** (models, aligners): only from the original publisher, licence read and recorded in the take record before use; nothing bought, no EULA accepted, no account created. A download that needs any of those stops the run.
- **Evidence in the transcript.** The `/goal` evaluator only reads the conversation, so each exit criterion is shown by printing the measured number or the path of the rendered file.

## Milestones and exit criteria

### Showcase 1: the duel

**M0. Impact layer on the existing duel** (`cinematics/fight_test.tscn`, no new motion)
- `ContactEvent` records on `PairedClip.contacts` (5.1); one dispatcher fires trauma shake, reaction, `SoundBeat`/`EffectBeat` content and a cut hint.
- No hit-stop and no freeze (user, 2026-11-20: out of place in a cinematic). Contacts shake the camera, spark or bleed, and sound; nothing stops.
- Shake decays to 0 in 0.3 to 0.6 s; a miss or a grab does not shake.
- Spark on parry, blood on hit, impact sound on the contact frame or up to 2 frames early.
- Exit: before and after renders of the same take side by side, measured shake durations printed, committed.

**M1. Kimodo bake-off on one exchange** (overhead miss, sidestep, killing thrust)
- Re-prompt for wind-up and commitment (heavy wind-up at least 8 frames at 30 fps), spatial and timeline constraints, contact IK (eases in over 4 to 6 frames, out over 6 to 10, moves the effector at most 15 cm).
- Take scorer: foot skate, root jerk, penetration, constraint miss, time-to-contact error. Generate several seeds, keep the top three.
- Exit: contact within 3 cm after IK (1 cm in any shot closer than 2.5 m), planted feet travel at most 1 cm, scores printed. If no seed passes, stop the run and report.

**M2. The nine-second duel, re-planned**
- Beat sheet and shot list from the proposal's M2 table, written to `cinematics/` beside the stage.
- Phrasing: threat, a burst of three events in about 2.6 s, the fall, aftermath. No three consecutive contact gaps within 15% of each other.
- Camera within 25 degrees of the strike line on landing blows; music silent or ducked at least 0.5 s before the kill.
- The townsperson ends dead or wounded as scripted through `HurtBeat`; skip lands in the same end state.
- Exit: every 5.1 tolerance met and printed, contact sheet rendered (one frame per shot and per contact), full-length recording rendered, committed. **Stop for the user's verdict.**

### Showcase 2: the conversation

**M3. Eyes:** saccades (talk and listen statistics), vergence, lid follow, blinks on gaze shifts and phrase ends, wired to `DialogueGaze` targets; an eye light in the dialogue light rig. Exit: 30 s recording with a blink count of 10 to 15 and visible catch-lights.

**M4. Lip sync:** forced alignment to visemes per voiced line, phrase boundaries and energy peaks baked at import, keyed by `#line:` ID; `FaceDriver.talk()` uses the baked track when present. Exit: on ten voiced lines, mouth leads audio by 0 to 40 ms and never lags more than 40 ms; unvoiced lines still play.

**M5. Copper generator:** template inheritance, named camera rigs, the 5.2 rules and validators, seeded re-roll, overrides stored apart from generated output, tier counter. Exit: both `.dlg` files stage end to end with zero overrides and zero validator failures.

**M6. Gestures and idles:** 30+ gestures and 6+ idles through the take scorer, 5.3 placement, nods, breathing. Exit: no actor holds one idle more than 8 s, no gesture repeats within 5 lines.

**M7. Emotions and shot lights:** 12 emotions x 3 intensities with upper/lower split; light sets switched by the active shot. Exit: the conversation and the duel use per-shot light sets with no per-light keys; every tagged line shows its emotion on the contact sheet; recording rendered, committed. **Stop for the user's verdict.**

### Showcase 3: the group fight

**M8. Camp raid by recipe:** one or two foreground duels on M1-quality choreography; background pairs on a small set of offset, mirrored exchange loops. Exit: no more than three unique paired clips, no two background pairs in sync in any shot, recording rendered, committed. **Stop for the user's verdict.**

## Rolling back

Everything lives on `bg3-cinematics`. `main` and `cinematics-fight` are never touched by a run.

- **Throw it all away:** switch back to `cinematics-fight` and delete `bg3-cinematics`. The tag `pre-bg3-cinematics` marks where it started.
- **Undo one milestone:** `git revert` its commits on `bg3-cinematics`.
- **Changes outside this repo** (kimodo.cpp at `D:\i_motion`) are committed in that repo with their own messages and can be reverted there.
- The user's uncommitted work in the tree is never staged or committed by a run, so it survives any of the above.

## /goal conditions

Showcase 1:

> Showcase 1 of docs/plans/bg3_cinematics.md is done: M0, M1 and M2 each meet their exit criteria, with the measured numbers and rendered file paths printed in this conversation, all work committed on branch bg3-cinematics following that doc's rules, and a final report given to the user. Or: a stop condition in that doc was hit and reported. Or: stop after 150 turns.
