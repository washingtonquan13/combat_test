shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_front, depth_test_disabled, shadows_disabled;

// The wall's main mass as a live volume: no bake, the flame is tiling noise
// rising through a box, looked through by marching each pixel's ray across
// it. Big slow noise bends the rising noise so tongues lick and merge; the
// fire needs more of it to burn the higher it goes, so it thins into tongues
// at the top. Any length, height or thickness: it never repeats.

uniform sampler3D noise : filter_linear, repeat_enable;
uniform vec3 box_size = vec3(8.0, 4.4, 1.2);
uniform int steps = 48;
// Meters a second the flame rises.
uniform float rise = 2.2;
// Noise tiles per meter for the tongues: across, up.
uniform vec2 tongue_scale = vec2(0.3, 0.14);
uniform vec2 detail_scale = vec2(0.75, 0.4);
uniform float detail = 0.35;
// Meters the big slow noise bends the tongues by.
uniform float warp = 1.4;
// How much noise the flame needs to burn at its foot and its top.
uniform float foot_threshold = 0.22;
uniform float top_threshold = 0.74;
uniform float contrast = 4.0;
// Share of the box's thickness the fuel fills at the foot and the top.
uniform float foot_depth = 0.85;
uniform float top_depth = 0.35;
// Light given off and light blocked per unit flame per meter.
uniform float emission = 2.2;
uniform float absorption = 2.5;
uniform vec3 core_color : source_color = vec3(1.0, 0.85, 0.55);
uniform vec3 body_color : source_color = vec3(1.0, 0.42, 0.08);
uniform vec3 tip_color : source_color = vec3(0.6, 0.07, 0.02);
// Meters the wall's ends fade over.
uniform float end_fade = 1.0;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

varying vec3 v_camera;
varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
	v_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

float sample_noise(vec3 p) {
	return texture(noise, p).r;
}

float flame(vec3 p, float t) {
	vec3 half_size = box_size * 0.5;
	float y = clamp((p.y + half_size.y) / box_size.y, 0.0, 1.0);
	vec3 slow = p * 0.12 - vec3(0.0, t * rise * 0.07, 0.0);
	vec3 bend = vec3(sample_noise(slow), sample_noise(slow + vec3(0.31, 0.17, 0.53)),
			sample_noise(slow + vec3(0.71, 0.43, 0.11))) - 0.5;
	vec3 w = p + bend * warp * (0.3 + y);
	vec3 up = vec3(0.0, t * rise, 0.0);
	float n = sample_noise((w - up) * tongue_scale.xyx);
	n = mix(n, sample_noise((w - up * 1.6) * detail_scale.xyx + 0.37), detail);
	float half_depth = half_size.z * mix(foot_depth, top_depth, y);
	float body = 1.0 - smoothstep(half_depth * 0.4, half_depth, abs(p.z + bend.x * 0.6));
	float heat = clamp((n - mix(foot_threshold, top_threshold, y)) * contrast * body, 0.0, 1.0);
	// Die out before the box's lid, so no tongue is cut flat.
	heat *= 1.0 - smoothstep(0.7, 0.97, y);
	return heat * smoothstep(0.0, end_fade, half_size.x - abs(p.x));
}

void fragment() {
	vec3 half_size = box_size * 0.5;
	vec3 dir = normalize(v_local - v_camera);
	vec3 inv = 1.0 / dir;
	vec3 t0 = (-half_size - v_camera) * inv;
	vec3 t1 = (half_size - v_camera) * inv;
	vec3 lo = min(t0, t1);
	vec3 hi = max(t0, t1);
	float t_near = max(max(max(lo.x, lo.y), lo.z), 0.0);
	float t_far = min(min(hi.x, hi.y), hi.z);
	// Stop at whatever's in front: the ground, a unit. This is the only
	// depth test - the box's far faces may lie under the ground.
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz / view.w, 1.0)).xyz;
	vec3 scene_local = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	t_far = min(t_far, dot(scene_local - v_camera, dir));
	float step_len = (t_far - t_near) / float(steps);
	if (step_len <= 0.0) {
		discard;
	}
	// Jitter where each ray starts, so the steps don't show as bands.
	float jitter = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	vec3 light = vec3(0.0);
	float transmit = 1.0;
	for (int i = 0; i < steps; i++) {
		vec3 p = v_camera + dir * (t_near + (float(i) + jitter) * step_len);
		float heat = flame(p, TIME);
		if (heat > 0.003) {
			vec3 color = mix(tip_color, body_color, smoothstep(0.05, 0.35, heat));
			color = mix(color, core_color, smoothstep(0.55, 0.95, heat));
			light += transmit * color * heat * emission * step_len;
			transmit *= exp(-heat * absorption * step_len);
			if (transmit < 0.02) {
				break;
			}
		}
	}
	ALBEDO = light;
	ALPHA = 1.0 - transmit;
}
