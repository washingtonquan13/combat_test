shader_type canvas_item;
render_mode unshaded, blend_disabled;

// The ground under a fire for decal_surface.gd. While it burns the
// ground itself is a carpet of flame - tongues crawling across it on
// loop_phase, gathered brightest in a band just inside its ragged rim,
// dark char showing only in the gaps. As it goes out the flame dies back
// to ember veins over the char, then those fade and the char recedes.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 char_color : source_color = vec3(0.025, 0.02, 0.018);
uniform vec3 soot_color : source_color = vec3(0.16, 0.13, 0.11);
uniform float alpha_max : hint_range(0.0, 1.0) = 0.92;
uniform vec3 ember_color : source_color = vec3(1.0, 0.32, 0.05);
uniform vec3 deep_color : source_color = vec3(0.45, 0.04, 0.0);
uniform vec3 hot_color : source_color = vec3(1.0, 0.78, 0.35);
// The white-yellow of the hottest tongues.
uniform vec3 core_color : source_color = vec3(1.0, 0.95, 0.75);
// Flame tongues per meter.
uniform float flame_scale = 1.8;
// How much brighter the rim burns than the middle.
uniform float rim_boost = 0.25;
// How far in from the outline the rim band reaches, in meters.
uniform float rim_width_m = 0.9;
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
	// The warps circle once per loop, so the flames come back to their
	// start; two layers turning opposite ways crawl rather than slide.
	float turn = loop_phase * 6.2831853;
	vec2 loop = vec2(cos(turn), sin(turn));
	vec2 warp = vec2(fbm(m * 0.8 + loop * 0.7), fbm(m * 0.8 - loop * 0.7 + 7.3));
	float tongues = fbm(m * flame_scale + warp * 2.2);
	float licks = fbm(m * flame_scale * 2.6 - warp * 1.4 + loop.yx * 0.9 + 4.1);
	// The rim band: brightest just inside the ragged outline.
	float rim = 1.0 - smoothstep(0.0, rim_width_m, depth_m(uv) + (fbm(m * 2.3 + loop * 0.5) - 0.5) * 0.6);
	float burning = smoothstep(0.05, 0.35, h) * (1.0 - smoothstep(0.0, 0.45, recede));
	float heat = tongues * 0.7 + licks * 0.45 + rim * rim_boost - 0.42;
	float glow = burning * smoothstep(0.05, 0.6, heat);
	vec3 color = mix(deep_color, ember_color, smoothstep(0.1, 0.45, glow));
	color = mix(color, hot_color, smoothstep(0.45, 0.75, glow));
	color = mix(color, core_color, smoothstep(0.88, 1.0, glow));
	// The veins linger a little as embers once the flames are out.
	float embers = veins(uv) * smoothstep(0.45, 0.75, h) * 0.6 * smoothstep(0.1, 0.5, recede) * (1.0 - smoothstep(0.5, 0.95, recede));
	return max(color * glow, ember_color * embers);
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
