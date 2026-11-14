shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// The solid core of the hair cards: cut out at alpha_cut, so it writes depth,
// sorts correctly and casts a clean shadow (a dithered one speckles the face).
// hair_edge.gdshader, as this material's next pass, adds the soft fringe.

#include "res://assets/characters/shaders/hair.gdshaderinc"

void fragment() {
	vec4 hair = hair_sample(UV);
	ALBEDO = hair.rgb;
	ALPHA = hair.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	ROUGHNESS = roughness;
	SPECULAR = specular_level;
	ANISOTROPY = anisotropy;
	ANISOTROPY_FLOW = strand_direction;
	BACKLIGHT = hair.rgb * translucency;
}
