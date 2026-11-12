shader_type spatial;
render_mode cull_disabled;

// A scanned rock set down in the quarry. The scan alone looks dropped in from
// somewhere else: every copy the same colour, clean on top, a hard line where
// it meets the ground. This ties it to the place:
//   - each copy takes its own shade, and a slow drift of colour runs across
//     the valley through all of them;
//   - what the ground is made of here settles on the faces that look up:
//     dust in the pit, moss in the grass;
//   - the foot of the rock fades into the ground's own colour and darkens
//     where the two meet.
// The ground's colour is read from the bake's paint weights and the ground's
// own textures, so the rock follows whatever it sits on.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// G roughness; R occlusion when arm_occlusion is on.
uniform sampler2D arm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// Below zero: read roughness from arm_tex.
uniform float flat_roughness = -1.0;
uniform bool arm_occlusion = false;

// The bake's ground: height in metres and paint weights (rock, soil, grass,
// dirt), one texel per mesh cell. ground_rect is x0, z0, 1/width, 1/depth.
uniform sampler2D ground_height : filter_linear, repeat_disable;
uniform sampler2D ground_paint : filter_linear, repeat_disable;
uniform vec4 ground_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform sampler2D soil_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D grass_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform float soil_tile = 0.30;
uniform float grass_tile = 0.33;
uniform float dirt_tile = 0.36;

// How far each copy's shade may stray, and the valley-wide drift.
uniform float copy_variation : hint_range(0.0, 1.0) = 0.16;
uniform float drift_variation : hint_range(0.0, 1.0) = 0.14;
// How much settles on upward faces, and how level a face must be.
uniform float settle_amount : hint_range(0.0, 1.0) = 0.6;
uniform float settle_slope : hint_range(0.0, 1.0) = 0.62;
// The foot: the rock's unscaled height, and the share of it that fades.
uniform float rock_height = 1.0;
uniform float foot_share : hint_range(0.0, 1.0) = 0.22;
uniform float foot_max = 0.4;
uniform float foot_amount : hint_range(0.0, 1.0) = 0.85;

varying vec3 wpos;
varying vec3 wnrm;
varying float copy_seed;
varying float foot;

float hash(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y),
		f.z);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize(mat3(MODEL_MATRIX) * NORMAL);
	copy_seed = hash(MODEL_MATRIX[3].xyz * 7.31);
	foot = clamp(rock_height * length(MODEL_MATRIX[1].xyz) * foot_share, 0.03, foot_max);
}

void fragment() {
	vec3 albedo = texture(albedo_tex, UV).rgb;
	vec3 arm = texture(arm_tex, UV).rgb;
	float rough = flat_roughness < 0.0 ? arm.g : flat_roughness;
	float occ = arm_occlusion ? arm.r : 1.0;
	vec3 n = normalize(wnrm) * (FRONT_FACING ? 1.0 : -1.0);

	// Each copy its own shade, a little warmer or cooler; the drift on top.
	float shade = 1.0 + (copy_seed - 0.5) * 2.0 * copy_variation;
	float warm = (fract(copy_seed * 7.13) - 0.5) * copy_variation;
	float drift = noise(wpos * 0.11) - 0.5;
	float drift2 = noise(wpos * 0.045 + 31.7) - 0.5;
	shade *= 1.0 + drift * 2.0 * drift_variation;
	warm += drift2 * drift_variation;
	albedo *= shade * vec3(1.0 + warm, 1.0, 1.0 - warm);

	// The ground under this point.
	vec2 guv = (wpos.xz - ground_rect.xy) * ground_rect.zw;
	float above = wpos.y - texture(ground_height, guv).r;
	vec4 paint = texture(ground_paint, guv);
	// Bare rock ground reads as dirt: the stone keeps its own face there.
	vec3 w = vec3(paint.g, paint.b, paint.a + paint.r) + 0.001;
	w /= w.x + w.y + w.z;
	vec3 ground = texture(soil_albedo, wpos.xz * soil_tile).rgb * w.x
		+ texture(grass_albedo, wpos.xz * grass_tile).rgb * w.y
		+ texture(dirt_albedo, wpos.xz * dirt_tile).rgb * w.z;
	// Settled dust is finer and paler than the ground it blew off.
	vec3 dust = textureLod(soil_albedo, wpos.xz * soil_tile, 5.0).rgb * w.x
		+ textureLod(grass_albedo, wpos.xz * grass_tile, 5.0).rgb * w.y * 0.8
		+ textureLod(dirt_albedo, wpos.xz * dirt_tile, 5.0).rgb * w.z * 1.25;

	float grain = noise(wpos * 5.0) * 0.6 + noise(wpos * 17.0) * 0.4;
	// Dust keeps to the cracks and pits first: where the scan is darker.
	float pits = 1.0 - clamp(dot(albedo, vec3(0.333)) * 2.2, 0.0, 1.0);
	float settle = smoothstep(settle_slope - 0.18, settle_slope + 0.2, n.y + (grain - 0.5) * 0.5 + pits * 0.15);
	settle *= settle_amount * (0.55 + 0.45 * noise(wpos * 1.3 + 9.0));

	float lift = above + (grain - 0.5) * foot * 0.9;
	float base = (1.0 - smoothstep(0.0, foot, lift)) * foot_amount;

	albedo = mix(albedo, dust, settle);
	albedo = mix(albedo, ground, base);
	// Where rock meets ground little light gets in.
	float contact = mix(0.62, 1.0, smoothstep(-0.02, foot * 1.6, above));

	float cover = max(settle, base);
	ALBEDO = albedo * contact;
	ROUGHNESS = mix(rough, 0.96, cover);
	AO = occ * contact;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = 1.0 - 0.6 * cover;
}
