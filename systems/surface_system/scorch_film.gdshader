shader_type canvas_item;
render_mode unshaded, blend_disabled;

// The ground under a fire for decal_surface.gd. The ground is char: dark,
// flaky crust whose relief catches the light, with pale ash flecks on it.
// While it burns, embers glow in a narrow cut of that crust - thin cracks
// and scattered flecks, a fifth of it at most - pulsing in place on
// loop_phase rather than crawling. Its edge crumbles into loose pieces.
// As it goes out the embers fade, then the char recedes.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 char_color : source_color = vec3(0.03, 0.025, 0.022);
uniform vec3 soot_color : source_color = vec3(0.11, 0.09, 0.08);
uniform vec3 ash_color : source_color = vec3(0.32, 0.3, 0.28);
uniform float alpha_max : hint_range(0.0, 1.0) = 0.95;
uniform vec3 deep_color : source_color = vec3(0.35, 0.02, 0.0);
uniform vec3 ember_color : source_color = vec3(1.0, 0.22, 0.03);
// The hottest flecks; kept orange, so only a few read as near white.
uniform vec3 hot_color : source_color = vec3(1.0, 0.55, 0.18);
// Crust flakes per meter.
uniform float flake_scale = 7.0;
// Crack cells per meter.
uniform float crack_density = 1.6;
// How far in from the outline the crust breaks into pieces, in meters.
uniform float crumble_m = 0.9;
// How bright the embers burn.
uniform float ember_strength = 1.3;

float flakes(vec2 m) {
	return fbm(m * flake_scale) * 0.6 + noise(m * flake_scale * 2.7 + 5.1) * 0.4;
}

// Toward the outline the crust only survives where its noise is high,
// so the edge breaks into scattered pieces instead of a smooth line.
float crumble(vec2 uv) {
	float edge = 1.0 - smoothstep(0.0, crumble_m, depth_m(uv));
	float cut = edge * 0.75;
	return smoothstep(cut, cut + 0.08, fbm(meters(uv) * 3.2 + 1.7));
}

float film_height(vec2 uv) {
	vec2 m = meters(uv);
	float base = body(uv, 0.4) * crumble(uv);
	return receded(base * (0.55 + 0.45 * flakes(m)), uv);
}

vec4 film_albedo(vec2 uv, float h) {
	vec2 m = meters(uv);
	vec3 color = mix(soot_color, char_color, smoothstep(0.3, 0.6, h));
	// Pale ash on the tops of the flakes.
	float ash = smoothstep(0.72, 0.8, flakes(m + 9.3)) * smoothstep(0.3, 0.5, h);
	color = mix(color, ash_color, ash * 0.6);
	return vec4(color, smoothstep(0.0, 0.25, h) * alpha_max);
}

vec3 film_emission(vec2 uv, float h) {
	vec2 m = meters(uv);
	float recede = local_recede(uv);
	// Thin cracks where ridged noise crosses its middle, and flecks where
	// fine noise peaks: both a narrow cut, so most of the char stays dark.
	float ridge = abs(fbm(m * crack_density) - 0.5) * 2.0;
	float cracks = 1.0 - smoothstep(0.0, 0.035, ridge);
	float flecks = smoothstep(0.62, 0.7, flakes(m + 3.7));
	// Each spot pulses on its own phase, once or twice per loop, so the
	// embers breathe where they are and come back to their start.
	float turn = loop_phase * 6.2831853;
	float phase = fbm(m * 1.4 + 2.2) * 12.566;
	float pulse = 0.55 + 0.45 * sin(turn + phase) * sin(turn * 2.0 + phase * 0.7);
	// Dimmer in the crumbling rim, where less is left to burn.
	float rim = smoothstep(0.0, crumble_m, depth_m(uv));
	float glow = max(cracks * 0.9, flecks) * pulse * (0.45 + 0.55 * rim) * smoothstep(0.2, 0.5, h);
	float burning = 1.0 - smoothstep(0.0, 0.45, recede);
	// Once the flames are out a few embers linger, dimming as it recedes.
	float lingering = smoothstep(0.1, 0.5, recede) * (1.0 - smoothstep(0.5, 0.95, recede)) * 0.5;
	glow *= max(burning, lingering);
	vec3 color = mix(deep_color, ember_color, smoothstep(0.1, 0.5, glow));
	color = mix(color, hot_color, smoothstep(0.75, 1.0, glow * pulse));
	return color * glow * ember_strength;
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
