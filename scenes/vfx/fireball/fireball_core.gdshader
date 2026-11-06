shader_type spatial;
// The burning heart of a held or flying fireball: a sphere whose surface
// churns, white-hot where it faces you and reddening toward the rim.
render_mode unshaded, blend_add, depth_draw_never, cull_back;

uniform vec4 hot_color : source_color = vec4(1.0, 0.92, 0.65, 1.0);
uniform vec4 rim_color : source_color = vec4(1.0, 0.32, 0.04, 1.0);
// Overall brightness; above 1 it blooms where the environment has glow.
uniform float intensity = 2.2;
// How fast the surface churns, how far it bulges, and how fine the churn is.
uniform float churn_speed = 1.6;
uniform float churn_amount = 0.18;
uniform float churn_scale = 7.0;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

varying float churn;

void vertex() {
	vec3 flow = vec3(0.0, -TIME * churn_speed, TIME * churn_speed * 0.4);
	churn = noise(VERTEX * churn_scale + flow) * 0.65 + noise(VERTEX * churn_scale * 2.3 + flow * 1.7) * 0.35;
	VERTEX += NORMAL * (churn - 0.5) * churn_amount;
}

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - facing, 1.6);
	vec3 col = mix(hot_color.rgb, rim_color.rgb, clamp(rim * 1.4 + (1.0 - churn) * 0.45, 0.0, 1.0));
	ALBEDO = col * intensity;
	ALPHA = clamp(facing * 1.5, 0.0, 1.0);
}
