shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// One tongue of flame on a fire.tscn particle: a quad that turns about
// its upright axis to face the camera, with noise scrolling up through
// a teardrop mask. COLOR.a (the particle's colour ramp) fades it in and
// out over its life.

uniform vec3 core_color : source_color = vec3(1.0, 0.72, 0.32);
uniform vec3 body_color : source_color = vec3(1.0, 0.38, 0.06);
uniform vec3 tip_color : source_color = vec3(0.55, 0.06, 0.02);
uniform float intensity = 1.1;
uniform float scroll_speed = 1.6;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;
// Fades the flame where it meets the ground, so no hard line.
uniform float soft_distance = 0.25;

varying float v_seed;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		sum += noise(p) * amp;
		p = p * 2.03 + vec2(17.3, 9.1);
		amp *= 0.5;
	}
	return sum;
}

void vertex() {
	// Cylindrical billboard: keep the particle's own up and scale, turn
	// its face toward the camera about that up.
	vec3 up = normalize(MODEL_MATRIX[1].xyz);
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	vec3 to_camera = INV_VIEW_MATRIX[3].xyz - MODEL_MATRIX[3].xyz;
	vec3 right = normalize(cross(up, to_camera));
	vec3 world = MODEL_MATRIX[3].xyz + right * VERTEX.x * scale_x + up * VERTEX.y * scale_y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	v_seed = INSTANCE_CUSTOM.x * 37.0 + MODEL_MATRIX[3].x * 3.1 + MODEL_MATRIX[3].z * 1.7;
}

void fragment() {
	vec2 uv = UV;
	float t = TIME * scroll_speed;
	// Licks: noise scrolling upward bends the flame side to side.
	// QuadMesh UV runs top to bottom; height runs base (0) to tip (1).
	float height = 1.0 - uv.y;
	float wobble = (fbm(vec2(height * 2.0 - t, v_seed)) - 0.5) * 0.35 * height;
	float x = (uv.x - 0.5 + wobble) * 2.0;
	// Teardrop: wide at the base, pinched at the tip.
	float width = mix(1.0, 0.12, pow(height, 1.4));
	float shape = 1.0 - smoothstep(width * 0.2, width, abs(x));
	shape *= smoothstep(0.0, 0.08, height) * (1.0 - smoothstep(0.8, 1.0, height));
	float turbulence = fbm(vec2(x * 1.5, uv.y * 3.0 + t * 1.8) + v_seed);
	float heat = shape * smoothstep(0.2, 0.75, turbulence + (1.0 - height) * 0.45);
	vec3 color = mix(tip_color, body_color, smoothstep(0.1, 0.45, heat));
	color = mix(color, core_color, smoothstep(0.55, 0.9, heat));
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -view.z / view.w;
	float soft = clamp((scene_z + VERTEX.z) / soft_distance, 0.0, 1.0);
	ALBEDO = color * heat * intensity * COLOR.a * soft;
}
