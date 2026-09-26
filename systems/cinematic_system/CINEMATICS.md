# Making cutscenes

This guide is for building cutscenes in the Godot editor. You do not need to read any code to follow it.

Contents:

1. [What a cutscene is](#what-a-cutscene-is)
2. [Try the demo first](#try-the-demo-first)
3. [Walkthrough: your first cutscene in 10 minutes](#walkthrough-your-first-cutscene-in-10-minutes)
4. [Beats reference](#beats-reference)
5. [Shots and the camera](#shots-and-the-camera)
6. [Roles and the cast](#roles-and-the-cast)
7. [Marks](#marks)
8. [Playing a cutscene in the game](#playing-a-cutscene-in-the-game)
9. [What the player can do: skip and continue](#what-the-player-can-do-skip-and-continue)
10. [Configuration warnings](#configuration-warnings)
11. [Gotchas](#gotchas)

---

## What a cutscene is

A cutscene is **one `.tscn` file**. Its root node is a **CinematicStage**. Cutscenes live in `res://cinematics/`. No other file goes with it.

A stage finds its parts by child **name**, so these names must be exact:

| Child | Node type | What it holds |
|---|---|---|
| `Timeline` | AnimationPlayer | The performance. The animation named `scene` is the one that plays by default. |
| `Roles` | Node3D | One **StageRole** per person in the scene (`leader`, `stranger`, ...). |
| `Shots` | Node3D | One **FramingRig** per camera shot (`wide`, `close`, ...). |
| `Marks` | Node3D | Optional Marker3D spots that belong to this scene (`MeetSpot`, ...). |
| `Beats` | Node | The things that **happen**: a line, a walk, a spawn, a sound. |

How the parts work together:

- **Shots are keyed properties.** The stage has a `shot` property. Keying it on the timeline is a **camera cut**. Keying a rig's own numbers (distance, angle) is a **camera move**.
- **Beats are fired by Call Method keys.** Each beat has its own Call Method track on the timeline with a key calling `fire()`. The beat's fire time is wherever that key sits, so you re-time a beat by dragging its key.
- **Roles are names, not people.** The stage says "leader" and "stranger". Who that actually is gets decided when the game plays the scene.

Existing cutscenes to look at:

| File | What it shows |
|---|---|
| `cinematics/demo_conversation.tscn` | The reference scene. It uses every kind of cut and nearly every beat. |
| `cinematics/fusion.tscn` | The demon fusion. Parents are placed, removed, and the result is spawned. |
| `cinematics/test_arena_arrival.tscn` | A camera-only establishing shot on the leader. |

---

## Try the demo first

The demo shows everything this guide describes in about 7 seconds.

1. Run the game (a debug build, which is what F5 in the editor gives you).
2. Load any area. Stand somewhere with open ground ahead of you and to your right. The stranger enters about 7 m ahead and 3.5 m to the right.
3. Press **K**.

What you should see:

1. Letterbox bars slide in and the HUD hides.
2. A townsperson appears and walks up to you while the wide shot pushes in.
3. You both turn to face each other.
4. The camera cuts between close-ups for three lines. Each line waits for you: press **Space**, **Enter** or **left click** to continue.
5. A hit flash and a chime play on the stranger.
6. The stranger walks away and disappears.
7. The bars slide out and the HUD returns.

Press **Esc** at any point to skip. The stranger is still gone at the end, because skipping jumps to the end state.

**J** plays the fusion cutscene the same way, with two test demons in front of you. After fusion the camera deliberately stays on the result.

Open `cinematics/demo_conversation.tscn` in the editor alongside to see how each moment is built.

---

## Walkthrough: your first cutscene in 10 minutes

You will make a scene where the leader is shown wide, the camera pushes in, a stranger appears and walks over, the camera cuts to a close-up, and the stranger says one line.

### 1. Create the skeleton

1. In the FileSystem dock, open `res://tools/new_cinematic.gd`. It opens in the Script editor.
2. In the Script editor menu choose **File > Run** (Ctrl+Shift+X).
3. A new scene opens: `res://cinematics/new_cinematic.tscn`. If that name is taken you get `new_cinematic_2.tscn` and so on.
4. Rename the file in the FileSystem dock (right-click > **Rename...**). Rename the root node in the Scene dock too.

You get:

- `Roles/leader`, shown as a pale capsule in the viewport
- `Shots/wide`, a wide shot of the leader
- empty `Marks` and `Beats`
- a `Timeline` with an empty 3-second `scene` animation

The capsules are **stand-ins**. They exist only in the editor and are never saved.

### 2. Open the timeline and pin it

1. Select `Timeline` in the Scene dock.
2. The **Animation** panel opens at the bottom. In its animation dropdown, choose `scene`.
3. Click the **pin** icon at the right end of the Animation panel's toolbar. The panel now stays open while you select other nodes. You need this so the key icons appear in the Inspector.

Tip: the length box (clock icon, right side of the panel) sets the animation length. Make it 6 seconds for this walkthrough.

### 3. Add a second shot

1. Right-click `Shots` > **Add Child Node...** Search for `FramingRig` and add it.
2. Rename it `stranger_close`.
3. In the Inspector:
   - `subject_role`: `stranger` (you create this role in step 5; you can type the name now)
   - `distance`: `1.8`
   - `azimuth_degrees`: `25`
   - `elevation_degrees`: `4`
   - `fov_degrees`: `40`

A new rig starts with `subject_role = speaker`. Always change it to one of your roles.

### 4. Key the shots: cuts

1. Put the timeline cursor at **0.0**.
2. Select the root stage node. In the Inspector, set `shot` to `wide` from the dropdown.
3. Click the **key icon** next to `shot`. A dialog asks to create the track. Leave **Create RESET Track(s)** checked and confirm.
4. On the new `.:shot` track in the Animation panel, check the **update mode** (the icon near the right end of the track row). It must be **Discrete**. Discrete means "jump", which is what a cut is.
5. Move the cursor to **3.5**. Set `shot` to `stranger_close` and click the key icon again.

You now have a cut from the wide shot to the close-up at 3.5 s.

### 5. Add the stranger's role and marks

1. Right-click `Roles` > **Add Child Node...** > `StageRole`. Rename it `stranger`. The node name is the role name.
2. Right-click `Marks` > **Add Child Node...** > `Marker3D`. Rename it `Entry`. Move it a few metres from the leader in the viewport.
3. Add another Marker3D under `Marks` named `Meet`, about 1.8 m in front of the leader. In the stage's own space, **-Z** is "ahead".

### 6. Key a camera move: push in

1. Move the cursor to **0.3**. Select `Shots/wide`. Key `distance` at its current value (6).
2. Move the cursor to **3.0**. Set `distance` to `4.5` and key it again.
3. On the `Shots/wide:distance` track, check that the update mode is **Continuous**. Open the **interpolation** dropdown (next to update mode) and choose **Linear** or **Cubic**. Cubic eases in and out.
4. To ease a single segment, click a key and edit its **Easing** value in the Inspector.

Any rig number can be keyed this way. See [Camera moves](#camera-moves) for what each one does.

### 7. Add beats

**Spawn the stranger:**

1. Right-click `Beats` > **Add Child Node...** > `SpawnBeat`. Rename it `SpawnStranger`.
2. Inspector:
   - `role`: `stranger` (dropdown)
   - `definition`: drag in a UnitDefinition, for example `res://data/units/npcs/townsperson.tres`
   - `at`: `Entry`

The beat shows a yellow warning triangle. That is expected: nothing fires it yet.

**Fire it with a Call Method key:**

1. In the Animation panel click **+ Add Track** > **Call Method Track**. Pick `Beats/SpawnStranger` in the node picker.
2. Move the cursor to **0.5**. Right-click on the new track at the cursor > **Insert Key...**
3. Choose **fire** from the method list. It takes no arguments.

The warning clears.

**Add the rest the same way.** Each beat gets its **own** Call Method track.

| Time | Beat node | Settings |
|---|---|---|
| 0.8 | `WalkToBeat` "Approach" | role `stranger`, mark `Meet`, duration `2.5` |
| 3.4 | `FaceBeat` "LeaderTurns" | role `leader`, target `stranger` |
| 3.4 | `FaceBeat` "StrangerTurns" | role `stranger`, target `leader` |
| 3.5 | `LineBeat` "Hello" | role `stranger`, text "Nice weather.", wait_for_advance on |

### 8. Preview by scrubbing

1. Drag the timeline cursor. The stand-ins show what happens:
   - the stranger's capsule is hidden before 0.5 s and appears on `Entry` after it
   - it slides to `Meet` from 0.8 s
   - it turns at 3.4 s
   - the line floats over its head from 3.5 s
2. Scrub backwards and everything undoes. The preview depends only on the cursor time.

### 9. Look through the camera

1. Select the root stage node.
2. In the Inspector, click **Look through preview camera**. This selects a hidden preview camera, which is not listed in the Scene dock.
3. In the 3D viewport's top-left corner, tick the **Preview** checkbox.
4. Scrub again. The viewport now shows the live shot: the wide push-in, then the cut to the close-up.
5. Untick **Preview** to get the normal editor view back.

The preview camera follows whichever shot `shot` names at the cursor time.

### 10. Save and play it

1. Save the scene (Ctrl+S).
2. Hook it up by one of the ways in [Playing a cutscene in the game](#playing-a-cutscene-in-the-game). The quickest is an area's **Entry Scene**.

A stage mark like `Entry` is placed relative to the stage. The stage itself sits on its `anchor_mark`, or at the world origin if that is empty. See [Marks](#marks) before playing a scene that uses stage marks.

---

## Beats reference

Every beat lives under `Beats/`. Every beat needs its own Call Method track calling `fire()`.

Each beat has two behaviours:

- **Fire** is what happens when the timeline reaches its key.
- **Skip** is what happens when the player skips before the key. Skip applies only the **end state** (who exists, where they stand, which way they face), with no visuals and no sound.

"Role or mark" fields accept a role name, a stage mark under `Marks/`, or a world mark listed in the stage's `world_marks`. They offer a dropdown, and you can still type a name.

| Beat | Fields | Fire | Skip | Editor preview |
|---|---|---|---|---|
| **LineBeat** | `role` (empty = narration)<br>`speaker_name` (overrides the unit's name)<br>`text`<br>`wait_for_advance` (default on)<br>`auto_seconds` | Shows the line in the subtitle band. If waiting, holds the timeline until the player continues. | Nothing | Text floats over the speaker's stand-in |
| **WaitBeat** | none | Holds the timeline until the player continues. Only the "Continue" prompt shows. | Nothing | Nothing |
| **PlaceBeat** | `role`, `mark` (role or mark) | Puts the actor on the mark instantly, position **and** rotation. | Same as fire | Stand-in jumps to the mark |
| **FaceBeat** | `role`, `target` (role or mark) | Turns the actor to face the target instantly. | Same as fire | Stand-in turns |
| **WalkToBeat** | `role`, `mark` (role or mark)<br>`speed` (m/s, 0 = unit's own)<br>`duration` (seconds, overrides speed) | Turns toward the mark, plays the walk clip, moves in a **straight line**, and stops exactly on the mark in idle. | Actor lands on the mark, facing the way it walked | Stand-in slides along the line (4 m/s if speed is 0) |
| **SpawnBeat** | `role`, `definition`<br>`prop_key` (wins when set)<br>`at` (optional) | Creates the unit, gives it the role, and stands it on `at`. | Same as fire | Hidden before the key, on `at` after |
| **DespawnBeat** | `role` | Removes the unit from the world (frees it). | Same as fire | Hidden after the key |
| **ClipBeat** | `role`, `animation_name` (typed)<br>`claims` (default on) | Plays the named clip on the actor's model. With `claims`, gameplay stops animating it until the scene ends. | Nothing | Nothing |
| **EffectBeat** | `vfx` (a VfxEffect)<br>`from`, `to` (`to` empty = at `from`) | Plays the effect. On a role it plays at the chest. | Nothing | Nothing |
| **SoundBeat** | `cue` (an SfxCue), `at` | Plays the sound at the role's chest or at the mark. | Nothing | Nothing |

### LineBeat timing

| wait_for_advance | auto_seconds | Result |
|---|---|---|
| on | 0 | Holds until the player continues. **The default.** |
| on | N | Holds, but continues by itself after N seconds. |
| off | 0 | Does not hold. The line stays up until the next line or the end of the scene. |
| off | N | Does not hold. The line is taken down after N seconds. |

### Walks run in real time

A walk keeps moving while a line holds the timeline. That lets someone talk while another person crosses the room. If a walk is still going when the timeline ends, the scene waits for it to arrive.

### Sounds and visuals that belong to the stage

For a sound or mesh that is part of the stage itself, use a normal AnimationPlayer track on a child node, such as an Audio track on an AudioStreamPlayer3D or a visibility track. Those scrub in the editor. SoundBeat and EffectBeat are for things that happen **at a unit or a world mark**.

---

## Shots and the camera

A **FramingRig** under `Shots/` is one shot. It has no camera of its own. It describes where the one game camera should be, **relative to a person or a mark**. The same scene therefore frames correctly wherever it plays and whoever is cast.

### Rig fields

| Field | Meaning |
|---|---|
| `subject_role` | Whose orbit the camera sits on. Measured from their **head**, using the way they face. |
| `subject_mark` | Orbit a mark instead of a person. Wins over `subject_role` when set. Use it to open on an object such as a door or altar. |
| `distance` | Metres from the subject. |
| `azimuth_degrees` | Angle around the subject, from the direction they face. **0** is straight in front of their face and **180** is behind them. Positive values swing toward the subject's left side. |
| `elevation_degrees` | Angle above the horizontal. Negative looks up from below. |
| `fov_degrees` | Lens field of view. Smaller is a tighter, longer lens. |
| `look_role` | Look at someone else instead of the subject, for an over-the-shoulder shot. |
| `look_mark` | Look at a mark instead. Wins over `look_role`. |
| `look_offset` | Shift the aim point without moving the camera, in world axes (x, y, z). This is the pan and tilt control. |

Empty look fields mean "look at the subject", which is what most shots want.

### Cuts

A cut is a key on the stage's `shot` property, on a track whose update mode is **Discrete**. The shot named at the cursor time drives the camera. If `shot` is empty or names a missing rig, the first rig under `Shots/` is used.

### Camera moves

A move is keys on **one rig's** numbers, with the track's update mode set to **Continuous** and interpolation set to **Linear** or **Cubic**.

| Move | What you key |
|---|---|
| Push-in / pull-out (dolly) | `distance` |
| Arc / orbit | `azimuth_degrees`. It sweeps around the subject, not through them. |
| Crane / jib | `elevation_degrees` |
| Zoom | `fov_degrees` |
| Dolly zoom | `distance` and `fov_degrees` together, in opposite directions |
| Pan / tilt | `look_offset` |

Name fields such as `subject_role` should never be interpolated: key them on a Discrete track. To move from one person to another, **cut** to a second rig. Don't animate one rig from one person to the other.

### When the scene ends

The camera stays on the last shot when the scene finishes. Whoever started the scene decides when to hand the camera back. See [Releasing the camera](#releasing-the-camera).

---

## Roles and the cast

A **StageRole** under `Roles/` is a placeholder for one person. The node name is the role name. You can set `role` to use a different name, but leaving it empty and naming the node is simpler.

The stage never moves the real unit into the cutscene scene. The unit stays in its world. The role marker and the unit are kept in step instead.

### drives_actor

| drives_actor | Who is in charge | Use it when |
|---|---|---|
| **off** (default) | The **unit**. When the scene starts, the marker jumps to where the unit already is. | The person is already standing somewhere sensible. The player's leader is the usual case. |
| **on** | The **marker**. Every frame the unit is put where the marker is. You can key the marker's transform on the timeline. | You want to animate a body's position directly with keyed transforms. |

Beats (Place, Walk, Face, Spawn) work with either setting.

### The cast: who plays each role

The cast is decided by whoever starts the scene. A role can be filled in two ways:

| Kind | Meaning | Examples |
|---|---|---|
| **Tracked** | The game is asked "who is this?" each time. If that unit dies or changes, the answer changes. | The party leader, the current speaker |
| **Held** | The scene owns the unit for its whole length. | Fusion's parent demons, and anyone a SpawnBeat creates |

A SpawnBeat always creates a **held** role. A DespawnBeat frees whoever plays the role, held or tracked.

What each built-in trigger provides:

| Trigger | Roles filled |
|---|---|
| Area entry scene | `leader` (tracked) |
| Area combat intro scene | `leader`, and `enemy` (the first non-player unit in the turn order) |
| Dialogue binding | `speaker` (the current speaker) |
| Fusion | `parent_a`, `parent_b` (held); prop `result` for the spawned demon |
| K debug demo | `leader` |

A role the cast does not fill resolves to nobody. Beats on that role do nothing and print a warning in the Output panel.

---

## Marks

A mark is a named spot with a position and a facing. **-Z is forward** (the opposite of the blue gizmo arrow). PlaceBeat copies the mark's rotation, so a mark's facing matters.

| | Stage marks | World marks |
|---|---|---|
| Where | Children of the stage's `Marks/` node | Any Node3D in an **area** scene that is in the group `scene_marks` |
| Belongs to | This cutscene. Moves with the stage. | The area. Shared by every cutscene played there. |
| Editor preview | Yes | No. The stage cannot see the area. |
| How the stage knows the name | Automatically | List it in the stage's `world_marks` so dropdowns offer it and typos get flagged |

To make a world mark:

1. Open the area scene and add a Marker3D where you want it.
2. With it selected, open the **Node** dock > **Groups** tab, type `scene_marks` and click **Add**.

If a stage mark and a world mark share a name, the **stage mark wins**.

### anchor_mark: where the stage sits

The stage's `anchor_mark` names a **world** mark. When the scene starts, the whole stage is moved onto it. Every stage mark, and any role marker with drives_actor on, is carried along.

With `anchor_mark` empty, the stage sits at the **world origin**. That is fine for a scene framed only on people, like the arrival shot. It is wrong for a scene that uses stage marks. Those marks would sit near the centre of the map.

The demo shows the pattern: `anchor_mark = DemoConversation`, and the K key drops that world mark on the leader, facing where the leader faces.

---

## Playing a cutscene in the game

### From an area (no code)

Open the area's `.tscn` and select its root node (a GameArea). In the Inspector, under **Staged Moments**:

| Field | When it plays |
|---|---|
| **Entry Scene** | The **first** time the player arrives in the area, never again. A save flag `cinematic.entered.<area id>` remembers it. |
| **Combat Intro Scene** | **Every** time a fight starts in this area. Leave it empty for fights that should simply start. |

Drag the cutscene `.tscn` into the field. Both triggers hand the camera back to gameplay when the scene finishes.

`world/test_arena.tscn` uses Entry Scene with `test_arena_arrival.tscn`.

### From dialogue (no code)

Dialogue lines frame the speaker with a plain camera cut and need no cutscene. To stage a particular dialogue node with a cutscene:

1. Create the resource `res://cinematics/dialogue_bindings.tres` of type **SceneBinding**. It does not exist yet, and without it every node gets the default framing.
2. In its `scenes` dictionary, add an entry: the key is the dialogue node's **id** (a String), and the value is the cutscene `.tscn`.

The scene plays once, on the first line of that node, when the speaker changes. The conversation continues underneath while the scene holds the screen. The only role provided is `speaker`.

### From code

Programmers call the director. It always returns: `true` if the scene finished (a skip counts as finished), `false` if it was aborted or refused.

```gdscript
var cast := SceneCast.new()
cast.track_unit(&"leader", PartyManager.leader)     # tracked: one unit for the whole scene
cast.hold(&"parent_a", some_demon)                  # held: the scene owns it
var finished: bool = await CinematicDirector.play(
	load("res://cinematics/my_scene.tscn"),
	cast,
	{"result": result_definition},                  # props, read by a SpawnBeat's prop_key
	&"scene")                                        # which Timeline animation; "scene" is the default
if finished:
	CinematicDirector.camera().release()
```

- **props** carry runtime values into the scene. A SpawnBeat with `prop_key = "result"` spawns whatever UnitDefinition the caller passed under `"result"`. Authored props on the stage are kept, and the caller's value wins on the same key.
- **animation** lets one stage hold several variants of a moment (for example `scene` and `scene_short`).
- Only one cutscene plays at a time. A second `play()` while one is running returns `false` immediately.

### Releasing the camera

When `play()` returns `true`, the camera stays on the scene's last shot. This is on purpose: fusion keeps showing the new demon while it introduces itself.

- If gameplay should resume, the caller calls `CinematicDirector.camera().release()`. Area triggers already do this.
- On an abort (`false`), the director releases the camera itself.
- A dialogue ending also releases it.

---

## What the player can do: skip and continue

While a cutscene plays, letterbox bars slide in and the HUD hides. They come back when it ends.

| Action | Keys and buttons | Effect |
|---|---|---|
| **Continue** | Space, Enter, keypad Enter, left mouse, gamepad A (button 0) | Releases a hold from a LineBeat or WaitBeat. "Continue ▸" shows while a hold is waiting. A press when nothing is waiting is thrown away, not saved for later. |
| **Skip** | Esc, gamepad B (button 1), gamepad Start (button 6) | Jumps to the end. |

Both inputs are swallowed while a scene runs. Esc does not also open the pause menu, and a click does not also move a unit.

What a skip leaves behind:

- Anyone the scene would have spawned **is** spawned.
- Anyone it would have removed **is** gone.
- Everyone who would have been placed, turned or walked is on their final mark.
- The camera ends on the last shot, at the rig values of the last frame.
- Lines, clips, effects and sounds that had not happened yet are **not** played.

An **abort** is different. It happens when a save is loaded, the world unloads, or code calls `CinematicDirector.abort()`. If the world is staying, the end state is still applied. The camera is released and `play()` returns `false`.

While a cutscene runs, the player cannot travel to another area.

---

## Configuration warnings

A yellow triangle in the Scene dock means something is wrong. Hover over it to read the message.

### On the stage root

| Warning | Meaning | Fix |
|---|---|---|
| No 'Timeline' AnimationPlayer child | Nothing to play. | Add an AnimationPlayer named exactly `Timeline`. |
| No FramingRig under 'Shots' | The scene has no camera. | Add at least one FramingRig under `Shots`. |
| 'shot' names 'X', which is not a child of Shots | The `shot` value points at a missing rig. | Rename the rig back, or pick another shot. |
| a method track keys the stage itself | A Call Method key targets the stage root. | Delete that track. Use a beat under `Beats/` instead. |
| two method keys at N s on track 'X' | One track has two keys at the same time. The editor may merge them, and the order is not guaranteed. | Give each beat its own track. |

### On a StageRole

| Warning | Fix |
|---|---|
| This marker plays no role | Give the node a name, or set `role`. |

### On a beat

| Warning | Meaning | Fix |
|---|---|---|
| A beat belongs under a CinematicStage's 'Beats' node | It is in the wrong place. | Move it under `Beats/`. |
| Nothing on the Timeline fires this beat | No Call Method key calls `fire()` on it, in any animation. | Add its own Call Method track and a `fire` key. |
| 'field' is empty | A required field is blank. | Fill it in. |
| 'field' names role 'X', which has no StageRole under Roles/ | Typo, or the role was renamed. | Pick from the dropdown, or add the role. |
| 'field' names 'X': not a role, not under Marks/, and not in the stage's world_marks | Unknown place. | Add a stage mark, or add the world mark's name to `world_marks`. |
| 'X' is told to face itself | FaceBeat role and target are the same. | Choose another target. |
| Set 'definition', or 'prop_key' ... | SpawnBeat does not know what to spawn. | Pick a UnitDefinition, or set a prop key the caller will supply. |
| 'definition' has no unit_scene to spawn | That definition cannot be spawned. | Choose another definition, or fix the definition. |
| 'vfx' is empty / 'cue' is empty / 'text' is empty / 'animation_name' is empty | Nothing to play or show. | Fill it in. |

### At runtime (Output panel)

These appear while the game runs, not in the editor:

| Message contains | Meaning |
|---|---|
| `nobody is playing 'X'` / `does not resolve` | The cast has no unit for that role, or the mark was not found. The beat did nothing. |
| `SceneCast: no mark named 'X' in group 'scene_marks'` | The area is missing a world mark the scene uses. |
| `has no animation 'scene'` | The Timeline lacks the animation that was asked for. The scene returns immediately. |
| `play refused: ... is already running` | Another cutscene was on screen. |
| `no UnitDefinition in props['X']` | A SpawnBeat's `prop_key` was not supplied by the caller. |

---

## Gotchas

**Never put comments in a `.tscn` or `.tres`.** A `#` or `##` line in a scene or resource file silently breaks loading, and the error shows up somewhere unrelated. Edit scenes in the editor.

**Close the editor before editing a scene file outside it.** If anything (a script, a merge, another tool) changes a `.tscn` while it is open, the editor can overwrite it with its old copy without asking. Close to the **Project List** (Project > Quit to Project List), make the change, then reopen.

**One Call Method track per beat.** Two keys at the same time on one track can merge or fire in the wrong order. The stage warns about it.

**Cuts need Discrete, moves need Continuous.** A `shot` track left on Continuous does not cut cleanly. Check the update-mode icon on each track.

**Keep "Create RESET Track(s)" ticked.** Scrubbing writes rig values into the scene, and the RESET animation puts them back on save. Without it, saving after a scrub can save a mid-move camera value. The `new_cinematic` tool does not create a RESET animation, but the first key you insert with that box ticked does.

**Rename the default `speaker` subject.** A FramingRig added by hand targets `speaker`, which only exists in dialogue-bound scenes.

**Stage marks need an anchor.** Without `anchor_mark`, the stage sits at the world origin and so do its marks.

**Walks are straight lines.** WalkToBeat does not pathfind. It walks through walls, furniture and other units. Lay marks out with a clear line between them.

**DespawnBeat frees the unit.** Despawning a tracked role such as `leader` removes the actual party leader from the game. To get someone out of shot, walk them away instead.

**Lines wait by default.** A scene with three LineBeats needs three presses. Turn `wait_for_advance` off for lines spoken over action.

**Things that do not preview.** World marks, ClipBeat, EffectBeat and SoundBeat show nothing in the editor. Check those in game.

**The dialogue binding needs a speaker change.** A bound scene starts on the first line of its node only if that line's speaker is different from the previous line's.

**Some asset-pack effects are broken.** `vfx_hit_03`, `04`, `06`, `07` and `08` reference missing textures and error when loaded. `vfx_hit_05` works.

**The camera holds after the scene.** A caller that starts a scene from code must release the camera itself if play should resume.

**Timeline method mode is Immediate.** The Timeline's **Callback Mode > Method** is set to Immediate in every existing scene and by the `new_cinematic` tool. Leave it that way.
