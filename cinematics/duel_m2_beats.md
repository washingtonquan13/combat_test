# duel_m2: beat sheet and shot list

Showcase 1 of `docs/plans/bg3_cinematics.md`, milestone M2. Stage: [duel_m2.tscn](duel_m2.tscn).
Walkthrough and measurements: `tools/duel_m2_demo.tscn` (plays it once, then again with a skip).
Render: `tools/render_movie.sh res://tools/duel_m2_demo.tscn recordings/bg3/m2_duel.avi`.

Cast: `hero` (player character, CC male body, sword), `attacker` (proof_hero / wanderer, CC body,
sword), `victim` (townsperson, CC female body). The stage stands on one world mark,
`duel_m2_anchor`, which the area (or the demo) supplies.

Marks, stage-local: the hero lands on `landing` (origin); the attacker ends his walk on
`attacker_spot` (0.72, 0, 0.88), turned -5 deg, which is the exchange's partner spot from the landing; the victim
is pinned on `victim_spot` (-0.7, 0, -1.7) with two rocks behind and beside her.

## Phrasing

Threat (0 to 2.4 s), a burst of three contacts in 2.53 s (land 2.40, miss 4.53, kill 4.93, planned), the fall
(to about 7.8 s), aftermath (8.1 s to the end). Contact gaps 2.13 s and 0.40 s: no three gaps even.

No hit-stop and no freeze: nothing stops on a contact, so the scene plays exactly its 11.07 s timeline.

All body motion is Mixamo (`tools/locomotion/takes/mixamo_duel.glb`, retargeted by
`tools/locomotion/mixamo_retarget.py` with DUEL=1), composed and fitted by
`tools/locomotion/make_mixamo_duel.gd`, which keeps M1's aim, contact IK and foot pins.

## Beats

| Scene s | Beat | What happens |
|---|---|---|
| 0.00 | PlaceVictim, VictimCornered | The townsperson backs against the rock, hands up (Duel/Victim_Cornered, Mixamo victim_terrified, feet pinned). |
| 0.00 | PlaceAttacker, AttackerAdvance | The attacker walks in on her, sword low (Duel/Attacker_Advance, Mixamo walk into the idle). |
| 0.00 | HeroInWings | The hero waits off stage (40 m out). |
| 1.43 | PlaceHero, HeroDrop | The hero leaps in from beside the camera (Duel/Hero_Drop, Mixamo gs_jump_attack trimmed 16 frames after the landing; lands 0.967 s into the clip). |
| 2.40 | Land | ImpactBeat LAND at the point under the hero's hips: shake, dust, thud. |
| 3.33 | Exchange | PairedActionBeat on `assets/paired_clips/exchange.tres` (M1): the attacker's downward slash (gs_downward_slash) misses (4.53), the hero's thrust (thrust_stabbing) kills (4.93), the attacker falls (death_back). |
| 4.20 | Duck | MusicDuckBeat: the music falls to -60 dB over 0.25 s, well before the kill. |
| 8.13 | HeroAfter | The hero settles into the idle (Duel/Hero_After, ss_idle_1). |
| 10.27 | Wound | HurtBeat WOUNDED on the victim, 40% HP left (she was hurt before the hero came). |
| 10.37 | Unduck | The music comes back over 0.8 s. |
| 11.07 | end | |

## Shots

| From s | Shot | Framing | Why |
|---|---|---|---|
| 0.00 | S1_wide | Wide, 40 deg, slow dolly in (keyed `cam_wide`) | Establish the attacker closing on the victim, the rock and the houses. |
| 1.60 | S2_victim | Long lens (15 deg) on her face, from the hero's side | Stakes. |
| 2.33 | S3_land | Knee-high (0.95 m) beside the landing, 44 deg | The landing, hero and attacker both full figure. Cut lands a frame before contact. |
| 3.20 | S4_over_attacker | Over the attacker's shoulder onto the hero, victim beyond | The squaring up. |
| 4.00 | S5_side | Side-on two-shot, 40 deg | The exchange reads across the frame: the miss and the thrust. |
| 4.97 | S6_fall | Wide, 1.5 m up, 44 deg, all three | Cut just after the kill, onto the fall (the kill contact is marked cut AFTER). |
| 8.10 | S7_crane | Keyed crane (`cam_crane`, `crane_look`) rising to 4.2 m and tilting down | Aftermath: the hero, the victim and the body. |

Screen order holds across every cut: attacker left, hero in the middle, victim right. All cameras
stand on the same side of the line between the fighters. The framing check
(`systems/cinematic_system/framing_check.gd`) prints every shot's numbers and passes with no problems;
the old shot list had 8.

## Deviations from the proposal's M2 table

- **The hero leaps rather than drops.** There is no ledge in the quarry clearing, so the hero
  jumps in from beside the camera (Mixamo's greatsword jump attack).
- **The motion is Mixamo, not Kimodo.** The Kimodo takes read badly; the user picked the six
  Mixamo clips above (2026-11-20).
- **No freeze on the kill, no hit-stops.** The proposal had both; the user cut them (2026-11-20)
  as out of place in a cinematic.
- **The attacker's walk starts at 0**, not after the establishing shot, so he is already closing
  when the scene opens.
- **Shot times shift +0.33 s** from the proposal so the landing cut sits a frame before the contact.
- **No strike-line rule.** The proposal put the camera within 25 deg of the strike line; shooting
  down the thrust crossed the line between the fighters and swapped them on screen. Every camera now
  stays on one side, and the framing check guards it.
- **S2 is not over the attacker's shoulder.** That would cross the line; it is a long lens from the
  hero's side.
- **No camera low in the grass.** At 0.3 to 0.55 m the tall grass filled the frame (the framing
  check cannot see grass); every camera is 0.95 m up or more.
- **The stage needs level ground.** The exchange keeps each body on its own ground height, so marks
  more than a few cm apart in height miss the kill contact by that much. The demo picks a flat
  anchor (ground spread 0.000 m); an area that hosts this scene must do the same.
