shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Draws the Grease film for grease_surface.gd: one pass as the decal's
// albedo (color, alpha = coverage), the other as its normal map. Both
// passes share film(), so the bumps sit exactly where the film is.

uniform bool normal_pass = false;
uniform float seed = 0.0;
// The decal's radius in meters: noise is sampled in meters, so a big
// patch has the same size of detail as a small one.
uniform float radius_m = 3.0;
// 0 nothing yet, 1 fully spread.
uniform float spread = 1.0;
// 0 whole, 1 gone. Thin film goes first.
uniform float recede = 0.0;
uniform vec3 thick_color : source_color = vec3(0.12, 0.08, 0.035);
uniform vec3 thin_color : source_color = vec3(0.42, 0.29, 0.1);
uniform float bumpiness = 0.08;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		sum += noise(p) * amp;
		p = p * 2.03 + vec2(17.3, 9.1);
		amp *= 0.5;
	}
	return sum;
}

// Film thickness at p (-1..1 across the decal), 0 where there is none.
float film(vec2 p) {
	vec2 m = p * radius_m;
	float r = length(p);
	// A lumpy outline wandering about 0.75 of the decal (the cast radius,
	// as grease.tscn sizes it), leaving room past it for droplets.
	float edge = (0.75 + (fbm(m * 0.45 + seed) - 0.5) * 0.3) * spread;
	float body = 1.0 - smoothstep(edge - 0.07, edge, r);
	// Splashed droplets just past the edge, arriving as the spread ends.
	vec2 cell_p = m * 1.7 + seed;
	vec2 cell = floor(cell_p);
	vec2 centre = cell + 0.3 + 0.4 * vec2(hash(cell), hash(cell + 3.7));
	float size = mix(0.07, 0.2, hash(cell + 9.1));
	float drop = 1.0 - smoothstep(size * 0.6, size, distance(cell_p, centre));
	drop *= step(hash(cell + 5.3), 0.4) * step(edge - 0.05, r) * step(r, edge + 0.12);
	drop *= 1.0 - smoothstep(0.9, 0.98, r);
	drop *= smoothstep(0.75, 1.0, spread) * 0.6;
	float thick = max(body, drop) * (0.55 + 0.45 * fbm(m * 1.1 + seed * 3.0));
	float cut = recede * 1.05;
	return thick * smoothstep(cut, cut + 0.12, thick);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float h = film(p);
	if (!normal_pass) {
		vec3 color = mix(thin_color, thick_color, smoothstep(0.1, 0.65, h));
		COLOR = vec4(color, smoothstep(0.0, 0.22, h) * 0.88);
	} else {
		// Fine ripples on top of the thickness, for the gloss to catch.
		float e = SCREEN_PIXEL_SIZE.x * 3.0;
		vec2 m = p * radius_m * 3.0;
		float step_m = e * radius_m * 3.0;
		float ripple_x = (fbm(m + vec2(step_m, 0.0)) - fbm(m - vec2(step_m, 0.0))) * 0.25;
		float ripple_y = (fbm(m + vec2(0.0, step_m)) - fbm(m - vec2(0.0, step_m))) * 0.25;
		float dx = (film(p + vec2(e, 0.0)) - film(p - vec2(e, 0.0)) + ripple_x * h) / (2.0 * e * radius_m);
		float dy = (film(p + vec2(0.0, e)) - film(p - vec2(0.0, e)) + ripple_y * h) / (2.0 * e * radius_m);
		vec3 n = normalize(vec3(-dx * bumpiness, dy * bumpiness, 1.0));
		COLOR = vec4(n * 0.5 + 0.5, 1.0);
	}
}
