shader_type spatial;
render_mode diffuse_lambert_wrap;

// Bark of generated trees. COLOR.r is baked occlusion, COLOR.a height up the
// tree; see tools/quarry/plant_gen.gd.
//
// Moss grows where water sits and the sun doesn't dry it: on surfaces that
// face up (the tops of roots and limbs), on the trunk's shaded side, and
// thickest near the ground. It fills the bark's dark furrows first, so the
// ridges stay showing through. The lowest half metre is darker and damper.

#include "res://world/goblin_quarry/tree_wind.gdshaderinc"

uniform sampler2D albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint = vec3(0.85, 0.82, 0.8);
uniform vec3 moss_dark = vec3(0.09, 0.12, 0.04);
uniform vec3 moss_light = vec3(0.22, 0.27, 0.09);
// The side moss favours, in world space (away from the quarry's sun).
uniform vec3 moss_side = vec3(0.88, 0.0, -0.47);
uniform float moss_amount = 1.0;

varying float above_ground;
varying vec3 world_n;

void vertex() {
	above_ground = VERTEX.y * length(MODEL_MATRIX[1].xyz);
	world_n = normalize(mat3(MODEL_MATRIX) * NORMAL);
	VERTEX = tree_wind(VERTEX, UV2, COLOR.a, MODEL_MATRIX[3].xyz, TIME);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec3 bark = texture(albedo, UV).rgb;
	vec3 n = normalize(world_n);
	float lum = dot(bark, vec3(0.33));
	float furrow = 1.0 - smoothstep(0.04, 0.25, lum);

	float up = smoothstep(0.2, 0.85, n.y);
	float side = smoothstep(0.0, 0.9, dot(n, normalize(moss_side)));
	float low = 1.0 - smoothstep(0.1, 2.0, above_ground);
	float m = max(up * 0.8, side * mix(0.3, 0.85, low)) * mix(0.4, 1.0, low) + low * 0.2;
	// Patches a hand or two across, so it grows in clumps, not a coat of paint.
	float patches = vnoise(UV * 3.0) * 0.65 + vnoise(UV * 9.0) * 0.35;
	m = smoothstep(0.5, 0.8, m * moss_amount + (patches - 0.5) * 0.7 + furrow * 0.3);

	vec3 moss = mix(moss_dark, moss_light, smoothstep(0.05, 0.3, lum) * 0.6 + vnoise(UV * 23.0) * 0.4);
	vec3 c = mix(bark * tint, moss, m);
	float damp = 1.0 - smoothstep(0.0, 0.6, above_ground);
	c *= mix(1.0, 0.6, damp);

	ALBEDO = c * COLOR.r;
	// Moss is soft: it smooths the bark's relief under it.
	NORMAL_MAP = mix(texture(normal_map, UV).rgb, vec3(0.5, 0.5, 1.0), m * 0.3);
	ROUGHNESS = mix(0.9, 1.0, m);
	SPECULAR = mix(0.3, 0.15, m);
}
