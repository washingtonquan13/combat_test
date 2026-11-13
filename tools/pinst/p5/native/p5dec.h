/* PINST5 decoder: the one decoder source, a C99 port of p5/decode.py and the
   decode halves it calls (AGENT_PLAN.md, wave 2, agent F).

   This interface is fixed by the integrator. The player (sfpp_test
   native/pinst, agent H) and the bench (ctypes on p5dec.dll) use only what is
   declared here; a change is reported, not made.

   Output matches decode.py to within 1e-6 (max abs, every sample) on every
   bench note. */
#ifndef P5DEC_H
#define P5DEC_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(P5DEC_DLL)
#define P5_API __declspec(dllexport)
#else
#define P5_API
#endif

typedef struct p5_note p5_note;   /* a parsed file: read-only once built, shared by any number of voices */
typedef struct p5_voice p5_voice; /* one read position in a note */

/* --- setup: may allocate; call off the audio thread --- */

/* Parse a .pinst5 file. The bytes must outlive the note (it may point into
   them). NULL, and *err set to a static string if err is not NULL, on
   anything malformed. */
P5_API p5_note* p5_parse(const uint8_t* data, size_t size, const char** err);
P5_API void p5_note_free(p5_note* note);
P5_API int p5_rate(const p5_note* note);
P5_API int p5_channels(const p5_note* note);       /* 1, or 2 (left, right) */
P5_API int64_t p5_frames(const p5_note* note);
P5_API size_t p5_note_memory(const p5_note* note);  /* heap bytes the note holds beyond the file */

/* Everything the voice will ever need is allocated here. */
P5_API p5_voice* p5_voice_new(const p5_note* note);
P5_API void p5_voice_free(p5_voice* v);
P5_API size_t p5_voice_memory(const p5_note* note); /* heap bytes one p5_voice_new takes */

/* --- real time: no allocation, no locks, bounded time --- */

/* The next p5_render starts at note frame `frame` (any value; frames outside
   [0, frames) are zeros). Costs at most what one block's decode costs. A new
   voice starts at frame 0. */
P5_API void p5_seek(p5_voice* v, int64_t frame);

/* The next k note frames, channels interleaved (k * channels floats). */
P5_API void p5_render(p5_voice* v, float* out, int k);

#ifdef __cplusplus
}
#endif
#endif
