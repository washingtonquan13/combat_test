shader_type spatial;
// The streak of fire behind a flying fireball: a cone trailing off the
// core, burning hot at its root and tearing into ragged tongues toward the
// tip, in crisp cel-shaded bands. Made for a CylinderMesh whose UV.y runs
// from root (0) to tip (1).
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform vec4 hot_color : source_color = vec4(1.0, 0.85, 0.5, 1.0);
uniform vec4 tail_color : source_color = vec4(1.0, 0.25, 0.03, 1.0);
uniform float intensity = 1.8;
// How fast the fire streams back along the tail, and how torn it is.
uniform float stream_speed = 5.0;
uniform float raggedness = 0.75;

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

void fragment() {
	float along = UV.y;
	// Around the cone as a circle, so the noise has no seam.
	float a = UV.x * TAU;
	vec3 p = vec3(cos(a) * 1.2, sin(a) * 1.2, along * 5.0 - TIME * stream_speed);
	float n = noise(p) * 0.6 + noise(p * 2.1 + vec3(0.0, 0.0, -TIME * stream_speed)) * 0.4;
	float body = pow(1.0 - along, 1.4);
	float torn = smoothstep(along * raggedness, along * raggedness + 0.35, n);
	float facing = abs(dot(NORMAL, VIEW));
	float heat = body * torn * (0.35 + facing * 0.65);
	// Two flat bands: a hot inner streak inside a coloured flame.
	float inner = step(0.55, heat + (n - 0.5) * 0.3);
	ALBEDO = mix(tail_color.rgb, hot_color.rgb, inner) * intensity;
	ALPHA = step(0.22, heat);
}
