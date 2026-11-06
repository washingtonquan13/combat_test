shader_type spatial;
// The glowing plasma ball at the heart of ball_lightning.gd. Worn by a
// unit sphere mesh (scaled by the node). Each pixel marches the camera ray
// through the sphere and adds up light from a hot white core and from
// thin, twisting filaments: the ridges of a scrolling 3D noise, which is
// what makes the ball churn. Additive and brighter than 1.0, so it blooms.
//
// cull_front draws the far side of the sphere, so the ball still draws
// when the camera is inside it, and the march starts at the near side.
render_mode unshaded, blend_add, depth_draw_never, cull_front, fog_disabled, shadows_disabled;

uniform sampler3D noise : filter_linear_mipmap, repeat_enable;
uniform vec3 core_color : source_color = vec3(0.9, 0.93, 1.0);
uniform vec3 filament_color : source_color = vec3(0.45, 0.5, 1.0);
uniform vec3 haze_color : source_color = vec3(0.25, 0.25, 0.9);
uniform float core_strength = 2.0;
uniform float filament_strength = 9.0;
uniform float haze_strength = 0.2;
// How thin the filaments are: higher is thinner.
uniform float filament_sharpness = 14.0;
// A glowing shell at the sphere's edge, the "fantasy orb" rim: brightest
// just inside the silhouette, shimmering with the noise. 0 turns it off
// (the electric cone's orb has none).
uniform vec3 shell_color : source_color = vec3(0.4, 0.6, 1.0);
uniform float shell_strength = 0.0;
// How sharply the rim hugs the edge: higher is thinner.
uniform float shell_sharpness = 6.0;
// Scale of the noise across the ball, and how fast it churns.
uniform float noise_scale = 0.35;
uniform float churn = 0.35;
// Overall brightness, set per frame (flicker, fade in and out).
uniform float strength = 1.0;
uniform float time = 0.0;

const int STEPS = 28;

varying vec3 local_vertex;
varying vec3 local_camera;

void vertex() {
	local_vertex = VERTEX;
	local_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

// Light given off at p, a point inside the unit sphere.
vec3 glow(vec3 p) {
	float r = length(p);
	float core = exp(-r * r * 20.0);
	// Two layers of noise drifting different ways make the filaments twist.
	vec3 q = p * noise_scale;
	float a = texture(noise, q + vec3(time * churn, time * churn * 0.6, 0.0)).r;
	float b = texture(noise, q * 1.7 - vec3(0.0, time * churn * 0.8, time * churn * 0.5)).r;
	float ridge = 1.0 - abs(mix(a, b, 0.5) * 2.0 - 1.0);
	float filament = pow(ridge, filament_sharpness) * smoothstep(1.0, 0.55, r);
	float haze = smoothstep(1.0, 0.2, r);
	return core_color * core * core_strength
		+ filament_color * filament * filament_strength
		+ haze_color * haze * haze_strength;
}

void fragment() {
	vec3 dir = normalize(local_vertex - local_camera);
	// Where the ray enters and leaves the unit sphere.
	float b = dot(local_camera, dir);
	float c = dot(local_camera, local_camera) - 1.0;
	float h = b * b - c;
	if (h <= 0.0) {
		discard;
	}
	h = sqrt(h);
	float enter = max(-b - h, 0.0);
	float leave = -b + h;
	float step_len = (leave - enter) / float(STEPS);
	vec3 total = vec3(0.0);
	for (int i = 0; i < STEPS; i++) {
		vec3 p = local_camera + dir * (enter + (float(i) + 0.5) * step_len);
		total += glow(p) * step_len;
	}
	// The rim, worked out from how close the ray passes to the centre:
	// a ray grazing the edge sees the most shell. Fades off at the very
	// edge so the silhouette stays soft.
	float closest = sqrt(max(1.0 - h * h, 0.0));
	vec3 entry = local_camera + dir * enter;
	float shimmer = texture(noise, entry * noise_scale * 2.0 + vec3(0.0, time * churn * 2.0, 0.0)).r;
	float rim = pow(closest, shell_sharpness) * smoothstep(1.0, 0.94, closest);
	total += shell_color * rim * shell_strength * (0.5 + shimmer);
	ALBEDO = total * strength;
}
