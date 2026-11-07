shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_front, depth_test_disabled, shadows_disabled;

// Fire Breath's gust as one live volume (fire_breath.gd), marched the way
// the wall's is (fire_march.gdshaderinc). The flame streams out along the
// cone from its apex, thick and hot at the mouth, thinning to ragged
// tongues at the rim and the far end, which lifts as the hot gas rises.
// age runs its life: the front shoots out to the cone's length, holds,
// then the tail lets go of the mouth and chases it out, and what is left
// burns out.

uniform sampler3D noise : filter_linear, repeat_enable;
uniform vec3 box_size = vec3(10.0);
// The cone's apex in the box's space; the cone points down +x.
uniform vec3 apex_local;
// The world's up in the box's space.
uniform vec3 up_local = vec3(0.0, 1.0, 0.0);
// Where the noise starts, so no two breaths burn alike.
uniform vec3 world_offset;
uniform float cone_length = 9.0;
uniform float half_angle = 0.46;
// The mouth's radius, at the apex.
uniform float nozzle = 0.2;
// Seconds since the breath let go.
uniform float age = 0.0;
// How long the front takes to reach the end, how long it holds there, how
// fast (meters a second) the tail chases it out.
uniform float front_seconds = 0.35;
uniform float hold_seconds = 0.5;
uniform float tail_speed = 13.0;
// Meters a second the flame streams out along the cone.
uniform float flow = 10.0;
// Meters the far end has risen.
uniform float lift = 0.9;
// Noise tiles per meter for the tongues, along the cone and across it,
// and the detail's.
uniform vec2 tongue_scale = vec2(0.16, 0.38);
uniform vec2 detail_scale = vec2(0.45, 0.9);
uniform float detail = 0.35;
// Meters the big slow noise bends the tongues by.
uniform float warp = 1.0;
// How much noise the flame needs to burn on its axis and at its rim.
uniform float axis_threshold = 0.3;
uniform float rim_threshold = 0.72;
uniform float contrast = 4.0;
// How much hotter the mouth burns than the far end.
uniform float mouth_heat = 1.2;
// The whole breath's burn, faded out at its end.
uniform float strength = 1.0;

float sample_noise(vec3 p) {
	return texture(noise, p).r;
}

float fire_heat(vec3 p, out float flash) {
	flash = 0.0;
	vec3 q = p - apex_local;
	float u = clamp(q.x / cone_length, 0.0, 1.0);
	// Undo the lift, so the cone curls up toward its end.
	q -= up_local * lift * u * u;
	float d = q.x;
	if (d < -nozzle) {
		return 0.0;
	}
	vec3 w = q + world_offset;
	vec3 slow = w * 0.1 - vec3(age * flow * 0.05, 0.0, 0.0);
	vec3 bend = vec3(sample_noise(slow), sample_noise(slow + vec3(0.31, 0.17, 0.53)),
			sample_noise(slow + vec3(0.71, 0.43, 0.11))) - 0.5;
	// Bent more the further out it is: the mouth is a tight jet.
	vec3 bent = q + bend * warp * (0.2 + u * 1.2);
	float radius = nozzle + max(bent.x, 0.0) * tan(half_angle);
	float r = length(bent.yz) / radius;
	if (r > 1.15) {
		return 0.0;
	}
	vec3 along = vec3(age * flow, 0.0, 0.0);
	float n = sample_noise((w + bend * warp - along) * tongue_scale.xyy);
	n = mix(n, sample_noise((w + bend * warp - along * 1.4) * detail_scale.xyy + 0.37), detail);
	float threshold = mix(axis_threshold, rim_threshold, r * r) + u * 0.12;
	float heat = clamp((n - threshold) * contrast, 0.0, 1.0);
	heat = min(heat * (1.0 + (1.0 - u) * mouth_heat), 1.0);
	// A soft rim, and a round far end past which it never reaches.
	heat *= 1.0 - smoothstep(0.75, 1.15, r);
	heat *= 1.0 - smoothstep(0.82, 1.0, length(bent) / cone_length);
	// The front, ragged: it shoots out fast and slows as it arrives.
	float a = clamp(age / front_seconds, 0.0, 1.0);
	float front = cone_length * (1.0 - (1.0 - a) * (1.0 - a)) + (n - 0.5) * 2.5;
	heat *= 1.0 - smoothstep(front - 1.2, front, d);
	// The tail, chasing it out once the breath lets go of the mouth.
	float tail = max(age - front_seconds - hold_seconds, 0.0) * tail_speed + (n - 0.5) * 2.0;
	heat *= smoothstep(tail, tail + 1.5, d);
	return heat * strength;
}

#include "res://systems/surface_system/fire_march.gdshaderinc"

void fragment() {
	vec4 fire = march_fire(box_size, SCREEN_UV, FRAGCOORD.xy, MODEL_MATRIX, INV_VIEW_MATRIX, INV_PROJECTION_MATRIX);
	if (fire.a <= 0.0) {
		discard;
	}
	ALBEDO = fire.rgb;
	ALPHA = fire.a;
}
