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
// Card normals point up at the root and tip outward toward the top like a
// dome over the clump (the mesh's own normals). normal_dome blends them
// toward straight up: at 0 every card lights exactly like the ground under
// it, as BG3's grass does, so a field reads as one lit surface; at 1 each
// clump shades as a mound, which from the game's high camera is speckle.
// Roots take the ground's own colour and only the upper blade carries the
// atlas shading, so a card's base never draws a line.
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
// The valley's relief and shape maps, as the ground reads them
// (quarry_ground.gdshader, tools/quarry/terrain_relief.py). A clump takes the
// light of the ground's swell under it, is shaded where the valley closes
// off the sky, and grows deeper green in a field's dips and paler on its
// rises. All three amounts at 0 leave the grass as it was.
uniform sampler2D terrain_relief : filter_linear_mipmap, repeat_disable;
uniform sampler2D terrain_masks : filter_linear_mipmap, repeat_disable;
uniform vec4 relief_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float relief_amount = 0.0;
uniform float occlusion_amount = 0.0;
uniform float shape_paint = 0.0;
uniform float grass_tile = 0.33;
// 0: normals straight up (BG3). 1: the mesh's dome.
uniform float normal_dome : hint_range(0.0, 1.0) = 0.25;
uniform vec3 dry_tip = vec3(0.58, 0.54, 0.27);
// Upper blades: a fresh green, bluer and deeper in lush patches, warmer in
// sunny ones. The roots keep the ground's colour.
uniform vec3 fresh = vec3(0.26, 0.4, 0.14);
uniform vec3 lush = vec3(0.19, 0.33, 0.13);
uniform vec3 sunny = vec3(0.35, 0.43, 0.15);
// Inside a clump, close to the camera, the lower blades stand in each
// other's shade. Kept to near the camera: from the game's height deep root
// shade reads as dark spots on the ground.
uniform float near_end = 14.0;
uniform float wind = 0.05;
uniform float thin_start = 12.0;
uniform float fade_start = 30.0;
uniform float fade_end = 44.0;
varying float tip;
varying vec3 base;
varying vec3 top;
varying vec2 cell;
varying float near;
varying vec2 swell;
varying float sky;

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

	// One texel up the mips: a clump is wider than a texel of the maps.
	vec2 relief_uv = (origin.xz - relief_rect.xy) * relief_rect.zw;
	vec3 relief = textureLod(terrain_relief, relief_uv, 1.0).rgb;
	float dip = (textureLod(terrain_masks, relief_uv, 1.0).b - 0.5) * 2.0 * shape_paint;
	swell = (relief.rg - 0.5) * 2.0 * relief_amount;
	sky = mix(1.0, relief.b, occlusion_amount);
	base *= 1.0 - 0.1 * dip;
	top *= 1.0 - 0.16 * dip;
	top = mix(top, lush * 0.8, max(dip, 0.0) * 0.4);
	top = mix(top, sunny * 0.8, max(-dip, 0.0) * 0.4);

	float dist = length((VIEW_MATRIX * vec4(origin, 1.0)).xyz);
	near = 1.0 - smoothstep(near_end * 0.4, near_end, dist);
	float keep = mix(1.0, 0.6, smoothstep(thin_start, fade_start, dist));
	float alive = clamp((keep - UV2.y) / 0.08, 0.0, 1.0);
	float sink = 1.0 - smoothstep(fade_start, fade_end, dist);
	VERTEX *= alive * sink;

	// One slow sway and a broad gust rolling across the field. Slow and low
	// in frequency on purpose: it has motion vectors (TIME), but thin cards
	// moving fast still shimmer under TAA.
	float gust = 0.6 + 0.4 * sin(TIME * 0.31 + origin.x * 0.06 - origin.z * 0.045);
	float sway = sin(TIME * 0.8 + origin.x * 0.23 + origin.z * 0.17) * gust;
	float bend = tip * tip;
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
	// Flatten the dome toward up, then lean it as the ground's swell leans,
	// the way the ground shader does.
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wn = mix(vec3(0.0, 1.0, 0.0), wn, normal_dome);
	wn = wn / max(wn.y, 0.2) - vec3(swell.x, 0.0, swell.y);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	// The atlas shading is kept shallow: deep shade at the roots reads as dark
	// spots on the ground from the game's high camera.
	if (painted) {
		ALBEDO = t.rgb * COLOR.rgb * mix(0.8, 1.0, tip);
	} else {
		ALBEDO = mix(base, top, smoothstep(0.0, 0.7, tip)) * mix(vec3(1.0), mix(0.55 + 0.6 * t.rgb, 0.25 + 0.95 * t.rgb, near), smoothstep(0.0, 0.5, tip));
		ALBEDO *= mix(1.0, mix(0.45, 1.0, smoothstep(0.0, 0.65, tip)), near);
	}
	ALBEDO *= mix(0.9, 1.0, sky);
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	AO = mix(0.9, 1.0, tip) * sky;
	AO_LIGHT_AFFECT = 0.3;
	// Light through a blade comes out a deeper, yellower green.
	BACKLIGHT = (painted ? ALBEDO : top * vec3(1.0, 0.95, 0.5)) * 0.25 * tip;
}
