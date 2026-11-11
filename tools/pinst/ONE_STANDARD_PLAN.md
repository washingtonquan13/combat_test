# pinst: one standard

Written 2026-11-11. Status: plan only, nothing built.

## Why

Three findings from the review of the encoder and file format:

1. **Tiers are an on/off switch with a weak judge.** "body" is "mid" plus the
   coded residual. The chooser compares the two against each other with a
   yardstick that calls itself "not a perceptual model"; it never asks whether
   a note reaches a target. After the crackle fix standard-bass is 938 body,
   2 mid.
2. **The residual is placed by rule, not by need.** It exists only in the
   first 200 ms after one onset, and below 300 Hz for the rest of the note.
   Those two places are where a guitar and a kick drum needed it.
3. **The model assumes one hit at the start of a harmonic note of known
   pitch.** Everything else is handled by a switch a person sets per library
   (`--judge`, `--pitch`, the kit-name test in the bake runner).

Most past fixes worked around one of those three. The plan removes the three
causes; it does not add a fourth tier or a better chooser.

## The standard

One encoder path for every note of every instrument. No tiers, no chooser, no
per-library switches.

- **Sines and noise as today.** Partial tracks, harmonic lock, ERB noise
  bands. These stay the cheap part.
- **A need map decides the residual.** After the sines are taken out, each
  band of each frame of what is left is tested: can smooth shaped noise stand
  in for it? It cannot when the band's level moves faster inside the frame
  than the noise model can follow (a transient), or when the band is not
  noise-like (unresolved partials, beating, a body resonance). Band-frames
  that fail are coded; the rest are left to the noise model; band-frames far
  under the note's level are left alone. An easy note comes out small because
  its map is nearly empty, not because something picked a cheap recipe.
- **Transients found per frame.** Any number of them, or none. A frame with a
  transient is coded with short blocks, the others with long blocks. This
  replaces the single onset, the fixed 200 ms window and the 1 ms attack
  noise envelope.
- **Pitch from the audio.** The file name or keycenter is a starting hint.
  Harmonic lock is used when the harmonic fit is good and dropped when it is
  not, so drums and bells come out unlocked without being told.
- **Sample rate is a parameter**, not a module global and not a list of two
  allowed values.

The file format already stores layers with their own block size, band count
and a per-band "dead" flag, so the map is expected to fit it. The player
mutes the noise per band-frame where the residual is live, in place of
today's time window and 300 Hz cutoff. Stage 0 found that this is more than
one change in the native code; see its answers below.

## Rule for constants

The new design still has thresholds (how fast is "too fast for noise", how
far down is "leave alone", the coded signal-to-noise). Each is one number for
all instruments, set on the whole proof set. If a library seems to need its
own value or its own switch, work stops and that is reported as a finding.

## Proof set

Three libraries, chosen because each breaks a different assumption:

| Library | What it tests |
|---|---|
| standard-bass | plucks that turned to noise (the main menu crackle) |
| sm-drums | unpitched, many transients, kick bodies, rolls and open hats |
| hamorg | sustained, looped, key click, currently excluded |

Plus the 23 guitar and drum notes of the old test set, so the instruments the
codec was tuned on do not get worse.

## Stages

Each stage ends at a gate. Nothing past a gate starts until it passes.

### 0. Baseline and unknowns (no behaviour change)

- Read the native player (`sfpp_test/native/pinst`) and correct this plan
  where the player differs from the Python reference.
- Write down exactly why hamorg and synth were excluded.
- Pin down what is left of the main menu crackle. The user's hypothesis is
  that the conversion itself is not accurate enough, so that is tested
  first: decode each bass note the song plays and compare it with its WAV,
  note by note, to find which notes carry the remaining 35 bursts and what
  in them the model got wrong. Cut voices in the player are checked only to
  rule them out.
- Record today's numbers for the proof set: bytes per library, burst count
  against the WAV render, bake time.

Gate: the three unknowns are answered in this file.

#### Stage 0 answers (2026-11-11)

**Native player.** "The player changes in one place" (above) is wrong. Per
band-frame coverage needs:

- a start time per layer (today every layer starts at sample 0);
- short and long blocks inside one layer (transition windows), or many short
  layers (the lazy player caps a channel at 8);
- a coverage flag of its own: `dead` is one code per layer, and noise_hz
  level-only bands count as live, so neither can say "the residual covers
  this band-frame";
- changes to the fixed 18-field header in `pinst_file.py` (:299, :331), the
  Voice reader (:531) and the lazy reader;
- a map from layer band-frames (linear bins, geomspace edges, block M) to the
  40 ERB noise bands and their 1024/512-sample frames;
- edits in five Python places (stream :123-126, :185-194; file :254-256;
  codec render and `_add_layers`) and both native players (Voice :657,
  :692-697, :847-856; Lazy :449, :628, :707-775). Lazy reads a noise row
  ahead of play, so the coverage for that row has to come before it in the
  stream.

The players also differ in ways that matter later:

- Both accept only 44.1 and 48 kHz. Python uses the module-global `pc.SR`.
- `TNS_BLOCK` is fixed at 44 samples.
- Native hard-codes 40 noise bands.
- Lazy reads PINST2 only; Voice reads PINST1 and PINST2.
- Phase is computed differently (remainder and chirp recurrences, against
  the cosine of a polynomial). They agree to rounding.
- The offline `xform_decode` noise-fills with `rng(11)`, which neither player
  does.

**hamorg and synth.** No commit gives a reason (07ef2f2 "except HamOrg",
9548d3f "all but hamorg and synth").

- **synth:** every region is a sfizz oscillator (`*saw`, `*sine`, `*noise`,
  `*square`, `*triangle`), and `inventory.py` skips `*`. There is nothing to
  bake. It stays out, and that is not a codec limit.
- **hamorg:** 549 mono WAVs, 48 kHz, 24-bit. Every region has
  `loop_continuous` with explicit loop points, and `offset_cc15=3000`. The
  file names carry no note name. Three things stop it today:
  1. `bake_library.py:98` allows 48 kHz only with a non-amp judge.
  2. Loop points pass through unchanged, but the codec has no phase
     continuity at loop_start/loop_end, so each pass of the loop can click.
     This is inferred, not heard.
  3. `--pitch name` finds no note, so it needs key-based pitch.

  Stage 4 covers all three. MUSIC_HANDOFF.md:108 says HamOrg may not ship,
  which is a licence question, not a codec one.

**Main menu crackle.** The cause is the encoder at note-on. Neither the
model's partials nor the player cause it.

- A decode of all 940 standard-bass notes against their WAVs (6 kHz
  high-pass, 5 ms windows):
  - 789 notes have a window more than 10 dB over the WAV.
  - In 275 of them that window is also within 60 dB of the note's peak.
  - Almost every worst window is the note's first 5 ms, 15-31 dB over the
    WAV.
  - Release, Hammer-On, Mute and Glissando_Tail lead; Sus_Long has none.
- In those first 5 ms the partials and the noise are silent: the partials
  start a quarter-window late, and the noise sits under the attack layer's
  time window. The attack layer is the only thing playing.
- At its 12 dB SNR target, the error in the first 3 ms is only 7 dB under
  the signal. For d#4_Release2 the first samples are 0.049, 0.047, 0.044
  where the WAV has -0.001, -0.003, -0.007. Out of silence that offset is a
  step, which is a click. The offline decode and the stream player agree, so
  the error is in the encoding.
- The same note coded at 24 dB SNR starts at -0.009; at 40 dB it starts at
  0.001.
- So this is pre-echo: a fixed SNR and a fixed block at a transient. It is
  what "transients per frame" and the need map are for, and it is fixed in
  stage 2, not patched here.
- Of the 35 song bursts:
  - The two loudest-looking ones (21.325 s and 29.910 s) did not come back
    in two fresh solo-bass renders, which were identical with and without
    the whole note in memory. They were not in the encoded notes.
  - 29.100 s comes back. It is the note-on pre-echo: the pinst high band
    arrives 5 ms before the WAV's.
  - The fresh render has 32 windows over +10 dB. The three biggest are pinst
    at -121 and -142 dBFS against WAV digital silence. The rest are
    -84 dBFS or quieter.

**Baseline** (PINST2 bake, the old chooser):

| Library | Notes | pinst | WAV | Ratio | Rate | Bake | Picked |
|---|---|---|---|---|---|---|---|
| standard-bass | 940 | 6.44 MB | 370 MB | 57x | 18.5 kbit/s | 5 cpu-min | 938 body, 2 mid |
| sm-drums | 3358 | 71.5 MB | 3617 MB | 51x | 41.9 kbit/s | 32 cpu-min | 2398 body, 960 mid |
| hamorg | 549 | not baked | | | | | |

- Song bursts (level-up-groovy, solo bass, fresh render): 32 windows over
  +10 dB, 3 over +20 dB.
- Per-note bursts, standard-bass: 789 notes, 275 audible.

### 1. Need map, analysis only

- Build the map and print it for the proof set. No encoder change yet.
- Check it against known cases without telling it the instrument: it must
  flag the 243 bass notes that were baked "mid" and crackled, the kick
  bodies, and the organ's key click; it must come out nearly empty on notes
  that are already fine.

Gate: every known failure is flagged and the fine notes are not. If the map
cannot separate them, the design is wrong and the plan is revised here,
before any encoder work.

#### Stage 1 result (2026-11-11): passed

`need_map.py`. The plain model (partials and noise as decoded, no residual,
no attack envelope) is compared with the source in the 40 ERB noise bands
every 128 samples. A band-frame is flagged when it is within 60 dB of the
note's loudest band-frame and the model is off by more than 6 dB in level or
8 dB in peakiness. Each band is measured with the shortest window that gives
it 16 bins.

Run on 1013 notes: all of standard-bass, 32 kicks, 18 organ notes (drawbars
1, 5, 9 at six keys) and the 23 old notes. Figures are p10/p50/p90 of the
share of audible band-frames flagged. "Attack" is the first 50 ms after the
onset; "cal" is the false-positive rate, a source that is the model itself
with another noise draw.

| Set | Notes | Whole note | Attack over 4 kHz | Body under 300 Hz | Cal |
|---|---|---|---|---|---|
| bass baked "mid" (crackled) | 242 | 1.0/2.9/8.9 | 29/66/89 | 0.3/2.3/6.9 | 0.0/0.2/0.7 |
| bass baked "body" | 697 | 7.9/22/46 | 68/97/100 | 1.5/20/44 | 0.0/0.6/2.3 |
| kicks | 32 | 60/70/77 | 93/100/100 | 57/64/74 | 1.8/2.2/2.8 |
| organ, drawbar 1/5/9 | 18 | 6-34 | 23-100 | 2-57 | 0.4-1.5 |
| old guitar sustains | 7 | 0.1-5.5 | 11-20 | 0.1-6.5 (e5: 45) | ≤0.5 |

- Every "mid" bass note is flagged in the attack's high bands: none under
  10%, the lowest 29%. The kick bodies and the organ's onset are flagged.
- The guitar sustains, which were fine, are nearly empty over the whole
  note. Their attacks are flagged 4-19%, which is the coded attack layer they
  already had.
- e5's body under 300 Hz is 45%. That note has almost nothing there, so a
  few band-frames are a large share.
- The map knows nothing of the instrument; no constant has a per-library
  value.
- One fix during the gate: the running mean could go a hair under zero, the
  log gave NaN and the note's map came out empty (g3_Sus_Down3, the kicks).
  It is now clipped at zero.

### 2. One encoder, Python reference

- Encoder: residual driven by the map, transients per frame.
- Reference decoder and block player (`pinst_file.py`, `pinst_stream.py`)
  updated to match. New magic; PINST2 files still load.
- Delete tiers, the chooser, `--judge`, and the import of settings from
  `run_prototype.py`.

Gate: size per library against the baseline is reported, and single-note A/B
clips from the proof set (WAV, old pinst, new pinst) go to the user. The user
is the only judge of sound.

#### Stage 2 result (2026-11-11): built, gate open (clips with the user)

`pinst_encode.py`, PINST3 in `pinst_file.py` / `pinst_stream.py`;
`bake_library.py` has one path (no tiers, no chooser, no `--judge`).

- Noise is hash noise: frame i is centred on sample i·512, and the seed is
  in the file. A layer frame f covers f·M−M/2 .. f·M+3M/2, and frame 0 has a
  start window (0, then 1, then the sine half), so a layer needs no junction
  crossfade.
- Around each transient (a 128-block 12 dB over the 8 before it) the noise
  frames are muted and short blocks carry everything. The noise comes back on
  its own window, so no step.
- The block player matches the offline render to 2e-13 on the 23 old notes.

| Library | Notes | PINST2 | PINST3 | kbit/s | cpu-min | need % p10/50/90 |
|---|---|---|---|---|---|---|
| standard-bass | 940 | 6.44 MB | 5.17 MB (−20%) | 18.5 → 14.8 | 4.6 → 24.5 | 2/12/39 |
| sm-drums | 3358 | 71.5 MB | 83.1 MB (+16%) | 41.9 → 48.6 | 32 → 237 | 5/13/26 |

No constant needed a per-library value. Waveform error against the source
(not a judge of sound, since noise is uncorrelated by design, but a pointer)
is worse on bass, median −27.3 → −22.9 dB, and peaks overshoot more, max
2.07× the source against 1.34×. Seen on e2_Hammer-On1, the cause: where the
partials miss part of a pitch move, the residual under a partial is a tone,
and the noise replaces it with band noise of equal energy. That doubles the
error and raises the crest. The need map compares whole-signal band levels,
so a residual 15 dB under a partial in the same band is not flagged. The
worst notes are fret noises (peak 2.07×) and Tom4 (14 dB more error).

### 3. Pitch from the audio

- Lock decided by fit. Delete `--pitch` and the kit-name test.

Gate: the proof set bakes with no switches; drums come out unlocked on their
own; pitched notes keep their lock.

### 4. Any rate, loops, the excluded libraries

- Sample rate as a parameter.
- Whatever stage 0 found blocking hamorg and synth.

Gate: hamorg bakes through the same path as the other two.

### 5. Native player

- The player in `sfpp_test` brought to the new reference and checked against
  it the way it is checked today.
- The user has uncommitted changes in `pinst_source.cpp`; this stage is
  agreed with them before it touches that file.

Gate: native and reference agree on the proof set.

### 6. Proof listen

- The three libraries re-baked, one song per library rendered WAV against
  pinst, sent as MP3.

Gate: the user accepts all three. Only then is the wider re-bake planned, as
its own decision.

## What goes away

Tiers, `AUTO_GAIN_DB`, the whole-note and attack-window scoring in the bake,
`--judge amp|dry|both`, `--pitch name|key|none`, the kit-name test, the single
onset, the fixed 200 ms attack layer, the 300 Hz low-band layer, the 1 ms
attack noise envelope, the 44.1/48 kHz asserts.

## What stays

Partial tracks and harmonic lock with phase steering, the ERB noise model,
the transform coder itself, mid/side, the hashed noise that makes players
agree, the frame-ordered layout, the store and score-driven prefetch.

## Risks

- **Size.** Coding wherever the model fails may cost more than today's two
  fixed places. Unknown until stage 1 prints the map; stage 2 reports it.
- **Bake time.** The map is one more analysis pass per note.
- **Thresholds becoming the new switches.** Covered by the rule for constants.
- **Re-listening.** Every library is eventually re-baked and has to be heard
  again. The proof set keeps that to three libraries until the design holds.

## Not in this plan

The wider re-bake, the engine-side prefetch and late-voice behaviour, and the
re-bake of other libraries' "mid" notes under the current chooser (superseded
if this plan goes ahead).
