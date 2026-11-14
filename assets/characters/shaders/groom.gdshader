shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// The hair's core: the strands drawn solid where they mostly cover, the
// rest cut away for groom_edges.gdshader (groom.tres's next pass) to draw
// soft. See groom.gdshaderinc.

#include "res://assets/characters/shaders/groom.gdshaderinc"
