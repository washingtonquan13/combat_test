// A volumetric fog sphere drawn on a unit SphereMesh (radius 1), scaled
// by SurfaceManager to the cloud's radius. Each pixel works out how much
// of the sphere its view ray crosses — clipped by whatever opaque
// geometry is in front of the far side — and fogs by that thickness, so
// the cloud reads as a solid volume from any angle, from inside too.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, depth_test_disabled, shadows_disabled;

uniform vec3 fog_color : source_color = vec3(0.78, 0.8, 0.84);
uniform float density = 0.9;
uniform float noise_scale = 0.6;
uniform float drift_speed = 0.15;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void fragment() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float radius = length(MODEL_MATRIX[0].xyz);
	vec3 dir = normalize(VERTEX);

	// Ray from the camera (view-space origin) against the sphere.
	float b = dot(dir, center);
	float c = dot(center, center) - radius * radius;
	float h = b * b - c;
	if (h <= 0.0) {
		discard;
	}
	h = sqrt(h);
	float near_t = max(b - h, 0.0);
	float far_t = b + h;

	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_t = length(view.xyz / view.w);
	far_t = min(far_t, scene_t);
	float thickness = max(far_t - near_t, 0.0);

	// Sample the noise at the middle of the crossing, in world space so
	// it doesn't swim with the camera.
	vec3 mid_view = dir * (near_t + far_t) * 0.5;
	vec3 world = (INV_VIEW_MATRIX * vec4(mid_view, 1.0)).xyz;
	float n = noise(world * noise_scale + vec3(TIME * drift_speed, TIME * drift_speed * 0.3, 0.0));
	n = mix(0.55, 1.0, n);

	ALBEDO = fog_color * mix(0.85, 1.0, n);
	ALPHA = clamp(1.0 - exp(-density * thickness * n), 0.0, 0.97);
}
