shader_type canvas_item;
render_mode unshaded, blend_disabled;

// A sheet of ice for decal_surface.gd: pale and glassy, frosted white
// toward its rim, split by cracks that read in the normal map too.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 ice_color : source_color = vec3(0.62, 0.8, 0.9);
uniform vec3 frost_color : source_color = vec3(0.92, 0.96, 1.0);
uniform float alpha_max : hint_range(0.0, 1.0) = 0.5;
// How far the outline wanders off the cells' edge.
uniform float edge_wander = 0.3;
// Crack cells per meter, and how wide a crack is (fraction of a cell).
uniform float crack_density = 1.2;
uniform float crack_width = 0.025;

// Distance to the nearest Voronoi cell wall at q: 0 on a crack.
float crack_distance(vec2 q) {
	vec2 cell = floor(q);
	vec2 f = fract(q);
	float d1 = 8.0;
	float d2 = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec2 point = o + vec2(hash(cell + o), hash(cell + o + 5.17));
			float d = length(point - f);
			if (d < d1) {
				d2 = d1;
				d1 = d;
			} else if (d < d2) {
				d2 = d;
			}
		}
	}
	return d2 - d1;
}

float crack(vec2 uv) {
	vec2 q = meters(uv) * crack_density;
	// Wobble the walls so they read as fractures, not tiles.
	q += (vec2(fbm(q * 1.7), fbm(q * 1.7 + 4.1)) - 0.5) * 0.35;
	return 1.0 - smoothstep(crack_width * 0.4, crack_width, crack_distance(q));
}

float film_height(vec2 uv) {
	float sheet_body = body(uv, edge_wander);
	float sheet = sheet_body * (0.85 + 0.15 * fbm(meters(uv) * 0.8));
	// Cracks are grooves in the sheet.
	sheet -= crack(uv) * 0.25 * sheet_body;
	return receded(max(sheet, 0.0), uv);
}

vec4 film_albedo(vec2 uv, float h) {
	vec2 m = meters(uv);
	// Frost: whiter toward the rim and in drifts across the sheet.
	float rim = 1.0 - smoothstep(0.0, 0.6, depth_m(uv));
	float frost = rim * 0.6 + smoothstep(0.55, 0.8, fbm(m * 1.4 + 3.0)) * 0.5;
	vec3 color = mix(ice_color, frost_color, clamp(frost, 0.0, 1.0));
	color = mix(color, frost_color, crack(uv) * 0.7);
	float alpha = smoothstep(0.0, 0.15, h) * mix(alpha_max, 1.0, clamp(frost, 0.0, 1.0) * 0.6);
	return vec4(color, alpha);
}

vec3 film_emission(vec2 uv, float h) {
	return vec3(0.0);
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
