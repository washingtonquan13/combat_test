# duel_m2: beat sheet and shot list

Showcase 1 of `docs/plans/bg3_cinematics.md`, milestone M2. Stage: [duel_m2.tscn](duel_m2.tscn).
Walkthrough and measurements: `tools/duel_m2_demo.tscn` (plays it once, then again with a skip).

Cast: `hero` (player character, CC male body, sword), `attacker` (proof_hero / wanderer, CC body,
sword), `victim` (townsperson, CC female body). The stage stands on one world mark,
`duel_m2_anchor`, which the area (or the demo) supplies.

Marks, stage-local: the hero lands on `landing` (origin); the attacker ends his walk on
`attacker_spot` (-0.96, 0, 1.12), which is the exchange's partner spot from the landing; the victim
is pinned on `victim_spot` (-0.7, 0, -1.7) with two rocks behind and beside her.

## Phrasing

Threat (0 to 2.4 s), a burst of three contacts in 2.53 s (land 2.40, miss 4.53, kill 4.93, as measured), one long
authored freeze on the kill (hit-stop plus 0.9 s), aftermath (6.4 s to the end). Contact gaps 2.13 s
and 0.40 s: no three gaps even.

Hit-stops and the freeze stop the timeline clock, so the times below are scene-clock times; the
recording runs about 1.2 s longer than the 9.3 s timeline.

## Beats

| Scene s | Beat | What happens |
|---|---|---|
| 0.00 | PlaceVictim, VictimCornered | The townsperson backs against the rock, hands up (Duel/Victim_Cornered, Kimodo take v2, feet pinned). |
| 0.00 | PlaceAttacker, AttackerAdvance | The attacker walks in on her, sword low (Duel/Attacker_Advance, take a3). |
| 0.00 | HeroInWings | The hero waits off stage (40 m out). |
| 1.23 | PlaceHero, HeroDrop | The hero leaps in from beside the camera (Duel/Hero_Drop, take f3; leaves the ground at 0.8 s into the clip, lands at 1.167 s). |
| 2.40 | Land | ImpactBeat LAND at the point under the hero's hips: small hold, shake, dust, thud. |
| 2.83 | Exchange | PairedActionBeat on `assets/paired_clips/exchange.tres` (M1): the attacker's overhead chop misses (4.53), the hero's sidestep thrust kills (4.93), freeze 0.9 s on the kill. |
| 4.20 | Duck | MusicDuckBeat: the music falls to -60 dB over 0.25 s, well before the kill. |
| 6.37 | HeroAfter | The hero lowers the sword and turns to the townsperson (Duel/Hero_After, take j3). |
| 8.50 | Wound | HurtBeat WOUNDED on the victim, 40% HP left (she was hurt before the hero came). |
| 8.60 | Unduck | The music comes back over 0.8 s. |
| 9.30 | end | |

## Shots

| From s | Shot | Framing | Why |
|---|---|---|---|
| 0.00 | S1_wide | Fixed, wide, from the side of the clearing | Establish all three and the rock. |
| 1.60 | S2_victim | Fixed, long lens on the victim's face over the attacker's shoulder | Stakes. The hero's leap enters this frame. |
| 2.33 | S3_land | Fixed, low, beside the landing | The landing. Cut lands a frame before contact, not inside its hold. |
| 3.20 | S4_behind_attacker | Orbit the attacker, looking at the hero | The chop reads along its line. |
| 4.70 | S5_thrust_line | Orbit the hero at 148 deg, looking at the attacker | Along the thrust: the kill blow lands within 25 deg of the camera line. |
| 5.03 | S6_floor | Fixed, 1.4 m up, looking down on the fall | Cut after the kill's freeze, onto the fall (the kill contact is marked cut AFTER). |
| 6.50 | S7_crane | Orbit the hero, rising 4 to 30 deg and pulling out 3 to 4.2 m | Aftermath. |

## Deviations from the proposal's M2 table

- **The hero leaps rather than drops.** There is no ledge in the quarry clearing; Kimodo's best
  jump takes travel forward, so the hero jumps in from beside the camera.
- **The landing is one-footed.** The best take (f3) lands on the right foot and steps through;
  the two-footed takes skated more.
- **Freeze and hit-stops take no timeline time.** They hold the timeline clock, so the authored
  9.3 s plays as about 10.5 s.
- **The attacker's walk starts at 0**, not after the establishing shot, so he is already closing
  when the scene opens.
- **Shot times shift +0.33 s** from the proposal so no cut falls inside the landing's hold.
- **S6 is not at floor level.** At 0.3 m the tall grass filled the frame; at 1.4 m it looks down
  onto the fall.
- **The stage needs level ground.** The exchange keeps each body on its own ground height, so marks
  more than a few cm apart in height miss the kill contact by that much. The demo picks a flat
  anchor (ground spread 0.000 m); an area that hosts this scene must do the same.
