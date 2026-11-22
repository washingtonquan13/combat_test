shader_type spatial;
// Character Creator RLEyeOcclusion: the soft shadow the lids and lashes
// throw onto the eye, multiplied over what is behind the shell. Procedural;
// CC exports no maps for it. Built for Godot from CC's JSON parameters.
//
// The shell's UVs (checked on the CC bases): u runs from the outer corner
// (0) to the inner corner (1), v from the top lid (0) to the bottom (1).
//
// Each side has a start and a range: the shadow is full at the lid and gone
// once you are `start + range * (1 - start)` in from it. The four sides
// multiply into one clear window in the middle of the eye; everything
// outside that window is shadow.
render_mode blend_mul, unshaded, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 shadow_color : source_color = vec3(0.33, 0.094, 0.055);
uniform float shadow_strength = 0.2;
uniform float shadow_top = 0.27;
uniform float shadow_top_range = 1.0;
uniform float shadow_top_arc = 1.0;
uniform float shadow_bottom = 0.05;
uniform float shadow_bottom_range = 0.3;
uniform float shadow_bottom_arc = 2.0;
uniform float shadow_inner = 0.25;
uniform float shadow_inner_range = 0.5;
uniform float shadow_outer = 0.2;
uniform float shadow_outer_range = 0.5;
// A second, wider shadow under the top lid only.
uniform float shadow2_strength = 0.45;
uniform float shadow2_top = 0.15;
uniform float shadow2_top_range = 1.0;
// Past this point along u the shadow fades out over the tear duct.
uniform float tear_duct_position = 0.8;
uniform float tear_duct_width = 0.5;
// Sharpens the whole shadow: higher keeps it closer to the lids.
// Falloff of the shade. Reallusion's 4.0 suits a path tracer that also casts
// the real lid shadow; here the shell is the only lid shadow, so it is softer.
uniform float hardness = 3.0;
uniform float bottom_shadow_weight = 0.3;
// The shell stands in for the lid's cast shadow, so the upper shadow is stronger.
uniform float lid_shadow_boost = 1.2;
// Metres the shell is pushed off the eye, so it never sinks into it.
uniform float expand = 0.0003;

void vertex() {
	VERTEX += NORMAL * expand;
}

// 0 at the lid until `start`, 1 once clear of its shadow.
float clear_of(float dist, float start, float range) {
	float end = start + range * (1.0 - start);
	return clamp((dist - start) / max(end - start, 0.001), 0.0, 1.0);
}

void fragment() {
	float u = UV.x;
	float v = UV.y;
	float sides = clear_of(1.0 - u, shadow_inner, shadow_inner_range)
			* clear_of(u, shadow_outer, shadow_outer_range)
			* pow(clear_of(v, shadow_top, shadow_top_range), shadow_top_arc);
	float bottom = pow(clear_of(1.0 - v, shadow_bottom, shadow_bottom_range), shadow_bottom_arc);
	// The lower lid is wet and catches light, so its shade is much the weaker.
	float window = sides * mix(1.0, bottom, bottom_shadow_weight);
	// CC's strengths are perceptual: the cube root is what the shadow uses.
	float s1 = (1.0 - window) * pow(shadow_strength, 1.0 / 3.0);
	float s2 = (1.0 - clear_of(v, shadow2_top, shadow2_top_range)) * min(pow(shadow2_strength, 1.0 / 3.0) * lid_shadow_boost, 1.0);
	float duct_end = tear_duct_position + (1.0 - tear_duct_position) * tear_duct_width;
	float duct = 1.0 - clamp((u - tear_duct_position) / max(duct_end - tear_duct_position, 0.001), 0.0, 1.0);
	float shade = pow(clamp(max(s1, s2), 0.0, 1.0) * duct, hardness);
	ALBEDO = mix(vec3(1.0), shadow_color * 0.25, shade);
}
