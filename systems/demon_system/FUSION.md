# Fusion: the menu and the cutscene

This is the map from the reference (Nocturne's Cathedral of Shadows fusion, recorded at `D:\2026-10-06 13-15-11.mp4`) to the files that rebuild it. Everything here can be opened, scrubbed and changed in the editor. Nothing is generated at runtime.

## Where things are

| What | File |
|---|---|
| The cutscene | `cinematics/fusion.tscn` |
| The room it plays in | `world/fusion_chamber.tscn` (instanced in `world/cathedral_of_shadows.tscn`) |
| The menu | `ui/fusion_menu.tscn` (instanced in `ui/cathedral_menu.tscn`) |
| One demon's stat sheet | `ui/demon_sheet.tscn` |
| What the newborn says | `data/fusion_greetings/fusion_greetings.tres` |
| The rules (which pair makes what) | `data/fusion_charts/fusion_chart.tres` |
| The transaction, then the cutscene | `systems/demon_system/fusion_ritual.gd` |

How to make cutscenes in general is in `systems/cinematic_system/CINEMATICS.md`. This file covers only what is particular to fusion.

## The flow

1. **Cathedral menu.** Fuse / Demonic Compendium / Talk / Leave. (The Compendium is described below.)
2. **Fuse.** The option list steps aside and the fusion menu opens on the first list. If you have fewer than two demons that can be chosen, the menu does not open and the Minister says why.
3. **First list.** Race, name, rank of every demon you own. Moving the highlight fills the **Demon 1** tab. Enter or double-click chooses.
4. **Second list.** The same, without your first pick, plus the **result** of each pairing. A pairing that makes nothing is grey and cannot be chosen, and its tooltip says why. The **Result** tab shows what the highlighted pair makes, and **Demon 2** shows the partner.
5. **"Are you sure?"** Starts on **No**, so pressing Enter twice cannot spend two demons.
6. **Yes.** Both menus close. The roster changes first (the two parents leave, the result joins), then the cutscene plays.
7. **Back.** The camera is released, and the Cathedral menu returns with "What will you do?".

Esc goes back one step: second list to first (your first pick still highlighted), first list out.

A demon that is out in the world (summoned as a live unit) is grey too: dismiss it first.

The Minister's lines for each step are inspector fields on the `FusionMenu` node (`first_prompt`, `second_prompt`, `confirm_text`, and so on). The Cathedral's own lines are the `LINES` constant in `ui/cathedral_menu.gd`.

## The Demonic Compendium

The Cathedral's other menu, `ui/compendium_menu.tscn`, with its rules in `systems/demon_system/demon_compendium.gd` (the `DemonCompendium` autoload, saved as the `compendium` section).

- **The book** lists every demon in `data/units/demons/`, by race, then rank. A page you have not recorded is `?????` and cannot be highlighted.
- **Record a demon...** lists your demons. Choosing one records its page (one page per species; recording again rewrites it) and returns to the book on that page.
- **Summon** (or Enter on a page) asks "Summon X for N gold?", starting on **No**. Yes takes the gold and adds a fresh, full-HP copy to your demons. A page you cannot afford can be read, but Summon is disabled.
- **The cost** is `SUMMON_COST_PER_RANK_SQUARED × rank²` (50 per rank², so rank 1 is 50 gold), in `demon_compendium.gd`.
- A page stays when the demon it was recorded from is fused away or dies. That is the point of recording.
- A page holds only the species for now, because a demon has nothing else of its own to keep. When demons gain levels or inherited skills, `register()` is where they get recorded.

The Minister's lines are inspector fields on the `CompendiumMenu` node. Esc goes back one step. Releasing a demon is not here; it is still in the party overview's Demons tab, along with the debug grant and summon-cap rows.

Test: `tests/world/test_the_compendium_menu.gd`.

## The cutscene, shot by shot

The scene's clock starts at the fade-in, which is **0:25.5** in the reference. So **scene time = video time − 24.5 s**. The timeline is 33 s long.

| Video | Scene | Shot (`Shots/`) | What happens | Nodes and keys |
|---|---|---|---|---|
| 0:25.5 | 0.0 | `opening` | Fade in on the Minister, small on the room's ground floor in front of the platforms, between two pillars. The camera is on the ground too, orbiting the `Below` mark (his chest, 10 m under the device) | `Effects/Screen/Fade` colour: black 0–1 s, clear by 2.0. The Minister is the room's own (role `minister`, cast by `FusionRitual.cast_for`) |
| 0:26.5–28 | 2.0–3.5 | `opening` | Tilt up from him, up the platforms to the device | `opening:look_offset` 0 → (0, 11, 6.5) |
| 0:28 | 3.5 | `ceiling_up` | Cut: straight up at the ceiling rings | `shot` key; `ceiling_up:fov_degrees` 75 → 62 |
| 0:28–33 | 3.5–8.5 | `ceiling_up` | Blue energy on the pillar tips | `Effects/TipGlow` visible 3.5–8.5 |
| 0:28 | 3.5 | | The parents appear on their pads, off camera | `SpawnParentA`, `SpawnParentB` (SpawnBeat, species from the props `parent_a`/`parent_b`) |
| 0:33 | 8.5 | `pads_wide` | Cut: the two demons on their pads, from inside the pillar ring, two pillars behind them; burst and light columns | `PadBurst` 8.5–10.5, `Columns` 8.5–9.6 (a flash, as in the reference: they must not veil the dissolve), Fade flash 8.45–9.2; `pads_wide` aims at `Marks/Pads`, `distance` 6 → 5.2 |
| 0:34.5 | 10.0 | | Lightning | **Not built** (see below) |
| 0:36.5 | 12.0 | | The parents go black | `BlackenParentA`, `BlackenParentB` (SilhouetteBeat, black) |
| 0:37.5 | 13.0 | | Dark blobs stream up off them; the black bodies stay until the cut | `Effects/Blobs` visible 13–18, rising to y 3.2 by 15.5 so they stay in frame; `DespawnParentA/B` at 15.5, on the cut, so nobody blinks out on camera |
| 0:40 | 15.5 | `ceiling_gather` | Cut, looking up: the blobs stream to the ceiling | Blobs converge on the orb by 18 |
| 0:41–44 | 16.5–19.5 | `ceiling_gather` | A black orb with a blue rim gathers | `Effects/Orb` visible from 16.5, grows until 19.5 |
| 0:45–49 | 20.5–24.8 | `orb_close` | Closer; the orb shrinks; the room lightens | `orb_close:distance` 7 → 3.5; Orb scale down to 0.35 by 25; `RoomLight` 20.5–28 |
| 0:49.5 | 24.8 | | Blue flash | Fade 24.8–25.0 |
| 0:49.75 | 25.25 | `strike` | Cut: the strike onto the result pad, seen head-on from in front of it, on the axis the reveal later pushes in along | `Effects/Strike` 25.25–25.6; `strike` orbits `Marks/ResultPad`, which faces the way the result does (+z, out of the room), at azimuth 0 |
| 0:50 | 25.5 | | White | Fade white 25.5–26; `SpawnResult` at 25.5, `WhitenResult` at 25.55 |
| 0:50.5–52 | 26–27.5 | `strike` | A white silhouette | Fade clears by 27.5; `ResultGlow` 25.5–28 |
| 0:52.5 | 28.0 | `reveal` | Colour returns | `ClearResult` (SilhouetteBeat, clear); `reveal:distance` 3.2 → 2.2 over 28–31 |
| 0:55.5 | 31.0 | `reveal` | "I am X of the Y clan..." | `Greeting` (LineBeat, text `{greeting}`); waits for the player |
| 0:59.5 | after the line | | Fade to black, back to the Cathedral | Fade clear 31.5 → black 32.5, then the menu returns |

The shot column is the value of the stage's `shot` track. It is a Discrete track, so every change on it is a cut.

### What was left out, and why

- **Lightning tendrils** at 0:34.5. They need a proper effect (a shader or a particle system), and the brief was the minimum set a person can read in the Animation panel.
- **The floating trickle** of small particles between the pads. Same reason.
- **The Minister's model.** There is no model to use, so he is the placeholder body (`data/units/npcs/minister.tres`). Swap `model_scene` there when there is one.
- **The reference's colour grading.** The room lightening is one light (`RoomLight`), not a grade.

Every effect that *is* here is a plain node (a sphere, a cylinder, a torus, a light, a coloured rectangle) with visibility, position, scale or energy keyed on the `Timeline`. Click a node, and its tracks are the ones named after it in the Animation panel.

### Who is in the scene, and who made them

Nobody exists when the scene starts. Everyone on screen is made by a spawn key on the timeline, and stands on their mark from the frame they appear:

- **The Minister** is not the scene's: he is the `Minister` unit in `world/cathedral_of_shadows.tscn` (`definition` = `minister.tres`, group `fusion_minister`). He stands on the room's ground floor (stage local y −10, 6.5 m in front of the device), facing out, and presides over the menu before any fusion. `FusionRitual.cast_for()` finds him under the current world and tracks him in the `minister` role; the scene borrows him and never spawns or removes him. The Cathedral's menu camera (`DeviceView`) is placed where the `opening` shot starts and aims at the `MenuFocus` marker on his chest (`device_view_target`), so confirming a fusion fades in on the picture the menu was showing.
- **The parents** (`SpawnParentA`/`B`) from the species `FusionRitual.perform()` passes as props. The ritual used to make the two bodies itself and hand them over. They then sat at the world origin, inside the floor, until the scene placed them, and the physics pushing them out of the floor launched them upward. A placement moves a body but does not stop it, so they flew off the pads. Do not hand the scene pre-made bodies.
- **The result** (`SpawnResult`) from the prop `result`.

## How to change it

1. Open `cinematics/fusion.tscn`. The chamber shows under it (the stage's `preview_set`), so you can see what each shot sees.
2. Select `Timeline` and pin the Animation panel. Open the `scene` animation.
3. **Scrub.** Roles show as capsules, and they go black and white at the silhouette beats.
4. **Look through the camera.** Pick the preview camera in the viewport's camera menu (see CINEMATICS.md, "Look through the camera").
5. **Retime.** Drag keys. A cut is a key on the `shot` track. A beat is a key on its own Call Method track.
6. **Reframe.** Select a rig under `Shots/` and change `distance`, `azimuth_degrees`, `elevation_degrees` or `fov_degrees`. If the value is keyed, change the key instead.
7. **Fades and flashes** are the colour of `Effects/Screen/Fade`. They draw in the **2D** tab, not the 3D one.
8. Close the scene before editing it outside the editor (see the Gotchas in CINEMATICS.md).

To play it in game, fuse in the Cathedral. In a debug build, the cutscene harness's **J** key plays it without spending demons.

The scene and the chamber were written once by a script, to get a first draft down. That script is not kept: the `.tscn` files are now the source. Edit them in the editor.

## Greetings

`data/fusion_greetings/fusion_greetings.tres` holds the introduction (`I am {name} of the {order} clan.`) and one remark per personality (Calm, Cryptic, Dumb, Foolish, Girly, Kind, Moody, Scary, Sly, Wild). The newborn's `personality` picks the remark. A personality with no entry gets `fallback_remark`. The cutscene's line just says `{greeting}`; `FusionRitual.props_for()` assembles it.

## Tests

- `tests/cinematic/test_fusion_plays_without_dialogue.gd`: the whole timeline plays and ends on the result; the room's Minister is in the opening shot, seen from in front of him, and still standing in the room after the cut and after a skip; no parent exists before its spawn key; both parents are standing on their marks and in frame when the pads shot cuts in; the result is not left painted; the greeting is filled in; the white silhouette is framed from in front, within about 30° of its facing; and a skip leaves only the result standing beside him.
- `tests/world/test_the_cathedral_is_a_room_not_a_menu.gd` also checks that the room has its Minister before any fusion, on the ground floor, in the menu camera's frame from in front, and that he is the one `cast_for` casts.
- `tests/world/test_the_fusion_menu.gd`: the menu's guarantees (greyed pairs, No by default, step-back, Yes fuses what was shown).
- `tests/world/test_the_cathedral_is_a_room_not_a_menu.gd`: the room and its marks.

Run them with:

```bash
bash tests/run.sh --suite=fusion --suite=cathedral --suite=compendium
```
