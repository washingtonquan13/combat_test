shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never;

// The hair's soft edges: only what the core (groom.gdshader) cut away,
// blended at its coverage over what is behind. It writes no depth, so its
// cards don't hide each other's edges, and casts no shadow, which the core
// casts. See groom.gdshaderinc.

#define GROOM_EDGES
#include "res://assets/characters/shaders/groom.gdshaderinc"
