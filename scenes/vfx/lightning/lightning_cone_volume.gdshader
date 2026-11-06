shader_type spatial;
// The glowing body that fills an electric cone (lightning_cone.gd), as a
// real volume rather than a shell. Each pixel walks the camera ray through
// the cone and adds up the light given off along the way: a faint smooth
// blue-violet glow, and thin bright filaments - the ridges of a 3D noise,
// as in ball_lightning_core.gdshader - stretched along the cone and rushing
// outward from the hand. Whiter near the axis, brightest by the hand,
// fading along the cone and to nothing at its edge, so it never shows a
// silhouette. Additive and brighter than 1.0, so it blooms.
//
// The box, the cone clipping and the depth stop are cone_volume.gdshaderinc.
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_front, fog_disabled, shadows_disabled;

uniform sampler3D noise : filter_linear_mipmap, repeat_enable;
#include "res://scenes/vfx/cone_volume.gdshaderinc"

// Set per frame: overall brightness, how far along it has spread (0..1),
// and the clock that moves the streaks.
uniform float strength = 1.0;
uniform float reveal = 1.0;
uniform float time = 0.0;
// How soft the growing front is, as a fraction of the cone's length.
uniform float reveal_softness = 0.12;
// How fast the brightness dies along the cone.
uniform float falloff = 3.5;
// Meters a second the streaks rush outward from the hand.
uniform float rush = 12.0;

// The faint smooth glow filling the body.
uniform vec3 color : source_color = vec3(0.42, 0.38, 1.0);
uniform float glow_strength = 0.35;
// The filaments: their colour out at the edge, and their colour near the
// axis, where they run white-hot.
uniform vec3 filament_color : source_color = vec3(0.55, 0.55, 1.0);
uniform vec3 filament_core_color : source_color = vec3(0.92, 0.95, 1.0);
uniform float filament_strength = 2.5;
// How thin the filaments are: higher is thinner.
uniform float filament_sharpness = 10.0;
// How tight the white runs round the axis: higher keeps it nearer.
uniform float core_tightness = 5.0;
// Noise scale across the cone (per radian of spread, so the streaks fan
// out from the hand like the cone does) and along it (per meter: lower
// makes longer streaks).
uniform float streak_across = 1.6;
uniform float streak_along = 0.08;
// Where the noise starts, so no two blasts crackle alike.
uniform vec3 noise_offset = vec3(0.0);

const int STEPS = 28;

void vertex() {
	VERTEX = cone_box(VERTEX);
	local_vertex = VERTEX;
	local_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

// Light given off at p, in the node's local space.
vec3 glow(vec3 p, float tan_half) {
	float depth = -p.z;
	float along = depth / cone_length;
	// How far out from the axis, as a fraction of the cone's radius here.
	float rr = length(p.xy) / max(depth * tan_half, 0.05);
	// Soft to the edge: zero at the cone's side, with no crease.
	float radial = max(1.0 - rr * rr, 0.0);
	// Brightest by the hand, gone by the far end, and cut at the reveal
	// front as it grows outward.
	float fade = exp(-along * falloff) * smoothstep(1.0, 0.7, along)
		* smoothstep(reveal, reveal - reveal_softness, along);
	float weight = fade * radial;
	if (weight < 0.002) {
		return vec3(0.0);
	}
	// Noise in spread-and-distance coordinates: stretched along the cone,
	// fanning from the hand, scrolling outward. Two layers moving at
	// different speeds make the filaments flicker and twist.
	vec2 spread = p.xy / max(depth, 0.25);
	vec3 q = vec3(spread * streak_across, (depth - time * rush) * streak_along) + noise_offset;
	float a = texture(noise, q).r;
	float b = texture(noise, vec3(spread * streak_across * 1.9, (depth - time * rush * 1.4) * streak_along * 1.7)
		+ noise_offset + vec3(0.37, 0.61, 0.13)).r;
	float ridge = 1.0 - abs(mix(a, b, 0.5) * 2.0 - 1.0);
	float filament = pow(ridge, filament_sharpness);
	float white = exp(-rr * rr * core_tightness);
	vec3 filament_light = mix(filament_color, filament_core_color, white) * filament * filament_strength;
	// The glow falls off faster toward the edge than the filaments do (the
	// radial term twice), and is gently mottled by the first noise layer.
	vec3 glow_light = color * glow_strength * radial * (0.7 + 0.6 * a);
	return (glow_light + filament_light) * weight;
}

void fragment() {
	vec3 dir = normalize(local_vertex - local_camera);
	float t_in;
	float t_out;
	if (!cone_span(dir, SCREEN_UV, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX, t_in, t_out)) {
		discard;
	}
	float step_len = (t_out - t_in) / float(STEPS);
	float jitter = cone_jitter(FRAGCOORD.xy);
	float tan_half = tan(half_angle);
	vec3 total = vec3(0.0);
	for (int i = 0; i < STEPS; i++) {
		vec3 p = local_camera + dir * (t_in + (float(i) + jitter) * step_len);
		total += glow(p, tan_half) * step_len;
	}
	ALBEDO = total * strength;
}
