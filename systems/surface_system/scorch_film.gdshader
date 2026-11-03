shader_type canvas_item;
render_mode unshaded, blend_disabled;

// The burnt ground under a fire for decal_surface.gd: soot, charred
// black at the centre, with ember veins that glow (the emission pass).

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 char_color : source_color = vec3(0.025, 0.02, 0.018);
uniform vec3 soot_color : source_color = vec3(0.16, 0.13, 0.11);
uniform float alpha_max : hint_range(0.0, 1.0) = 0.92;
uniform vec3 ember_color : source_color = vec3(1.0, 0.32, 0.05);
// Ember vein cells per meter.
uniform float vein_density = 2.2;

float veins(vec2 p) {
	vec2 q = p * radius_m * vein_density + seed;
	// Ridged noise: thin bright lines where the noise crosses its middle.
	float n = abs(fbm(q) - 0.5) * 2.0;
	float n2 = abs(fbm(q * 2.1 + 3.3) - 0.5) * 2.0;
	return (1.0 - smoothstep(0.0, 0.08, n)) * 0.8 + (1.0 - smoothstep(0.0, 0.05, n2)) * 0.4;
}

float film_height(vec2 p) {
	float body = lumpy_body(p, 0.78, 0.15);
	float r = length(p);
	return receded(body * (0.4 + 0.6 * (1.0 - smoothstep(0.0, 0.8, r)) * (0.6 + 0.4 * fbm(p * radius_m * 1.3 + seed))));
}

vec4 film_albedo(vec2 p, float h) {
	vec3 color = mix(soot_color, char_color, smoothstep(0.35, 0.7, h));
	return vec4(color, smoothstep(0.0, 0.3, h) * alpha_max);
}

vec3 film_emission(vec2 p, float h) {
	// Embers only where it burnt deep.
	return ember_color * veins(p) * smoothstep(0.45, 0.75, h);
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
