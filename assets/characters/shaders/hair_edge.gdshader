shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, shadows_disabled;

// The soft fringe of the hair cards: only what hair.gdshader cut away,
// blended over what is behind it.

#include "res://assets/characters/shaders/hair.gdshaderinc"

void fragment() {
	vec4 hair = hair_sample(UV);
	if (hair.a >= alpha_cut) {
		discard;
	}
	// Where the card is see-through its colour means nothing; use the
	// hair's averaged colour there.
	ALBEDO = mix(hair_base(UV), hair.rgb, clamp(hair.a / alpha_cut, 0.0, 1.0));
	ALPHA = min(hair_fringe(UV, hair.a), alpha_cut);
	ROUGHNESS = roughness;
	SPECULAR = specular_level;
	ANISOTROPY = anisotropy;
	ANISOTROPY_FLOW = strand_direction;
	BACKLIGHT = hair.rgb * translucency;
}
