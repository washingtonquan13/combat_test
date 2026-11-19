shader_type spatial;
// Character Creator RLHair: hair cards coloured from a root-to-tip gradient
// and two dyes, with a strand-wise (anisotropic) shine. Built for Godot from
// CC's JSON parameters and its maps.
//
// This is the solid pass: card texels at or above `cutoff` opacity draw
// opaque, write depth and cast shadows, so the hair sorts against itself and
// everything else. cc_hair_fringe.gdshader is chained after it (next_pass) to
// blend the thin strand ends this pass cuts away.
//
// The maps: Root (0 root, 1 tip), ID (a grey per strand, used to pick which
// strands take each dye), Flow (the strand direction, tangent space RG),
// blend_multiply (strand-wise darkening), ORM (AO, roughness).
render_mode cull_disabled;

#include "cc_hair.gdshaderinc"

uniform float cutoff = 0.5;

void fragment() {
	HAIR_SURFACE(UV);
	ALPHA = hair_alpha(UV);
	ALPHA_SCISSOR_THRESHOLD = cutoff;
}
