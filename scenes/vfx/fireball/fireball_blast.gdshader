shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_front, depth_test_disabled, shadows_disabled;

// Explosive Fireball's blast as one live volume (fireball_blast.gd),
// marched the way the wall's and the breath's are (fire_march.gdshaderinc).
// age runs its life: a white-hot flash at the centre, a front that bursts
// out to the blast's radius fast and slows as it arrives, a churning ball
// that rises as the hot gas lifts, then a core that burns out first,
// leaving a ragged shell of tongues that thins away. Nothing is drawn
// under the ground: the march stops there, so a burst on the floor is a
// dome and one in the air a whole ball.

uniform sampler3D noise : filter_linear, repeat_enable;
uniform vec3 box_size = vec3(7.0);
// The blast's centre in the box's space.
uniform vec3 centre_local;
// Where the noise starts, so no two blasts burn alike.
uniform vec3 world_offset;
uniform float radius = 3.0;
// Seconds since it went off.
uniform float age = 0.0;
// How long the front takes to reach radius, how long the ball burns
// whole, and how long what is left takes to burn out after.
uniform float front_seconds = 0.3;
uniform float hold_seconds = 0.35;
uniform float burnout_seconds = 0.9;
// How long the centre flashes white.
uniform float flash_seconds = 0.18;
// Meters the ball rises over its life.
uniform float lift = 0.9;
// Meters a second the churn rolls upward.
uniform float churn = 1.6;
// Noise tiles per meter for the billows, and the detail's.
uniform float billow_scale = 0.22;
uniform float detail_scale = 0.6;
uniform float detail = 0.35;
// Meters the big slow noise bends the billows by.
uniform float warp = 0.9;
// How much noise the flame needs to burn at the centre and at the rim.
uniform float centre_threshold = 0.22;
uniform float rim_threshold = 0.62;
uniform float contrast = 4.0;
// The whole blast's burn, faded out at its end.
uniform float strength = 1.0;

float sample_noise(vec3 p) {
	return texture(noise, p).r;
}

float fire_heat(vec3 p, out float flash) {
	float life = front_seconds + hold_seconds + burnout_seconds;
	float a = clamp(age / front_seconds, 0.0, 1.0);
	float front = radius * (1.0 - (1.0 - a) * (1.0 - a));
	// How far it has burnt out, 0 while it burns whole.
	float spent = clamp((age - front_seconds - hold_seconds) / burnout_seconds, 0.0, 1.0);
	vec3 q = p - centre_local;
	q.y -= lift * smoothstep(0.0, life, age);
	if (length(q) > radius * 1.25) {
		flash = 0.0;
		return 0.0;
	}
	vec3 w = q + world_offset;
	vec3 slow = w * 0.12 - vec3(0.0, age * churn * 0.1, 0.0);
	vec3 bend = vec3(sample_noise(slow), sample_noise(slow + vec3(0.31, 0.17, 0.53)),
			sample_noise(slow + vec3(0.71, 0.43, 0.11))) - 0.5;
	vec3 bent = q + bend * warp;
	// The billows swell out with the front, then roll upward.
	float swell = radius / max(front, radius * 0.25);
	vec3 rise = vec3(0.0, age * churn, 0.0);
	vec3 b = w * swell + bend * warp - rise;
	float n = sample_noise(b * billow_scale);
	n = mix(n, sample_noise((b - rise * 0.6) * detail_scale + 0.37), detail);
	float r = length(bent) / radius;
	// The front, ragged.
	float edge = (front + (n - 0.5) * 1.2) / radius;
	if (r > edge) {
		flash = 0.0;
		return 0.0;
	}
	float threshold = mix(centre_threshold, rim_threshold, r * r) + spent * 0.25;
	float heat = clamp((n - threshold) * contrast, 0.0, 1.0);
	heat *= 1.0 - smoothstep(edge - 0.3, edge, r);
	// The core burns out first, from the centre outward, leaving the shell.
	float hollow = spent * 1.1 + (n - 0.5) * 0.3;
	heat *= smoothstep(hollow - 0.25, hollow, r);
	// The flash: white-hot at the centre, gone in a blink.
	float burst = 1.0 - smoothstep(0.0, flash_seconds, age);
	flash = burst * (1.0 - smoothstep(0.0, 0.7, r));
	heat = min(heat + flash * 0.8, 1.0);
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
