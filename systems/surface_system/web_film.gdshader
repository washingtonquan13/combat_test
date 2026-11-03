shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Webbing for decal_surface.gd: one big web with smaller ones lapping
// its edge, each spokes plus a spiral of rings, over a gauzy sheet of
// stray strands. Silk lies flat, so it barely shows in the normal map.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 silk_color : source_color = vec3(0.9, 0.89, 0.84);
uniform float alpha_max : hint_range(0.0, 1.0) = 0.85;
uniform int spokes = 14;
// Meters between the spiral's rings.
uniform float ring_spacing_m = 0.22;
// Strand width in meters.
uniform float strand_m = 0.018;
// How thick the gauze between strands is.
uniform float gauze : hint_range(0.0, 1.0) = 0.35;

// One web centred at c, of radius `reach` (both in decal -1..1 space).
float web(vec2 p, vec2 c, float reach, float turn) {
	vec2 d = p - c;
	float r = length(d) * radius_m;
	float reach_m = reach * radius_m * spread;
	if (r > reach_m) {
		return 0.0;
	}
	float a = atan(d.y, d.x) + turn;
	// Spokes, a little uneven.
	float n = float(spokes);
	float spoke_a = (a / 6.2832) * n + hash(vec2(floor((a / 6.2832) * n), turn)) * 0.25;
	float spoke = 1.0 - smoothstep(0.0, strand_m * 1.2, abs(fract(spoke_a + 0.5) - 0.5) / n * 6.2832 * r);
	// Spiral rings: radius climbs one spacing per turn around.
	float ring_t = (r - (a / 6.2832) * ring_spacing_m) / ring_spacing_m;
	float ring = 1.0 - smoothstep(0.0, strand_m, abs(fract(ring_t + 0.5) - 0.5) * ring_spacing_m);
	// Sagging threads: break the spiral here and there.
	ring *= step(0.25, noise(vec2(a * 3.0, r * 2.0) + turn));
	// No spiral in the hub, threads thinning out toward the edge.
	ring *= smoothstep(0.08, 0.2, r);
	float fade = 1.0 - smoothstep(reach_m * 0.7, reach_m, r);
	return max(spoke, ring) * fade;
}

float film_height(vec2 p) {
	float strands = web(p, vec2(0.0), 0.72, seed);
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		float a = seed + fi * 2.1;
		vec2 c = vec2(cos(a), sin(a)) * (0.48 + 0.1 * hash(vec2(fi, seed)));
		strands = max(strands, web(p, c, 0.32 + 0.08 * hash(vec2(seed, fi)), a * 1.7) * 0.85);
	}
	// Gauze: wispy streaks of stray silk across the whole patch.
	vec2 m = p * radius_m;
	float wisp = smoothstep(0.5, 0.75, fbm(vec2(m.x * 2.5, m.y * 0.8) + seed)) * gauze;
	float body = lumpy_body(p, 0.8, 0.1);
	return receded(max(strands, wisp * body));
}

vec4 film_albedo(vec2 p, float h) {
	return vec4(silk_color, smoothstep(0.0, 0.5, h) * alpha_max);
}

vec3 film_emission(vec2 p, float h) {
	return vec3(0.0);
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
