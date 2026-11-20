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

Threat (0 to 2.4 s), a burst of three contacts in 2.53 s (land 2.40, miss 4.53, kill 4.93, planned), one long
authored freeze on the kill (hit-stop plus 0.9 s), the fall (to about 7.8 s), aftermath (8.1 s to the end). Contact gaps 2.13 s
and 0.40 s: no three gaps even.

Hit-stops and the freeze stop the timeline clock, so the times below are scene-clock times; the
recording runs about 1.2 s longer than the 11.07 s timeline.

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
| 2.40 | Land | ImpactBeat LAND at the point under the hero's hips: small hold, shake, dust, thud. |
| 3.33 | Exchange | PairedActionBeat on `assets/paired_clips/exchange.tres` (M1): the attacker's downward slash (gs_downward_slash) misses (4.53), the hero's thrust (thrust_stabbing) kills (4.93), freeze 0.9 s on the kill, the attacker falls (death_back). |
| 4.20 | Duck | MusicDuckBeat: the music falls to -60 dB over 0.25 s, well before the kill. |
| 8.13 | HeroAfter | The hero settles into the idle (Duel/Hero_After, ss_idle_1). |
| 10.27 | Wound | HurtBeat WOUNDED on the victim, 40% HP left (she was hurt before the hero came). |
| 10.37 | Unduck | The music comes back over 0.8 s. |
| 11.07 | end | |

## Shots

| From s | Shot | Framing | Why |
|---|---|---|---|
| 0.00 | S1_wide | Fixed, wide, from the side of the clearing | Establish all three and the rock. |
| 1.60 | S2_victim | Fixed, long lens on the victim's face over the attacker's shoulder | Stakes. The hero's leap enters this frame. |
| 2.33 | S3_land | Fixed, low, beside the landing | The landing. Cut lands a frame before contact, not inside its hold. |
| 3.20 | S4_behind_attacker | Orbit the attacker, looking at the hero | The chop reads along its line. |
| 4.70 | S5_thrust_line | Orbit the hero at 228 deg, looking at the attacker | Along the thrust: the kill blow lands within 25 deg of the camera line. |
| 4.97 | S6_floor | Fixed, 1.4 m up, looking down on the fall | Cut after the kill's freeze, onto the fall (the kill contact is marked cut AFTER). |
| 8.10 | S7_crane | Orbit the hero, rising 4 to 30 deg and pulling out 3 to 4.2 m | Aftermath. |

## Deviations from the proposal's M2 table

- **The hero leaps rather than drops.** There is no ledge in the quarry clearing, so the hero
  jumps in from beside the camera (Mixamo's greatsword jump attack).
- **The motion is Mixamo, not Kimodo.** The Kimodo takes read badly; the user picked the six
  Mixamo clips above (2026-11-20).
- **Freeze and hit-stops take no timeline time.** They hold the timeline clock, so the authored
  11.07 s plays as about 12.3 s.
- **The attacker's walk starts at 0**, not after the establishing shot, so he is already closing
  when the scene opens.
- **Shot times shift +0.33 s** from the proposal so no cut falls inside the landing's hold.
- **S6 is not at floor level.** At 0.3 m the tall grass filled the frame; at 1.4 m it looks down
  onto the fall.
- **The stage needs level ground.** The exchange keeps each body on its own ground height, so marks
  more than a few cm apart in height miss the kill contact by that much. The demo picks a flat
  anchor (ground spread 0.000 m); an area that hosts this scene must do the same.
