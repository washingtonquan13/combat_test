shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;

// Grass tufts: a clump is a few cards fanned from one root, each showing a
// cell of the tuft atlas, so the thin blades are texture that mips down
// smoothly rather than geometry thinner than a pixel. The atlas carries only
// each blade's shading; its colour is the ground's own grass layer under the
// clump, graded as the ground shader grades it, so grass grows out of the
// ground instead of sitting on it as a separate carpet. The upper blades
// turn a fresher green, deeper in lush patches and warmer in sunny ones, and
// straw in dry patches. INSTANCE color is per-clump variation.
//
// Card normals point up at the root, so a clump's base lights exactly like
// the ground under it, and tip outward toward the top like a dome over the
// clump, so each clump shades as a mound: lit on the sunward side, darker
// on the far side. Roots take the ground's own colour and only the upper
// blade carries the atlas shading, so a card's base never draws a line.
// UV is the point in the card; UV2.x is 0 at the root and 1 at the top,
// UV2.y a random number per card. With distance a share of the cards fold
// away, and past fade_start the clump sinks into the ground. Where units
// walk, the clump is pressed flat and springs back after they leave.
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
// Upper blades: a fresh green, bluer and deeper in lush patches, warmer in
// sunny ones. The roots keep the ground's colour.
uniform vec3 fresh = vec3(0.31, 0.5, 0.12);
uniform vec3 lush = vec3(0.22, 0.41, 0.12);
uniform vec3 sunny = vec3(0.42, 0.54, 0.13);
// Inside a clump, close to the camera, the lower blades stand in each
// other's shade. Kept to near the camera: from the game's height deep root
// shade reads as dark spots on the ground.
uniform float near_end = 14.0;
uniform float wind = 0.05;
uniform float thin_start = 12.0;
uniform float fade_start = 30.0;
uniform float fade_end = 44.0;
// Where units have stood (world/grass_trample.gd): per texel, the time it
// was last trodden. Fresh grass lies flat, pushed out from the middle of
// the trodden patch, and stands again over `trample_recover` seconds once
// the mark is `trample_hold` seconds old.
global uniform sampler2D grass_trample : filter_linear, repeat_disable;
global uniform vec4 grass_trample_rect;
global uniform float grass_trample_now;
uniform float trample_hold = 2.0;
uniform float trample_recover = 6.0;

varying float tip;
varying vec3 base;
varying vec3 top;
varying vec2 cell;
varying float near;

float lum(vec3 c) {
	return dot(c, vec3(0.33));
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float trodden(vec2 xz) {
	vec2 uv = (xz - grass_trample_rect.xy) / grass_trample_rect.zw;
	float age = grass_trample_now - textureLod(grass_trample, uv, 0.0).r;
	return 1.0 - smoothstep(trample_hold, trample_hold + trample_recover, age);
}

void vertex() {
	tip = UV2.x;
	vec3 origin = MODEL_MATRIX[3].xyz;

	// Each card of a clump shows a different cell of its rows of the atlas.
	float cells = INSTANCE_CUSTOM.g * 4.0;
	float c = mod(floor(hash(origin.xz) * cells) + floor(UV2.y * 5.0) * 3.0, cells);
	float col = INSTANCE_CUSTOM.b < 3.5 ? INSTANCE_CUSTOM.b : mod(c, 4.0);
	cell = vec2(col, INSTANCE_CUSTOM.r + floor(c / 4.0));

	// The ground shader's grass layer, at the mip it mostly shows.
	vec3 g = textureLod(ground_grass, origin.xz * grass_tile, 7.0).rgb;
	g = mix(vec3(lum(g)), g, 1.3) * vec3(0.3, 0.5, 0.22);
	float macro = textureLod(ground_soil, origin.xz * 0.031, 0.0).g;
	g *= mix(0.86, 1.14, smoothstep(0.08, 0.34, macro));
	float dry = smoothstep(0.38, 0.62, textureLod(ground_soil, origin.xz * 0.013 + vec2(0.37, 0.71), 0.0).r);
	base = g * COLOR.rgb;
	float l = textureLod(ground_soil, origin.xz * 0.019 + vec2(0.61, 0.13), 0.0).b;
	vec3 green = mix(lush, fresh, smoothstep(0.2, 0.45, l));
	green = mix(green, sunny, smoothstep(0.45, 0.7, l));
	// The per-clump tint rides on top, a little stronger than on the roots.
	green *= 1.0 + (COLOR.rgb - 1.0) * 1.5;
	top = mix(green * mix(0.9, 1.1, smoothstep(0.08, 0.34, macro)), dry_tip, dry * 0.4) * 0.8;

	float dist = length((VIEW_MATRIX * vec4(origin, 1.0)).xyz);
	near = 1.0 - smoothstep(near_end * 0.4, near_end, dist);
	float keep = mix(1.0, 0.6, smoothstep(thin_start, fade_start, dist));
	float alive = clamp((keep - UV2.y) / 0.08, 0.0, 1.0);
	float sink = 1.0 - smoothstep(fade_start, fade_end, dist);
	VERTEX *= alive * sink;

	// Trodden grass folds over about its root, away from the middle of the
	// trodden patch (downhill on the mark), so a path parts the grass.
	float pressed = 0.0;
	if (grass_trample_rect.z > 0.0) {
		pressed = trodden(origin.xz);
		if (pressed > 0.001) {
			vec2 slope = vec2(trodden(origin.xz + vec2(0.35, 0.0)), trodden(origin.xz + vec2(0.0, 0.35))) - pressed;
			float h = hash(origin.xz) * 6.2832;
			vec2 away = length(slope) > 0.02 ? -normalize(slope) : vec2(cos(h), sin(h));
			mat3 to_world = mat3(MODEL_MATRIX);
			vec3 w = to_world * VERTEX;
			float up = max(w.y, 0.0);
			float angle = pressed * 1.25 * (0.85 + 0.3 * UV2.y);
			w.y = up * cos(angle);
			w.xz += away * up * sin(angle);
			VERTEX = inverse(to_world) * w;
		}
	}

	// One slow sway and a broad gust rolling across the field. Slow and low
	// in frequency on purpose: this motion has no motion vectors, so fast
	// wind smears under TAA.
	float gust = 0.6 + 0.4 * sin(TIME * 0.31 + origin.x * 0.06 - origin.z * 0.045);
	float sway = sin(TIME * 0.8 + origin.x * 0.23 + origin.z * 0.17) * gust;
	float bend = tip * tip * (1.0 - pressed * 0.8);
	VERTEX.x += sway * wind * bend;
	VERTEX.z += sway * wind * 0.6 * bend;
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
		ALBEDO = mix(base, top, smoothstep(0.0, 0.7, tip)) * mix(vec3(1.0), mix(0.55 + 0.6 * t.rgb, 0.25 + 0.95 * t.rgb, near), smoothstep(0.0, 0.5, tip));
		ALBEDO *= mix(1.0, mix(0.45, 1.0, smoothstep(0.0, 0.65, tip)), near);
	}
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	AO = mix(0.9, 1.0, tip);
	AO_LIGHT_AFFECT = 0.3;
	// Light through a blade comes out a deeper, yellower green.
	BACKLIGHT = (painted ? ALBEDO : top * vec3(1.0, 1.0, 0.45)) * 0.35 * tip;
}
