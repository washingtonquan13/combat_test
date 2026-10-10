// The fog at the edge of the city overworld: the map ends where the city
// does, and past its boundary there is only fog. Each layer is a flat sheet
// above the ground, clear everywhere inside the city and solid past its
// edge, with a ragged, drifting margin out beyond the line: the fog hides
// what is off the map and never a road on it. A few sheets stacked at
// rising heights, each starting a little farther out, read as a bank of fog
// rather than a painted line.
//
// edge_tex holds the signed distance to the boundary, inside positive,
// baked by tools/blockout/shore_field.py as 128 + metres / edge_step.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec3 fog_color : source_color = vec3(0.72, 0.76, 0.80);
uniform sampler2D edge_tex : filter_linear, repeat_disable;
// Where edge_tex lies, in world units, and its metres per step.
uniform vec2 edge_origin = vec2(0.0);
uniform vec2 edge_size = vec2(1.0);
uniform float edge_step = 8.0;
uniform float units_per_metre = 0.25;
// Metres outside the boundary where this sheet starts to thicken, and
// metres more over which it turns solid.
uniform float start_out = 0.0;
uniform float band = 120.0;
// Metres the ragged margin wanders outward, and world units across one
// wisp.
uniform float wander = 100.0;
uniform float wisp_size = 30.0;
uniform float drift_speed = 0.6;
uniform vec2 drift = vec2(1.0, 0.35);
// Per sheet, so stacked sheets do not wisp in step.
uniform float seed = 0.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

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
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += noise(p) * amp;
		p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 xz = world_pos.xz;
	vec2 uv = (xz - edge_origin) / edge_size;
	// Off the baked field is far outside the city.
	float metres = -1e4;
	if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
		metres = (texture(edge_tex, uv).r * 255.0 - 128.0) * edge_step;
	}
	vec2 p = xz / wisp_size + vec2(seed * 17.0, seed * 5.0);
	vec2 flow = drift * TIME * drift_speed / wisp_size;
	// Two drifting copies at different scales, warped by a third, so the
	// wisps curl rather than slide.
	float warp = fbm(p * 0.35 - flow * 0.5);
	float n = fbm(p + flow + warp * 1.5) * 0.65 + fbm(p * 2.3 - flow * 1.3) * 0.35;
	// Only ever pushed outward, so inside the boundary m stays above 0
	// and the sheet stays clear.
	float m = metres + start_out + n * wander;
	float thick = 1.0 - smoothstep(-band, 0.0, m);
	// Denser cores inside the wisps, and solid well past the edge.
	thick *= mix(0.7, 1.15, n);
	thick = mix(thick, 1.0, 1.0 - smoothstep(-(start_out + wander + band * 3.0), -(start_out + wander + band), metres));
	ALBEDO = fog_color * mix(0.96, 1.04, n);
	ALPHA = clamp(thick, 0.0, 1.0);
}
