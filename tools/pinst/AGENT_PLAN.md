# pinst: build plan for several agents at once

Written 2026-11-12. Nothing here is built. Working name for the result:
**PINST5** (PINST3's design with the two reviews' fixes; the file layout
changes, so it gets a new number). PINST3, PINST4 and the game's WAV setup are
not touched until the end.

## The bar

"Near 100% accurate with no artifacts." The owner's ear is the only judge.

## When the three goals collide

Size, accuracy and bake time pull against each other in two places: sounds
that are mostly noise (cymbals, hats, amp hiss) and any step that tries
several encodings and keeps the best. The plan settles it in this order:

1. **Accuracy is fixed first**, by one quality dial the owner sets by ear, once.
2. **Size is the smallest that dial allows.**
3. **Bake time is cut only by changes that leave every byte the same.**

So speed work can never cost sound, and size work can never cost sound beyond
what the dial already allowed.

## What lets agents work at the same time

Four things, all made before any agent starts (wave 0):

- **One file per stage.** The encoder is split into stage files with fixed
  inputs and outputs. Each agent owns one file and edits no other.
- **One decoder, written once.** The code that turns a file back into sound
  exists as one C source, built into the bake tool and into the player. The
  encoder subtracts what that decoder will actually play, so "the player
  sounds different from the bake" cannot happen and needs no test.
- **A file made of labelled sections.** Each stage writes its own section, so
  a stage can change what it stores without breaking the others. The layout
  is frozen only at the end.
- **One bench** (below). It is the only test anyone runs while building.

## The bench

`tools/pinst/p5/bench.py`: encodes a fixed set of about 20 notes, decodes
them, prints one line per note and a total. About 20 s of CPU for the 13
notes already measured, a few seconds across 8 cores.

Notes: the 13 the review used (6 bass, kick, side-stick, tom, china, ride
bell, foot hat, rimshot), plus the cases the adversarial review broke: a
48 kHz piano note, a looped organ note, a silent file, three unamped guitar
notes scored after the amp.

Per note it prints: bytes and kbit/s; waveform match in dB (SNR: how far the
decoded wave is from the source, higher is closer); loudest-peak ratio
(1.00 = same); pre-echo (sound before the hit that the source does not
have); encode seconds; decode seconds. With `--base` it prints the change
from a saved run.

The decode inside the bench is the real decoder reading the real bytes, so
"the file round-trips" is checked on every run for free.

## Waves

I am the integrator: I write wave 0, merge each wave, build every DLL, run
Godot, run the full libraries, and send the listening packs. Agents never
touch Godot or git.

### Wave 0: me, alone

| Piece | Done when |
|---|---|
| Split the PINST3 encoder into `tools/pinst/p5/` stage files: `analysis.py`, `blocks.py`, `transform.py`, `quant.py`, `pack.py`, `decode.py`, `contract.py` (shared types, mine only) | Output matches PINST3 on the 13 notes |
| Reviewer's step 1: code the remainder (source minus sines) in every audible band, noise only fills gaps, the need map is deleted | Bench matches the review's "all30" figures: bass 23–26 kbit/s at 37–49 dB, kick/tom 28–34 at 30–40 dB, peak ratio 1.00–1.03 |
| The bench, with a saved baseline | One deliberately damaged encode turns it red, once |

### Wave 1: five agents at once

| Agent | Owns | Does | Done when (bench) |
|---|---|---|---|
| **A. Analysis** | `analysis.py` | Picks the analysis window from the sound, not the file name. Finds pitch from the sound. Drops the sine layer on a note when it does not make the file smaller. Subtracts the sines as the decoder renders them. Lifts the 18 kHz ceiling. | No note worse than baseline in bytes or dB. `a3_Sus_Up1` found at 110 Hz with the name hidden. Cymbal notes lose their 12–16 kbit/s of useless sine tracks. Encode time not above baseline. |
| **B. Transients** | `blocks.py`, `transform.py` | Finds each hit. Exact silence before the first hit stays exact silence. Short blocks around hits, long blocks elsewhere. | Pre-echo within 1 dB of the source on side-stick, tom, rimshot, kick. Bytes within 3% of baseline. |
| **C. Step sizes** | `quant.py` | One dial. Each band's step comes from how tone-like the band measures: tone-like bands stay fine, noise-like bands may go coarser. The quiet floor follows the note's own level, not a fixed −80 dB. Left/right coded as sum/difference per band when that is smaller. | Tone-like bands unchanged in dB. Bytes reported at three dial settings. Stereo notes smaller with no dB loss. |
| **D. Packing** | `pack.py` | Replaces LZMA on the coefficient streams with a range coder (a compressor that learns each band's statistics as it goes). Trims fixed overhead. | Round trip exact. 3–19% under LZMA (the review's measured headroom). Silent file under 100 bytes, not 77 KB. Unpack no slower than LZMA. |
| **E. Bake driver** | `bake.py` | Profiles the baseline with py-spy. Driver skips files whose source and encoder version are unchanged. | Top five costs listed with percentages. Second bake of an unchanged library takes seconds. |

D works on the baseline's numbers and is lossless, so it does not wait for
A–C. B and C meet only at one interface in `contract.py` (a list of blocks,
each with its length and coefficients).

**After wave 1 (me):** merge, bake bass and drums in full in the background,
send **listening pack 1**: the same phrases at C's three dial settings
against WAV. The owner picks the lowest setting they cannot tell from WAV.
Wave 2 starts without waiting for that answer.

### Wave 2: four agents at once

| Agent | Owns | Does | Done when |
|---|---|---|---|
| **F. C decoder** | `native/p5dec.c` | The one decoder in C. | Sample-identical to `decode.py` on the bench. Cost of 150 voices measured in a console loop and reported beside the PINST4 player's. |
| **G. C encoder loops** | `native/p5enc.c` | Ports whatever E's profile put on top. | Every bench file byte-identical to before. Bass and drum bakes at or under PINST2's time (4.6 and 32 CPU-minutes). |
| **H. Player** | sfpp_test `native/pinst/pinst5_*.cpp` | A new player kind behind the existing store (which already makes each note as its voice plays and holds nothing else). Loops, any sample rate. | Compiles; I build the DLL and run the render. |
| **I. Library sweep** | scratch only | Every 20th note of all 20 libraries through the bench measures. | A list of notes that break, nothing else. |

### Wave 3: me

Freeze the layout. Bake everything. **Listening pack 2**: the same six
phrases already on the owner's phone, new format against WAV, through the
real player. Then the tests (below), then commit.

## Testing: what runs and what does not

Runs:

- The bench, by an agent, only when its change can alter output.
- Bass and drums in full: twice in the whole plan (after wave 1, after wave
  3), by me, in the background while the next wave works.
- Speed work is checked by "bytes identical", a hash compare. No accuracy
  run and no listening is needed for it.
- Two listening packs.

Does not run:

- No unit tests while building. They would pin code that is still moving.
- No full bake per change.
- No player/bake comparison suite: one decoder source makes it unnecessary.
- No Godot runs by agents.

Written last, after the layout is frozen: one test. Three tiny files must
decode to stored hashes, so the layout cannot drift by accident.

## Rules in every agent brief

- Edit only the files you own. Need an interface change: say so in your
  report, do not make it.
- No Godot. No git commands that change anything. Never `git checkout --`,
  `git stash`, `git reset`. To undo, re-apply the lines or copy from a backup.
- Use the Edit tool for project files, not `sed -i`.
- numpy/scipy first. Profile with py-spy before optimising. C only where the
  profile points.
- Each C file builds to its own DLL name, so two agents never write one DLL.
- No rule may name a kind of sound. No switch per library.
- No tests beyond the bench. No downloads or installs.
- Report numbers from the bench, with the command that made them.
- Design-heavy agents (A, B, C, D, F) run on Opus; mechanical ones (E, G, I)
  on Sonnet; H on Opus.

## What to expect

Measured (review, 13 notes): at the 30 dB setting, sustained bass 23–26
kbit/s, kick and tom 28–34, cymbals and hats 176–387. Vorbis at like error
is 4–5 times larger on bass, kick and tom, and even to 2 times larger on
cymbals.

Projected from few notes: bass library about 14 MB (WAV 588 MB); drums
250–330 MB (WAV 3.5 GB) before A, C and D.

Guesses, unmeasured: drums 150–200 MB after A, C and D. Bake at PINST2's
time after G; today's figure without the need map is 2.4–3 times PINST2.

## What could stop it

- **Voice cost.** 150 voices of this decoder has never been measured. F
  measures it first thing. If it is too high, the plan stops there.
- **Memory.** Drums on disk may exceed the 256 MB budget, so notes must be
  read as voices need them. The existing store already works that way.
- **Guitar through an amp.** The amp lifts quiet errors by 10–16 dB; clean
  after the amp cost 135–220 kbit/s in the review, no smaller than 16-bit
  lossless. Rule in C: never store a note larger than lossless would be.
  Whether that is acceptable is the owner's size call, after pack 1.
- **Noise-like bands.** How coarse they may go is the owner's ear, pack 1.

## Not in this plan

Sharing data between similar notes (round robins, velocity layers). Any
modelled or Opus-based instrument. Changes to PINST4.
