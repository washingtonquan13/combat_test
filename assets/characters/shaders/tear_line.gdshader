shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, shadows_disabled;

// The wet meniscus where the lid meets the eyeball, on the tear line strip
// tools/characters/eye_shells.py lays along the lid's waterline: nearly
// clear, smooth and bright in its highlights, so the lid's edge reads as
// wet rather than cut. UV.y runs from tucked against the lid (0) onto the
// eye (1); COLOR.r is 1 at the upper lid and 0 at the lower, which holds
// most of the water.

uniform vec3 color : source_color = vec3(0.80, 0.60, 0.58);
uniform float opacity : hint_range(0.0, 1.0) = 0.25;
uniform float upper_opacity : hint_range(0.0, 1.0) = 0.2;
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float specular : hint_range(0.0, 1.0) = 0.9;

void fragment() {
	ALBEDO = color;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	ALPHA = opacity * mix(1.0, upper_opacity, COLOR.r) * sin(3.14159 * clamp(UV.y, 0.0, 1.0));
}
