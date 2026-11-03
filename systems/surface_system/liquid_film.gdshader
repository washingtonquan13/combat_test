shader_type canvas_item;
render_mode unshaded, blend_disabled;

// A spilled liquid for decal_surface.gd: Grease, Water, Blood, Acid.
// A lumpy pool with splashed droplets past its edge, darker where it's
// thick; optional dome bubbles and glow.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 thick_color : source_color = vec3(0.12, 0.08, 0.035);
uniform vec3 thin_color : source_color = vec3(0.42, 0.29, 0.1);
// Coverage at its thickest: below 1 the floor shows through.
uniform float alpha_max : hint_range(0.0, 1.0) = 0.88;
// Where the outline sits (fraction of the decal) and how far it wanders.
uniform float edge_base = 0.75;
uniform float edge_wander = 0.15;
// Share of cells past the edge that hold a droplet.
uniform float droplets : hint_range(0.0, 1.0) = 0.4;
// How uneven the thickness is: 0 flat, 1 very lumpy.
uniform float lumpiness : hint_range(0.0, 1.0) = 0.45;
// Share of the pool dotted with domed bubbles, and their size in meters.
uniform float bubbles : hint_range(0.0, 1.0) = 0.0;
uniform float bubble_size_m = 0.12;
uniform vec3 glow_color : source_color = vec3(0.0);

float bubble(vec2 p) {
	if (bubbles <= 0.0) {
		return 0.0;
	}
	vec2 cell_p = p * radius_m / (bubble_size_m * 2.5) + seed * 1.3;
	vec2 cell = floor(cell_p);
	vec2 centre = cell + 0.25 + 0.5 * vec2(hash(cell + 1.9), hash(cell + 7.3));
	float size = mix(0.15, 0.4, hash(cell + 4.4));
	float d = distance(cell_p, centre) / size;
	return step(hash(cell + 2.2), bubbles) * sqrt(max(0.0, 1.0 - d * d));
}

float film_height(vec2 p) {
	vec2 m = p * radius_m;
	float r = length(p);
	float body = lumpy_body(p, edge_base, edge_wander);
	float edge = (edge_base + (fbm(m * 0.45 + seed) - 0.5) * edge_wander * 2.0) * spread;
	// Splashed droplets just past the edge, arriving as the spread ends.
	vec2 cell_p = m * 1.7 + seed;
	vec2 cell = floor(cell_p);
	vec2 centre = cell + 0.3 + 0.4 * vec2(hash(cell), hash(cell + 3.7));
	float size = mix(0.07, 0.2, hash(cell + 9.1));
	float drop = 1.0 - smoothstep(size * 0.6, size, distance(cell_p, centre));
	drop *= step(hash(cell + 5.3), droplets) * step(edge - 0.05, r) * step(r, edge + 0.12);
	drop *= 1.0 - smoothstep(0.9, 0.98, r);
	drop *= smoothstep(0.75, 1.0, spread) * 0.6;
	float thick = max(body, drop) * (1.0 - lumpiness + lumpiness * fbm(m * 1.1 + seed * 3.0));
	thick += bubble(p) * body * 0.5;
	return receded(thick);
}

vec4 film_albedo(vec2 p, float h) {
	vec3 color = mix(thin_color, thick_color, smoothstep(0.1, 0.65, h));
	return vec4(color, smoothstep(0.0, 0.22, h) * alpha_max);
}

vec3 film_emission(vec2 p, float h) {
	return glow_color * smoothstep(0.05, 0.5, h) * (0.6 + 0.4 * fbm(p * radius_m * 2.0 + seed));
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
