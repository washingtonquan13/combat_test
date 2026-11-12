# pinst: generators only

Written 2026-11-11. Status: plan only, nothing built. Replaces
`ONE_STANDARD_PLAN.md` from its stage 3 on.

## Why

The goal was always the .kkrieger one: store how to make the sound, not the
sound. PINST3 (stage 2 of the old plan) stores a transform-coded remainder
wherever its two generators fail, and that remainder is a codec inside the
format. Measured on the two baked libraries:

| Library | Total | Partials | Noise | Stored remainder |
|---|---|---|---|---|
| standard-bass | 5.17 MB | 26.8% | 37.9% | 33.9% |
| sm-drums | 83.05 MB | 38.3% | 24.0% | 37.1% |

This plan removes the remainder. Where no generator explains a sound, the
answer is a missing generator, never stored waveform. There is no safety net:
a note the generators cannot make will sound wrong until they can, and the
plan's job is to say exactly where and why.

The field is spectral modelling synthesis (sines + transients + noise). What
the literature says, from a review on 2026-11-11:

- **Nobody has shown a generic system of this kind to be transparent without
  waveform-coding something.** Levine (1998) transform-coded attacks. MPEG-4
  SSC beat AAC at 24 kbit/s and was called "acceptable for streaming"; its
  authors later added a waveform coder to go higher. HILN tested equal to or
  worse than AAC at 16 kbit/s.
- **Where shaped noise broke for Levine:** sharp high-frequency onsets
  (closing hi-hat, cymbal taps) came out "distorted and spread" even with a
  2.9 ms noise envelope. An envelope on noise gets the energy's timing right
  but not the phase agreement across bands that makes a click a click.
- **What did work:** a 2.9 ms noise envelope in 6 bands above 5 kHz for
  material without sharp onsets; damped sinusoids (one-sided, so no pre-echo)
  for piano, bells and plucked sounds; all-pole time envelopes that shape
  noise finer than the frame.
- **Dense-mode sounds** (cymbals) defeat mode-by-mode models: about 2000
  linear modes still miss a crash attack. Noise is the only compact model.

So this is research with a known hard spot (sharp onsets, cymbals), not a
recipe. Sizes and the user's ear decide whether each step was worth it.

## The standard

One encoder path for every note of every instrument. No tiers, no chooser, no
per-library switches, no rule that names a kind of sound, no stored
waveform.

A note is the sum of generators. Each is tried in turn on what the ones
before it left, and takes only what it explains:

1. **Partials.** Tracked sines that follow pitch frame by frame, analysed
   with short windows in high bands and long ones in low bands. Harmonic lock
   when the fit is good, dropped when it is not.
2. **Modes.** Decaying sines, each an onset time, frequency, decay rate,
   level and phase. They start at their onset and ring down, so nothing
   sounds before the hit. This is the struck-body generator (kick, toms,
   plucks, bells).
3. **Pulses.** The part of a hit that is in step across bands. Candidate
   form: an onset time, a level per band and a short decay, rendered with one
   shared phase. The published alternatives are Verma and Meng's method (sine
   modelling of the block's DCT) and hybrid dictionary decomposition
   (Daudet and Torrésani): matching pursuit over short atoms at several
   scales, each atom a position, scale, frequency, phase and level. Which one
   is decided in stage 5, from what is measured to be left by then.
4. **Noise.** Band noise as today, with a time envelope fine enough to carry
   the noisy part of a hit. Whatever the first three leave goes here.

The need map changes job. It no longer picks what to store. It becomes the
**report card**: per band and frame, does the output sound like the source,
and if not, which kind of miss is it (a tone the partials missed, an envelope
the noise could not follow, a click nothing made). Every stage is aimed at
the largest kind of miss on the card.

## Rule for constants

Unchanged: each threshold is one number for all instruments, set on the
whole proof set. If a library seems to need its own value or its own switch,
work stops and that is reported as a finding.

## Yardsticks

- **The user's ear**, on clips. The only judge of sound.
- **The report card**: share of audible band-frames that miss, by kind.
- **Size against Opus.** A note should be smaller than Opus at the same
  sound, or the generators are not explaining it yet.
- Waveform error is not used. Generated noise never matches a waveform.

Every gate sends clips in this order: original, the previous stage, this
stage, Opus at this stage's size.

## Proof set

As before: standard-bass, sm-drums, hamorg (from stage 7), and the 23 guitar
and drum notes of the old test set. The 14 notes of the gate 2 clips are the
listening set, with a closing hi-hat added (Levine's failure case).

## Stages

Each stage ends at a gate. Nothing past a gate starts until it passes.

### 0. Where we stand with no net

- Encode the listening set with the remainder switched off and the forced
  noise mute around hits removed: partials and noise only.
- Record size and the old need map's share per note.

Gate: clips sent, numbers in this file. This is the honest starting point,
and it is expected to sound worse than PINST3.

**Result (2026-11-11).** Clips sent: original, PINST3, stage 0, Opus at
stage 0's size. Bytes are PINST3 → stage 0. Peak is source / stage 0, the
crudest sign of a lost or overshot hit.

| Note | Bytes | Need % | Peak |
|---|---|---|---|
| bass d#4 release2 | 2558 → 1110 | 42 | 0.437 / 0.468 |
| bass a2 mute down1 | 4682 → 3521 | 6.6 | 1.0 / 0.732 |
| bass e2 hammer-on1 | 9173 → 6490 | 6.2 | 1.0 / 1.502 |
| bass e2 sus long | 26263 → 20957 | | |
| bass fret noise10 | 3613 → 898 | | 1.0 / 1.715 |
| kick v32 | 6011 → 2813 | 44 | |
| snare v34 | 7390 → 2514 | | |
| tom2 v30 | 9490 → 5672 | | |
| tom4 v23 | 11620 → 7406 | | |
| hat open v14 | 79695 → 59275 | | 0.943 / 0.333 |
| hat tight v47 | 11730 → 4184 | | 0.839 / 0.263 |
| hat closed-open v12 | 58255 → 44021 | | 0.943 / 0.71 |
| crash15 v22 | 56681 → 45769 | | |
| gtr e2 sus | 22395 → 19075 | 0.1 | |
| gtr e2 mute | 11073 → 8337 | | 0.999 / 0.557 |
| gtr a2 release | 8061 → 4842 | 17 | |

Read: hat onsets lose most of their peak (smeared into noise); the hammer-on
and fret noise overshoot (partials fitted at the wrong pitch or lock); kick
body is the largest need share on drums. These are the cases stage 1's card
has to name.

### 1. Report card

- The test the old plan described and never built: is what is left after
  the generators noise-like? Per band and frame, two checks, as AAC's noise
  substitution does: is it tonal, and does its level move inside the frame
  faster than the noise can follow.
- Misses sorted by kind: tone, envelope, click.

Gate: with no knowledge of the instrument, the card names the known cases
correctly: the hammer-on and fret noise as tone, the kick body as tone or
mode, the hat and snare onsets as envelope or click. If it cannot, the plan
is revised here.

**Result (2026-11-11). Gate failed as written; the card works, and the plan
is revised.**

The card (`report_card.py`, run through `sms.py`) is calibrated. The
calibration source (the output with another noise draw) misses ≤ 5 % of
audible band-frames on 15 of 16 notes; the worst is the bass release at
14.6 %. The kinds it gives:

- Every level miss is the output too loud, never too quiet.
- The tone test never fires. With the partials in, tones turn into level
  errors and not into missing peaks.
- No click test could be made. A phase-alignment measure across bands
  (Rayleigh statistic, at the band's best instant) gives our own noise draw
  scores as high as the sources' attacks, because a noise band that switches
  on at a frame edge is itself in step. The sources' attacks are fast
  envelopes, not phase-aligned impulses, at any scale the bands can resolve.

The card's misses trace to two causes, both checked directly:

1. **Power smoothing smears the noise envelope.** Turning the 5-frame
   smoothing off drops attack misses on its own:

   | Note | Attack misses: smoothing on → off |
   |---|---|
   | fret noise | 15.5 → 0.4 % |
   | hammer-on | 39.8 → 6.8 % |
   | kick | 29 → 17 % |

   So the hammer-on and fret noise are envelope misses, not tone misses.
2. **The noise generator spills across bands.** Asked for one band, it
   gives the next band at 0 dB at 100 Hz, and a skirt of −40 to −60 dB over
   the whole spectrum from a mid band. Wherever the source has little
   energy, the spill is the output: low bands on hats, snare and crash
   (19–51 % misses below 300 Hz), high bands on bass (90–100 % above
   4 kHz). The kick body is a low tone carried by noise (partials: 30
   bytes), and its spill makes the low bands 45 % too loud.

Plan changes:

- Stage 2 gains a noise generator with sharp band edges and no frame-edge
  skirt; the band shape is part of the generator.
- Stage 5 uses envelope misses at onsets in place of a click kind.
- The gate's expectations were wrong about kinds, not about notes. Each
  later gate is read on misses per note.

### 2. Noise that follows a hit

- A level per band every 128 samples (2.9 ms at 44.1 kHz), stored as
  breakpoints so a steady stretch costs nothing extra.
- Band shape decoupled from the envelope step: each band's noise is
  filtered to its band with sharp edges (long filters, or one long FFT per
  note) and its gain moves in time, so a 128-sample step does not widen the
  band. The test is one band alone: every other band at least 60 dB down.
  No power smoothing.
- If the card still shows envelope misses at that step, an all-pole envelope
  inside the frame (the SSC method) is the next move.
- The transient detector, the forced mute and their constants are deleted.

Gate: envelope misses fall on the whole proof set; clips. Expected to be
enough for snare and tom noise, and not enough for the sharpest hat onsets.

### 3. Partials that follow pitch

- Pitch from the audio per frame; the file name is only a starting hint.
- Short analysis windows in high bands.
- Lock decided by fit. `--pitch` and the kit-name test are deleted.

Gate: tone misses fall on hammer-ons, slides and fret noise; drums come out
unlocked on their own; pitched notes keep their lock; no switches.

### 4. Modes

- Decaying sines found on what partials leave at each onset, by a
  high-resolution method (ESPRIT in sub-bands) or by greedy search; whichever
  is stable on the proof set.
- A cap on modes per onset, one number for all instruments. Past it the
  sound is dense and belongs to noise.

Gate: kick and tom bodies and plucked attacks pass by ear; cymbals are not
made worse or larger.

### 5. Pulses

- Read the card: what is still an envelope or level miss at onsets after
  stages 2 to 4 (stage 1 found no measure that separates a click from fast
  noise).
- Build three candidates and compare them on the same card and clips:
  the plan's own pulse form, the DCT method, and matching pursuit atoms.
- Atoms: a dictionary of short atoms at several scales, picked one at a time
  from what stages 2 to 4 left at each onset. Each atom must lower the
  residual in its bands. Atoms per onset are capped by one number for all
  instruments, as modes are. Past the cap the attack belongs to noise.
- Atoms start at their onset and decay (damped atoms, Goodwin and
  Vetterli), never symmetric Gabor atoms: half of a symmetric atom sounds
  before the hit, which is pre-echo. Several scales solve the one-window
  trade-off; the damped shape keeps nothing ahead of the attack.
- The atom cap is what keeps this a generator and not a stored waveform in
  another basis. Report misses and bytes at several caps. If the bar is only
  reached where the atoms are as dense as the attack's samples, that count
  is reported and the user decides where the line is.

Gate: clips. This is where earlier work stopped short, so the gate may fail.
If it does, what remains is listed note by note and the user decides what
happens next. No remainder is added quietly.

### 6. Fewer bytes for the same generators (stretch goal)

Moved to a stretch goal (2026-11-12): after stage 5 the 16-note set is about
8 KB a note, small enough to ship. The fewer-tracks ideas below come back if
stage 8 measures voice cost as too high; stage 9 reports the size either way.

- Breakpoints for every slowly changing value (partial levels, noise bands).
- Harmonic partials stored as a pitch and a spectral shape, not one track
  each, where the fit allows.

Gate: size per library reported against PINST2, PINST3 and Opus; the sound
is unchanged by ear.

### 7. Any rate, loops, hamorg

- Sample rate as a parameter.
- Phase carried across loop points.
- hamorg bakes through the same path.

Gate: hamorg bakes with no switches and loops without a click.

**Result (2026-11-12). Gate passed by the user's ear.** PINST4 (`sms_file.py`:
the generators' own bytes, any rate) round-trips exactly; `bake_library.py`
bakes through `sms.run`. Every 60th hamorg file (10, 48 kHz) baked with no
switches, 7-15 KB a note against ~470 KB WAV. Seams looped plainly on the
SFZ's loop points, jump over step at the seam, source → render: within reach
of the source on 9 of 10; Drawbar 1-01 1.33 → 6.13. The user hears clicks
but most are imperceptible: "this is probably good enough".

The loop fix was then built as a Python reference anyway. The worst click
(1-01) was the noise, not the partials: the band-noise table read jumped
back with the loop. Looped with the state carried (partial phase and the
noise table read both run on through the loop; only frequencies and levels
are read at the looped position), every seam is at or below the source's
(1-01 6.15 → 0.47). The user listened: "this is good". Stage 8's player
loops this way.


### 8. Native player

- The player in `sfpp_test` brought to the new reference. It gets simpler:
  the transform decoder and layer reader go.
- The uncommitted `sfpp_test` diff (sample rate read from the file for the
  PINST2 player, 2026-11-11) is an earlier Claude session's, not the
  user's. **Agreed 2026-11-12:** the PINST2/PINST3 decoders are dropped now
  (only PINST4 plays; existing baked libraries stop playing until re-baked).
- Loops as stage 7's reference: partial phase and the noise table read run
  on through the loop; only frequencies and levels are read at the looped
  position.
- **Reference set (28e1bb9):** `reference/notes/` holds 19 PINST4 notes (the
  16 test notes, the stereo snare, hamorg 1-01 and 5-57 looped by their SFZ
  loops). `make_reference.py` renders them (21 renders, float32 interleaved,
  `reference/render/`, not in git); `make_reference.py --check DIR` compares
  a native player's renders of the same names.

Gate: native and reference agree on the proof set: `--check` passes, every
render at least 80 dB under its peak.

### 9. Proof listen

- One song per library (the three libraries), rendered WAV against pinst,
  sent as MP3. Only the notes the songs play are baked, in Python: the
  whole three libraries are about 7,800 notes, 1-2 days at the Python bake's
  speed.
- Each library's size against PINST2 and Opus (stage 6 is a stretch goal).

Gate: the user accepts all three. Only then is the wider re-bake planned.

**Passed 2026-11-12, with a known gap.** Songs: sealed-ward (hamorg),
low-end (standard-bass), level-up-groovy (sm-drums, and once with all three
swapped). The user's verdict: within acceptable bounds for now, about 70-80%
accurate; some notes sound dropped (percussion near 0:04, bass near 0:08).
Measured: the drum attacks lose their front. At 4.57 s and 8.00 s the attack
peak is about a third of the WAV's (0.85 against 0.25, 0.56 against 0.25),
the first 10 ms 7-15 dB under and the next 200 ms 2-3 dB under; 84 of 4,546
10 ms frames of the song are more than 6 dB under the WAV, all on hits. The
bass at 0:08 is unconfirmed (about 1 dB down over 200 ms with all three).
Raising this toward "sounds the same" is the first quality work after stage
10, done in the native bake.

Storage, every note the three songs play:

| Library | Notes | WAV | pinst | Opus 32k | Opus 64k | Opus 96k | PINST2 |
|---|---|---|---|---|---|---|---|
| hamorg | 186 | 87.24 MB | 1.884 MB | 1.344 MB | 3.371 MB | 4.902 MB | none |
| standard-bass | 222 | 112.73 MB | 1.085 MB | 1.813 MB | 3.629 MB | 5.294 MB | table only |
| sm-drums | 196 | 65.51 MB | 0.716 MB | 0.685 MB | 1.586 MB | 2.670 MB | 2.266 MB |

Real-time playback, whole process (`render.gd --realtime --as-game`):

| Song, build | Load | RAM after load | Peak RAM | CPU-s | Starved |
|---|---|---|---|---|---|
| sealed-ward WAV | 864 ms | 269 MB | 383 MB | 68.6 | 7 |
| sealed-ward pinst | 953 ms | 294 MB | 674 MB | 136.8 | 4 |
| low-end WAV | 1372 ms | 296 MB | 451 MB | 111.8 | 12 |
| low-end pinst | 1561 ms | 321 MB | 554 MB | 119.3 | 15 |
| level-up-groovy WAV | 229 ms | 194 MB | 255 MB | 32.2 | 13 |
| level-up-groovy pinst drums | 424 ms | 216 MB | 329 MB | 35.8 | 173 |
| level-up-groovy all three | 634 ms | 230 MB | 658 MB | 106.9 | 173 |

Every starved voice is a WAV voice (its disk stream did not arrive past the
2048-frame preload), never a pinst one; WAV streaming falls behind more when
pinst plays alongside. That is a player bug, fixed before stage 10.

### 10. Native bake

**Agreed 2026-11-12:** the Python encoder is frozen as it stood at stage 9
and ported as is; the stage 8 reference check is the gate. Once it passes,
encoder changes (the attack work above first) are made in C++ only; Python
stays a frozen reference, not a second place to change.


- The bake in C++, after the sound is signed off, so it ports a design that
  holds still. It reuses stage 8's render code for the card's candidates.
- The Python bake stays the reference: the native bake makes the same
  choices (packs per generator) on the 16-note set.
- Then the wider re-bake (about 23,000 notes; several days in Python).

Gate: same choices as Python on the 16 notes, and the bake time reported.

## Language

The encoder stays in Python (numpy) until stage 5 has passed. The generators
are still guesses and will be rewritten more than once; that is cheap in
Python and slow in C++. Bake time is paid offline and is attacked by
profiling first. A C++ encoder is decided after stage 5, when the design has
stopped moving, and only if the wider re-bake would otherwise take days. The
player is already C++ and stays so (stage 8).

## Working in parallel

Stages 0 and 1 are done by one hand, in order: they fix the interface and the
report card everything else is measured with.

After that each generator is its own module with the same two functions:
`analyse(what_is_left, sr)` gives its settings, `render(settings, n, sr)`
gives its sound. With that fixed, these run at once, one Opus agent each, in
its own worktree, touching only its own module:

| Agent | Work | Measured by |
|---|---|---|
| A | Stage 2, noise envelope | envelope misses on the card |
| B | Stage 3, partials that follow pitch | tone misses on the card |
| C | Stage 4, modes | kick, tom and pluck bodies on the card |
| D | Stage 7, sample rate as a parameter and loop phase | hamorg bakes |
| E | Stage 6 groundwork: breakpoint coding of the existing streams | bytes, output unchanged |

Rules:

- Agents never judge sound. They report card numbers and sizes, and produce
  clips. The user hears them.
- One hand (the main session) owns `pinst_encode.py`, the file format and
  the merge. Agents do not edit those.
- The merge is its own step: the generators are chained in the standard's
  order and the card is run again, because each one changes what the next
  is given. Clips for stages 2, 3 and 4 go to the user as one gate: each
  alone, then all together.
- Stage 5 (pulses) is not started in parallel. It depends on what the
  merged three leave.
- Each agent's work is reviewed by a second agent that did not write it,
  before the merge.
- No agent touches `sfpp_test` or Godot.

## What goes away

The transform layers and their coder, the need map as a chooser, the
transient detector and forced mute, `SNR_DB`, `LAYER_BANDS`, the short and
long block sizes, `--pitch`, the kit-name test, the 44.1/48 kHz asserts, and
PINST3 as a shipped format (its bakes were never committed).

## What stays

Partial tracks and harmonic lock, ERB noise bands, hash noise with the seed
in the file, mid/side, the frame-ordered layout, the block player, the store
and prefetch, `bake_library.py`'s one path. PINST2 stays in the game until
stage 9 passes.

## Risks

- **It may not be reachable.** No published generic system got to "sounds
  the same" without stored waveform. Sharp high onsets and cymbals are the
  known hard spots. With no net, some notes may stay wrong for a long time.
- **Pulses are unproven.** The candidate form is this plan's own guess.
  The published alternatives (DCT sines, matching pursuit atoms) separate
  transients well, but were shown transparent only with their own bit
  rate for the transient layer, not as a few settings per hit.
- **Bake time.** Modes and per-frame pitch are slow to find. PINST3 already
  cost 5 to 7 times PINST2.
- **Size could rise.** A fine noise envelope and many modes cost bytes;
  stage 6 exists to pay that back.
- **Thresholds becoming the new switches.** Covered by the rule for
  constants.

## Not in this plan

The wider re-bake, engine-side prefetch and late-voice behaviour, trained
(neural) generators, and hand-written physical models per instrument.

Stretch goal, most likely never pursued (user, 2026-11-11): recipes. Fit
smooth generic rules across an instrument's notes (harmonic level by number,
decay by frequency) and store the rules plus corrections instead of each
note's measured settings, for tens of bytes per note. Judged too much work
for the return; measured settings fit the premise.
