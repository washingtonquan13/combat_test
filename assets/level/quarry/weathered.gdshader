shader_type spatial;

// Weathering for the quarry's generated buildings and props. prop_gen.gd bakes
// masks into vertex colour and this blends layers over a Poly Haven set:
//   r  ground grime: splash and soil creeping up from the ground
//   g  moss: up-facing and sheltered surfaces
//   b  verticality: rain streaks run down vertical faces
//   a  occlusion: reveals, eaves and the ground line
// Noise is world space, so neighbouring pieces weather as one surface.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float variation = 0.18;
uniform float grime = 1.0;
uniform float moss = 1.0;
uniform float streaks = 1.0;
uniform vec3 grime_color : source_color = vec3(0.24, 0.2, 0.15);
uniform vec3 moss_color : source_color = vec3(0.16, 0.2, 0.07);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.13) * 0.3 + vnoise(p * 4.37) * 0.15;
}

void fragment() {
	vec3 alb = texture(albedo_tex, UV).rgb * tint;
	vec3 orm = texture(orm_tex, UV).rgb;
	float rough = orm.g;

	// Low-frequency tone drift so long runs of one texture don't repeat flat.
	float drift = fbm(wpos * 0.45);
	alb *= 1.0 + (drift - 0.5) * 2.0 * variation;

	// Rain streaks: noise stretched down the wall.
	float s = vnoise(vec3(wpos.x * 7.0, wpos.y * 0.35, wpos.z * 7.0));
	float streak = smoothstep(0.55, 0.85, s) * COLOR.b * streaks;
	alb *= 1.0 - streak * 0.28;

	// Ground grime, ragged at its upper edge.
	float gn = fbm(wpos * 2.2);
	float g = smoothstep(0.25, 0.75, COLOR.r * 1.3 + (gn - 0.5) * 0.9) * grime;
	alb = mix(alb, alb * grime_color * 2.6, g * 0.85);
	rough = mix(rough, 1.0, g * 0.6);

	// Moss in patches, thicker in crevices (dark albedo) than on high spots.
	float mn = fbm(wpos * 3.1 + vec3(13.1));
	float lum = dot(texture(albedo_tex, UV).rgb, vec3(0.33));
	float m = smoothstep(0.62, 0.8, mn + COLOR.g * 0.25 - lum * 0.3) * COLOR.g * moss;
	alb = mix(alb, alb * 0.6 + moss_color * (0.5 + mn * 0.5), m * 0.8);
	rough = mix(rough, 1.0, m * 0.4);

	ALBEDO = alb * mix(0.55, 1.0, COLOR.a);
	ROUGHNESS = rough;
	METALLIC = 0.0;
	AO = orm.r * COLOR.a;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
}
