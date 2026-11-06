shader_type canvas_item;
render_mode unshaded, blend_disabled;

// A spilled liquid for decal_surface.gd: Grease, Water, Blood, Acid.
// A lumpy pool over its cells with splashed droplets past its edge,
// darker where it's thick and deepest away from the edge; optional dome
// bubbles and glow, and a wet, darkened band of ground round its rim.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 thick_color : source_color = vec3(0.12, 0.08, 0.035);
uniform vec3 thin_color : source_color = vec3(0.42, 0.29, 0.1);
// Coverage at its thickest: below 1 the floor shows through.
uniform float alpha_max : hint_range(0.0, 1.0) = 0.88;
// How far the outline wanders off the cells' edge.
uniform float edge_wander = 0.5;
// Share of cells past the edge that hold a droplet.
uniform float droplets : hint_range(0.0, 1.0) = 0.4;
// How uneven the thickness is: 0 flat, 1 very lumpy.
uniform float lumpiness : hint_range(0.0, 1.0) = 0.45;
// Share of the pool dotted with domed bubbles, and their size in meters.
uniform float bubbles : hint_range(0.0, 1.0) = 0.0;
uniform float bubble_size_m = 0.12;
uniform vec3 glow_color : source_color = vec3(0.0);
// Crackling arcs in the glow (Electrified Water): thin bright lines that
// wander round the loop, so the pool flickers. 0 for none.
uniform float glow_arcs : hint_range(0.0, 1.0) = 0.0;
// The ground darkened round the pool where it soaked in: how dark, and
// what color the wet ground takes.
uniform float wet_rim : hint_range(0.0, 1.0) = 0.0;
uniform vec3 wet_color : source_color = vec3(0.02, 0.02, 0.02);

float bubble(vec2 uv) {
	if (bubbles <= 0.0) {
		return 0.0;
	}
	vec2 cell_p = meters(uv) / (bubble_size_m * 2.5);
	vec2 cell = floor(cell_p);
	vec2 centre = cell + 0.25 + 0.5 * vec2(hash(cell + 1.9), hash(cell + 7.3));
	float size = mix(0.15, 0.4, hash(cell + 4.4));
	float d = distance(cell_p, centre) / size;
	return step(hash(cell + 2.2), bubbles) * sqrt(max(0.0, 1.0 - d * d));
}

float film_height(vec2 uv) {
	vec2 m = meters(uv);
	float f = edge_field(uv, edge_wander);
	float pool = smoothstep(0.42, 0.58, f);
	// Splashed droplets just past the edge.
	vec2 cell_p = m * 1.7;
	vec2 cell = floor(cell_p);
	vec2 centre = cell + 0.3 + 0.4 * vec2(hash(cell), hash(cell + 3.7));
	float size = mix(0.07, 0.2, hash(cell + 9.1));
	float drop = 1.0 - smoothstep(size * 0.6, size, distance(cell_p, centre));
	drop *= step(hash(cell + 5.3), droplets) * step(0.15, f) * step(f, 0.42) * 0.6;
	float thick = max(pool, drop) * (1.0 - lumpiness + lumpiness * fbm(m * 1.1 + 7.0));
	thick *= 0.85 + 0.15 * smoothstep(0.0, 1.5, depth_m(uv));
	thick += bubble(uv) * pool * 0.5;
	return receded(thick, uv);
}

vec4 film_albedo(vec2 uv, float h) {
	vec3 color = mix(thin_color, thick_color, smoothstep(0.1, 0.65, h));
	float alpha = smoothstep(0.0, 0.22, h) * alpha_max;
	// Soaked a little past the pool's own ragged edge; it dries with it.
	float wet = smoothstep(0.22, 0.46, edge_field(uv, edge_wander * 1.3)) * wet_rim
			* (1.0 - smoothstep(0.3, 0.9, local_recede(uv)));
	float out_alpha = alpha + wet * (1.0 - alpha);
	vec3 out_color = (color * alpha + wet_color * wet * (1.0 - alpha)) / max(out_alpha, 0.0001);
	return vec4(out_color, out_alpha);
}

vec3 film_emission(vec2 uv, float h) {
	vec3 glow = glow_color * smoothstep(0.05, 0.5, h) * (0.6 + 0.4 * fbm(meters(uv) * 2.0));
	if (glow_arcs > 0.0) {
		// Where a drifting noise field crosses its middle; the drift
		// runs round a circle, so the loop's last picture meets its first.
		float turn = loop_phase * 6.2831853;
		float field = fbm(meters(uv) * 1.6 + vec2(cos(turn), sin(turn)) * 1.2);
		float arc = 1.0 - smoothstep(0.0, 0.035, abs(field - 0.5));
		glow += vec3(0.75, 0.88, 1.0) * arc * glow_arcs * 2.5 * smoothstep(0.05, 0.3, h);
	}
	return glow;
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
