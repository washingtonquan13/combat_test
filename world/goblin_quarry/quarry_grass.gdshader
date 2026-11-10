shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;

// Blades carry an upward normal so a clump lights like the ground under it.
// INSTANCE color is per-clump variation. UV.y is 0 at the root, 1 at the tip.

uniform vec3 root_color : source_color = vec3(0.12, 0.19, 0.06);
uniform vec3 tip_color : source_color = vec3(0.36, 0.5, 0.16);
uniform float wind = 0.05;
uniform float fade_start = 28.0;
uniform float fade_end = 40.0;

varying float tip;
varying vec3 tint;

void vertex() {
	tip = UV.y;
	tint = COLOR.rgb;
	vec3 world = MODEL_MATRIX[3].xyz;
	float sway = sin(TIME * 1.3 + world.x * 0.7 + world.z * 0.5) + 0.5 * sin(TIME * 2.9 + world.x * 1.9);
	float bend = UV.y * UV.y;
	VERTEX.x += sway * wind * bend;
	VERTEX.z += sway * wind * 0.6 * bend;
	float dist = length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	VERTEX *= 1.0 - smoothstep(fade_start, fade_end, dist);
	NORMAL = (inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
}

void fragment() {
	ALBEDO = mix(root_color, tip_color, tip) * tint;
	ROUGHNESS = 0.9;
	AO = mix(0.75, 1.0, tip);
	AO_LIGHT_AFFECT = 0.6;
}
