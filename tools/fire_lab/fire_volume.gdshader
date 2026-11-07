shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_front, depth_test_disabled, shadows_disabled;

// The wall's main mass as real volume: the sim's flame (export_fire_volume.py)
// in a box, looked through by marching each pixel's ray across it, so the
// wall is solid fire from every angle, straight down included. The tile
// repeats along the box's x; its frames sit one after another along the
// texture's depth, `thickness` slices each.

uniform sampler3D volume : filter_linear, repeat_disable;
uniform int frames = 64;
uniform int thickness = 32;
uniform float fps = 24.0;
uniform vec3 box_size = vec3(8.0, 4.4, 1.2);
// One tile's width along the wall, in meters.
uniform float tile_width = 3.3;
uniform int steps = 48;
// Light given off and light blocked per unit flame per meter.
uniform float emission = 2.2;
uniform float absorption = 2.5;
uniform vec3 core_color : source_color = vec3(1.0, 0.85, 0.55);
uniform vec3 body_color : source_color = vec3(1.0, 0.42, 0.08);
uniform vec3 tip_color : source_color = vec3(0.6, 0.07, 0.02);
// Meters the wall's ends fade over.
uniform float end_fade = 1.0;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

varying vec3 v_local;
varying vec3 v_camera;

void vertex() {
	v_local = VERTEX;
	v_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

float flame(vec3 p, float frame) {
	vec3 half_size = box_size * 0.5;
	vec3 q = (p + half_size) / box_size;
	float x = fract((p.x + half_size.x) / tile_width);
	float slab = float(thickness);
	float z = clamp(q.z * slab, 0.5, slab - 0.5);
	return texture(volume, vec3(x, q.y, (frame * slab + z) / (slab * float(frames)))).r;
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
	float position = mod(TIME * fps, float(frames));
	float frame = floor(position);
	float next = mod(frame + 1.0, float(frames));
	float blend = position - frame;
	// Jitter where each ray starts, so the steps don't show as bands.
	float jitter = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	vec3 light = vec3(0.0);
	float transmit = 1.0;
	for (int i = 0; i < steps; i++) {
		vec3 p = v_camera + dir * (t_near + (float(i) + jitter) * step_len);
		float heat = mix(flame(p, frame), flame(p, next), blend);
		heat *= smoothstep(0.0, end_fade, half_size.x - abs(p.x));
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
