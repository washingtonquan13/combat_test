# Shelter entrance exam: draft

Five questions in three parts, 100 points in all. Every answer is a rule
RMD uses now, checked against the data and code on 2026-11-26. Each answer
lists its source, so the exam can be updated if a rule changes.

---

## Part 1: Combat

**Q1 (15 points)**
A demon's claws land a critical hit on you. Can you Dodge it?

- A. Yes, if your Dodge roll succeeds
- B. Yes, but at -4
- C. **No. A critical hit can't be dodged or parried.** ✔

Source: `systems/unit_system/unit_combat.gd` (only non-critical hits get a defense roll).

**Q2 (20 points)**
You have already parried once this turn. A second blow comes in. What is
your best defense likely to be?

- A. Parry again, at full skill
- B. **Dodge. Each parry after the first is at -4, and Dodge has no limit.** ✔
- C. Nothing. You get one defense per turn.

Source: `unit_combat.gd` `PARRY_PENALTY`; `data/stats/dodge.tres`.

---

## Part 2: Terrain

**Q3 (15 points)**
You step onto a patch of ice. Which attribute keeps you on your feet?

- A. ST
- B. HT
- C. **DX** ✔ (grease is the same)

Source: `data/surfaces/ice.tres`, `data/surfaces/grease.tres` (both resisted by DX).

---

## Part 3: Conditions

**Q4 (30 points)**
Your fighter is Exhausted. What happens to the damage of their sword swing?

- A. It is halved, along with ST
- B. **Nothing. Exhaustion halves ST, Move and Dodge, but damage uses full ST.** ✔
- C. It drops by one die

Source: `data/statuses/exhausted.tres`; damage reads the unhalved ST.

**Q5 (20 points)**
A sleep dart hits you. Which attribute do you roll to stay awake?

- A. Will
- B. **HT** ✔
- C. Per

Source: `data/abilities/sleep_dart.tres` (resisted by HT).

---

## Notes for editing

- **In game:** data/terminal/shelter_exam.tres is what the terminal shows.
  Its answer options are shorter than the ones above (no explanations) so
  each fits on one line of the screen. Edit that file to change the exam.
- **Pass mark:** 60 for now, a placeholder (`pass_mark` in the .tres).
- **Point weights.** Q4 is worth the most because answer A looks right to
  anyone who knows that Exhausted halves ST.
- **Rules only.** There are no lore questions (the shelter, the invasion,
  the demons) because the story isn't settled. Writing them now would
  invent canon.
- **Not decided yet:** the pass mark, and what passing (or failing) does.
