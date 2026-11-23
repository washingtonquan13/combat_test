# Baked libraries with Opus

Status: plan only, 2026-11-12. Nothing is built. Nothing here starts until the
user agrees.

This is a separate road from `ONE_STANDARD_PLAN.md` (PINST3) and `SMS_PLAN.md`
(PINST4). It does not change or remove either. Their code stays in git as it
is.

## Why

The goal, in the user's words: take the live SFZ player and make its
instruments bakeable, so they need much less RAM, much less disk and much less
load time, without giving up quality. And the bake must be generic: any SFZ
library goes in, with no work per library.

Every pinst format so far tried to *model* the sound (partials, noise, modes,
atoms). A model has opinions about what a sound is, so each kind of sound it
got wrong needed its own fix. That is where the per-instrument patches came
from.

A perceptual codec (a compressor that drops only what hearing cannot detect,
like MP3 but newer) has no opinion about what the sound is. A kick, a guitar
and an organ all go through the same encoder with the same setting. There is
nothing to patch per instrument because the encoder does not know instruments
exist.

Opus is the codec: it is the best open one at every bitrate, it is free to
ship (BSD licence), and its decoder is small and fast.

What this road gives up, said plainly:

- The files will be bigger than PINST2's on tonal libraries. Earlier
  projection: at 48 kbit/s, guitar + drums came to 147 MB as Opus against
  99 MB as PINST2. At a bitrate nobody can tell from the original it will be
  more than that. It will still be far below WAV.
- It is not "store how to make the sound". It stores the sound, compressed.

## The standard

1. One encoder path. Every sample of every library goes through it.
2. One quality setting for everything: a bitrate per channel, chosen once by
   the user's ear (stage 1).
3. No tiers, no chooser, no per-library flag, no rule that names a kind of
   sound.
4. Rule for constants: if any library seems to need its own value of anything,
   work stops and that is reported as a finding. If the guitar needs a higher
   bitrate than the drums, the one bitrate goes up for all of them.
5. The user is the only judge of sound. Numbers pick what to listen to; they
   never pass a stage on their own.

## What a baked library is

"Bake" here means three things done once, offline, per library:

1. **Samples.** Each sample is encoded to Opus at the one bitrate.
2. **Pack.** All of a library's encoded samples go into one file with an index
   at the front (name, where it starts, how long, sample rate, channels, loop
   points). One file to open instead of thousands.
3. **SFZ.** The instrument definition is rewritten to point at the baked
   samples. Whether it is also stored pre-read (so the game skips parsing
   text) is decided from a measurement in stage 0, not assumed.

At run time sfizz stays the engine. A baked sample is a sample source inside
sfizz, the same seat a `.pinst` note sits in today.

## Where the RAM and load savings come from

Not from the codec. They come from holding nothing ahead of time:

- **The store** (already built, `sfpp_test/native/pinst/pinst_store.*`): the
  score knows which notes are coming, so each note is asked for shortly before
  it sounds, made on a worker thread, and dropped when the voice ends. Nothing
  of any note is unpacked at load.
- **The pack is memory-mapped**: the file's bytes are read by the system only
  where touched and can be dropped by the system at any time. They are not
  counted as the game's own memory.
- **The existing sfizz patches** stay: regions the score can never play are
  dropped, region tables are slimmer, one copy of a file is shared.

Measured before, same run, sealed-ward as the game plays it: WAV 971 MB peak,
PINST2 with the store 775 MB. An earlier pair gave a different WAV figure, so
stage 0 re-measures before anything is claimed.

What this plan does not shrink: the region tables themselves (about 100 MB for
the guitar's 14,235 regions). That is sfizz's own bookkeeping.

## What is already known (measured 2026-11-12, this PC)

Using the Opus encoder inside the Python sound library already installed
(`soundfile` 0.14.0, libsndfile 1.2.2), so no download was needed:

- It only accepts 48 kHz input. 44.1 kHz is refused.
- Bitrate is set by one number and is linear: 6 to 256 kbit/s per channel.
- Decoded output lines up with the input to the sample (the encoder's
  312-frame lead-in is trimmed correctly).
- Decoding one stereo voice ran at roughly 350 to 960 times real time on a
  synthetic test signal. Rough reading: 150 voices at once would cost a few
  tenths of one CPU core. PINST4 measured 80 to 180 times real time per voice.
  Real numbers come in stage 0.

Not known yet: real sizes per library at each bitrate, and which bitrate
passes by ear. A size run was started and stopped before it reported.

## Decisions the plan makes (say if you disagree)

- **44.1 kHz libraries are resampled to 48 kHz at bake.** Opus only works at
  48 kHz. The SFZ's frame-counted values (`offset`, `end`, `loop_start`,
  `loop_end`) are scaled to match. The alternative, labelling 44.1 kHz audio
  as 48 kHz, throws away everything above about 18.4 kHz, so it is not used.
- **Looped and reversed notes are decoded whole** when asked for, and sfizz
  loops them exactly as it loops a WAV. No seeking inside the codec at a loop
  point. Cost: that one note sits unpacked in memory while it plays.
- **Notes that start part-way in** (`offset`) start decoding 80 ms early and
  throw that part away. Opus needs that run-up to settle.
- **Raw Opus packets in the pack, not Ogg files.** Only the small core decoder
  (libopus) is needed in the game, and jumping to a point is a table lookup.
  The Python baker gets the packets by unwrapping what `soundfile` writes, so
  the bake needs no new tool either.

## Two things that need the user's word before work starts

1. **Download libopus** (the decoder source, BSD licence, from xiph.org) into
   `sfpp_test/native`, the way the LZMA code was brought in. Stages 0 to 2
   need no download; stage 3 does.
2. The 44.1 to 48 kHz decision above.

## Stages

Each stage ends at a gate. A stage that fails its gate stops the plan there
for a talk; it is not patched around.

### Stage 0: baseline and sizes (no native work, no download)

- Re-measure the three songs (groovy, low-end, sealed-ward) as WAV and as
  PINST2 with the store, in one sitting: peak RAM, CPU, load time. These are
  the numbers every later stage is compared against.
- Split the load time: how much is reading SFZ text, how much is opening
  files, how much is the rest.
- Size table for every library: WAV, FLAC (lossless, sfizz reads it today, a
  free reference row), Opus at 32 / 48 / 64 / 96 / 128 / 192 kbit/s per
  channel, PINST2.
- Decode speed per voice on real samples.

Gate: the user reads the table. If Opus at the likely bitrates is not a clear
win on disk over FLAC, or the baseline shows RAM and load are already where
the user wants them, we talk before going on.

### Stage 1: pick the bitrate by ear (no native work)

- Take one real song passage per hard case, rendered through the real effects:
  the DI guitar through the amp (the amp raises very quiet content, so it is
  the hardest case), drums with cymbals, the organ, the bass.
- For each rung of the ladder, round-trip only the samples through Opus in
  Python, write them back as WAV, and render the passage with the normal
  player. So the only thing that differs between clips is the codec.
- Send the clips blind (original hidden among them).

Gate: the user names the lowest rung they cannot tell from the original on any
passage. That number is the standard. If no rung passes on the guitar, stop
and report; do not give the guitar its own setting.

### Stage 2: file layout and Python reference

- Write down the pack layout: index, packet table, raw packets.
- Baker: `bake_library.py` gains an Opus path that reuses its SFZ reading and
  rewriting. Resampling, scaling of frame values, lead-in trimmed.
- Python reference decoder that reads a note back out of a pack.

Gate: every sample of two libraries (one 44.1 kHz, one 48 kHz with loops)
reads back from the pack identical to decoding it on its own, and starts on
the right sample.

### Stage 3: native decoder behind the store (needs libopus)

- `pinst::Player` is tied to PINST4 today. Split out the small set of calls
  the store uses, so the store can hold either kind of player and picks by the
  file's first bytes. PINST4 keeps working unchanged.
- Opus player: opens a note from the mapped pack, decodes ahead into the same
  sliding buffer the voice already reads.
- sfizz side: the file pool finds a sample by name in the library's pack. The
  dormant heads-pack patch already has an index lookup in the right place;
  reuse it if it fits.

Gate: native output matches the Python reference on the stage 2 notes, and
the existing PINST4 check (`make_reference.py --check`) still passes 21/21.

### Stage 4: offsets, reversed notes, loops

- Starts part-way in, reversed notes, `loop_continuous`, `loop_sustain`,
  `loop_count`.
- Loop seams: measure the jump at each seam against the source, as SMS stage 7
  did, on the tonewheel organ.

Gate: offsets land on the right sample; seams are no worse than the source by
the number; then the user listens to the organ.

### Stage 5: load and RAM

- Whole libraries baked. The three songs measured again, same sitting as a
  fresh WAV run: peak RAM, CPU, load time, late notes, starved voices.
- If stage 0 showed SFZ text reading is a real share of load, add the pre-read
  SFZ here and measure again. If it did not, skip it.

Gate: the user reads the numbers against stage 0 and says whether they count
as "significant".

### Stage 6: proof songs

Whole songs, baked against WAV, sent to the user.

Gate: the user's ear. This is where stage 9 of the last plan landed at
"70 to 80%"; the bar here is "can't tell".

### Stage 7: bake everything, switch the game

- Suite bake, with the time it took.
- The game's DLL and registries move to the baked libraries. One line per
  registry to switch back.

Gate: the game plays its music from the baked libraries and the user is happy
with it.

## What stays

- sfizz as the engine, and the whole existing patch series.
- The store and score-driven fetching.
- `bake_library.py`'s SFZ handling, `--registry` A/B renders, `amp.py`.
- The WAV libraries, as the source every bake starts from.
- All pinst code and plans, untouched. The game keeps playing PINST2 until
  stage 7.

## Risks

- **The amp.** High gain makes very quiet content audible. A codec's error
  follows the signal's level, which helps, but nobody has measured it here. It
  may push the one bitrate high. Stage 1 finds out before any native work.
- **Transposed samples.** A codec hides its error under sounds at the pitch it
  was encoded at. A sample played well below its recorded pitch moves that
  error to where it is easier to hear. Stage 1 must include a passage that
  does this if any library does.
- **Loop seams.** The decoded wave is not the original wave, so a seam that
  was smooth can gain a small step. Stage 4 measures it.
- **CPU.** Decoding costs more than reading a WAV. The rough figure above says
  it is affordable; stage 0 says for real.
- **Cold disk.** A mapped pack is read from disk on first touch. A note asked
  for with little warning on a cold cache can start late. The store already
  counts late notes; stage 5 reports them.
- **Two kinds of player in the store.** The split in stage 3 touches code
  PINST4 uses. Its 21-note check guards that.
- **Size.** If the passing bitrate is high, some libraries may land near FLAC.
  Stage 0's table shows that before anything is built.

## Not in this plan

- Any synthesis or modelling of sound.
- Changes to PINST2, PINST3 or PINST4.
- Any per-library or per-instrument tuning.
- Recipes, hard-disk load work, alert-based preloading.
