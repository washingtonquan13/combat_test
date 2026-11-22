// The grass colours, shared by the grass cards (quarry_grass.gdshader) and
// the ground (quarry_ground.gdshader), so the two cannot drift apart
// (docs/plans/bg3_grass_proposal.md, 5.5 and 5.6).
//
// The valley's colour drift is computed here, not read from a texture: the
// grass materials carry no drift texture, and giving them one means a
// rebake. Two value noises stand in for the ground's old `variation` reads
// and match their spread and patch size: the slow one (warm against cool)
// has patches about 5.5 m across, the tone one (light against dark) about
// 1.8 m.
//
// The four greens are plain uniforms with shared defaults. Nothing sets them;
// a material that wants other greens sets them on both the grass and the
// ground.

#ifndef GRASS_COLOUR_GDSHADERINC
#define GRASS_COLOUR_GDSHADERINC

#include "res://world/goblin_quarry/value_noise.gdshaderinc"

// Upper blades: a fresh green, bluer and deeper in lush patches, warmer in
// sunny ones, straw in dry ones.
uniform vec3 dry_tip = vec3(0.58, 0.54, 0.27);
uniform vec3 fresh = vec3(0.26, 0.4, 0.14);
uniform vec3 lush = vec3(0.19, 0.33, 0.13);
uniform vec3 sunny = vec3(0.35, 0.43, 0.15);

// The grass floor: under the cards the ground is not the grass texture's
// own colour (an old path texture, olive and pale) but the blades' green,
// shaded, so the gaps between tufts read as more grass, low down, and the
// cards' roots grow out of the same colour. floor_cover is how far the
// ground under full grass moves to it, floor_shade how dark it is against
// the upper blades.
uniform float floor_cover = 0.75;
uniform float floor_shade = 0.36;

const mat2 GRASS_COLOUR_TURN = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));

float grass_colour_lum(vec3 c) {
	return dot(c, vec3(0.33));
}

// Warm against cool, 0..1. Two octaves; the second turned so the two grids
// don't line up.
float drift_slow(vec2 xz) {
	vec2 p = xz / 10.06;
	float n = 0.67 * value_noise(p) + 0.33 * value_noise(GRASS_COLOUR_TURN * p * 2.03 + 17.1);
	return clamp(0.5 + (n - 0.5) * 1.21, 0.0, 1.0);
}

// Light against dark, 0..1, turned and shifted off the slow noise.
float drift_tone(vec2 xz) {
	float n = value_noise(GRASS_COLOUR_TURN * xz / 2.77 + vec2(5.3, 9.1));
	return clamp(0.5 + (n - 0.5) * 0.89, 0.0, 1.0);
}

// The colour drift across the valley, a multiplier near 1.
vec3 ground_drift(vec2 xz) {
	vec3 d = mix(vec3(0.93, 0.97, 1.05), vec3(1.07, 1.0, 0.9), smoothstep(0.25, 0.75, drift_slow(xz)));
	return d * mix(0.86, 1.12, smoothstep(0.2, 0.8, drift_tone(xz)));
}

// The ground's grass layer graded green and dark: the shade at the roots.
vec3 grass_root(vec3 g) {
	return mix(vec3(grass_colour_lum(g)), g, 1.3) * vec3(0.3, 0.5, 0.22);
}

// The upper blades' colour at xz, before the drift. `soil` is the soil
// albedo, read as three slow masks: brightness, dry patches, lush against
// sunny. `tint` is the per-clump tint (1 for the field's average), `dip` the
// field's hollow (+1) or rise (-1). `lod` is the mip: a clump reads one point
// (0), the ground reads an average over many clumps. `dry` comes back for the
// wind.
vec3 grass_top(sampler2D soil, vec2 xz, vec3 tint, float dip, float lod, out float dry) {
	float macro = textureLod(soil, xz * 0.031, lod).g;
	dry = smoothstep(0.38, 0.62, textureLod(soil, xz * 0.013 + vec2(0.37, 0.71), lod).r);
	float l = textureLod(soil, xz * 0.019 + vec2(0.61, 0.13), lod).b;
	vec3 green = mix(lush, fresh, smoothstep(0.2, 0.45, l));
	green = mix(green, sunny, smoothstep(0.45, 0.7, l));
	// The per-clump tint rides on top, a little stronger than on the roots.
	green *= 1.0 + (tint - 1.0) * 1.5;
	vec3 top = mix(green * mix(0.9, 1.1, smoothstep(0.08, 0.34, macro)), dry_tip, dry * 0.4) * 0.8;
	top *= 1.0 - 0.16 * dip;
	top = mix(top, lush * 0.8, max(dip, 0.0) * 0.4);
	return mix(top, sunny * 0.8, max(-dip, 0.0) * 0.4);
}

// The ground under grass: `root` is grass_root() of the ground's grass
// texture, `top` grass_top() at a coarse mip, `cover` how much grass the
// paint grows there (0-1), `streak` the texture's own light against dark
// (1 for its average), kept so the floor is not flat.
vec3 grass_floor(vec3 root, vec3 top, float cover, float streak) {
	return mix(root, top * floor_shade * streak, cover * floor_cover);
}

#endif
