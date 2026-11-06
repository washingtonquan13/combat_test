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
// Charge crackling over the whole pool (Electrified Water), 0 for none:
// a web of thin jagged filaments - the edges of cells about
// crackle_cell_m across, each edge blinking on and off by itself - and
// brighter ridges wandering through it, both strongest where a slow
// drifting "presence" gathers. World-space, so it runs on unbroken
// across a merged pool.
uniform float crackle : hint_range(0.0, 1.0) = 0.0;
uniform float crackle_cell_m = 0.45;
// A filament's width, meters.
uniform float crackle_width_m = 0.025;
// Share of the web's edges lit in any one picture.
uniform float crackle_lit : hint_range(0.0, 1.0) = 0.5;
uniform vec3 crackle_color : source_color = vec3(0.75, 0.88, 1.0);
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

// The cells' web at p (in cells), its points circling as `turn` goes
// round: x the distance to the nearest edge, in cells; y a number of
// that edge's own (the same on both its sides), to blink it by.
vec2 web(vec2 p, float turn) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 near_r = vec2(8.0);
	vec2 near_c = vec2(0.0);
	float near_d = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 c = i + vec2(float(x), float(y));
			vec2 o = vec2(hash(c), hash(c + 19.19));
			vec2 r = vec2(float(x), float(y)) + 0.5 + 0.38 * sin(turn + 6.2831853 * o) - f;
			float d = dot(r, r);
			if (d < near_d) {
				near_d = d;
				near_r = r;
				near_c = c;
			}
		}
	}
	// The edge with each neighbour is halfway between them: the nearest
	// of those is the edge here.
	float edge = 8.0;
	vec2 other_c = near_c;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			vec2 c = i + vec2(float(x), float(y));
			if (c == near_c) {
				continue;
			}
			vec2 o = vec2(hash(c), hash(c + 19.19));
			vec2 r = vec2(float(x), float(y)) + 0.5 + 0.38 * sin(turn + 6.2831853 * o) - f;
			float d = dot(0.5 * (near_r + r), normalize(r - near_r));
			if (d < edge) {
				edge = d;
				other_c = c;
			}
		}
	}
	vec2 lo = min(near_c, other_c);
	vec2 hi = max(near_c, other_c);
	return vec2(edge, hash(lo * 1.31 + hi * 0.77 + 3.3));
}

vec3 crackle_glow(vec2 m) {
	float turn = loop_phase * 6.2831853;
	vec2 drift = vec2(cos(turn), sin(turn));
	// Each picture of the loop its own blink, the loop's pictures being
	// whole steps round it.
	float picture = floor(loop_phase * 97.0 + 0.5);
	// Jagged, not the cells' straight edges: the web is bent by noise.
	vec2 bend = vec2(fbm(m * 2.7 + 3.0), fbm(m * 2.7 + 41.0)) - 0.5;
	vec2 fine = vec2(noise(m * 11.0 + 5.0), noise(m * 11.0 + 71.0)) - 0.5;
	vec2 p = m / crackle_cell_m + bend * 1.1 + fine * 0.18;
	vec2 e = web(p, turn);
	float edge_m = e.x * crackle_cell_m;
	float line = 1.0 - smoothstep(crackle_width_m * 0.35, crackle_width_m, edge_m);
	float halo = exp(-edge_m / (crackle_width_m * 1.2));
	float lit = step(hash(vec2(e.y * 61.7, picture)), crackle_lit);
	// Where the charge gathers, drifting slowly over the pool.
	float presence = smoothstep(0.38, 0.62, fbm(m * 0.5 + drift * 0.7 + 13.0));
	float web_glow = (line + halo * 0.2) * lit * mix(0.3, 1.0, presence);
	// Brighter ridges wandering through, where a field crosses its middle.
	float field = fbm(m * 1.3 + bend * 1.6 + drift * 0.5);
	float ridge = pow(1.0 - clamp(abs(field - 0.5) * 16.0, 0.0, 1.0), 6.0) * presence;
	ridge *= step(0.35, hash(vec2(floor(field * 23.0), picture + 0.5)));
	return crackle_color * (web_glow + ridge * 1.4);
}

vec3 film_emission(vec2 uv, float h) {
	vec3 glow = glow_color * smoothstep(0.05, 0.5, h) * (0.6 + 0.4 * fbm(meters(uv) * 2.0));
	if (crackle > 0.0) {
		glow += crackle_glow(meters(uv)) * crackle * smoothstep(0.05, 0.3, h);
	}
	return glow;
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
