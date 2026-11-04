// What every decal_surface.gd film shader shares: the uniforms the
// script sets, the cell mask, and noise. Include this first, define the
// film, then include film_passes.gdshaderinc for fragment().
//
// The film's shape is its patch's cells (SurfaceGrid squares), handed in
// as cell_mask: one texel per cell over the decal, the decal exactly
// covering the mask. Smoothed, the cells' outline is the film's outline,
// so two casts that merge draw as one pool. Noise is sampled in world
// meters, so it lines up across a merge too.

// 0 albedo, 1 normal map, 2 emission. Set by decal_surface.gd.
uniform int film_pass = 0;
// Per cell: r coverage (0 until the spill reaches it, 0 again once it
// has receded), g meters in from the patch's edge / 4, a how far its own
// recede has run (thin film goes first).
uniform sampler2D cell_mask : filter_linear, repeat_disable;
uniform vec2 mask_cells = vec2(1.0);
// The decal's corner and size on the ground, in world meters.
uniform vec2 origin_m = vec2(0.0);
uniform vec2 size_m = vec2(1.0);
// 0..1 around decal_surface.gd's loop (loop_frames): a film that
// animates its glow or ripples comes back to where it began at 1.
uniform float loop_phase = 0.0;
// How strongly the thickness shows in the normal map.
uniform float bumpiness = 0.08;
// Fine ripples on top of the thickness, for the gloss to catch, and how
// far they drift round each loop (0 holds them still).
uniform float ripple_scale = 3.0;
uniform float ripple_strength = 0.25;
uniform float ripple_drift = 0.0;
// Small bites out of the outline, on top of its big lumps, as a share
// of the wander.
uniform float edge_detail = 0.35;

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

// The world point (x, z) under uv.
vec2 meters(vec2 uv) {
	return origin_m + uv * size_m;
}

// Coverage, smoothed round the cells' corners: 1 well inside, 0.5 on the
// patch's edge, 0 a cell outside it.
float field(vec2 uv) {
	vec2 h = 0.5 / mask_cells;
	return (texture(cell_mask, uv + vec2(h.x, h.y)).r + texture(cell_mask, uv + vec2(-h.x, h.y)).r
			+ texture(cell_mask, uv + vec2(h.x, -h.y)).r + texture(cell_mask, uv + vec2(-h.x, -h.y)).r) * 0.25;
}

// field with its outline pushed in and out by noise, up to `wander`:
// big lumps, and edge_detail of small bites.
float edge_field(vec2 uv, float wander) {
	vec2 m = meters(uv);
	return field(uv) + (fbm(m * 0.9) - 0.5) * wander + (fbm(m * 3.7 + 11.0) - 0.5) * wander * edge_detail;
}

// The film's body: 1 inside its lumpy outline, 0 outside.
float body(vec2 uv, float wander) {
	return smoothstep(0.42, 0.58, edge_field(uv, wander));
}

// How far uv is in from the patch's edge, in meters.
float depth_m(vec2 uv) {
	return texture(cell_mask, uv).g * 4.0;
}

// 0 whole, 1 gone, for the cells here.
float local_recede(vec2 uv) {
	return texture(cell_mask, uv).a;
}

// Thin film goes first: what is left of thickness h as the cells here
// recede, 0 once they are gone.
float receded(float h, vec2 uv) {
	float a = local_recede(uv);
	float cut = a * 1.05;
	return h * smoothstep(cut, cut + 0.12, h) * (1.0 - smoothstep(0.9, 1.0, a));
}
