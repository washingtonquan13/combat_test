# Side discussion: audio formats and an SFZ-specific codec (2026-10-07)

Forked from the main session while the decode benchmark was running. Nothing was
changed in the project; this file is the only output.

## State of the decode benchmark (interrupted)
- Harness: `<main scratchpad>/codec/bench.c` (main session 25f15385 scratchpad), built
  as `bench.exe` with gcc -O2 against sfizz's own st_audiofile sources (dr_wav,
  dr_flac, stb_vorbis, WavPack with x64 asm) copied into `codec/src`.
  - Link needs the 8.3 short path: `GCC_EXEC_PREFIX=<short mingw64>/lib/gcc/` (space in
    "Quan Washington" breaks ld's default-manifest.o lookup).
- Modes: `enc_wv` (lossless or hybrid bits/sample), `enc_qoa` (own spec QOA
  encoder), `dec` / `dec_qoa` (timed, warm cache, best of 3), `snr`, `dump_qoa`.
- QOA encoder/decoder verified BIT-EXACT against ffmpeg's independent qoa decoder.
- Test set: samples/clavinet, 240 files, 24-bit stereo 44.1k, ~410 MB.
- Encode pass (wav24, wav16, flac, wv lossless, wv hybrid 3.2/4.0 bps, qoa, ogg q5/q8
  into `codec/d/*`) was cut off by the session ending; may be partial. Re-run it, then
  the dec and snr passes.
- Finding: sfizz's st_audiofile already reads WAV, FLAC, AIFF, Ogg Vorbis, MP3 and
  WavPack. It does NOT read Opus or QOA.

## Opus: not a good fit
- Not supported by sfizz (would need libopus/opusfile + a new reader).
- Always 48 kHz internally: 44.1k libraries get resampled, so every SFZ loop point,
  offset, end and head/tail split (all in source samples) would be wrong.
- ~312-sample priming (pre-skip) must be handled exactly on every file and seek.
- No RAM saving: sfizz decodes preloaded heads to float32 at load regardless of format;
  lossy only saves disk and streaming bandwidth.
- Better lossy options if wanted: hybrid WavPack (already supported, native rate,
  sample-accurate) or QOA (cheapest decode, needs a reader).

## Custom codec: where the real levers are
"Without quality loss" means lossless, which has an entropy floor: FLAC/WavPack are
already within a few % of the best; a custom predictor might win ~5-10%, not 3-10x.

Bigger wins that need no new codec:
1. RAM: keep preloaded heads at native bit depth (int16/int24) instead of float32,
   convert on read. 33-50% head-RAM cut, lossless. (Compressed heads in RAM would push
   decode to note-on on the audio thread: avoid.)
2. Load time: dominated by ~5.4k file opens/seeks, not decode. One pack file per
   library fixes it (cf. the deferred HDD plan: head WAV + JSON index).
3. Disk: WavPack lossless tails, already readable by sfizz, decode on background
   streaming threads.

## SFZ-specific format sketch (if built)
| Part | Design | Fixes |
|---|---|---|
| Container | One pack per library, index keyed by the .sfz sample paths | ~5.4k opens/seeks -> one |
| Heads | Contiguous, uncompressed, native bit depth; one sequential read | Load time, RAM |
| Tails | Lossless, fixed blocks (~4096 frames) + seek table; decoded only by streaming threads | Disk size; note-on never decodes |
| Timing | Native sample rate, no priming, exact loop points | Opus/Vorbis risks |
| Preprocess | Strip padded bits, collapse identical-channel stereo to mono, trim silent tails | Free size |
| Optional | Code velocity layers / round-robins as residual vs a neighbour | Possibly large, UNPROVEN (phase/timing drift) |

Most benefit is from the container and head layout, not compression math; a pack of
WavPack tails likely gets ~90% of it. Correctness is mechanically checkable
(bit-exact round trip), so risk is low except for the cross-layer idea.

## Suggested order
1. Measure: finish the benchmark (lossless ratio, decode speed); count padded-bit and
   duplicate-channel files; test cross-layer similarity on one library.
2. Native-bit-depth heads (small change, biggest lossless RAM win).
3. Pack format (heads uncompressed + compressed tails).
4. Cross-layer prediction only if step 1 shows it pays.

Full transcript zip: `D:\session-export-1791381696800.zip` (includes all parent history).
