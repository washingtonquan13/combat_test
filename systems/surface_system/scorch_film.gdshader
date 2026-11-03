shader_type canvas_item;
render_mode unshaded, blend_disabled;

// The ground under a fire for decal_surface.gd: soot, charred black
// away from the patch's edge. While it burns, the char glows - hot, boiling under dark
// crust plates, looping on glow_phase - and as it goes out the glow dies
// back to ember veins, then those fade and the char recedes.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 char_color : source_color = vec3(0.025, 0.02, 0.018);
uniform vec3 soot_color : source_color = vec3(0.16, 0.13, 0.11);
uniform float alpha_max : hint_range(0.0, 1.0) = 0.92;
uniform vec3 ember_color : source_color = vec3(1.0, 0.32, 0.05);
uniform vec3 deep_color : source_color = vec3(0.45, 0.04, 0.0);
uniform vec3 hot_color : source_color = vec3(1.0, 0.78, 0.35);
// Boiling and crust detail per meter.
uniform float boil_scale = 1.4;
uniform float crust_scale = 2.2;
// Ember vein cells per meter.
uniform float vein_density = 2.2;

float veins(vec2 uv) {
	vec2 q = meters(uv) * vein_density;
	// Ridged noise: thin bright lines where the noise crosses its middle.
	float n = abs(fbm(q) - 0.5) * 2.0;
	float n2 = abs(fbm(q * 2.1 + 3.3) - 0.5) * 2.0;
	return (1.0 - smoothstep(0.0, 0.08, n)) * 0.8 + (1.0 - smoothstep(0.0, 0.05, n2)) * 0.4;
}

float film_height(vec2 uv) {
	float inner = smoothstep(0.0, 1.5, depth_m(uv));
	return receded(body(uv, 0.4) * (0.4 + 0.6 * inner * (0.6 + 0.4 * fbm(meters(uv) * 1.3))), uv);
}

vec4 film_albedo(vec2 uv, float h) {
	vec3 color = mix(soot_color, char_color, smoothstep(0.35, 0.7, h));
	return vec4(color, smoothstep(0.0, 0.3, h) * alpha_max);
}

vec3 film_emission(vec2 uv, float h) {
	vec2 m = meters(uv);
	float recede = local_recede(uv);
	// The warp circles once per loop, so the boil comes back to its start.
	float turn = glow_phase * 6.2831853;
	vec2 loop = vec2(cos(turn), sin(turn)) * 0.5;
	vec2 warp = vec2(fbm(m * 0.9 + loop), fbm(m * 0.9 - loop + 7.3));
	float heat = fbm(m * boil_scale + warp * 1.6);
	float crust = smoothstep(0.45, 0.62, fbm(m * crust_scale + warp * 0.8 + 2.0));
	// Burning goes out first; the veins linger a little as embers.
	float burning = smoothstep(0.2, 0.55, h) * (1.0 - smoothstep(0.0, 0.45, recede));
	float glow = burning * mix(1.0, 0.12, crust) * smoothstep(0.25, 0.7, heat + (h - 0.5) * 0.4);
	vec3 color = mix(deep_color, ember_color, smoothstep(0.15, 0.55, glow));
	color = mix(color, hot_color, smoothstep(0.6, 0.95, glow));
	float embers = veins(uv) * smoothstep(0.45, 0.75, h) * 0.6 * (1.0 - smoothstep(0.3, 0.9, recede));
	return max(color * glow, ember_color * embers);
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
