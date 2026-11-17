shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

// The shadow the lid and lashes cast on the eye, which the eye's own
// shading misses: drawn over the eyeball by the occlusion strip that
// tools/characters/eye_shells.py lays along the lid's waterline, as a
// multiply on what is behind it. UV.y runs from under the lid (0) inward
// (1); COLOR.r is 1 at the upper lid and 0 at the lower, whose shadow is
// lighter.

uniform float strength : hint_range(0.0, 1.0) = 0.9;
uniform float lower_strength : hint_range(0.0, 1.0) = 0.5;
// How fast the shadow fades inward: higher keeps it closer to the lid.
uniform float falloff : hint_range(0.5, 6.0) = 1.3;
uniform vec3 tint : source_color = vec3(0.38, 0.30, 0.29);

void fragment() {
	float amount = strength * mix(lower_strength, 1.0, COLOR.r) * pow(1.0 - clamp(UV.y, 0.0, 1.0), falloff);
	ALBEDO = mix(vec3(1.0), tint, amount);
}
