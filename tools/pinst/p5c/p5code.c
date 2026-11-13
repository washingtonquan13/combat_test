/* PINST5 C encoder: freeing the shared structs (owner: the integrator). */
#include "p5code.h"

#include <stdlib.h>
#include <string.h>

void p5_buf_free(P5Buf *b) {
    if (!b) return;
    free(b->p);
    b->p = NULL;
    b->n = 0;
}

void p5_tracks_free(P5Tracks *t) {
    int64_t i;
    if (!t) return;
    for (i = 0; i < t->ntracks; i++) {
        free(t->tracks[i].f);
        free(t->tracks[i].a);
        free(t->tracks[i].ph);
    }
    free(t->tracks);
    t->tracks = NULL;
    t->ntracks = 0;
}

void p5_sine_free(P5Sine *s) {
    int i;
    if (!s) return;
    for (i = 0; i < P5S_NSTREAMS; i++) p5_buf_free(&s->s[i]);
}

void p5_layer_free(P5Layer *L) {
    if (!L) return;
    free(L->sc);
    free(L->q);
    free(L->dq);
    L->sc = L->q = L->dq = NULL;
}

void p5_channel_free(P5Channel *c) {
    int64_t i;
    if (!c) return;
    if (c->sines) {
        p5_sine_free(c->sines);
        free(c->sines);
    }
    for (i = 0; i < c->nlayers; i++) p5_layer_free(&c->layers[i]);
    free(c->layers);
    memset(c, 0, sizeof(*c));
}

void p5_note_free(P5Note *note) {
    int64_t i;
    if (!note) return;
    for (i = 0; i < note->nch && i < 2; i++) p5_channel_free(&note->ch[i]);
    note->nch = 0;
}
