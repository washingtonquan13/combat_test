shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Webbing for decal_surface.gd: webs strung across the patch, one to
// every couple of meters and lapping each other, each spokes plus a
// spiral of rings, over a gauzy sheet of stray strands, all cut to the
// patch's cells. Silk lies flat, so it barely shows in the normal map.

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
// Meters between webs.
uniform float web_spacing_m = 2.0;

// One web centred at c, of radius reach_m (world meters).
float web(vec2 m, vec2 c, float reach_m, float turn) {
	vec2 d = m - c;
	float r = length(d);
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

float film_height(vec2 uv) {
	vec2 m = meters(uv);
	// One web to a tile, somewhere in it; neighbours' webs reach in.
	vec2 tile = floor(m / web_spacing_m);
	float strands = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 t = tile + vec2(float(x), float(y));
			vec2 c = (t + 0.25 + 0.5 * vec2(hash(t + 0.7), hash(t + 3.1))) * web_spacing_m;
			float reach_m = web_spacing_m * mix(0.5, 0.7, hash(t + 8.3));
			strands = max(strands, web(m, c, reach_m, hash(t + 5.9) * 6.2832) * mix(0.8, 1.0, hash(t + 2.4)));
		}
	}
	// Gauze: wispy streaks of stray silk across the whole patch.
	float wisp = smoothstep(0.5, 0.75, fbm(vec2(m.x * 2.5, m.y * 0.8))) * gauze;
	return receded(max(strands, wisp) * body(uv, 0.3), uv);
}

vec4 film_albedo(vec2 uv, float h) {
	return vec4(silk_color, smoothstep(0.0, 0.5, h) * alpha_max);
}

vec3 film_emission(vec2 uv, float h) {
	return vec3(0.0);
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
