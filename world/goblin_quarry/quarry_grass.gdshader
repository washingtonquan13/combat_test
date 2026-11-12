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
// Where units have stood (world/grass_trample.gd): per texel, the time it
// was last trodden (red) and the time this press began (green). Grass eases
// down over `trample_down` seconds as a foot arrives. Fresh grass lies curled flat, pushed out from the middle
// of the trodden patch, each card of a clump a little to its own side. Once
// the mark is `trample_hold` seconds old it stands again over
// `trample_recover` seconds, rocking as it comes up, and a shallow dent
// lingers `trample_dent` seconds more. Pressed grass is darker and duller,
// its blades crushed together.
// Read texel by texel (trample_field): blending two texels' times makes a
// time neither had, so each texel's flatness is worked out first and the
// flatness is blended.
global uniform sampler2D grass_trample : filter_nearest, repeat_disable;
global uniform vec4 grass_trample_rect;
global uniform float grass_trample_now;
// For motion vectors: the clock last frame, and TIME this frame (-1 if not
// known). See trample_clock().
global uniform float grass_trample_then;
global uniform float grass_trample_time;
uniform float trample_hold = 2.0;
uniform float trample_recover = 6.0;
uniform float trample_dent = 20.0;
uniform float trample_down = 0.35;

varying float tip;
varying vec3 base;
varying vec3 top;
varying vec2 cell;
varying float near;
varying float crushed;
varying vec2 swell;
varying float sky;

float lum(vec3 c) {
	return dot(c, vec3(0.33));
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// The trample clock for this run of the vertex code. For TAA's motion
// vectors Godot runs it again as of the previous frame, TIME then being the
// previous frame's: that run takes the previous frame's clock, so trodden
// grass moving between frames gets motion vectors like the wind does.
float trample_clock() {
	float behind = grass_trample_time - TIME;
	return behind > 0.0015 && behind < 0.25 ? grass_trample_then : grass_trample_now;
}

// One texel's mark, last trodden at `stamp` in a press begun at `begun`:
// x how flat the grass lies (1 flat, 0 upright), y how far it rocks back
// past upright as it rises.
vec2 trample_texel(float now, float stamp, float begun) {
	float t = now - stamp - trample_hold;
	float rise = 1.0 - smoothstep(0.0, trample_recover, t);
	float dent = 0.18 * (1.0 - smoothstep(trample_recover * 0.5, trample_recover + trample_dent, t));
	float pressed = max(rise, dent) * smoothstep(0.0, trample_down, now - begun);
	float s = max(t, 0.0);
	float rock = t > 0.0 ? sin(s * 4.2) * exp(-s * 0.9) * 0.22 * (1.0 - pressed) : 0.0;
	return vec2(pressed, rock);
}

// The trample at xz, blended between the four texels around it, so a
// trodden patch grows and its push direction turns smoothly rather than a
// texel at a time.
vec2 trample_field(float now, vec2 xz) {
	vec2 size = vec2(textureSize(grass_trample, 0));
	vec2 p = (xz - grass_trample_rect.xy) / grass_trample_rect.zw * size - 0.5;
	vec2 f = fract(p);
	vec2 at = (floor(p) + 1.0) / size;
	// Gather order: (0,1) (1,1) (1,0) (0,0).
	vec4 stamp = textureGather(grass_trample, at, 0);
	vec4 begun = textureGather(grass_trample, at, 1);
	vec2 a = trample_texel(now, stamp.w, begun.w);
	vec2 b = trample_texel(now, stamp.z, begun.z);
	vec2 c = trample_texel(now, stamp.x, begun.x);
	vec2 d = trample_texel(now, stamp.y, begun.y);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
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

	// Trodden grass folds over about its root, away from the middle of the
	// trodden patch (downhill on the mark), so a path parts the grass.
	// Blades curve over along their length rather than hinging at the root:
	// each point keeps its height up the blade as length along an arc whose
	// angle grows toward the tip.
	float pressed = 0.0;
	crushed = 0.0;
	if (grass_trample_rect.z > 0.0) {
		float now = trample_clock();
		vec2 field = trample_field(now, origin.xz);
		pressed = field.x;
		float rock = field.y;
		if (pressed > 0.001 || abs(rock) > 0.001) {
			vec2 slope = vec2(
					trample_field(now, origin.xz + vec2(0.3, 0.0)).x - trample_field(now, origin.xz - vec2(0.3, 0.0)).x,
					trample_field(now, origin.xz + vec2(0.0, 0.3)).x - trample_field(now, origin.xz - vec2(0.0, 0.3)).x);
			float h = hash(origin.xz) * 6.2832;
			// Where the patch is level (its middle) the clump falls its own way;
			// toward the rim it turns outward, blended, so it never flips.
			vec2 own = vec2(cos(h), sin(h));
			float edge = smoothstep(0.02, 0.2, length(slope));
			vec2 away = mix(own, -slope / max(length(slope), 1e-4), edge);
			away = length(away) > 1e-3 ? normalize(away) : own;
			// Each card of the clump falls a little to its own side.
			float fan = (UV2.y - 0.5) * 1.1;
			away = mat2(vec2(cos(fan), sin(fan)), vec2(-sin(fan), cos(fan))) * away;
			// Coming up, the clump rocks back past upright and settles.
			float angle = (pressed * 1.45 + rock) * (0.8 + 0.4 * UV2.y);
			mat3 to_world = mat3(MODEL_MATRIX);
			vec3 w = to_world * VERTEX;
			float up = max(w.y, 0.0);
			float a = angle * tip;
			float k = abs(a) > 0.001 ? 1.0 / a : 0.0;
			w.y = abs(a) > 0.001 ? up * sin(a) * k : up;
			w.xz += away * (abs(a) > 0.001 ? up * (1.0 - cos(a)) * k : 0.0);
			VERTEX = inverse(to_world) * w;
			crushed = pressed;
		}
	}

	// One slow sway and a broad gust rolling across the field. Slow and low
	// in frequency on purpose: it has motion vectors (TIME), but thin cards
	// moving fast still shimmer under TAA.
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
	// Lean it as the ground's swell leans, the way the ground shader does.
	vec3 wn = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
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
	// Crushed blades lie in each other's shade and lose their sheen.
	ALBEDO *= mix(1.0, 0.78, crushed);
	ALBEDO *= mix(0.9, 1.0, sky);
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	AO = mix(0.9, 1.0, tip) * sky;
	AO_LIGHT_AFFECT = 0.3;
	// Light through a blade comes out a deeper, yellower green.
	BACKLIGHT = (painted ? ALBEDO : top * vec3(1.0, 0.95, 0.5)) * 0.25 * tip * (1.0 - crushed * 0.7);
}
