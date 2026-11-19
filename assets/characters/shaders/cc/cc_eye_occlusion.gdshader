shader_type spatial;
// Character Creator RLEyeOcclusion: the soft shadow the lids and lashes
// throw onto the eye, multiplied over what is behind the shell. Procedural;
// CC exports no maps for it. Built for Godot from CC's JSON parameters.
//
// The shell's UVs (checked on the CC bases): u runs from the outer corner
// (0) to the inner corner (1), v from the top lid (0) to the bottom (1).
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
uniform vec3 shadow2_color : source_color = vec3(0.24, 0.082, 0.043);
uniform float shadow2_strength = 0.45;
uniform float shadow2_top = 0.15;
uniform float shadow2_top_range = 1.0;
// Softness of each edge: the higher, the tighter the falloff.
uniform float top_contrast = 2.0;
uniform float bottom_contrast = 1.4;
uniform float outer_contrast = 3.2;
uniform float blur_strength = 0.53;
// Where the tear duct sits along u, and how sharply the inner corner
// shadow stops at it.
uniform float tear_duct_position = 0.8;
uniform float tear_duct_contrast = 0.45;
// Metres the shell is pushed off the eye, so it never sinks into it.
uniform float expand = 0.0003;

void vertex() {
	VERTEX += NORMAL * expand;
}

// 1 at the edge, falling to 0 a distance `range` in.
float edge(float dist, float range, float contrast) {
	float t = clamp(1.0 - dist / max(range, 0.001), 0.0, 1.0);
	return pow(t, mix(contrast, 1.0, blur_strength));
}

void fragment() {
	float u = UV.x;
	float v = UV.y;
	// Arcs: the top shadow is heaviest mid-lid, fading toward the corners.
	float mid = 1.0 - pow(abs(u * 2.0 - 1.0), 2.0);
	float top = edge(v, shadow_top_range * 0.5, top_contrast) * mix(1.0, mid, clamp(shadow_top_arc * 0.5, 0.0, 1.0));
	float bottom = edge(1.0 - v, shadow_bottom_range * 0.5, bottom_contrast) * mix(1.0, mid, clamp(shadow_bottom_arc * 0.5, 0.0, 1.0));
	float outer = edge(u, shadow_outer_range * 0.5, outer_contrast);
	float inner = edge(1.0 - u, shadow_inner_range * 0.5, 1.0)
			* smoothstep(tear_duct_position - tear_duct_contrast * 0.5, tear_duct_position + 0.05, u);
	float m1 = clamp(top * shadow_top + bottom * shadow_bottom + outer * shadow_outer + inner * shadow_inner, 0.0, 1.0);
	float m2 = clamp(edge(v, shadow2_top_range * 0.5, top_contrast) * shadow2_top, 0.0, 1.0);
	// The scale-up keeps CC's small strengths visible as a multiply.
	vec3 f = mix(vec3(1.0), shadow_color, clamp(m1 * shadow_strength * 5.0, 0.0, 1.0));
	f *= mix(vec3(1.0), shadow2_color, clamp(m2 * shadow2_strength * 5.0, 0.0, 1.0));
	ALBEDO = f;
}
