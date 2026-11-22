shader_type spatial;
// Character Creator RLEyeTearline: the wet strip where the lower lid meets
// the eye. Almost invisible itself; it catches a thin glint. Procedural;
// built for Godot from CC's JSON parameters.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform float roughness = 0.1;
uniform float detail_amount = 0.03;
uniform vec2 detail_scale = vec2(2.3, 0.12);
// How much of each end fades away.
uniform float edge_fadeout = 1.0;
uniform float opacity = 0.25;
// The wet strip mirrors its surroundings however clear it is.
uniform float reflect_opacity = 0.7;
uniform float depth_offset = 0.0001;

void vertex() {
	VERTEX += NORMAL * depth_offset;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	float fade = smoothstep(0.0, 0.15 * edge_fadeout, UV.x) * smoothstep(0.0, 0.15 * edge_fadeout, 1.0 - UV.x)
			* smoothstep(0.0, 0.2, UV.y) * smoothstep(0.0, 0.2, 1.0 - UV.y);
	// A faint wobble so the glint isn't a clean line.
	vec2 g = floor(UV * vec2(40.0, 4.0) * detail_scale);
	float wobble = (hash(g) - 0.5) * detail_amount * 20.0;
	ALBEDO = vec3(0.0);
	ROUGHNESS = roughness;
	SPECULAR = 0.5;
	NORMAL_MAP = normalize(vec3(wobble, 0.0, 1.0)) * 0.5 + 0.5;
	float graze = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALPHA = mix(opacity, reflect_opacity, graze) * fade;
}
