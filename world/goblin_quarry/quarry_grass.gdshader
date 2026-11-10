shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;

// Grass tufts: a clump is a few cards fanned from one root, each showing a
// cell of the tuft atlas, so the thin blades are texture that mips down
// smoothly rather than geometry thinner than a pixel. The atlas carries only
// each blade's shading; its colour is the ground's own grass layer under the
// clump, graded as the ground shader grades it, so grass grows out of the
// ground instead of sitting on it as a separate carpet. Tips are lighter,
// and straw in dry patches. INSTANCE color is per-clump variation.
//
// Cards carry an upward normal so a clump lights like the ground under it.
// UV is the point in the card; UV2.x is 0 at the root and 1 at the top,
// UV2.y a random number per card. With distance a share of the cards fold
// away, and past fade_start the clump sinks into the ground.
//
// INSTANCE_CUSTOM picks the atlas cells: r the first row, g how many rows,
// b a fixed column, or 4 for any. The same shader draws the meadow plants
// (clover, weeds, flowers, stalks) with `painted` on: their atlas is in full
// colour and keeps it, tinted only by INSTANCE color.

uniform sampler2D tufts : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D ground_grass : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ground_soil : source_color, filter_linear_mipmap, repeat_enable;
uniform bool painted = false;
uniform float grass_tile = 0.33;
uniform vec3 dry_tip = vec3(0.58, 0.54, 0.27);
uniform float wind = 0.05;
uniform float thin_start = 12.0;
uniform float fade_start = 30.0;
uniform float fade_end = 44.0;

varying float tip;
varying vec3 base;
varying vec3 top;
varying vec2 cell;

float lum(vec3 c) {
	return dot(c, vec3(0.33));
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	tip = UV2.x;
	vec3 origin = MODEL_MATRIX[3].xyz;

	// Each card of a clump shows a different cell of its rows of the atlas.
	float cells = INSTANCE_CUSTOM.g * 4.0;
	float c = mod(floor(hash(origin.xz) * cells) + floor(UV2.y * 5.0) * 3.0, cells);
	float col = INSTANCE_CUSTOM.b < 3.5 ? INSTANCE_CUSTOM.b : mod(c, 4.0);
	cell = vec2(col, INSTANCE_CUSTOM.r + floor(c / 4.0));

	vec3 g = textureLod(ground_grass, origin.xz * grass_tile, 5.0).rgb;
	g = mix(vec3(lum(g)), g, 1.2) * vec3(0.5, 0.68, 0.36);
	float macro = textureLod(ground_soil, origin.xz * 0.031, 0.0).g;
	g *= mix(0.86, 1.14, smoothstep(0.08, 0.34, macro));
	float dry = smoothstep(0.38, 0.62, textureLod(ground_soil, origin.xz * 0.013 + vec2(0.37, 0.71), 0.0).r);
	base = g * COLOR.rgb;
	top = mix(g * vec3(1.3, 1.35, 1.1), dry_tip, dry * 0.4) * COLOR.rgb;

	float dist = length((VIEW_MATRIX * vec4(origin, 1.0)).xyz);
	float keep = mix(1.0, 0.6, smoothstep(thin_start, fade_start, dist));
	float alive = clamp((keep - UV2.y) / 0.08, 0.0, 1.0);
	float sink = 1.0 - smoothstep(fade_start, fade_end, dist);
	VERTEX *= alive * sink;

	// One slow sway and a broad gust rolling across the field. Slow and low
	// in frequency on purpose: this motion has no motion vectors, so fast
	// wind smears under TAA.
	float gust = 0.6 + 0.4 * sin(TIME * 0.31 + origin.x * 0.06 - origin.z * 0.045);
	float sway = sin(TIME * 0.8 + origin.x * 0.23 + origin.z * 0.17) * gust;
	float bend = tip * tip;
	VERTEX.x += sway * wind * bend;
	VERTEX.z += sway * wind * 0.6 * bend;
	NORMAL = (inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
}

void fragment() {
	// Inset so a cell's mips don't pick up its neighbour's blades.
	vec2 uv = (cell + clamp(UV, vec2(0.01), vec2(0.99))) * 0.25;
	vec4 t = texture(tufts, uv);
	// Godot turns the normal over on a card's back face; both faces should
	// light like the ground, so turn it back.
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	// The atlas shading is kept shallow: deep shade at the roots reads as dark
	// spots on the ground from the game's high camera.
	if (painted) {
		ALBEDO = t.rgb * COLOR.rgb * mix(0.8, 1.0, tip);
	} else {
		ALBEDO = mix(base, top, tip) * (0.5 + 0.75 * t.rgb);
	}
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	AO = mix(0.9, 1.0, tip);
	AO_LIGHT_AFFECT = 0.3;
	BACKLIGHT = (painted ? ALBEDO : top) * 0.35 * tip;
}
