# Authoring a cutscene by hand

[CINEMATICS.md](CINEMATICS.md) is the reference: every field, every beat, every warning. This is the
other half: **how to work**. It walks you through building one short scene yourself, in the order a
director would, and explains what to look at and what to change at each step.

You will make a 10-second scene: a stranger walks up to the player, they square up, the stranger
says one line, and the camera covers it in four shots. No code.

Read [What a cutscene is](CINEMATICS.md#what-a-cutscene-is) first (two minutes). The rest of this page
assumes you know the five children of a stage: `Timeline`, `Roles`, `Shots`, `Marks`, `Beats`.

---

## The way to think about it

A cutscene here is three layers on one timeline, and you build them in this order:

1. **Blocking**: who stands where and moves where. Marks, Place, Walk, Face beats.
2. **Performance**: what the bodies do. Clip beats, paired actions, lines.
3. **Coverage**: where the camera is. Shots, cuts, camera moves.

Do the blocking first and get it right while scrubbing. Shots are cheap once the people are in
place; moving a person after the shots are built breaks every shot framed on them.

Plan on paper before you open the editor. Five lines is enough:

```
0.0  stranger enters from the right, walks to the player       wide, slow push
3.0  both turn to face each other                              over the stranger's shoulder
3.5  stranger: "You're the one they sent?"                     close on the stranger
6.0  the player doesn't answer; hold                           close on the player
8.0  stranger walks off                                        wide again
```

The duel's version is [cinematics/duel_m2_beats.md](../../cinematics/duel_m2_beats.md). Write one for
every scene: it is what you check the result against.

---

## 1. Set up the stage

1. Open `res://tools/new_cinematic.gd` and run it (**File > Run**, Ctrl+Shift+X). A new scene opens
   under `res://cinematics/`. Rename the file and the root node, e.g. `stranger_meets.tscn`.
2. Select `Timeline`, open the Animation panel, choose the `scene` animation and **pin** the panel
   (pin icon, right end of its toolbar). Set the length to **10** s.
3. Select the root. Set `preview_set` to the room the scene will play in if it has one (a scene of
   walls and floor). Without it you are framing against an empty void, which hides the two most common
   faults: a rock in front of a face and a wall behind the camera.

## 2. Cast it with bodies

Every role gets a **body** before anything else. Shots framed on a capsule are framed on nothing.

1. Select `Roles/leader`. Set `preview_unit` to `res://data/units/companions/player_character.tres`.
   The capsule becomes the player's body, standing in its idle.
2. Add a second `StageRole` under `Roles`, name it `stranger`, and set its `preview_unit` to
   `res://data/units/npcs/townsperson.tres`.

The bodies are editor only and show **undressed** (no clothes, hair, weapon or face), because the scripts
that dress a unit do not run in the editor. In game the role is whoever plays it. Pick a
`preview_unit` the same size as who will really play the part, or your framing will be off by a head.

## 3. Block it: marks

Marks are the spots on the floor. Lay them out from the top view (keypad 7) so you see distances.

1. Under `Marks`, add Marker3Ds: `Entry` about 6 m to the leader's right, `Meet` about 1.6 m in front
   of the leader, `Exit` 8 m off to the left.
2. The stage's **-Z is "ahead"** of the leader. A mark's own rotation matters only to PlaceBeat (it
   sets facing too).
3. Draw a straight line between each pair of marks in your head: walks do not pathfind. If the line
   crosses a rock in the `preview_set`, add a bend with a `Paths/` Path3D and use a WalkPathBeat
   instead.

Spacing tip: two people talking stand 1.2 to 1.8 m apart. Closer reads as threat, further as distrust.

## 4. Block it: beats

Each beat is a node under `Beats` plus its **own** Call Method track on the Timeline calling
`fire()`. The time of that key is when the beat happens. You re-time a beat by dragging its key.

Add these, keying each one (Add Track > Call Method Track > pick the beat > right-click at the time
> Insert Key > `fire`):

| Key at | Beat | Settings |
|---|---|---|
| 0.0 | SpawnBeat `SpawnStranger` | role `stranger`, definition `townsperson.tres`, at `Entry` |
| 0.2 | WalkToBeat `Approach` | role `stranger`, mark `Meet`, duration `2.6` |
| 3.0 | FaceBeat `LeaderTurns` | role `leader`, target `stranger` |
| 3.0 | FaceBeat `StrangerTurns` | role `stranger`, target `leader` |
| 8.0 | WalkToBeat `Leave` | role `stranger`, mark `Exit`, duration `2.0` |

Now **scrub**. The stranger appears on `Entry`, walks to `Meet` in the walk clip, stands in idle,
both turn at 3.0, and the stranger walks off at 8.0. Everything you see in the editor comes from the
cursor time alone, so scrubbing backwards undoes it.

What to look for while scrubbing:

- **Feet sliding.** A walk that is too short for its distance slides. Lengthen `duration`, or leave it
  0 and let the unit's own speed decide.
- **Bodies passing through each other or the set.** Move the marks.
- **Dead air.** Nothing happening for more than a second or two with no line and no camera move reads
  as a stall. Tighten the keys.

## 5. Performance: lines and clips

Add a LineBeat `Hello` at **3.5**: role `stranger`, text "You're the one they sent?". Leave
`wait_for_advance` on for a line the player should read; turn it off for a bark spoken over action.
A held line **stops the timeline**, so anything keyed after it waits too.

For a gesture, add a ClipBeat at the same time: role `stranger`, `animation_name` a clip the unit's
library has (the duel uses names like `Duel/Victim_Cornered`). The body plays it as you scrub. Only
the body layer previews; upper-body layers and blends show in game only.

For two bodies doing one thing together (a blow, a grab, a kill) use a PairedActionBeat. Those need a
PairedClip asset made for that pair; see
[Making a fight exchange](CINEMATICS.md#making-a-fight-exchange-from-kimodo-takes) and the duel.

## 6. Coverage: shots, framed by eye

This is where hand-authoring pays off. You do not type camera numbers; you fly the viewport.

**Your first shot (the wide):**

1. Make sure the viewport's **Preview** checkbox (top left of the 3D viewport) is **off**.
2. Scrub to about 1.0 s, so the stranger is mid-walk.
3. Fly the viewport (hold right mouse, WASD, mouse wheel for speed) to a spot behind and to the
   left of the leader, about 1.6 m up, looking at both of them.
4. Select the root and click **New shot from view** in the Inspector.

You get `Shots/S<n>_view`, standing on `Marks/cam_S<n>_view`, looking at `Marks/S<n>_view_look`
(placed on the head of whoever is nearest the middle of your view). Its field of view is the
viewport's, and its `framed_roles` lists everyone who was in view. It becomes the live shot.
Rename the rig to something you will recognise (`wide`), and the two marks to match (`cam_wide`,
`wide_look`), and fix the rig's `subject_mark` and `look_mark` to the new names.

**Look through it:** click **Look through preview camera**, tick **Preview**, and scrub. That is what
the player sees. Untick Preview before you fly the viewport again.

**The other three shots.** Scrub to the moment each shot covers, fly, click **New shot from view**:

| Scrub to | Shot | Where to put the view |
|---|---|---|
| 3.2 | `over_stranger` | Behind the stranger's shoulder, 0.5 m off it, looking at the leader's face. Their shoulder fills a third of the frame. |
| 3.6 | `stranger_close` | In front of the stranger, on the leader's side, head height, close. A narrower lens (set `fov_degrees` to 30 to 35 after) flattens the face nicely. |
| 6.0 | `leader_close` | The mirror of the last one, in front of the leader, on the stranger's side. |

**Fixing a shot.** Make it live (set `shot` on the root, or scrub to where it is cut to), Preview off,
fly the view, click **Update live shot from view**. Its marks move to the new view. Ctrl+Z undoes it
in one step.

### The one rule: stay on one side of the line

Draw a line through the stranger and the leader. **Every camera stays on the same side of it.** Cross
it and the two swap left and right on screen between cuts, and the audience loses who is where. If
the stranger is on the left in the wide, the stranger is on the left in every shot. Over-the-shoulder
and close-ups sit near the line on your side of it, never past it.

## 7. Cuts and moves on the Timeline

**Cuts.** Select the root, put the cursor at a time, set `shot`, click its key icon. The `.:shot`
track must be **Discrete** (it is a jump). Key:

| Time | shot |
|---|---|
| 0.0 | `wide` |
| 3.0 | `over_stranger` |
| 3.5 | `stranger_close` |
| 6.0 | `leader_close` |
| 7.8 | `wide` |

Timing that reads well:

- **Cut on the action, a beat early.** Cutting to the close-up on 3.5, the same frame the line starts,
  is right. A cut that arrives after the thing it shows feels late.
- **Hold a shot at least 0.5 s.** Shorter is a flash nobody reads.
- **Cut away from a face after the line, not during it**, unless the reaction is the point.

**A camera move: the push-in on the wide.**

1. Scrub to 0.0. Select `Marks/cam_wide` and key its `position` (key icon). The track is
   `Marks/cam_wide:position`. Set it to **Continuous** and interpolation **Cubic**.
2. Scrub to 2.8. Fly the viewport a metre closer, make `wide` live, click **Update live shot from
   view**. Because the mark's position is keyed, this adds a key at 2.8 instead of moving the mark.
3. Scrub between 0 and 2.8 with Preview on: the camera eases in.

Any number on a rig can be keyed the same way: `fov_degrees` for a zoom, `focus_blur` for a rack
focus. See [Camera moves](CINEMATICS.md#camera-moves) for the full list. Do not key a rig from one
person to another; cut to a second rig instead.

## 8. Check it in game

The editor preview is close, but not the game. In game the bodies are dressed, layers and blends run,
sounds and effects fire, and the scene sits where its `anchor_mark` puts it.

1. Set the root's `anchor_mark` to a world mark in the area that will play it (without one the stage
   sits at the world origin, and so do your marks).
2. Hook it to the area: select the area's root, drag the `.tscn` into **Entry Scene** (under Staged
   Moments). It plays the first time you arrive.
3. Run, arrive, watch. Then watch again with **Esc** pressed halfway: a skip must leave everyone where
   the scene ends.

**The framing check** measures what each shot actually shows (heads cut, people off screen, faces
behind rocks, the line crossed). It runs from a walkthrough scene: `tools/duel_m2_demo.gd` is the one
to copy. It plays the scene, samples every frame, and prints each shot's numbers and problems in the
Output panel. For a quick scene, watching it in game is usually enough; for a fight, run the check.

## 9. Pitfalls, in the order you will hit them

| Symptom | Cause | Fix |
|---|---|---|
| New shot from view makes a shot of the old camera spot | Preview was on: the viewport shows the preview camera, its own camera did not move | Untick Preview, then click |
| The body is a capsule | No `preview_unit` on that role | Set one |
| Camera jumps oddly between keys | `shot` track left on Continuous | Set it to Discrete |
| A move freezes for seconds | A held line (`wait_for_advance`) under it stops the timeline | Move it off the line, or turn the hold off |
| Saving after scrubbing saved a mid-move camera | No RESET track | Keep "Create RESET Track(s)" ticked on your first key |
| The scene plays in the middle of the map | No `anchor_mark` | Set it |
| A walker goes through a wall | Walks are straight lines | Move the marks, or draw a path and use WalkPathBeat |
| Framing fine in the editor, off in game | Different-sized actor, or an older shot aimed at the capsule | Set a `preview_unit` the size of the real actor; re-frame |
| Low shots full of grass in game | Grass has no collision and no editor preview | Keep cameras about 0.9 m up or more |

## Where to look next

- Every beat's fields and behaviour: [Beats reference](CINEMATICS.md#beats-reference)
- Every rig field: [Rig fields](CINEMATICS.md#rig-fields)
- Riding a drawn camera line: [CameraPathRig](CINEMATICS.md#moving-shots-on-a-line-camerapathrig)
- Who plays each role: [The cast](CINEMATICS.md#the-cast-who-plays-each-role)
- A full fight to learn from: `cinematics/duel_m2.tscn` with its beat sheet `cinematics/duel_m2_beats.md`
