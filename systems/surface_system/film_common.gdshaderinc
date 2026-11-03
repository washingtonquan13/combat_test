// What every decal_surface.gd film shader shares: the uniforms the
// script sets, and noise. Include this first, define the film, then
// include film_passes.gdshaderinc for fragment().

// 0 albedo, 1 normal map, 2 emission. Set by decal_surface.gd.
uniform int film_pass = 0;
uniform float seed = 0.0;
// The decal's half-width in meters: noise is sampled in meters, so a
// big patch has the same size of detail as a small one.
uniform float radius_m = 3.0;
// 0 nothing yet, 1 fully spread.
uniform float spread = 1.0;
// 0 whole, 1 gone. Thin film goes first.
uniform float recede = 0.0;
// 0..1 around a looping glow (decal_surface.gd's glow_frames): a film
// that animates its emission comes back to where it began at 1.
uniform float glow_phase = 0.0;
// How strongly the thickness shows in the normal map.
uniform float bumpiness = 0.08;
// Fine ripples on top of the thickness, for the gloss to catch.
uniform float ripple_scale = 3.0;
uniform float ripple_strength = 0.25;

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

// A lumpy outline at p: 1 inside, 0 outside, wandering by `wander`
// around `base` (both fractions of the decal) as the film spreads.
float lumpy_body(vec2 p, float base, float wander) {
	vec2 m = p * radius_m;
	float edge = (base + (fbm(m * 0.45 + seed) - 0.5) * wander * 2.0) * spread;
	return 1.0 - smoothstep(edge - 0.07, edge, length(p));
}

// Thin film goes first: what's left of thickness h as recede runs 0..1.
float receded(float h) {
	float cut = recede * 1.05;
	return h * smoothstep(cut, cut + 0.12, h);
}
