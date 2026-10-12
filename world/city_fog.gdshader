// The fog wall at the edge of the city overworld, drifting. Every city
// material already turns to haze toward the boundary
// (city_edge_fog.gdshaderinc), which hides whatever is past it; these
// sheets give that fade movement. Each is a flat sheet above the ground,
// solid out past the line and clear well inside it, with a ragged,
// drifting margin in the fade between. A few stacked at rising heights,
// the low ones reaching farthest in, read as a bank of fog rolling in at
// the edge of the map rather than a painted gradient.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
#include "res://world/city_edge_fog.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float units_per_metre = 1.0;
// Metres outside the boundary where this sheet starts to thicken,
// negative for inside it, and metres more over which it turns solid.
uniform float start_out = 0.0;
uniform float band = 60.0;
// Metres the ragged margin wanders outward, and world units across one
// wisp.
uniform float wander = 60.0;
uniform float wisp_size = 30.0;
uniform float drift_speed = 0.6;
uniform vec2 drift = vec2(1.0, 0.35);
// Per sheet, so stacked sheets do not wisp in step.
uniform float seed = 0.0;
// World units over which a sheet fades out where it meets a surface, so a
// wall or a ramp passing through it shows no hard line.
uniform float proximity = 0.5;

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
	float metres = edge_metres(xz);
	// The wisps only ever push the margin outward, so this far in the
	// sheet is clear whatever they do.
	if (metres + start_out >= 0.0) {
		discard;
	}
	vec2 p = xz / wisp_size + vec2(seed * 17.0, seed * 5.0);
	vec2 flow = drift * TIME * drift_speed / wisp_size;
	// Two drifting copies at different scales, warped by a third, so the
	// wisps curl rather than slide.
	float warp = fbm(p * 0.35 - flow * 0.5);
	float n = fbm(p + flow + warp * 1.5) * 0.65 + fbm(p * 2.3 - flow * 1.3) * 0.35;
	float m = metres + start_out + n * wander;
	float thick = 1.0 - smoothstep(-band, 0.0, m);
	// Denser cores inside the wisps, and solid well past the edge.
	thick *= mix(0.7, 1.15, n);
	thick = mix(thick, 1.0, 1.0 - smoothstep(-(start_out + wander + band * 3.0), -(start_out + wander + band), metres));
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	thick *= clamp((VERTEX.z - behind.z / behind.w) / proximity, 0.0, 1.0);
	ALBEDO = edge_fog_color * mix(0.96, 1.04, n);
	ALPHA = clamp(thick, 0.0, 1.0);
}
