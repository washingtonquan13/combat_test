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
   shared phase. The published alternative is Verma and Meng's method (sine
   modelling of the block's DCT). Which one is decided in stage 5, from what
   is measured to be left by then.
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

### 2. Noise that follows a hit

- A level per band every 128 samples (2.9 ms at 44.1 kHz), stored as
  breakpoints so a steady stretch costs nothing extra.
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

- Read the card: what is still a click miss after stages 2 to 4.
- Build the pulse generator in the candidate form. If it fails by ear on the
  closing hat and the pick attacks, try the DCT method.

Gate: clips. This is where earlier work stopped short, so the gate may fail.
If it does, what remains is listed note by note and the user decides what
happens next. No remainder is added quietly.

### 6. Fewer bytes for the same generators

Two thirds of a PINST3 file is already generator settings, so this matters
as much as the stages above.

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

### 8. Native player

- The player in `sfpp_test` brought to the new reference. It gets simpler:
  the transform decoder and layer reader go.
- The user has uncommitted changes in `pinst_source.cpp`; this stage is
  agreed with them before it touches that file.

Gate: native and reference agree on the proof set.

### 9. Proof listen

- The three libraries re-baked, one song per library rendered WAV against
  pinst, sent as MP3.

Gate: the user accepts all three. Only then is the wider re-bake planned.

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
- **Pulses are unproven.** The candidate form is this plan's own guess. The
  published alternative was never shown to be transparent either.
- **Bake time.** Modes and per-frame pitch are slow to find. PINST3 already
  cost 5 to 7 times PINST2.
- **Size could rise.** A fine noise envelope and many modes cost bytes;
  stage 6 exists to pay that back.
- **Thresholds becoming the new switches.** Covered by the rule for
  constants.

## Not in this plan

The wider re-bake, engine-side prefetch and late-voice behaviour, trained
(neural) generators, and hand-written physical models per instrument.
