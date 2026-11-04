shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// One flame on a fire.tscn particle: a quad that turns about its upright
// axis to face the camera, showing a frame of the Blender-baked flipbook
// (tools/vfx/bake_fire_flipbook.py) - grayscale heat, colored here by a
// ramp. Each particle starts the loop at its own frame and some play
// mirrored, so neighbors never move in step; frames are blended so the
// loop is smooth at any fps. COLOR.a (the particle's colour ramp) fades
// it in and out over its life.

uniform sampler2D flipbook : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform int columns = 8;
uniform int frames = 64;
uniform float fps = 24.0;
// The baked flame sits in the middle of its cell: widen it to fill the quad.
uniform float crop_width = 0.62;
// Height band (0-1 up the quad) the base fades in over.
uniform vec2 base_fade = vec2(0.03, 0.2);
uniform vec3 core_color : source_color = vec3(1.0, 0.85, 0.55);
uniform vec3 body_color : source_color = vec3(1.0, 0.42, 0.08);
uniform vec3 tip_color : source_color = vec3(0.6, 0.07, 0.02);
uniform float intensity = 1.6;
// Slight noise bend on top of the baked motion.
uniform float wobble_amount = 0.12;
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

vec2 cell_uv(vec2 uv, float frame) {
	vec2 cell = vec2(mod(frame, float(columns)), floor(frame / float(columns)));
	return (cell + uv) / float(columns);
}

void fragment() {
	vec2 uv = UV;
	// QuadMesh UV runs top to bottom; height runs base (0) to tip (1).
	float height = 1.0 - uv.y;
	float wobble = (fbm(vec2(height * 2.0 - TIME * scroll_speed, v_seed)) - 0.5) * wobble_amount * height;
	float x = (uv.x - 0.5 + wobble) * crop_width;
	// Half the particles play mirrored.
	x *= fract(v_seed * 0.173) < 0.5 ? -1.0 : 1.0;
	vec2 sample_uv = clamp(vec2(0.5 + x, uv.y), vec2(0.002), vec2(0.998));
	float position = fract(TIME * fps / float(frames) + fract(v_seed * 0.0917)) * float(frames);
	float frame = floor(position);
	float next = mod(frame + 1.0, float(frames));
	float heat = mix(texture(flipbook, cell_uv(sample_uv, frame)).r,
			texture(flipbook, cell_uv(sample_uv, next)).r, position - frame);
	// The bake has a hard bright line along its base: fade it in instead.
	heat *= smoothstep(base_fade.x, base_fade.y, height);
	// And at the quad's sides, so a wide glow never shows its edge.
	heat *= smoothstep(0.0, 0.18, 0.5 - abs(uv.x - 0.5));
	vec3 color = mix(tip_color, body_color, smoothstep(0.05, 0.35, heat));
	color = mix(color, core_color, smoothstep(0.55, 0.95, heat));
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -view.z / view.w;
	float soft = clamp((scene_z + VERTEX.z) / soft_distance, 0.0, 1.0);
	ALBEDO = color * heat * intensity * COLOR.a * soft;
}
