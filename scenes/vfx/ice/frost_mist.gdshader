shader_type spatial;
// The cold mist a frost cone (frost_cone.gd) blows out: a raymarched volume
// filling the cone, billowing and drifting outward, thickest by the hand
// and thinning along the cone and to nothing at its edge. Unlike the
// electric cone's glow it is a real (blended) mist: it veils what is
// behind it in pale blue-white, and glows faintly cold where it is thick.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_front, fog_disabled, shadows_disabled;

uniform sampler3D noise : filter_linear_mipmap, repeat_enable;
#include "res://scenes/vfx/cone_volume.gdshaderinc"

// Set per frame: overall thickness, how far along it has spread (0..1),
// and the clock it drifts by.
uniform float strength = 1.0;
uniform float reveal = 1.0;
uniform float time = 0.0;
uniform float reveal_softness = 0.2;
// How thick the mist is, and how fast it thins along the cone.
uniform float density = 1.6;
uniform float falloff = 1.6;
// Meters a second it drifts outward, and the size of its billows.
uniform float drift = 3.0;
uniform float noise_scale = 0.28;
uniform vec3 color : source_color = vec3(0.82, 0.92, 1.0);
// The faint cold glow where it is thick.
uniform vec3 glow_color : source_color = vec3(0.45, 0.75, 1.0);
uniform float glow_strength = 0.6;
uniform vec3 noise_offset = vec3(0.0);

const int STEPS = 24;

void vertex() {
	VERTEX = cone_box(VERTEX);
	local_vertex = VERTEX;
	local_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

float mist(vec3 p, float tan_half) {
	float depth = -p.z;
	float along = depth / cone_length;
	float rr = length(p.xy) / max(depth * tan_half, 0.05);
	float radial = smoothstep(1.0, 0.35, rr);
	float fade = exp(-along * falloff) * smoothstep(1.0, 0.65, along)
		* smoothstep(reveal, reveal - reveal_softness, along)
		// Not right at the hand: it puffs out from there.
		* smoothstep(0.0, 0.08, along);
	float weight = fade * radial;
	if (weight < 0.002) {
		return 0.0;
	}
	vec3 q = (p + vec3(0.0, 0.0, time * drift)) * noise_scale + noise_offset;
	float n = texture(noise, q).r * 0.65 + texture(noise, q * 2.3 + vec3(0.31, 0.17, 0.53)).r * 0.35;
	return smoothstep(0.3, 0.75, n) * weight * density;
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
	float thickness = 0.0;
	for (int i = 0; i < STEPS; i++) {
		vec3 p = local_camera + dir * (t_in + (float(i) + jitter) * step_len);
		thickness += mist(p, tan_half) * step_len;
	}
	float cover = 1.0 - exp(-thickness * strength);
	ALBEDO = color + glow_color * glow_strength * cover;
	ALPHA = cover;
}
