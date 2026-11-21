// One wind for every plant: grass (quarry_grass.gdshader) and trees
// (tree_wind.gdshaderinc). The recipe is BG3's (docs/plans/bg3_grass_proposal.md,
// 5.4): a world direction, a slow wave whose phase runs downwind, a
// 45% constant lean under a 55% sway, and gusts from a noise sampled in
// world space that scrolls downwind, so gust fronts cross the field and the
// trees in it at the same moment.
//
// The two values are plain uniforms with shared defaults, not project
// shader globals: a `global uniform` that project.godot does not list is a
// compile error in the editor. A material that wants different weather sets
// them itself; nothing sets them today. Do not change them from script every
// frame: a uniform changed from script has no previous-frame value, so its
// motion vectors would be wrong. TIME-driven motion does get motion vectors
// in Godot 4.4 Forward+ (checked with the motion-vector debug draw, change 2).
//
// The noise is computed, not a texture (value_noise.gdshaderinc).

#ifndef WIND_GDSHADERINC
#define WIND_GDSHADERINC

#include "res://world/goblin_quarry/value_noise.gdshaderinc"

uniform vec2 wind_direction = vec2(0.8, 0.6);
uniform float wind_strength : hint_range(0.0, 1.0) = 0.5;

// Gusts travel downwind at this speed, in m/s.
const float WIND_GUST_SPEED = 3.0;

vec2 wind_dir() {
	return normalize(wind_direction);
}

// Gust at a world point: the noise at 1/15 m scrolling downwind, cubed and
// held to 0..0.5, so most of the field is calm and fronts stand out.
float wind_gust_at(vec2 xz, vec2 dir, float time) {
	float s = value_noise((xz - dir * time * WIND_GUST_SPEED) / 15.0);
	return clamp(s * s * s, 0.0, 0.5);
}

float wind_gust(vec2 xz, float time) {
	return wind_gust_at(xz, wind_dir(), time);
}

// The sway, 0..1: a triangle wave smoothed by x²(3-2x). Its phase is a broad
// offset (two sines, about 100 m across), the distance downwind over 30 m,
// and time, so crests run downwind. `rate` scales the frequency (1 for
// grass, lower for big trees). The offset is sines, not a second noise:
// grass runs this per vertex and the noise cost 0.1 ms at station B.
float wind_wave_at(vec2 xz, vec2 dir, float time, float rate) {
	float freq = mix(0.2, 0.4, wind_strength) * rate;
	float broad = 0.25 * (sin(xz.x * 0.061 + 1.3) + sin(xz.y * 0.053 + 0.4));
	float phase = broad + time * freq - dot(xz, dir) / 30.0;
	float t = abs(fract(phase) * 2.0 - 1.0);
	return t * t * (3.0 - 2.0 * t);
}

float wind_wave(vec2 xz, float time, float rate) {
	return wind_wave_at(xz, wind_dir(), time, rate);
}

// How far a plant rooted at xz leans downwind, per metre of height, at its
// top: 0.2 x strength at full gust and full sway, so 0.03 m on 0.3 m grass
// at strength 0.5. 45% of it is a constant lean, 55% the sway.
float wind_lean(vec2 xz, float time, float rate) {
	vec2 dir = wind_dir();
	float gust = wind_gust_at(xz, dir, time);
	return 0.2 * wind_strength * (0.5 + gust) * (0.45 + 0.55 * wind_wave_at(xz, dir, time, rate));
}

// The wind direction in a model's own space (rotation and uniform scale).
vec3 wind_dir_local(mat4 model) {
	vec2 d = wind_dir();
	return normalize(transpose(mat3(model)) * vec3(d.x, 0.0, d.y));
}

#endif
